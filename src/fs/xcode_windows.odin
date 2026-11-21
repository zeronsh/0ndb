package fs

import "base:runtime"
import "core:strings"
import "core:sync"
import win "core:sys/windows"
import "../prim"

foreign import kernel32_xcode "system:Kernel32.lib"

@(private)
@(default_calling_convention = "system")
foreign kernel32_xcode {
	@(link_name = "GetCPInfo")
	xc_get_cp_info :: proc(cp: u32, info: ^Cp_Info) -> win.BOOL ---
	@(link_name = "IsDBCSLeadByteEx")
	xc_is_lead :: proc(cp: u32, b: u8) -> win.BOOL ---
	@(link_name = "IsValidCodePage")
	xc_valid_cp :: proc(cp: u32) -> win.BOOL ---
}

@(private)
Cp_Info :: struct {
	max_char:     u32,
	default_char: [2]u8,
	lead:         [12]u8,
}

@(private)
Iconv_Open_Proc :: #type proc "c" (to, from: cstring) -> rawptr
@(private)
Iconv_Proc :: #type proc "c" (cd: rawptr, inbuf: ^[^]u8, inleft: ^uint, outbuf: ^[^]u8, outleft: ^uint) -> uint
@(private)
Iconv_Close_Proc :: #type proc "c" (cd: rawptr) -> i32

@(private)
Git_Iconv :: struct {
	once:   sync.Once,
	ok:     bool,
	open:   Iconv_Open_Proc,
	conv:   Iconv_Proc,
	close:  Iconv_Close_Proc,
	module: win.HMODULE,
}

@(private)
git_iconv: Git_Iconv

@(private)
git_iconv_load :: proc() {
	sync.once_do(&git_iconv.once, proc() {
		pbuf: [prim.PATH_MAX]u8
		prefix, ok := git_prefix(pbuf[:])
		if !ok {
			return
		}
		for sub in ([]string{"mingw64\\bin", "clangarm64\\bin", "mingw32\\bin", "bin", ""}) {
			dbuf: prim.Path_Buf
			dir := prefix
			if len(sub) > 0 {
				d, dok := path_join_buf(dbuf[:], prefix, sub)
				if !dok {
					continue
				}
				dir = d
			}
			fbuf: prim.Path_Buf
			p, pok := path_join_buf(fbuf[:], dir, "libiconv-2.dll")
			if !pok || !prim.exists(prim.os_vfs(), p) {
				continue
			}
			wide := win.utf8_to_wstring(p, context.temp_allocator)
			h := win.LoadLibraryExW(wide, nil, {.LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR, .LOAD_LIBRARY_SEARCH_SYSTEM32})
			if h == nil {
				continue
			}
			o := win.GetProcAddress(h, "libiconv_open")
			c := win.GetProcAddress(h, "libiconv")
			x := win.GetProcAddress(h, "libiconv_close")
			if o == nil || c == nil || x == nil {
				win.FreeLibrary(h)
				continue
			}
			git_iconv.open = Iconv_Open_Proc(o)
			git_iconv.conv = Iconv_Proc(c)
			git_iconv.close = Iconv_Close_Proc(x)
			git_iconv.module = h
			git_iconv.ok = true
			return
		}
	})
}

@(private)
Xcode_Kind :: enum u8 {
	None,
	Iconv,
	Cp_Decode,
	Cp_Encode,
	Utf_Decode,
	Utf_Encode,
}

@(private)
Cp_Split :: enum u8 {
	Any,
	Dbcs,
	Gb18030,
	Line,
}

@(private)
Xcode :: struct {
	kind:     Xcode_Kind,
	cd:       rawptr,
	cp:       u32,
	split:    Cp_Split,
	strict:   bool,
	width:    int,
	le:       bool,
	detect:   bool,
	bom:      bool,
	started:  bool,
	pend:     [dynamic]u8,
	pend_off: int,
	wide:     [dynamic]u16,
}

@(private)
XCODE_SLICE :: 64 << 10

@(private)
xcode_open :: proc(to, from: string) -> (x: Xcode, ok: bool) {
	git_iconv_load()
	if git_iconv.ok {
		t := strings.clone_to_cstring(to, context.temp_allocator)
		f := strings.clone_to_cstring(from, context.temp_allocator)
		cd := git_iconv.open(t, f)
		if cd == nil || uintptr(cd) == max(uintptr) {
			return {}, false
		}
		return Xcode{kind = .Iconv, cd = cd}, true
	}
	encode := enc_is_utf8(from)
	if !encode && !enc_is_utf8(to) {
		return {}, false
	}
	name := to if encode else from
	if enc_is_utf8(name) {
		return {}, false
	}
	alloc := runtime.heap_allocator()
	x.pend = make([dynamic]u8, alloc)
	x.wide = make([dynamic]u16, alloc)
	if width, le, detect, uok := utf_kind(name); uok {
		x.kind = .Utf_Encode if encode else .Utf_Decode
		x.width = width
		x.le = le
		x.detect = detect
		x.bom = detect
		return x, true
	}
	cp := cp_lookup(name)
	if cp == 0 || !xc_valid_cp(cp) {
		delete(x.pend)
		delete(x.wide)
		return {}, false
	}
	x.kind = .Cp_Encode if encode else .Cp_Decode
	x.cp = cp
	x.strict = cp_strict(cp)
	info: Cp_Info
	switch {
	case !x.strict || cp == 52936:
		x.split = .Line
	case cp == 54936:
		x.split = .Gb18030
	case xc_get_cp_info(cp, &info) && info.max_char == 1:
		x.split = .Any
	case info.max_char == 2:
		x.split = .Dbcs
	case:
		x.split = .Line
	}
	return x, true
}

@(private)
xcode_close :: proc(x: ^Xcode) {
	if x.kind == .Iconv && x.cd != nil {
		git_iconv.close(x.cd)
	}
	delete(x.pend)
	delete(x.wide)
	x^ = {}
}

@(private)
xcode_step :: proc(x: ^Xcode, src: []u8, dst: []u8, final := false) -> (used, made: int, st: Xcode_Status) {
	if x.kind == .Iconv {
		if len(src) == 0 {
			return 0, 0, .Ok
		}
		inp := ([^]u8)(raw_data(src))
		inl := uint(len(src))
		outp := ([^]u8)(raw_data(dst))
		outl := uint(len(dst))
		r := git_iconv.conv(x.cd, &inp, &inl, &outp, &outl)
		used = len(src) - int(inl)
		made = len(dst) - int(outl)
		switch {
		case r != max(uint):
			return used, made, .Ok
		case outl < 32:
			return used, made, .Full
		case inl < 16 && !final:
			return used, made, .Incomplete
		}
		return used, made, .Invalid
	}
	for {
		if x.pend_off < len(x.pend) {
			n := copy(dst[made:], x.pend[x.pend_off:])
			made += n
			x.pend_off += n
			if x.pend_off < len(x.pend) {
				return used, made, .Full
			}
			clear(&x.pend)
			x.pend_off = 0
		}
		if used == len(src) {
			return used, made, .Ok
		}
		n, ok := fallback_convert(x, src[used:], final)
		if !ok {
			return used, made, .Invalid
		}
		if n == 0 {
			return used, made, .Incomplete
		}
		used += n
	}
}

@(private)
xcode_finish :: proc(x: ^Xcode, dst: []u8) -> (made: int, st: Xcode_Status) {
	if x.kind == .Iconv {
		outp := ([^]u8)(raw_data(dst))
		outl := uint(len(dst))
		r := git_iconv.conv(x.cd, nil, nil, &outp, &outl)
		made = len(dst) - int(outl)
		if r != max(uint) {
			return made, .Ok
		}
		return made, .Full if outl < 32 else .Invalid
	}
	_, made, st = xcode_step(x, nil, dst, true)
	return
}

@(private)
utf_kind :: proc(name: string) -> (width: int, le: bool, detect: bool, ok: bool) {
	n := enc_norm(name)
	switch n {
	case "UTF16":
		return 2, false, true, true
	case "UTF16LE":
		return 2, true, false, true
	case "UTF16BE":
		return 2, false, false, true
	case "UTF32":
		return 4, false, true, true
	case "UTF32LE":
		return 4, true, false, true
	case "UTF32BE":
		return 4, false, false, true
	}
	return
}

@(private)
enc_norm :: proc(name: string) -> string {
	b := make([]u8, len(name), context.temp_allocator)
	n := 0
	for c in transmute([]u8)name {
		switch c {
		case '-', '_', ' ':
			continue
		case 'a' ..= 'z':
			b[n] = c - 32
		case:
			b[n] = c
		}
		n += 1
	}
	return string(b[:n])
}

@(private)
cp_lookup :: proc(name: string) -> u32 {
	n := enc_norm(name)
	switch n {
	case "ASCII", "USASCII", "ANSIX3.41968", "646", "ISO646US":
		return 20127
	case "LATIN1", "L1":
		return 28591
	case "LATIN2", "L2":
		return 28592
	case "LATIN3", "L3":
		return 28593
	case "LATIN4", "L4":
		return 28594
	case "CYRILLIC":
		return 28595
	case "ARABIC":
		return 28596
	case "GREEK":
		return 28597
	case "HEBREW":
		return 28598
	case "LATIN5", "L5":
		return 28599
	case "LATIN7", "L7":
		return 28603
	case "LATIN9", "L9":
		return 28605
	case "SHIFTJIS", "SJIS", "MSKANJI", "CSSHIFTJIS", "WINDOWS31J":
		return 932
	case "EUCJP":
		return 20932
	case "EUCKR":
		return 51949
	case "EUCCN", "GB2312", "GBK":
		return 936
	case "GB18030":
		return 54936
	case "HZGB2312", "HZ":
		return 52936
	case "BIG5", "BIGFIVE", "CNBIG5":
		return 950
	case "KOI8R":
		return 20866
	case "KOI8U":
		return 21866
	case "UTF7":
		return 65000
	case "ISO2022JP":
		return 50220
	case "ISO2022KR":
		return 50225
	case "MACINTOSH", "MAC", "MACROMAN":
		return 10000
	case "TIS620":
		return 874
	}
	prefixes := [?]string{"ISO8859", "WINDOWS", "CP", "IBM", "MS"}
	for p in prefixes {
		if len(n) <= len(p) || n[:len(p)] != p {
			continue
		}
		v: u32
		for c in transmute([]u8)n[len(p):] {
			if c < '0' || c > '9' {
				return 0
			}
			v = v * 10 + u32(c - '0')
			if v > 65535 {
				return 0
			}
		}
		if p == "ISO8859" {
			switch v {
			case 1 ..= 9:
				return 28590 + v
			case 13:
				return 28603
			case 15:
				return 28605
			}
			return 0
		}
		return v
	}
	return 0
}

@(private)
cp_strict :: proc "contextless" (cp: u32) -> bool {
	switch cp {
	case 42, 50220, 50221, 50222, 50225, 50227, 50229, 57002 ..= 57011, 65000:
		return false
	}
	return true
}

@(private)
fallback_convert :: proc(x: ^Xcode, src: []u8, final: bool) -> (used: int, ok: bool) {
	switch x.kind {
	case .Utf_Decode:
		return utf_decode(x, src, final)
	case .Utf_Encode:
		return utf_encode(x, src, final)
	case .Cp_Decode:
		n := cp_complete(x, src, final)
		if n == 0 {
			return 0, true
		}
		return n, cp_decode(x, src[:n])
	case .Cp_Encode:
		n := len(src)
		if x.split == .Line && !final {
			n = line_complete(src)
		} else if !final {
			n = utf8_complete(src[:min(len(src), XCODE_SLICE)])
		}
		if n == 0 {
			return 0, true
		}
		return n, cp_encode(x, src[:n])
	case .None, .Iconv:
	}
	return 0, false
}

@(private)
line_complete :: proc "contextless" (src: []u8) -> int {
	for i := len(src) - 1; i >= 0; i -= 1 {
		if src[i] == '\n' {
			return i + 1
		}
	}
	return 0
}

@(private)
utf8_complete :: proc "contextless" (src: []u8) -> int {
	n := len(src)
	for k := 1; k <= 4 && k <= n; k += 1 {
		c := src[n - k]
		if c & 0xC0 == 0x80 {
			continue
		}
		need := 1
		switch {
		case c & 0xE0 == 0xC0:
			need = 2
		case c & 0xF0 == 0xE0:
			need = 3
		case c & 0xF8 == 0xF0:
			need = 4
		}
		return n if need <= k else n - k
	}
	return n
}

@(private)
cp_complete :: proc(x: ^Xcode, src: []u8, final: bool) -> int {
	if final {
		return len(src)
	}
	s := src[:min(len(src), XCODE_SLICE)]
	switch x.split {
	case .Any:
		return len(s)
	case .Line:
		return line_complete(src)
	case .Dbcs:
		i := 0
		for i < len(s) {
			if xc_is_lead(x.cp, s[i]) {
				if i + 1 >= len(s) {
					return i
				}
				i += 2
			} else {
				i += 1
			}
		}
		return len(s)
	case .Gb18030:
		i := 0
		for i < len(s) {
			c := s[i]
			if c < 0x81 || c == 0xFF {
				i += 1
				continue
			}
			if i + 1 >= len(s) {
				return i
			}
			if s[i + 1] >= 0x30 && s[i + 1] <= 0x39 {
				if i + 3 >= len(s) {
					return i
				}
				i += 4
			} else {
				i += 2
			}
		}
		return len(s)
	}
	return len(s)
}

@(private)
cp_decode :: proc(x: ^Xcode, src: []u8) -> bool {
	flags: u32 = win.MB_ERR_INVALID_CHARS if x.strict else 0
	wn := win.MultiByteToWideChar(x.cp, flags, raw_data(src), i32(len(src)), nil, 0)
	if wn <= 0 {
		return false
	}
	resize(&x.wide, int(wn))
	if win.MultiByteToWideChar(x.cp, flags, raw_data(src), i32(len(src)), raw_data(x.wide), wn) != wn {
		return false
	}
	return wide_to_pend(x, win.CP_UTF8, 0, false)
}

@(private)
cp_encode :: proc(x: ^Xcode, src: []u8) -> bool {
	wn := win.MultiByteToWideChar(win.CP_UTF8, win.MB_ERR_INVALID_CHARS, raw_data(src), i32(len(src)), nil, 0)
	if wn <= 0 {
		return false
	}
	resize(&x.wide, int(wn))
	if win.MultiByteToWideChar(win.CP_UTF8, win.MB_ERR_INVALID_CHARS, raw_data(src), i32(len(src)), raw_data(x.wide), wn) != wn {
		return false
	}
	flags: u32 = 0x400 if x.strict && x.cp != 54936 else 0
	return wide_to_pend(x, x.cp, flags, x.strict && x.cp != 54936)
}

@(private)
wide_to_pend :: proc(x: ^Xcode, cp: u32, flags: u32, check: bool) -> bool {
	used_default: win.BOOL
	pu: ^win.BOOL = &used_default if check else nil
	wn := i32(len(x.wide))
	n := win.WideCharToMultiByte(cp, flags, cstring16(raw_data(x.wide)), wn, nil, 0, nil, pu)
	if n <= 0 || used_default {
		return false
	}
	base := len(x.pend)
	resize(&x.pend, base + int(n))
	if win.WideCharToMultiByte(cp, flags, cstring16(raw_data(x.wide)), wn, raw_data(x.pend[base:]), n, nil, pu) != n || used_default {
		return false
	}
	return true
}

@(private)
utf_unit :: proc "contextless" (b: []u8, width: int, le: bool) -> u32 {
	if width == 2 {
		return u32(b[0]) | u32(b[1]) << 8 if le else u32(b[1]) | u32(b[0]) << 8
	}
	if le {
		return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
	}
	return u32(b[3]) | u32(b[2]) << 8 | u32(b[1]) << 16 | u32(b[0]) << 24
}

@(private)
utf_put :: proc(out: ^[dynamic]u8, v: u32, width: int, le: bool) {
	if width == 2 {
		if le {
			append(out, u8(v), u8(v >> 8))
		} else {
			append(out, u8(v >> 8), u8(v))
		}
		return
	}
	if le {
		append(out, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
	} else {
		append(out, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))
	}
}

@(private)
utf8_put :: proc(out: ^[dynamic]u8, cp: u32) {
	switch {
	case cp < 0x80:
		append(out, u8(cp))
	case cp < 0x800:
		append(out, u8(0xC0 | cp >> 6), u8(0x80 | cp & 0x3F))
	case cp < 0x10000:
		append(out, u8(0xE0 | cp >> 12), u8(0x80 | (cp >> 6) & 0x3F), u8(0x80 | cp & 0x3F))
	case:
		append(out, u8(0xF0 | cp >> 18), u8(0x80 | (cp >> 12) & 0x3F), u8(0x80 | (cp >> 6) & 0x3F), u8(0x80 | cp & 0x3F))
	}
}

@(private)
utf_decode :: proc(x: ^Xcode, src: []u8, final: bool) -> (used: int, ok: bool) {
	w := x.width
	s := src[:min(len(src), XCODE_SLICE)]
	i := 0
	if x.detect && !x.started {
		if len(s) < w {
			return 0, !final || len(s) == 0
		}
		first := utf_unit(s, w, false)
		if (w == 2 && first == 0xFEFF) || (w == 4 && first == 0x0000FEFF) {
			x.le = false
			i = w
		} else if (w == 2 && first == 0xFFFE) || (w == 4 && first == 0xFFFE0000) {
			x.le = true
			i = w
		}
		x.started = true
	}
	for i + w <= len(s) {
		cp := utf_unit(s[i:], w, x.le)
		step := w
		if w == 2 && cp >= 0xD800 && cp < 0xDC00 {
			if i + 4 > len(s) {
				break
			}
			lo := utf_unit(s[i + 2:], 2, x.le)
			if lo < 0xDC00 || lo >= 0xE000 {
				return i, false
			}
			cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
			step = 4
		} else if (cp >= 0xD800 && cp < 0xE000) || cp > 0x10FFFF {
			return i, false
		}
		utf8_put(&x.pend, cp)
		i += step
	}
	if final && i < len(src) && len(s) == len(src) {
		return i, false
	}
	return i, true
}

@(private)
utf_encode :: proc(x: ^Xcode, src: []u8, final: bool) -> (used: int, ok: bool) {
	s := src[:min(len(src), XCODE_SLICE)]
	if len(s) > 0 && x.bom && !x.started {
		utf_put(&x.pend, 0xFEFF, x.width, x.le)
	}
	if len(s) > 0 {
		x.started = true
	}
	i := 0
	for i < len(s) {
		c := u32(s[i])
		cp: u32
		size: int
		lo: u32
		switch {
		case c < 0x80:
			cp, size, lo = c, 1, 0
		case c >= 0xC2 && c <= 0xDF:
			cp, size, lo = c & 0x1F, 2, 0x80
		case c >= 0xE0 && c <= 0xEF:
			cp, size, lo = c & 0x0F, 3, 0x800
		case c >= 0xF0 && c <= 0xF4:
			cp, size, lo = c & 0x07, 4, 0x10000
		case:
			return i, false
		}
		if i + size > len(s) {
			break
		}
		for k in 1 ..< size {
			b := u32(s[i + k])
			if b & 0xC0 != 0x80 {
				return i, false
			}
			cp = cp << 6 | (b & 0x3F)
		}
		if cp < lo || cp > 0x10FFFF || (cp >= 0xD800 && cp < 0xE000) {
			return i, false
		}
		if x.width == 2 && cp >= 0x10000 {
			v := cp - 0x10000
			utf_put(&x.pend, 0xD800 + (v >> 10), 2, x.le)
			utf_put(&x.pend, 0xDC00 + (v & 0x3FF), 2, x.le)
		} else {
			utf_put(&x.pend, cp, x.width, x.le)
		}
		i += size
	}
	if final && i < len(src) && len(s) == len(src) {
		return i, false
	}
	return i, true
}
