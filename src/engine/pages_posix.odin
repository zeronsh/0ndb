#+build darwin, linux
package engine

import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "core:sync"
import "core:sys/posix"

@(private)
PAGE_CHUNK :: 256 * 1024
@(private)
PAGE_HEAD :: 4096
@(private)
PAGE_LARGE :: 32 * 1024
@(private)
PAGE_CLASSES := [?]int{16, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096, 6144, 8192, 12288, 16384, 24576, 32768}

@(private)
Page_Chunk :: struct {
	next:    ^Page_Chunk,
	prev:    ^Page_Chunk,
	class:   i32,
	large:   bool,
	full:    bool,
	live:    int,
	gone:    [8]u64,
	bump:    int,
	free:    rawptr,
	size:    int,
}

Page_Heap :: struct {
	mu:      sync.Mutex,
	on:      bool,
	lists:   [len(PAGE_CLASSES)]^Page_Chunk,
	larges:  ^Page_Chunk,
	mapped:  int,
}

@(private)
_pages_init :: proc(h: ^Page_Heap) {
	h^ = {}
	h.on = true
}

@(private)
_pages_allocator :: proc(h: ^Page_Heap) -> runtime.Allocator {
	return runtime.Allocator{procedure = _pages_proc, data = h}
}

@(private)
_pages_map :: proc(h: ^Page_Heap, size: int) -> ^Page_Chunk {
	total := size + PAGE_CHUNK
	p := posix.mmap(nil, uint(total), {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS}, -1, 0)
	if p == posix.MAP_FAILED {
		return nil
	}
	base := uintptr(p)
	aligned := (base + PAGE_CHUNK - 1) & ~uintptr(PAGE_CHUNK - 1)
	if aligned > base {
		posix.munmap(p, uint(aligned - base))
	}
	tail := base + uintptr(total) - (aligned + uintptr(size))
	if tail > 0 {
		posix.munmap(rawptr(aligned + uintptr(size)), uint(tail))
	}
	h.mapped += size
	c := (^Page_Chunk)(aligned)
	c^ = {}
	c.size = size
	return c
}

@(private)
_pages_unmap :: proc(h: ^Page_Heap, c: ^Page_Chunk) {
	h.mapped -= c.size
	posix.munmap(rawptr(c), uint(c.size))
}

@(private)
_pages_class :: proc(size: int, align: int) -> int {
	for s, i in PAGE_CLASSES {
		if s >= size && s % align == 0 {
			return i
		}
	}
	return -1
}

@(private)
_pages_link :: proc(head: ^^Page_Chunk, c: ^Page_Chunk) {
	c.prev = nil
	c.next = head^
	if head^ != nil {
		head^.prev = c
	}
	head^ = c
}

@(private)
_pages_unlink :: proc(head: ^^Page_Chunk, c: ^Page_Chunk) {
	if c.prev != nil {
		c.prev.next = c.next
	} else if head^ == c {
		head^ = c.next
	}
	if c.next != nil {
		c.next.prev = c.prev
	}
	c.next = nil
	c.prev = nil
}

@(private)
_pages_alloc :: proc(h: ^Page_Heap, size: int, align: int) -> rawptr {
	a := max(align, 16)
	ci := _pages_class(size, a) if size <= PAGE_LARGE && a <= PAGE_HEAD else -1
	if ci < 0 {
		need := (PAGE_HEAD + size + PAGE_HEAD - 1) & ~int(PAGE_HEAD - 1)
		c := _pages_map(h, need)
		if c == nil {
			return nil
		}
		c.large = true
		c.class = -1
		_pages_link(&h.larges, c)
		return rawptr(uintptr(c) + PAGE_HEAD)
	}
	c := h.lists[ci]
	for c != nil && c.full {
		c = c.next
	}
	if c == nil {
		c = _pages_map(h, PAGE_CHUNK)
		if c == nil {
			return nil
		}
		c.class = i32(ci)
		c.bump = PAGE_HEAD
		_pages_link(&h.lists[ci], c)
	}
	slot := PAGE_CLASSES[ci]
	if c.free == nil && c.gone != {} {
		_pages_reclaim(c, slot)
	}
	p: rawptr
	if c.free != nil {
		p = c.free
		c.free = (^rawptr)(p)^
	} else {
		p = rawptr(uintptr(c) + uintptr(c.bump))
		c.bump += slot
	}
	c.live += 1
	if c.free == nil && c.bump + slot > PAGE_CHUNK && c.gone == {} {
		c.full = true
	}
	intrinsics.mem_zero(p, slot)
	return p
}

@(private)
_pages_chunk :: proc(p: rawptr) -> ^Page_Chunk {
	return (^Page_Chunk)(uintptr(p) & ~uintptr(PAGE_CHUNK - 1))
}

@(private)
_pages_size :: proc(p: rawptr) -> int {
	c := _pages_chunk(p)
	if c.large {
		return c.size - PAGE_HEAD
	}
	return PAGE_CLASSES[c.class]
}

@(private)
_pages_free :: proc(h: ^Page_Heap, p: rawptr) {
	if p == nil {
		return
	}
	c := _pages_chunk(p)
	if c.large {
		_pages_unlink(&h.larges, c)
		_pages_unmap(h, c)
		return
	}
	(^rawptr)(p)^ = c.free
	c.free = p
	c.live -= 1
	c.full = false
}

@(private)
_pages_release :: proc(h: ^Page_Heap) {
	if !h.on {
		return
	}
	sync.mutex_lock(&h.mu)
	defer sync.mutex_unlock(&h.mu)
	for &head in h.lists {
		c := head
		for c != nil {
			next := c.next
			if c.live == 0 {
				_pages_unlink(&head, c)
				_pages_unmap(h, c)
			} else {
				_pages_advise_free(c)
			}
			c = next
		}
	}
}

@(private)
_pages_page :: proc() -> int {
	page := int(posix.sysconf(._PAGESIZE))
	if page <= 0 || PAGE_CHUNK / page > 512 {
		return 0
	}
	return page
}

@(private)
_pages_advise_free :: proc(c: ^Page_Chunk) {
	slot := PAGE_CLASSES[c.class]
	page := _pages_page()
	if page == 0 || c.free == nil {
		return
	}
	first_page := PAGE_HEAD / page
	last_page := (c.bump + page - 1) / page
	if last_page <= first_page {
		return
	}
	used := make([]bool, last_page, context.temp_allocator)
	free_set := make(map[uintptr]bool, context.temp_allocator)
	for f := c.free; f != nil; f = (^rawptr)(f)^ {
		free_set[uintptr(f)] = true
	}
	base := uintptr(c)
	for off := PAGE_HEAD; off + slot <= c.bump; off += slot {
		if free_set[base + uintptr(off)] {
			continue
		}
		for k in off / page ..= (off + slot - 1) / page {
			used[k] = true
		}
	}
	for k in 0 ..< first_page {
		used[k] = true
	}
	if PAGE_HEAD % page != 0 {
		used[PAGE_HEAD / page] = true
	}
	any := false
	for k in first_page ..< last_page {
		if !used[k] && c.gone[k / 64] & (u64(1) << u64(k % 64)) == 0 {
			_pages_discard(rawptr(base + uintptr(k * page)), page)
			c.gone[k / 64] |= u64(1) << u64(k % 64)
			any = true
		}
	}
	if !any {
		return
	}
	c.free = nil
	for off := c.bump - slot; off >= PAGE_HEAD; off -= slot {
		a := base + uintptr(off)
		if !free_set[a] || _pages_touches_gone(c, off, slot, page) {
			continue
		}
		(^rawptr)(rawptr(a))^ = c.free
		c.free = rawptr(a)
	}
}

@(private)
_pages_touches_gone :: proc(c: ^Page_Chunk, off: int, slot: int, page: int) -> bool {
	for k in off / page ..= (off + slot - 1) / page {
		if c.gone[k / 64] & (u64(1) << u64(k % 64)) != 0 {
			return true
		}
	}
	return false
}

@(private)
_pages_reclaim :: proc(c: ^Page_Chunk, slot: int) {
	page := _pages_page()
	if page == 0 {
		c.gone = {}
		return
	}
	base := uintptr(c)
	for k in 0 ..< len(c.gone) * 64 {
		if c.gone[k / 64] & (u64(1) << u64(k % 64)) != 0 {
			_pages_reuse(rawptr(base + uintptr(k * page)), page)
		}
	}
	for off := c.bump - slot; off >= PAGE_HEAD; off -= slot {
		if _pages_touches_gone(c, off, slot, page) {
			a := base + uintptr(off)
			(^rawptr)(rawptr(a))^ = c.free
			c.free = rawptr(a)
		}
	}
	c.gone = {}
}

@(private)
_pages_destroy :: proc(h: ^Page_Heap) {
	if !h.on {
		return
	}
	for &head in h.lists {
		for head != nil {
			c := head
			_pages_unlink(&head, c)
			_pages_unmap(h, c)
		}
	}
	for h.larges != nil {
		c := h.larges
		_pages_unlink(&h.larges, c)
		_pages_unmap(h, c)
	}
	h.on = false
}

@(private)
_pages_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	h := (^Page_Heap)(data)
	sync.mutex_lock(&h.mu)
	defer sync.mutex_unlock(&h.mu)
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		if size == 0 {
			return nil, nil
		}
		p := _pages_alloc(h, size, alignment)
		if p == nil {
			return nil, .Out_Of_Memory
		}
		return mem.byte_slice(p, size), nil
	case .Free:
		_pages_free(h, old_memory)
		return nil, nil
	case .Resize, .Resize_Non_Zeroed:
		if old_memory == nil {
			if size == 0 {
				return nil, nil
			}
			p := _pages_alloc(h, size, alignment)
			if p == nil {
				return nil, .Out_Of_Memory
			}
			return mem.byte_slice(p, size), nil
		}
		if size == 0 {
			_pages_free(h, old_memory)
			return nil, nil
		}
		cap := _pages_size(old_memory)
		if size <= cap && uintptr(old_memory) % uintptr(max(alignment, 1)) == 0 {
			if size > old_size && mode == .Resize {
				intrinsics.mem_zero(rawptr(uintptr(old_memory) + uintptr(old_size)), size - old_size)
			}
			return mem.byte_slice(old_memory, size), nil
		}
		p := _pages_alloc(h, size, alignment)
		if p == nil {
			return nil, .Out_Of_Memory
		}
		intrinsics.mem_copy_non_overlapping(p, old_memory, min(old_size, size))
		_pages_free(h, old_memory)
		return mem.byte_slice(p, size), nil
	case .Free_All:
		return nil, .Mode_Not_Implemented
	case .Query_Features:
		set := (^runtime.Allocator_Mode_Set)(old_memory)
		if set != nil {
			set^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Resize, .Resize_Non_Zeroed, .Query_Features}
		}
		return nil, nil
	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	return nil, nil
}
