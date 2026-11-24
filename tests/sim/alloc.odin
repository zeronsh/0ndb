package sim

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:mem"

REGION_BASE :: uintptr(0x2000_0000_0000)
REGION_ALIGN :: uintptr(64 << 20)

region_main_size := uint(256 << 20)
region_temp_size := uint(96 << 20)

region_stride :: proc() -> uintptr {
	total := uintptr(region_main_size + region_temp_size)
	return (total + REGION_ALIGN - 1) & ~(REGION_ALIGN - 1)
}

region_configure :: proc(main_mb, temp_mb: u64) {
	region_main_size = uint(max(main_mb, 16)) << 20
	region_temp_size = uint(max(temp_mb, 8)) << 20
}
HEADER :: 16
MIN_CLASS :: 5
MAX_CLASS :: 40

Region :: struct {
	base:   uintptr,
	size:   uint,
	top:    uintptr,
	free:   [MAX_CLASS + 1]uintptr,
	bump:   bool,
	mapped: bool,
	live:   int,
	bytes:  int,
	peak:   uintptr,
	sites:  ^map[uintptr]runtime.Source_Code_Location,
}

region_map :: proc(r: ^Region, base: uintptr, size: uint, bump: bool) -> (ok: bool, why: string) {
	r^ = {}
	if mok, mwhy := os_region_map(base, size); !mok {
		return false, mwhy
	}
	r.base = base
	r.size = size
	r.top = base
	r.bump = bump
	r.mapped = true
	regions_mapped += 1
	return true, ""
}

region_unmap :: proc(r: ^Region) {
	if r.mapped {
		os_region_unmap(r.base, r.size)
		regions_mapped -= 1
	}
	r^ = {}
}

region_reset :: proc(r: ^Region) {
	if r.top > r.base {
		used := uint(r.top - r.base)
		os_region_discard(r.base, used)
	}
	r.top = r.base
	r.free = {}
	r.live = 0
	r.bytes = 0
}

region_allocator :: proc(r: ^Region) -> runtime.Allocator {
	return runtime.Allocator{procedure = _region_proc, data = r}
}

@(private = "file")
_class_of :: proc "contextless" (n: uint) -> int {
	k := MIN_CLASS
	for (uint(1) << uint(k)) < n {
		k += 1
	}
	return k
}

@(private = "file")
_alloc :: proc(r: ^Region, size: int, alignment: int, zero: bool, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	align := max(alignment, HEADER)
	need := uint(size) + HEADER + uint(align - HEADER)
	if r.bump {
		start := mem.align_forward_uintptr(r.top + HEADER, uintptr(align))
		end := start + uintptr(size)
		if end > r.base + uintptr(r.size) {
			region_exhausted(r, size, loc)
			return nil, .Out_Of_Memory
		}
		r.top = end
		r.peak = max(r.peak, r.top)
		p := rawptr(start)
		if zero && size > 0 {
			intrinsics.mem_zero(p, size)
		}
		return ([^]byte)(p)[:size], nil
	}
	k := _class_of(need)
	if k > MAX_CLASS {
		return nil, .Out_Of_Memory
	}
	bsize := uintptr(1) << uint(k)
	block: uintptr
	if r.free[k] != 0 {
		block = r.free[k]
		r.free[k] = (^uintptr)(block)^
	} else {
		block = mem.align_forward_uintptr(r.top, HEADER)
		if block + bsize > r.base + uintptr(r.size) {
			region_exhausted(r, size, loc)
			return nil, .Out_Of_Memory
		}
		r.top = block + bsize
		r.peak = max(r.peak, r.top)
	}
	ptr := mem.align_forward_uintptr(block + HEADER, uintptr(align))
	hdr := (^[2]u32)(ptr - HEADER)
	hdr[0] = u32(k)
	hdr[1] = u32(ptr - block)
	if zero && size > 0 {
		intrinsics.mem_zero(rawptr(ptr), size)
	}
	r.live += 1
	r.bytes += int(bsize)
	return ([^]byte)(rawptr(ptr))[:size], nil
}

@(private = "file")
_cap :: proc "contextless" (ptr: rawptr) -> int {
	hdr := (^[2]u32)(uintptr(ptr) - HEADER)
	return int((uintptr(1) << uint(hdr[0])) - uintptr(hdr[1]))
}

@(private = "file")
_free :: proc(r: ^Region, ptr: rawptr) {
	if ptr == nil || r.bump {
		return
	}
	p := uintptr(ptr)
	if p < r.base || p >= r.base + uintptr(r.size) {
		return
	}
	hdr := (^[2]u32)(p - HEADER)
	k := int(hdr[0])
	block := p - uintptr(hdr[1])
	(^uintptr)(block)^ = r.free[k]
	r.free[k] = block
	r.live -= 1
	r.bytes -= int(uintptr(1) << uint(k))
}

@(private = "file")
_region_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	r := (^Region)(data)
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		out, err := _alloc(r, size, alignment, mode == .Alloc, loc)
		if r.sites != nil && err == nil {
			r.sites[uintptr(raw_data(out))] = loc
		}
		return out, err
	case .Free:
		if r.sites != nil {
			delete_key(r.sites, uintptr(old_memory))
		}
		_free(r, old_memory)
		return nil, nil
	case .Free_All:
		if r.bump {
			r.top = r.base
			return nil, nil
		}
		return nil, .Mode_Not_Implemented
	case .Resize, .Resize_Non_Zeroed:
		zero := mode == .Resize
		if old_memory == nil {
			return _alloc(r, size, alignment, zero, loc)
		}
		if size == 0 {
			_free(r, old_memory)
			return nil, nil
		}
		if r.bump {
			if uintptr(old_memory) + uintptr(old_size) == r.top && uintptr(old_memory) + uintptr(size) <= r.base + uintptr(r.size) {
				r.top = uintptr(old_memory) + uintptr(size)
				r.peak = max(r.peak, r.top)
				if zero && size > old_size {
					intrinsics.mem_zero(rawptr(uintptr(old_memory) + uintptr(old_size)), size - old_size)
				}
				return ([^]byte)(old_memory)[:size], nil
			}
		} else if size <= _cap(old_memory) && uintptr(old_memory) % uintptr(max(alignment, 1)) == 0 {
			if zero && size > old_size {
				intrinsics.mem_zero(rawptr(uintptr(old_memory) + uintptr(old_size)), size - old_size)
			}
			return ([^]byte)(old_memory)[:size], nil
		}
		out, err := _alloc(r, size, alignment, false, loc)
		if err != nil {
			return nil, err
		}
		if r.sites != nil {
			delete_key(r.sites, uintptr(old_memory))
			r.sites[uintptr(raw_data(out))] = loc
		}
		n := min(old_size, size)
		if n > 0 {
			intrinsics.mem_copy(raw_data(out), old_memory, n)
		}
		if zero && size > n {
			intrinsics.mem_zero(rawptr(uintptr(raw_data(out)) + uintptr(n)), size - n)
		}
		_free(r, old_memory)
		return out, nil
	case .Query_Features:
		set := (^runtime.Allocator_Mode_Set)(old_memory)
		if set != nil {
			set^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Resize, .Resize_Non_Zeroed, .Query_Features}
			if r.bump {
				set^ += {.Free_All}
			}
		}
		return nil, nil
	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	return nil, nil
}

region_exhausted :: proc(r: ^Region, size: int, loc: runtime.Source_Code_Location) {
	if r.size == 0 {
		fmt.eprintf("sim: allocation of %d bytes through an unmapped region (an instance that was killed or never started) at %v\n", size, loc)
		return
	}
	slot := int((r.base - REGION_BASE) / region_stride())
	fmt.eprintf("sim: memory region exhausted: slot %d %s region (%d MiB) cannot satisfy %d bytes at %v; live=%d blocks, %d MiB in use (raise SIM_REGION_MB / SIM_TEMP_MB)\n", slot, "temp" if r.bump else "main", r.size >> 20, size, loc, r.live, r.bytes >> 20)
}
