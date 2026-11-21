package fs

import "base:intrinsics"
import "base:runtime"
import "core:io"
import "core:strconv"
import "../fstree"
import "../odb"
import "../prim"

@(private)
Xcode_Status :: enum u8 {
	Ok,
	Incomplete,
	Full,
	Invalid,
}

@(private)
CONV_BUF :: 64 << 10
@(private)
SPOOL_MEM :: 1 << 20
@(private)
CARRY_MEM :: 1 << 20
@(private)
LARGE_CHUNK :: 1 << 20

@(private)
conv_seq: u64

@(private)
enc_is_utf8 :: proc "contextless" (name: string) -> bool {
	return ascii_fold_eq(name, "utf-8") || ascii_fold_eq(name, "utf8")
}

@(private)
strip_utf :: proc "contextless" (s: string) -> (string, bool) {
	if len(s) < 3 || !ascii_fold_eq(s[:3], "utf") {
		return "", false
	}
	r := s[3:]
	if len(r) > 0 && r[0] == '-' {
		r = r[1:]
	}
	return r, true
}

@(private)
same_utf_encoding :: proc "contextless" (a, b: string) -> bool {
	x, xok := strip_utf(a)
	y, yok := strip_utf(b)
	return xok && yok && ascii_fold_eq(x, y)
}

@(private)
has_bom :: proc "contextless" (head: []u8, bom: []u8) -> bool {
	return len(head) >= len(bom) && string(head[:len(bom)]) == string(bom)
}

@(private)
BOM16BE :: [2]u8{0xFE, 0xFF}
@(private)
BOM16LE :: [2]u8{0xFF, 0xFE}
@(private)
BOM32BE :: [4]u8{0, 0, 0xFE, 0xFF}
@(private)
BOM32LE :: [4]u8{0xFF, 0xFE, 0, 0}

@(private)
enc_validate :: proc(enc: string, head: []u8) -> bool {
	if _, ok := strip_utf(enc); !ok {
		return true
	}
	b16be, b16le, b32be, b32le := BOM16BE, BOM16LE, BOM32BE, BOM32LE
	any16 := has_bom(head, b16be[:]) || has_bom(head, b16le[:])
	any32 := has_bom(head, b32be[:]) || has_bom(head, b32le[:])
	if (same_utf_encoding("UTF-16BE", enc) || same_utf_encoding("UTF-16LE", enc)) && any16 {
		return false
	}
	if (same_utf_encoding("UTF-32BE", enc) || same_utf_encoding("UTF-32LE", enc)) && any32 {
		return false
	}
	if same_utf_encoding(enc, "UTF-16") && !any16 {
		return false
	}
	if same_utf_encoding(enc, "UTF-32") && !any32 {
		return false
	}
	return true
}

@(private)
fold_byte :: #force_inline proc "contextless" (c: u8) -> u8 {
	return c + 32 if c >= 'A' && c <= 'Z' else c
}

@(private)
is_space :: #force_inline proc "contextless" (c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r'
}

@(private)
check_roundtrip :: proc(m: ^Mount, enc: string) -> bool {
	g := mount_git_settings(m)
	list := g.roundtrip if g.has_roundtrip else "SHIFT-JIS"
	if len(enc) == 0 || len(enc) > len(list) {
		return false
	}
	found := -1
	outer: for i in 0 ..= len(list) - len(enc) {
		for k in 0 ..< len(enc) {
			if fold_byte(list[i + k]) != fold_byte(enc[k]) {
				continue outer
			}
		}
		found = i
		break
	}
	if found < 0 {
		return false
	}
	next := found + len(enc)
	start_ok := found == 0 || is_space(list[found - 1]) || list[found - 1] == ','
	end_ok := next == len(list) || is_space(list[next]) || list[next] == ','
	return start_ok && end_ok
}

@(private)
enc_fallback :: proc "contextless" (name: string) -> string {
	if enc_is_utf8(name) {
		return "UTF-8"
	}
	if ascii_fold_eq(name, "latin-1") {
		return "ISO-8859-1"
	}
	return name
}

@(private)
enc_open :: proc(to, from: string) -> (Xcode, bool) {
	if x, ok := xcode_open(to, from); ok {
		return x, true
	}
	return xcode_open(enc_fallback(to), enc_fallback(from))
}

@(private)
enc_worktree_target :: proc(enc: string) -> (name: string, bom: []u8) {
	@(static) le := BOM16LE
	@(static) be := BOM16BE
	if same_utf_encoding("UTF-16LE-BOM", enc) {
		return "UTF-16LE", le[:]
	}
	if same_utf_encoding("UTF-16BE-BOM", enc) {
		return "UTF-16BE", be[:]
	}
	return enc, nil
}

@(private)
Enc_Stage :: struct {
	next:    io.Stream,
	x:       Xcode,
	rt:      Xcode,
	has_rt:  bool,
	check:   bool,
	enc:     string,
	bom:     []u8,
	rt_bom:  []u8,
	inb:     [dynamic]u8,
	rtin:    [dynamic]u8,
	cmp:     [dynamic]u8,
	cmp_off: int,
	outb:    []u8,
	rtb:     []u8,
	fed:     bool,
	checked: bool,
	sent:    bool,
	rt_sent: bool,
	failed:  bool,
	opened:  bool,
}

@(private)
enc_stage_init :: proc(s: ^Enc_Stage, enc: string, to_git: bool, roundtrip: bool, next: io.Stream) {
	alloc := runtime.heap_allocator()
	s^ = {
		next  = next,
		enc   = enc,
		check = to_git,
		inb   = make([dynamic]u8, alloc),
		outb  = make([]u8, CONV_BUF, alloc),
	}
	if to_git {
		from := "UTF-16" if same_utf_encoding("UTF-16LE-BOM", enc) else enc
		s.x, s.opened = enc_open("UTF-8", from)
		if s.opened && roundtrip {
			name, bom := enc_worktree_target(enc)
			s.rt, s.has_rt = enc_open(name, "UTF-8")
			if !s.has_rt {
				s.failed = true
			}
			s.rt_bom = bom
			s.rtin = make([dynamic]u8, alloc)
			s.cmp = make([dynamic]u8, alloc)
			s.rtb = make([]u8, CONV_BUF, alloc)
		}
	} else {
		name, bom := enc_worktree_target(enc)
		s.x, s.opened = enc_open(name, "UTF-8")
		s.bom = bom
	}
	if !s.opened {
		s.failed = true
	}
}

@(private)
enc_stage_destroy :: proc(s: ^Enc_Stage) {
	if s.opened {
		xcode_close(&s.x)
	}
	if s.has_rt {
		xcode_close(&s.rt)
	}
	alloc := runtime.heap_allocator()
	delete(s.inb)
	delete(s.rtin)
	delete(s.cmp)
	delete(s.outb, alloc)
	if s.rtb != nil {
		delete(s.rtb, alloc)
	}
}

@(private)
enc_rt_compare :: proc(s: ^Enc_Stage, p: []u8) -> bool {
	if len(s.cmp) - s.cmp_off < len(p) || string(s.cmp[s.cmp_off:s.cmp_off + len(p)]) != string(p) {
		return false
	}
	s.cmp_off += len(p)
	if s.cmp_off >= CONV_BUF {
		remove_range(&s.cmp, 0, s.cmp_off)
		s.cmp_off = 0
	}
	return true
}

@(private)
enc_rt_feed :: proc(s: ^Enc_Stage, p: []u8, final: bool) -> bool {
	if !s.rt_sent && (len(p) > 0 || len(s.rtin) > 0) {
		s.rt_sent = true
		if s.rt_bom != nil && !enc_rt_compare(s, s.rt_bom) {
			return false
		}
	}
	src := p
	if len(s.rtin) > 0 {
		append(&s.rtin, ..p)
		src = s.rtin[:]
	}
	off := 0
	for {
		used, made, st := xcode_step(&s.rt, src[off:], s.rtb, final)
		off += used
		if made > 0 && !enc_rt_compare(s, s.rtb[:made]) {
			return false
		}
		switch st {
		case .Ok:
			off = len(src)
		case .Full:
			if used == 0 && made == 0 {
				return false
			}
			continue
		case .Incomplete:
			if final {
				return false
			}
		case .Invalid:
			return false
		}
		break
	}
	rest := src[off:]
	if len(s.rtin) > 0 {
		remove_range(&s.rtin, 0, off)
	} else if len(rest) > 0 {
		append(&s.rtin, ..rest)
	}
	if !final {
		return true
	}
	for {
		made, st := xcode_finish(&s.rt, s.rtb)
		if made > 0 && !enc_rt_compare(s, s.rtb[:made]) {
			return false
		}
		if st == .Ok {
			break
		}
		if st != .Full || made == 0 {
			return false
		}
	}
	return s.cmp_off == len(s.cmp)
}

@(private)
enc_emit :: proc(s: ^Enc_Stage, p: []u8) -> bool {
	if s.has_rt && !enc_rt_feed(s, p, false) {
		return false
	}
	if _, e := io.write(s.next, p); e != nil {
		return false
	}
	return true
}

@(private)
enc_run :: proc(s: ^Enc_Stage, src: []u8, final: bool) -> (used: int, ok: bool) {
	if !s.sent && len(src) > 0 {
		s.sent = true
		if s.bom != nil && !enc_emit(s, s.bom) {
			return 0, false
		}
	}
	for {
		u, made, st := xcode_step(&s.x, src[used:], s.outb, final)
		used += u
		if made > 0 && !enc_emit(s, s.outb[:made]) {
			return used, false
		}
		switch st {
		case .Ok:
			return len(src), true
		case .Full:
			if u == 0 && made == 0 {
				return used, false
			}
		case .Incomplete:
			return used, !final
		case .Invalid:
			return used, false
		}
	}
}

@(private)
enc_write :: proc(s: ^Enc_Stage, p: []u8) -> bool {
	if s.failed {
		return false
	}
	if len(p) == 0 {
		return true
	}
	s.fed = true
	if s.has_rt {
		append(&s.cmp, ..p)
	}
	if !s.checked && s.check {
		append(&s.inb, ..p)
		if len(s.inb) < 4 {
			return true
		}
		s.checked = true
		if !enc_validate(s.enc, s.inb[:4]) {
			s.failed = true
			return false
		}
		used, ok := enc_run(s, s.inb[:], false)
		if !ok {
			s.failed = true
			return false
		}
		remove_range(&s.inb, 0, used)
		return true
	}
	s.checked = true
	if len(s.inb) > 0 {
		append(&s.inb, ..p)
		used, ok := enc_run(s, s.inb[:], false)
		if !ok {
			s.failed = true
			return false
		}
		remove_range(&s.inb, 0, used)
		return true
	}
	used, ok := enc_run(s, p, false)
	if !ok {
		s.failed = true
		return false
	}
	if used < len(p) {
		append(&s.inb, ..p[used:])
	}
	return true
}

@(private)
enc_finish :: proc(s: ^Enc_Stage) -> bool {
	if s.failed {
		return false
	}
	if !s.fed {
		return true
	}
	if !s.checked && s.check {
		s.checked = true
		if !enc_validate(s.enc, s.inb[:]) {
			s.failed = true
			return false
		}
	}
	if len(s.inb) > 0 {
		if _, ok := enc_run(s, s.inb[:], true); !ok {
			s.failed = true
			return false
		}
		clear(&s.inb)
	}
	for {
		made, st := xcode_finish(&s.x, s.outb)
		if made > 0 && !enc_emit(s, s.outb[:made]) {
			s.failed = true
			return false
		}
		if st == .Ok {
			break
		}
		if st != .Full || made == 0 {
			s.failed = true
			return false
		}
	}
	if s.has_rt && !enc_rt_feed(s, nil, true) {
		s.failed = true
		return false
	}
	return true
}

@(private)
enc_stage_proc :: proc(data: rawptr, mode: io.Stream_Mode, p: []u8, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
	s := (^Enc_Stage)(data)
	#partial switch mode {
	case .Write:
		if !enc_write(s, p) {
			return 0, .Unknown
		}
		return i64(len(p)), nil
	case .Flush:
		if !enc_finish(s) {
			return 0, .Unknown
		}
		return 0, conv_flush(s.next)
	case .Query:
		return io.query_utility({.Write, .Flush, .Query})
	}
	return 0, .Unsupported
}

@(private)
conv_flush :: proc(s: io.Stream) -> io.Error {
	if s.procedure == nil {
		return nil
	}
	e := io.flush(s)
	if e == .Unsupported || e == .Empty {
		return nil
	}
	return e
}

@(private)
Null_Sink :: struct {}

@(private)
null_sink_proc :: proc(data: rawptr, mode: io.Stream_Mode, p: []u8, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
	#partial switch mode {
	case .Write:
		return i64(len(p)), nil
	case .Flush:
		return 0, nil
	case .Query:
		return io.query_utility({.Write, .Flush, .Query})
	}
	return 0, .Unsupported
}

@(private)
null_stream :: proc() -> io.Stream {
	return io.Stream{procedure = null_sink_proc}
}

@(private)
Eol_Stream :: struct {
	s:    Text_Stat,
	cr:   bool,
	last: u8,
	n:    i64,
}

@(private)
eol_stream_feed :: proc "contextless" (es: ^Eol_Stream, data: []u8) {
	for c in data {
		if es.cr {
			es.cr = false
			if c == '\n' {
				es.s.crlf += 1
				continue
			}
			es.s.lonecr += 1
		}
		switch {
		case c == '\r':
			es.cr = true
		case c == '\n':
			es.s.lonelf += 1
		case c == 127:
			es.s.nonprintable += 1
		case c < 32:
			switch c {
			case '\b', '\t', 0o33, 0o14:
				es.s.printable += 1
			case 0:
				es.s.nul += 1
				es.s.nonprintable += 1
			case:
				es.s.nonprintable += 1
			}
		case:
			es.s.printable += 1
		}
	}
	if len(data) > 0 {
		es.last = data[len(data) - 1]
		es.n += i64(len(data))
	}
}

@(private)
eol_stream_finish :: proc "contextless" (es: ^Eol_Stream) -> Text_Stat {
	s := es.s
	if es.cr {
		s.lonecr += 1
	}
	if es.n >= 1 && es.last == 0o32 {
		s.nonprintable -= 1
	}
	return s
}

@(private)
Stat_Stage :: struct {
	next: io.Stream,
	es:   Eol_Stream,
}

@(private)
stat_stage_proc :: proc(data: rawptr, mode: io.Stream_Mode, p: []u8, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
	s := (^Stat_Stage)(data)
	#partial switch mode {
	case .Write:
		eol_stream_feed(&s.es, p)
		if s.next.procedure != nil {
			if _, e := io.write(s.next, p); e != nil {
				return 0, e
			}
		}
		return i64(len(p)), nil
	case .Flush:
		return 0, conv_flush(s.next)
	case .Query:
		return io.query_utility({.Write, .Flush, .Query})
	}
	return 0, .Unsupported
}

@(private)
Crlf_Stage :: struct {
	next:    io.Stream,
	smudge:  bool,
	auto:    bool,
	pending: bool,
	prev:    u8,
	buf:     []u8,
}

@(private)
crlf_stage_proc :: proc(data: rawptr, mode: io.Stream_Mode, p: []u8, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
	s := (^Crlf_Stage)(data)
	#partial switch mode {
	case .Write:
		k := 0
		for c in p {
			if k + 2 > len(s.buf) {
				if _, e := io.write(s.next, s.buf[:k]); e != nil {
					return 0, e
				}
				k = 0
			}
			if s.smudge {
				if c == '\n' && s.prev != '\r' {
					s.buf[k] = '\r'
					k += 1
				}
				s.buf[k] = c
				k += 1
				s.prev = c
				continue
			}
			if s.auto {
				if c != '\r' {
					s.buf[k] = c
					k += 1
				}
				continue
			}
			if s.pending {
				s.pending = false
				if c != '\n' {
					s.buf[k] = '\r'
					k += 1
				}
			}
			if c == '\r' {
				s.pending = true
				continue
			}
			s.buf[k] = c
			k += 1
		}
		if k > 0 {
			if _, e := io.write(s.next, s.buf[:k]); e != nil {
				return 0, e
			}
		}
		return i64(len(p)), nil
	case .Flush:
		if s.pending {
			s.pending = false
			one := [1]u8{'\r'}
			if _, e := io.write(s.next, one[:]); e != nil {
				return 0, e
			}
		}
		return 0, conv_flush(s.next)
	case .Query:
		return io.query_utility({.Write, .Flush, .Query})
	}
	return 0, .Unsupported
}

@(private)
Buffer_Stage :: struct {
	next: io.Stream,
	buf:  [dynamic]u8,
}

@(private)
buffer_stage_proc :: proc(data: rawptr, mode: io.Stream_Mode, p: []u8, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
	s := (^Buffer_Stage)(data)
	#partial switch mode {
	case .Write:
		if len(s.buf) + len(p) > CONV_BUF && len(s.buf) > 0 {
			if _, e := io.write(s.next, s.buf[:]); e != nil {
				return 0, e
			}
			clear(&s.buf)
		}
		if len(p) >= CONV_BUF {
			if _, e := io.write(s.next, p); e != nil {
				return 0, e
			}
		} else {
			append(&s.buf, ..p)
		}
		return i64(len(p)), nil
	case .Flush:
		if len(s.buf) > 0 {
			if _, e := io.write(s.next, s.buf[:]); e != nil {
				return 0, e
			}
			clear(&s.buf)
		}
		return 0, conv_flush(s.next)
	case .Query:
		return io.query_utility({.Write, .Flush, .Query})
	}
	return 0, .Unsupported
}

@(private)
Carry :: struct {
	vfs:  prim.Vfs,
	dir:  string,
	mem:  [dynamic]u8,
	fd:   prim.Fd,
	path: string,
	size: i64,
}

@(private)
carry_init :: proc(c: ^Carry, m: ^Mount) {
	c^ = {
		vfs = m.vfs,
		dir = m.dir,
		mem = make([dynamic]u8, runtime.heap_allocator()),
		fd  = prim.INVALID_FD,
	}
}

@(private)
conv_temp_path :: proc(dir: string) -> string {
	seq := intrinsics.atomic_add(&conv_seq, 1)
	digits: [24]u8
	num := strconv.write_uint(digits[:], seq, 10)
	name := make([]u8, len(TEMP_PREFIX) + 5 + len(num), runtime.heap_allocator())
	n := copy(name, TEMP_PREFIX)
	n += copy(name[n:], "conv-")
	copy(name[n:], num)
	out, _ := path_join(dir, string(name), runtime.heap_allocator())
	delete(name, runtime.heap_allocator())
	return out
}

@(private)
carry_add :: proc(c: ^Carry, p: []u8) -> bool {
	if len(p) == 0 {
		return true
	}
	if c.fd == prim.INVALID_FD && len(c.mem) + len(p) <= CARRY_MEM {
		append(&c.mem, ..p)
		c.size += i64(len(p))
		return true
	}
	if c.fd == prim.INVALID_FD {
		c.path = conv_temp_path(c.dir)
		fd, err := prim.open_file(c.vfs, c.path, {.Write, .Create, .Truncate}, 0o600)
		if err != .None {
			return false
		}
		c.fd = fd
		if prim.write_at(c.vfs, c.fd, c.mem[:], 0) != .None {
			return false
		}
		clear(&c.mem)
	}
	if prim.write_at(c.vfs, c.fd, p, c.size) != .None {
		return false
	}
	c.size += i64(len(p))
	return true
}

@(private)
carry_emit :: proc(c: ^Carry, next: io.Stream) -> bool {
	if c.fd == prim.INVALID_FD {
		if len(c.mem) > 0 {
			if _, e := io.write(next, c.mem[:]); e != nil {
				return false
			}
		}
	} else {
		buf := make([]u8, CONV_BUF, runtime.heap_allocator())
		defer delete(buf, runtime.heap_allocator())
		off: i64
		for off < c.size {
			n, err := prim.read_at(c.vfs, c.fd, buf, off)
			if err != .None || n <= 0 {
				return false
			}
			if _, e := io.write(next, buf[:n]); e != nil {
				return false
			}
			off += i64(n)
		}
	}
	carry_reset(c)
	return true
}

@(private)
carry_reset :: proc(c: ^Carry) {
	clear(&c.mem)
	c.size = 0
	if c.fd != prim.INVALID_FD {
		prim.close_file(c.vfs, c.fd)
		prim.remove(c.vfs, c.path)
		delete(c.path, runtime.heap_allocator())
		c.fd = prim.INVALID_FD
		c.path = ""
	}
}

@(private)
carry_destroy :: proc(c: ^Carry) {
	carry_reset(c)
	delete(c.mem)
}

@(private)
Ident_State :: enum u8 {
	Normal,
	Dollar,
	Body,
}

@(private)
Ident_Stage :: struct {
	next:    io.Stream,
	to_git:  bool,
	stream:  bool,
	hex:     string,
	state:   Ident_State,
	la:      [3]u8,
	la_n:    int,
	carry:   Carry,
	space:   i64,
	head:    int,
	skip:    bool,
	k:       i64,
	pre_ok:  bool,
	prev_sp: bool,
	alien:   bool,
}

@(private)
ident_stream_write :: proc(s: ^Ident_Stage, p: []u8) -> bool {
	HEAD := "$Id"
	i := 0
	for i < len(p) {
		if s.skip {
			j := -1
			for c, x in p[i:] {
				if c == '$' || c == '\n' {
					j = x
					break
				}
			}
			seg := p[i:] if j < 0 else p[i:i + j]
			for c in seg {
				if s.k == 0 {
					s.pre_ok = c == ' '
				} else {
					if s.prev_sp {
						s.alien = true
					}
					s.prev_sp = is_space(c)
				}
				s.k += 1
			}
			if !carry_add(&s.carry, seg) {
				return false
			}
			if j < 0 {
				return true
			}
			c := p[i + j]
			i += j + 1
			s.skip = false
			if c == '$' && !(s.pre_ok && s.alien) {
				carry_reset(&s.carry)
				if !ident_out(s, transmute([]u8)string(HEAD)) || !ident_out(s, transmute([]u8)string(": ")) || !ident_out(s, transmute([]u8)s.hex) || !ident_out(s, transmute([]u8)string(" $")) {
					return false
				}
				continue
			}
			one := [1]u8{c}
			if !ident_out(s, transmute([]u8)string("$Id:")) || !carry_emit(&s.carry, s.next) || !ident_out(s, one[:]) {
				return false
			}
			continue
		}
		if s.head == 0 {
			j := -1
			for c, x in p[i:] {
				if c == '$' {
					j = x
					break
				}
			}
			if j < 0 {
				return ident_out(s, p[i:])
			}
			if !ident_out(s, p[i:i + j]) {
				return false
			}
			i += j + 1
			s.head = 1
			continue
		}
		c := p[i]
		i += 1
		if s.head < 3 && HEAD[s.head] == c {
			s.head += 1
			continue
		}
		h := s.head
		s.head = 0
		if h == 3 && (c == ':' || c == '$') {
			if c == '$' {
				if !ident_out(s, transmute([]u8)string(HEAD)) || !ident_out(s, transmute([]u8)string(": ")) || !ident_out(s, transmute([]u8)s.hex) || !ident_out(s, transmute([]u8)string(" $")) {
					return false
				}
				continue
			}
			s.skip = true
			s.k = 0
			s.pre_ok = false
			s.prev_sp = false
			s.alien = false
			continue
		}
		one := [1]u8{c}
		if !ident_out(s, transmute([]u8)string(HEAD[:h])) || !ident_out(s, one[:]) {
			return false
		}
	}
	return true
}

@(private)
ident_stream_finish :: proc(s: ^Ident_Stage) -> bool {
	if s.skip {
		s.skip = false
		return ident_out(s, transmute([]u8)string("$Id:")) && carry_emit(&s.carry, s.next)
	}
	h := s.head
	s.head = 0
	head := "$Id"
	return ident_out(s, transmute([]u8)head[:h])
}

@(private)
ident_out :: proc(s: ^Ident_Stage, p: []u8) -> bool {
	if len(p) == 0 {
		return true
	}
	_, e := io.write(s.next, p)
	return e == nil
}

@(private)
ident_subst :: proc(s: ^Ident_Stage) -> bool {
	if s.to_git {
		return ident_out(s, transmute([]u8)string("Id$"))
	}
	return ident_out(s, transmute([]u8)string("Id: ")) && ident_out(s, transmute([]u8)s.hex) && ident_out(s, transmute([]u8)string(" $"))
}

@(private)
ident_verbatim :: proc(s: ^Ident_Stage) -> bool {
	ok := ident_out(s, transmute([]u8)string("Id:")) && carry_emit(&s.carry, s.next)
	s.space = -1
	return ok
}

@(private)
ident_body_add :: proc(s: ^Ident_Stage, p: []u8) -> bool {
	if !s.to_git && s.space < 0 {
		for c, i in p {
			if c == ' ' && s.carry.size + i64(i) >= 1 {
				s.space = s.carry.size + i64(i)
				break
			}
		}
	}
	return carry_add(&s.carry, p)
}

@(private)
ident_write :: proc(s: ^Ident_Stage, p: []u8) -> bool {
	i := 0
	for i < len(p) {
		switch s.state {
		case .Normal:
			j := -1
			for c, k in p[i:] {
				if c == '$' {
					j = k
					break
				}
			}
			if j < 0 {
				return ident_out(s, p[i:])
			}
			if !ident_out(s, p[i:i + j + 1]) {
				return false
			}
			i += j + 1
			s.state = .Dollar
			s.la_n = 0
		case .Dollar:
			c := p[i]
			i += 1
			s.la[s.la_n] = c
			s.la_n += 1
			want_ok := false
			switch s.la_n {
			case 1:
				want_ok = c == 'I'
			case 2:
				want_ok = c == 'd'
			case 3:
				want_ok = c == ':' if s.to_git else (c == ':' || c == '$')
			}
			if !want_ok {
				la := s.la
				n := s.la_n
				s.state = .Normal
				if !ident_write(s, la[:n]) {
					return false
				}
				continue
			}
			if s.la_n < 3 {
				continue
			}
			if c == '$' {
				if !ident_subst(s) {
					return false
				}
				s.state = .Normal
				continue
			}
			s.state = .Body
			s.space = -1
		case .Body:
			j := -1
			for c, k in p[i:] {
				if c == '$' || c == '\n' {
					j = k
					break
				}
			}
			if j < 0 {
				return ident_body_add(s, p[i:])
			}
			if !ident_body_add(s, p[i:i + j]) {
				return false
			}
			c := p[i + j]
			i += j + 1
			if c == '\n' {
				one := [1]u8{'\n'}
				if !ident_verbatim(s) || !ident_out(s, one[:]) {
					return false
				}
				s.state = .Normal
				continue
			}
			if !s.to_git && s.space >= 1 && s.space < s.carry.size - 1 {
				dollar := [1]u8{'$'}
				if !ident_verbatim(s) || !ident_out(s, dollar[:]) {
					return false
				}
				s.state = .Dollar
				s.la_n = 0
				continue
			}
			carry_reset(&s.carry)
			if !ident_subst(s) {
				return false
			}
			s.state = .Normal
		}
	}
	return true
}

@(private)
ident_finish :: proc(s: ^Ident_Stage) -> bool {
	switch s.state {
	case .Normal:
	case .Dollar:
		if !ident_out(s, s.la[:s.la_n]) {
			return false
		}
	case .Body:
		if !ident_verbatim(s) {
			return false
		}
	}
	s.state = .Normal
	return true
}

@(private)
ident_stage_proc :: proc(data: rawptr, mode: io.Stream_Mode, p: []u8, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
	s := (^Ident_Stage)(data)
	#partial switch mode {
	case .Write:
		if !(ident_stream_write(s, p) if s.stream else ident_write(s, p)) {
			return 0, .Unknown
		}
		return i64(len(p)), nil
	case .Flush:
		if !(ident_stream_finish(s) if s.stream else ident_finish(s)) {
			return 0, .Unknown
		}
		return 0, conv_flush(s.next)
	case .Query:
		return io.query_utility({.Write, .Flush, .Query})
	}
	return 0, .Unsupported
}

@(private)
Spool :: struct {
	vfs:   prim.Vfs,
	dir:   string,
	mem:   [dynamic]u8,
	limit: int,
	fd:    prim.Fd,
	path:  string,
	size:  i64,
	bad:   bool,
}

@(private)
spool_init :: proc(s: ^Spool, m: ^Mount, limit: int, allocator: runtime.Allocator) {
	s^ = {
		vfs   = m.vfs,
		dir   = m.dir,
		mem   = make([dynamic]u8, allocator),
		limit = limit,
		fd    = prim.INVALID_FD,
	}
}

@(private)
spool_write :: proc(s: ^Spool, p: []u8) -> bool {
	if s.bad {
		return false
	}
	if s.fd == prim.INVALID_FD && (s.limit < 0 || len(s.mem) + len(p) <= s.limit) {
		append(&s.mem, ..p)
		s.size += i64(len(p))
		return true
	}
	if s.fd == prim.INVALID_FD {
		s.path = conv_temp_path(s.dir)
		fd, err := prim.open_file(s.vfs, s.path, {.Write, .Create, .Truncate}, 0o600)
		if err != .None {
			delete(s.path, runtime.heap_allocator())
			s.path = ""
			s.bad = true
			return false
		}
		s.fd = fd
		if len(s.mem) > 0 && prim.write_at(s.vfs, s.fd, s.mem[:], 0) != .None {
			s.bad = true
			return false
		}
		clear(&s.mem)
	}
	if prim.write_at(s.vfs, s.fd, p, s.size) != .None {
		s.bad = true
		return false
	}
	s.size += i64(len(p))
	return true
}

@(private)
spool_proc :: proc(data: rawptr, mode: io.Stream_Mode, p: []u8, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
	s := (^Spool)(data)
	#partial switch mode {
	case .Write:
		if !spool_write(s, p) {
			return 0, .Unknown
		}
		return i64(len(p)), nil
	case .Flush:
		return 0, nil
	case .Query:
		return io.query_utility({.Write, .Flush, .Query})
	}
	return 0, .Unsupported
}

@(private)
spool_stream :: proc(s: ^Spool) -> io.Stream {
	return io.Stream{procedure = spool_proc, data = s}
}

@(private)
spool_reset :: proc(s: ^Spool) {
	clear(&s.mem)
	s.size = 0
	s.bad = false
	if s.fd != prim.INVALID_FD {
		prim.truncate(s.vfs, s.fd, 0)
	}
}

@(private)
spool_destroy :: proc(s: ^Spool) {
	if s.fd != prim.INVALID_FD {
		prim.close_file(s.vfs, s.fd)
		prim.remove(s.vfs, s.path)
		delete(s.path, runtime.heap_allocator())
		s.fd = prim.INVALID_FD
		s.path = ""
	}
	delete(s.mem)
	s.mem = nil
}

@(private)
Conv_Kind :: enum u8 {
	Data,
	Fd,
	Blob,
}

@(private)
Conv_Source :: struct {
	kind: Conv_Kind,
	data: []u8,
	fd:   prim.Fd,
	vfs:  prim.Vfs,
	oid:  odb.Oid,
}

@(private)
spool_source :: proc(s: ^Spool) -> Conv_Source {
	if s.fd != prim.INVALID_FD {
		return Conv_Source{kind = .Fd, fd = s.fd, vfs = s.vfs}
	}
	return Conv_Source{kind = .Data, data = s.mem[:]}
}

@(private)
source_input :: proc(src: Conv_Source) -> Filter_Input {
	if src.kind == .Fd {
		return Filter_Input{fd = src.fd, vfs = src.vfs}
	}
	return Filter_Input{data = src.data, fd = prim.INVALID_FD}
}

@(private)
source_feed :: proc(m: ^Mount, src: Conv_Source, out: io.Stream) -> bool {
	switch src.kind {
	case .Data:
		if len(src.data) > 0 {
			if _, e := io.write(out, src.data); e != nil {
				return false
			}
		}
	case .Fd:
		buf := make([]u8, LARGE_CHUNK, runtime.heap_allocator())
		defer delete(buf, runtime.heap_allocator())
		off: i64
		for {
			n, err := prim.read_at(src.vfs, src.fd, buf, off)
			if err != .None {
				return false
			}
			if n <= 0 {
				break
			}
			if _, e := io.write(out, buf[:n]); e != nil {
				return false
			}
			off += i64(n)
		}
	case .Blob:
		if m.db == nil {
			return false
		}
		t, _, err := odb.stream(m.db, src.oid, out)
		if err != .None || t != .Blob {
			return false
		}
	}
	return conv_flush(out) == nil
}

@(private)
Clean_Result :: enum u8 {
	Same,
	Changed,
	Failed,
}

@(private)
clean_convert :: proc(m: ^Mount, rel: string, cv: Conv, src: Conv_Source, out: ^Spool, limit: int, allocator: runtime.Allocator) -> Clean_Result {
	if cv.enc_bad {
		return .Failed
	}
	eol := cv.action != .Binary && cv.action != .Undefined
	if cv.driver == nil && len(cv.encoding) == 0 && !cv.ident && !eol {
		return .Same
	}
	spools: [3]Spool
	used := 0
	defer for i in 0 ..< used {
		spool_destroy(&spools[i])
	}
	cur := src
	final: ^Spool
	if cv.driver != nil {
		a := &spools[used]
		used += 1
		spool_init(a, m, limit, allocator)
		if filter_apply(m, cv.driver, .Clean, rel, source_input(src), spool_stream(a)) && !a.bad {
			cur = spool_source(a)
			final = a
		} else if cv.driver.required {
			return .Failed
		}
	}
	stats: Stat_Stage
	if len(cv.encoding) > 0 {
		b := &spools[used]
		used += 1
		spool_init(b, m, limit, allocator)
		stats.next = spool_stream(b)
		es: Enc_Stage
		enc_stage_init(&es, cv.encoding, true, check_roundtrip(m, cv.encoding), io.Stream{procedure = stat_stage_proc, data = &stats})
		ok := !es.failed && source_feed(m, cur, io.Stream{procedure = enc_stage_proc, data = &es})
		failed := es.failed
		enc_stage_destroy(&es)
		if !ok || failed || b.bad {
			return .Failed
		}
		cur = spool_source(b)
		final = b
	} else if eol {
		if !source_feed(m, cur, io.Stream{procedure = stat_stage_proc, data = &stats}) {
			return .Failed
		}
	}
	convert := false
	auto := action_auto(cv.action)
	if eol {
		st := eol_stream_finish(&stats.es)
		convert = st.crlf > 0 && stats.es.n > 0
		if convert && auto && (text_is_binary(st) || index_has_crlf(m, rel)) {
			convert = false
		}
	}
	if convert || cv.ident {
		c := &spools[used]
		used += 1
		spool_init(c, m, limit, allocator)
		head := spool_stream(c)
		id: Ident_Stage
		bs := Buffer_Stage{next = head, buf = make([dynamic]u8, 0, CONV_BUF, runtime.heap_allocator())}
		defer delete(bs.buf)
		if cv.ident {
			head = io.Stream{procedure = buffer_stage_proc, data = &bs}
			id = Ident_Stage {
				next   = head,
				to_git = true,
				space  = -1,
			}
			carry_init(&id.carry, m)
			head = io.Stream{procedure = ident_stage_proc, data = &id}
		}
		cr: Crlf_Stage
		if convert {
			cr = Crlf_Stage {
				next = head,
				auto = auto,
				buf  = make([]u8, CONV_BUF, runtime.heap_allocator()),
			}
			head = io.Stream{procedure = crlf_stage_proc, data = &cr}
		}
		ok := source_feed(m, cur, head)
		if cv.ident {
			carry_destroy(&id.carry)
		}
		if convert {
			delete(cr.buf, runtime.heap_allocator())
		}
		if !ok || c.bad {
			return .Failed
		}
		final = c
	}
	if final == nil {
		return .Same
	}
	out^ = final^
	final^ = Spool {
		fd = prim.INVALID_FD,
	}
	return .Changed
}

@(private)
Smudge_Rewind :: #type proc(data: rawptr) -> bool

@(private)
smudge_convert :: proc(m: ^Mount, rel: string, cv: Conv, src: Conv_Source, out: io.Stream, rewind: Smudge_Rewind = nil, rewind_data: rawptr = nil) -> bool {
	format := m.db.format if m.db != nil else odb.Hash_Format.Sha1
	hexbuf: [odb.MAX_HEX]u8
	hex := ""
	if cv.ident {
		oid := src.oid
		if src.kind == .Data {
			o, herr := odb.hash(format, .Blob, src.data)
			if herr != .None {
				return false
			}
			oid = o
		}
		hex = odb.oid_to_string(oid, format, &hexbuf)
	}
	can_crlf := cv.action != .Binary && output_crlf(m, cv.action)
	enc := cv.encoding if !cv.enc_bad else ""
	convert := false
	enc_ok := len(enc) > 0
	streamable := cv.driver == nil && len(enc) == 0 && !cv.enc_bad && cv.action != .Auto && cv.action != .Auto_Crlf
	if streamable {
		convert = can_crlf
	} else if can_crlf || len(enc) > 0 {
		stats: Stat_Stage
		es: Enc_Stage
		head := io.Stream{procedure = stat_stage_proc, data = &stats}
		if len(enc) > 0 {
			enc_stage_init(&es, enc, false, false, null_stream())
			if !es.failed {
				stats.next = io.Stream{procedure = enc_stage_proc, data = &es}
			}
		}
		id: Ident_Stage
		if cv.ident {
			id = Ident_Stage {
				next  = head,
				hex   = hex,
				space = -1,
			}
			carry_init(&id.carry, m)
			head = io.Stream{procedure = ident_stage_proc, data = &id}
		}
		ok := source_feed(m, src, head)
		if cv.ident {
			carry_destroy(&id.carry)
		}
		if len(enc) > 0 {
			enc_ok = !es.failed
			enc_stage_destroy(&es)
		}
		if !ok && !(len(enc) > 0 && !enc_ok) {
			return false
		}
		if !ok {
			return smudge_convert(m, rel, Conv{action = cv.action, ident = cv.ident, driver = cv.driver}, src, out, rewind, rewind_data)
		}
		st := eol_stream_finish(&stats.es)
		if can_crlf && st.lonelf > 0 && stats.es.n > 0 {
			convert = !(action_auto(cv.action) && (st.lonecr > 0 || st.crlf > 0 || text_is_binary(st)))
		}
	}
	spool: Spool
	target := out
	if cv.driver != nil {
		spool_init(&spool, m, SPOOL_MEM, runtime.heap_allocator())
		target = spool_stream(&spool)
	}
	defer if cv.driver != nil {
		spool_destroy(&spool)
	}
	head := target
	es: Enc_Stage
	if enc_ok {
		enc_stage_init(&es, enc, false, false, head)
		head = io.Stream{procedure = enc_stage_proc, data = &es}
	}
	defer if enc_ok {
		enc_stage_destroy(&es)
	}
	cr: Crlf_Stage
	if convert {
		cr = Crlf_Stage {
			next   = head,
			smudge = true,
			buf    = make([]u8, CONV_BUF, runtime.heap_allocator()),
		}
		head = io.Stream{procedure = crlf_stage_proc, data = &cr}
	}
	defer if convert {
		delete(cr.buf, runtime.heap_allocator())
	}
	id: Ident_Stage
	bs := Buffer_Stage{next = head, buf = make([dynamic]u8, 0, CONV_BUF, runtime.heap_allocator())}
	defer delete(bs.buf)
	if cv.ident {
		head = io.Stream{procedure = buffer_stage_proc, data = &bs}
		id = Ident_Stage {
			next   = head,
			hex    = hex,
			space  = -1,
			stream = streamable,
		}
		carry_init(&id.carry, m)
		head = io.Stream{procedure = ident_stage_proc, data = &id}
	}
	defer if cv.ident {
		carry_destroy(&id.carry)
	}
	if !source_feed(m, src, head) {
		return false
	}
	if cv.driver == nil {
		return true
	}
	if spool.bad {
		return false
	}
	if rewind != nil {
		if filter_apply(m, cv.driver, .Smudge, rel, source_input(spool_source(&spool)), out) {
			return true
		}
		if cv.driver.required || !rewind(rewind_data) {
			return false
		}
		return source_feed(m, spool_source(&spool), out)
	}
	fo: Spool
	spool_init(&fo, m, SPOOL_MEM, runtime.heap_allocator())
	defer spool_destroy(&fo)
	if filter_apply(m, cv.driver, .Smudge, rel, source_input(spool_source(&spool)), spool_stream(&fo)) && !fo.bad {
		return source_feed(m, spool_source(&fo), out)
	}
	if cv.driver.required {
		return false
	}
	return source_feed(m, spool_source(&spool), out)
}

@(private)
index_has_crlf :: proc(m: ^Mount, rel: string) -> bool {
	oid, found := index_blob(m, rel)
	if !found || m.db == nil {
		return false
	}
	st: Stat_Stage
	t, _, err := odb.stream(m.db, oid, io.Stream{procedure = stat_stage_proc, data = &st})
	if err != .None || t != .Blob {
		return false
	}
	s := eol_stream_finish(&st.es)
	return !text_is_binary(s) && s.crlf > 0
}

eol_clean :: proc(m: ^Mount, rel: string, data: []u8, inode := fstree.Inode_Id{}, has_old := false, allocator := context.temp_allocator) -> ([]u8, bool) {
	if !m.has_git {
		return data, true
	}
	attr_begin(m)
	defer attr_end(m)
	cv := conv_attrs(m, rel)
	out: Spool
	switch clean_convert(m, rel, cv, Conv_Source{kind = .Data, data = data}, &out, -1, allocator) {
	case .Same:
		return data, true
	case .Failed:
		return nil, false
	case .Changed:
	}
	return out.mem[:], true
}

eol_smudge_to :: proc(m: ^Mount, rel: string, data: []u8, out: io.Stream) -> bool {
	if !m.has_git {
		_, err := io.write(out, data)
		return err == nil
	}
	attr_begin(m)
	defer attr_end(m)
	cv := conv_attrs(m, rel)
	return smudge_convert(m, rel, cv, Conv_Source{kind = .Data, data = data}, out)
}

eol_smudge :: proc(m: ^Mount, rel: string, data: []u8, allocator := context.temp_allocator) -> []u8 {
	if !m.has_git || len(data) == 0 {
		return data
	}
	sink := Buf_Sink{buf = make([dynamic]u8, 0, len(data), allocator)}
	if !eol_smudge_to(m, rel, data, io.Stream{procedure = buf_sink_proc, data = &sink}) {
		return data
	}
	return sink.buf[:]
}

eol_smudge_blob :: proc(m: ^Mount, rel: string, oid: odb.Oid, out: io.Stream, rewind: Smudge_Rewind, rewind_data: rawptr) -> bool {
	cv: Conv
	if m.has_git {
		attr_begin(m)
		cv = conv_attrs(m, rel)
	} else {
		cv.action = .Binary
	}
	defer if m.has_git {
		attr_end(m)
	}
	return smudge_convert(m, rel, cv, Conv_Source{kind = .Blob, oid = oid}, out, rewind, rewind_data)
}

Large_Clean :: enum u8 {
	Raw,
	Stored,
	Failed,
}

store_large_clean :: proc(m: ^Mount, rel: string, abs: string, old := fstree.Inode_Id{}, has_old := false) -> (oid: odb.Oid, size: i64, status: Large_Clean) {
	if !m.has_git || m.db == nil {
		return {}, 0, .Raw
	}
	attr_begin(m)
	defer attr_end(m)
	cv := conv_attrs(m, rel)
	fd, oerr := prim.open_file(m.vfs, abs)
	if oerr != .None {
		return {}, 0, .Failed
	}
	defer prim.close_file(m.vfs, fd)
	out: Spool
	r := clean_convert(m, rel, cv, Conv_Source{kind = .Fd, fd = fd, vfs = m.vfs}, &out, SPOOL_MEM, runtime.heap_allocator())
	switch r {
	case .Same:
		return {}, 0, .Raw
	case .Failed:
		return {}, 0, .Failed
	case .Changed:
	}
	defer spool_destroy(&out)
	o: odb.Oid
	werr: odb.Error
	if out.fd != prim.INVALID_FD {
		prim.close_file(m.vfs, out.fd)
		out.fd = prim.INVALID_FD
		o, werr = odb.write_file(m.db, out.path)
		prim.remove(m.vfs, out.path)
		delete(out.path, runtime.heap_allocator())
		out.path = ""
	} else {
		o, werr = odb.write(m.db, .Blob, out.mem[:])
	}
	if werr != .None {
		return {}, 0, .Failed
	}
	history_note_blob(m.history, o)
	return o, out.size, .Stored
}
