#+build linux, darwin
package fs

import "core:c"
import "core:strings"
import "core:sys/posix"

when ODIN_OS == .Darwin {
	foreign import iconv_lib "system:iconv"
} else {
	foreign import iconv_lib "system:c"
}

@(private)
@(default_calling_convention = "c")
foreign iconv_lib {
	iconv_open :: proc(to, from: cstring) -> rawptr ---
	iconv :: proc(cd: rawptr, inbuf: ^[^]u8, inleft: ^c.size_t, outbuf: ^[^]u8, outleft: ^c.size_t) -> c.size_t ---
	iconv_close :: proc(cd: rawptr) -> c.int ---
}

@(private)
Xcode :: struct {
	cd: rawptr,
}

@(private)
xcode_open :: proc(to, from: string) -> (x: Xcode, ok: bool) {
	t := strings.clone_to_cstring(to, context.temp_allocator)
	f := strings.clone_to_cstring(from, context.temp_allocator)
	cd := iconv_open(t, f)
	if cd == nil || uintptr(cd) == max(uintptr) {
		return {}, false
	}
	return Xcode{cd}, true
}

@(private)
xcode_close :: proc(x: ^Xcode) {
	if x.cd != nil {
		iconv_close(x.cd)
		x.cd = nil
	}
}

@(private)
xcode_step :: proc(x: ^Xcode, src: []u8, dst: []u8, final := false) -> (used, made: int, st: Xcode_Status) {
	if len(src) == 0 {
		return 0, 0, .Ok
	}
	inp := ([^]u8)(raw_data(src))
	inl := c.size_t(len(src))
	outp := ([^]u8)(raw_data(dst))
	outl := c.size_t(len(dst))
	r := iconv(x.cd, &inp, &inl, &outp, &outl)
	used = len(src) - int(inl)
	made = len(dst) - int(outl)
	if r != max(c.size_t) {
		return used, made, .Ok
	}
	#partial switch posix.errno() {
	case .E2BIG:
		return used, made, .Full
	case .EINVAL:
		return used, made, .Incomplete
	}
	return used, made, .Invalid
}

@(private)
xcode_finish :: proc(x: ^Xcode, dst: []u8) -> (made: int, st: Xcode_Status) {
	outp := ([^]u8)(raw_data(dst))
	outl := c.size_t(len(dst))
	r := iconv(x.cd, nil, nil, &outp, &outl)
	made = len(dst) - int(outl)
	if r != max(c.size_t) {
		return made, .Ok
	}
	if posix.errno() == .E2BIG {
		return made, .Full
	}
	return made, .Invalid
}
