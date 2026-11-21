package keystore

import "core:crypto"
import "core:time"

@(private)
Tpm_Call :: struct {
	data: rawptr,
	call: proc(data: rawptr, cmd: []u8, resp: []u8) -> (int, Error),
}

@(private = "file")
ST_NO_SESSIONS :: 0x8001
@(private = "file")
ST_SESSIONS :: 0x8002
@(private = "file")
RH_OWNER :: 0x4000_0001
@(private = "file")
RS_PW :: 0x4000_0009
@(private = "file")
CC_CREATE_PRIMARY :: 0x131
@(private = "file")
CC_CREATE :: 0x153
@(private = "file")
CC_LOAD :: 0x157
@(private = "file")
CC_UNSEAL :: 0x15E
@(private = "file")
CC_FLUSH_CONTEXT :: 0x165
@(private = "file")
MAX_COMMAND :: 1024
@(private = "file")
MAX_RESPONSE :: 4096
@(private = "file")
RETRIES :: 20

@(private = "file")
PRIMARY_TEMPLATE :: [?]u8 {
	0x00, 0x23,
	0x00, 0x0B,
	0x00, 0x03, 0x04, 0x72,
	0x00, 0x00,
	0x00, 0x06, 0x00, 0x80, 0x00, 0x43,
	0x00, 0x10,
	0x00, 0x03,
	0x00, 0x10,
	0x00, 0x20,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0x00, 0x20,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
}

@(private = "file")
SEALED_TEMPLATE :: [?]u8 {
	0x00, 0x08,
	0x00, 0x0B,
	0x00, 0x00, 0x04, 0x52,
	0x00, 0x00,
	0x00, 0x10,
	0x00, 0x00,
}

@(private = "file")
Buf :: struct {
	b:    []u8,
	n:    int,
	over: bool,
}

@(private = "file")
_put_u8 :: proc(w: ^Buf, v: u8) {
	if w.n + 1 > len(w.b) {
		w.over = true
		return
	}
	w.b[w.n] = v
	w.n += 1
}

@(private = "file")
_put_u16 :: proc(w: ^Buf, v: u16) {
	_put_u8(w, u8(v >> 8))
	_put_u8(w, u8(v))
}

@(private = "file")
_put_u32 :: proc(w: ^Buf, v: u32) {
	_put_u16(w, u16(v >> 16))
	_put_u16(w, u16(v))
}

@(private = "file")
_put :: proc(w: ^Buf, b: []u8) {
	if w.n + len(b) > len(w.b) {
		w.over = true
		return
	}
	copy(w.b[w.n:], b)
	w.n += len(b)
}

@(private = "file")
_put_2b :: proc(w: ^Buf, b: []u8) {
	_put_u16(w, u16(len(b)))
	_put(w, b)
}

@(private = "file")
_get_u16 :: proc(r: ^Buf) -> u16 {
	if r.n + 2 > len(r.b) {
		r.over = true
		return 0
	}
	v := u16(r.b[r.n]) << 8 | u16(r.b[r.n + 1])
	r.n += 2
	return v
}

@(private = "file")
_get_u32 :: proc(r: ^Buf) -> u32 {
	hi := _get_u16(r)
	lo := _get_u16(r)
	return u32(hi) << 16 | u32(lo)
}

@(private = "file")
_get_2b :: proc(r: ^Buf) -> []u8 {
	n := int(_get_u16(r))
	if r.over || r.n + n > len(r.b) {
		r.over = true
		return nil
	}
	b := r.b[r.n:r.n + n]
	r.n += n
	return b
}

@(private)
_tpm_rc_error :: proc(rc: u32) -> Error {
	base := rc & 0x80 != 0 ? 0x80 | (rc & 0x3F) : rc & 0xFFF
	switch base {
	case 0x8E, 0xA2, 0x921, 0x85, 0x9D:
		return .Denied
	case 0x9F, 0x95, 0x84, 0x8A, 0x82, 0x9C, 0xA5:
		return .Corrupt
	case 0x902, 0x903, 0x904:
		return .No_Memory
	}
	return .Io
}

@(private = "file")
_retryable :: proc(rc: u32) -> bool {
	switch rc & 0xFFF {
	case 0x908, 0x90A, 0x922:
		return true
	}
	return false
}

@(private = "file")
_run :: proc(t: Tpm_Call, cc: u32, handles: []u32, session: bool, params: []u8, resp: []u8) -> (body: Buf, err: Error) {
	cmd: [MAX_COMMAND]u8
	defer crypto.zero_explicit(&cmd, size_of(cmd))
	w := Buf{b = cmd[:]}
	_put_u16(&w, session ? ST_SESSIONS : ST_NO_SESSIONS)
	_put_u32(&w, 0)
	_put_u32(&w, cc)
	for h in handles {
		_put_u32(&w, h)
	}
	if session {
		_put_u32(&w, 9)
		_put_u32(&w, RS_PW)
		_put_u16(&w, 0)
		_put_u8(&w, 0)
		_put_u16(&w, 0)
	}
	_put(&w, params)
	if w.over {
		return {}, .Invalid
	}
	size := Buf{b = cmd[2:6]}
	_put_u32(&size, u32(w.n))
	for attempt in 0 ..< RETRIES {
		n := t.call(t.data, cmd[:w.n], resp) or_return
		r := Buf{b = resp[:n]}
		_ = _get_u16(&r)
		total := _get_u32(&r)
		rc := _get_u32(&r)
		if r.over || int(total) != n {
			return {}, .Io
		}
		if rc == 0 {
			return r, .None
		}
		if !_retryable(rc) || attempt == RETRIES - 1 {
			return {}, _tpm_rc_error(rc)
		}
		time.sleep(50 * time.Millisecond)
	}
	return {}, .Io
}

@(private = "file")
_flush :: proc(t: Tpm_Call, handle: u32) {
	resp: [64]u8
	p: [4]u8
	w := Buf{b = p[:]}
	_put_u32(&w, handle)
	_, _ = _run(t, CC_FLUSH_CONTEXT, nil, false, p[:], resp[:])
}

@(private = "file")
_primary :: proc(t: Tpm_Call) -> (handle: u32, err: Error) {
	p: [256]u8
	w := Buf{b = p[:]}
	_put_u16(&w, 4)
	_put_u16(&w, 0)
	_put_u16(&w, 0)
	tmpl := PRIMARY_TEMPLATE
	_put_2b(&w, tmpl[:])
	_put_u16(&w, 0)
	_put_u32(&w, 0)
	resp: [MAX_RESPONSE]u8
	r := _run(t, CC_CREATE_PRIMARY, {RH_OWNER}, true, p[:w.n], resp[:]) or_return
	handle = _get_u32(&r)
	if r.over {
		return 0, .Io
	}
	return handle, .None
}

@(private)
_tpm_probe :: proc(t: Tpm_Call) -> Error {
	h := _primary(t) or_return
	_flush(t, h)
	return .None
}

@(private)
_tpm_seal :: proc(t: Tpm_Call, inner: []u8, out: ^[dynamic]u8) -> Error {
	if len(inner) > 128 {
		return .Invalid
	}
	parent := _primary(t) or_return
	defer _flush(t, parent)
	p: [512]u8
	defer crypto.zero_explicit(&p, size_of(p))
	w := Buf{b = p[:]}
	_put_u16(&w, u16(4 + len(inner)))
	_put_u16(&w, 0)
	_put_2b(&w, inner)
	tmpl := SEALED_TEMPLATE
	_put_2b(&w, tmpl[:])
	_put_u16(&w, 0)
	_put_u32(&w, 0)
	if w.over {
		return .Invalid
	}
	resp: [MAX_RESPONSE]u8
	r := _run(t, CC_CREATE, {parent}, true, p[:w.n], resp[:]) or_return
	_ = _get_u32(&r)
	start := r.n
	private := _get_2b(&r)
	public := _get_2b(&r)
	if r.over || len(private) == 0 || len(public) == 0 {
		return .Io
	}
	if _, aerr := append(out, ..resp[start:r.n]); aerr != nil {
		return .No_Memory
	}
	return .None
}

@(private)
_tpm_unseal :: proc(t: Tpm_Call, payload: []u8, out: []u8) -> (n: int, err: Error) {
	pr := Buf{b = payload}
	private := _get_2b(&pr)
	public := _get_2b(&pr)
	if pr.over || pr.n != len(payload) || len(private) == 0 || len(public) == 0 || len(payload) > 900 {
		return 0, .Corrupt
	}
	parent := _primary(t) or_return
	defer _flush(t, parent)
	resp: [MAX_RESPONSE]u8
	defer crypto.zero_explicit(&resp, size_of(resp))
	r := _run(t, CC_LOAD, {parent}, true, payload, resp[:]) or_return
	item := _get_u32(&r)
	if r.over {
		return 0, .Io
	}
	defer _flush(t, item)
	u := _run(t, CC_UNSEAL, {item}, true, nil, resp[:]) or_return
	_ = _get_u32(&u)
	data := _get_2b(&u)
	if u.over {
		return 0, .Io
	}
	if len(data) > len(out) {
		return 0, .Corrupt
	}
	return copy(out, data), .None
}
