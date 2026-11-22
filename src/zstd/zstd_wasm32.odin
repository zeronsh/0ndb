#+build wasm32
package zstd

import "base:runtime"

@(private = "file")
HEAD :: 16

@(require, linkage = "strong", link_name = "ozstd_malloc")
ozstd_malloc :: proc "c" (size: uint) -> rawptr {
	return _alloc(size, false)
}

@(require, linkage = "strong", link_name = "ozstd_calloc")
ozstd_calloc :: proc "c" (n, size: uint) -> rawptr {
	if size != 0 && n > (max(uint) - HEAD) / size {
		return nil
	}
	return _alloc(n * size, true)
}

@(require, linkage = "strong", link_name = "ozstd_free")
ozstd_free :: proc "c" (p: rawptr) {
	if p == nil {
		return
	}
	context = runtime.default_context()
	base := rawptr(uintptr(p) - HEAD)
	runtime.mem_free_with_size(base, int((^uint)(base)^) + HEAD)
}

@(private = "file")
_alloc :: proc "c" (size: uint, zero: bool) -> rawptr {
	if size > uint(max(int)) - HEAD {
		return nil
	}
	context = runtime.default_context()
	b: []u8
	err: runtime.Allocator_Error
	if zero {
		b, err = runtime.mem_alloc(int(size) + HEAD, HEAD)
	} else {
		b, err = runtime.mem_alloc_non_zeroed(int(size) + HEAD, HEAD)
	}
	if err != nil || b == nil {
		return nil
	}
	(^uint)(raw_data(b))^ = size
	return rawptr(uintptr(raw_data(b)) + HEAD)
}
