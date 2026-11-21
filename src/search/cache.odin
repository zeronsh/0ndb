package search

import "base:runtime"
import "../prim"

PAGE :: 4096
WAYS :: 4

Cache :: struct {
	sets:      int,
	pages:     []u8,
	gens:      []u64,
	nos:       []i64,
	lens:      []u16,
	ticks:     []u32,
	clock:     u32,
	allocator: runtime.Allocator,
}

cache_init :: proc(c: ^Cache, pages: int, allocator := context.allocator) -> Error {
	n := max(pages, WAYS)
	n = (n + WAYS - 1) / WAYS * WAYS
	c^ = {
		sets      = n / WAYS,
		allocator = allocator,
	}
	err: runtime.Allocator_Error
	c.pages, err = make([]u8, n * PAGE, allocator)
	if err != nil {
		return .No_Memory
	}
	c.gens, err = make([]u64, n, allocator)
	if err != nil {
		cache_destroy(c)
		return .No_Memory
	}
	c.nos, err = make([]i64, n, allocator)
	if err != nil {
		cache_destroy(c)
		return .No_Memory
	}
	c.lens, err = make([]u16, n, allocator)
	if err != nil {
		cache_destroy(c)
		return .No_Memory
	}
	c.ticks, err = make([]u32, n, allocator)
	if err != nil {
		cache_destroy(c)
		return .No_Memory
	}
	return .None
}

cache_destroy :: proc(c: ^Cache) {
	delete(c.pages, c.allocator)
	delete(c.gens, c.allocator)
	delete(c.nos, c.allocator)
	delete(c.lens, c.allocator)
	delete(c.ticks, c.allocator)
	c^ = {}
}

cache_clear :: proc "contextless" (c: ^Cache) {
	for &g in c.gens {
		g = 0
	}
}

cache_drop :: proc "contextless" (c: ^Cache, gen: u64) {
	for &g in c.gens {
		if g == gen + 1 {
			g = 0
		}
	}
}

@(private)
_cache_page :: proc(c: ^Cache, s: ^Seg, no: i64) -> (page: []u8, err: Error) {
	h := (u64(no) * 0x9E3779B97F4A7C15 ~ s.gen * 0xC2B2AE3D27D4EB4F) >> 17
	set := int(h % u64(c.sets))
	base := set * WAYS
	c.clock += 1
	victim := base
	for w in 0 ..< WAYS {
		i := base + w
		if c.gens[i] == s.gen + 1 && c.nos[i] == no {
			c.ticks[i] = c.clock
			return c.pages[i * PAGE:][:c.lens[i]], .None
		}
		if c.gens[victim] != 0 && (c.gens[i] == 0 || c.ticks[i] < c.ticks[victim]) {
			victim = i
		}
	}
	buf := c.pages[victim * PAGE:][:PAGE]
	c.gens[victim] = 0
	n, rerr := prim.read_at(s.vfs, s.fd, buf, no * PAGE)
	if rerr != .None {
		return nil, _perr(rerr)
	}
	c.gens[victim] = s.gen + 1
	c.nos[victim] = no
	c.lens[victim] = u16(n)
	c.ticks[victim] = c.clock
	return buf[:n], .None
}

cache_read :: proc(c: ^Cache, s: ^Seg, off: i64, dst: []u8) -> Error {
	if off < 0 || off + i64(len(dst)) > s.size {
		return .Corrupt
	}
	if len(dst) > 4 * PAGE {
		n, err := prim.read_at(s.vfs, s.fd, dst, off)
		if err != .None {
			return _perr(err)
		}
		if n != len(dst) {
			return .Corrupt
		}
		return .None
	}
	done := 0
	for done < len(dst) {
		at := off + i64(done)
		no := at / PAGE
		page := _cache_page(c, s, no) or_return
		in_page := int(at - no * PAGE)
		if in_page >= len(page) {
			return .Corrupt
		}
		done += copy(dst[done:], page[in_page:])
	}
	return .None
}
