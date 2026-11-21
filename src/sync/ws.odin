#+build linux, darwin, windows
package osync

import "base:runtime"
import "core:crypto/legacy/sha1"
import "core:strings"
import "../prim"

WS_HEADER_MAX :: 4096
WS_FRAME_MAX :: 64 * 1024
WS_OUT_MAX :: 256 * 1024
WS_READ :: 16 * 1024
WS_PAYLOAD_LIMIT :: i64(1) << 62
WS_GUID :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

Ws :: struct {
	head:      [dynamic]u8,
	inb:       [dynamic]u8,
	ipos:      int,
	left:      i64,
	opcode:    u8,
	mask:      [4]u8,
	mpos:      int,
	out:       [dynamic]u8,
	opos:      int,
	closed:    bool,
	upgraded:  bool,
	allocator: runtime.Allocator,
}

ws_new :: proc(allocator := context.allocator) -> (^Ws, Error) {
	w, aerr := new(Ws, allocator)
	if aerr != nil {
		return nil, .No_Memory
	}
	w.allocator = allocator
	w.head = make([dynamic]u8, allocator)
	w.inb = make([dynamic]u8, allocator)
	w.out = make([dynamic]u8, allocator)
	return w, .None
}

ws_free :: proc(w: ^Ws) {
	if w == nil {
		return
	}
	delete(w.head)
	delete(w.inb)
	delete(w.out)
	free(w, w.allocator)
}

ws_upgrade :: proc(w: ^Ws, fd: prim.Fd) -> Error {
	buf: [WS_HEADER_MAX]u8
	for {
		end := strings.index(string(w.head[:]), "\r\n\r\n")
		if end >= 0 {
			rest := w.head[end + 4:]
			append(&w.inb, ..rest)
			resize(&w.head, end + 4)
			break
		}
		if len(w.head) >= WS_HEADER_MAX {
			return .Protocol
		}
		n, err := _recv(fd, buf[:WS_HEADER_MAX - len(w.head)])
		if err != .None {
			return err
		}
		append(&w.head, ..buf[:n])
	}
	accept, ok := _ws_accept_key(string(w.head[:]))
	if !ok {
		_, _ = _send(fd, transmute([]u8)string("HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"), false)
		return .Protocol
	}
	resp: [256]u8
	n := copy(resp[:], "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ")
	n += copy(resp[n:], accept[:])
	n += copy(resp[n:], "\r\n\r\n")
	sent, serr := _send(fd, resp[:n], false)
	if serr != .None || sent != n {
		return .Closed
	}
	clear(&w.head)
	shrink(&w.head)
	w.upgraded = true
	return .None
}

@(private)
_ws_accept_key :: proc(req: string) -> (accept: [28]u8, ok: bool) {
	lines := req
	first := true
	key: string
	upgrade, connection, version := false, false, false
	for line in strings.split_lines_iterator(&lines) {
		l := strings.trim_right(line, "\r")
		if first {
			first = false
			if !strings.has_prefix(l, "GET ") || !strings.has_suffix(l, " HTTP/1.1") {
				return
			}
			continue
		}
		colon := strings.index_byte(l, ':')
		if colon <= 0 {
			continue
		}
		name := strings.trim_space(l[:colon])
		value := strings.trim_space(l[colon + 1:])
		switch {
		case strings.equal_fold(name, "upgrade"):
			upgrade = strings.equal_fold(value, "websocket")
		case strings.equal_fold(name, "connection"):
			v := value
			for tok in strings.split_iterator(&v, ",") {
				if strings.equal_fold(strings.trim_space(tok), "upgrade") {
					connection = true
				}
			}
		case strings.equal_fold(name, "sec-websocket-version"):
			version = value == "13"
		case strings.equal_fold(name, "sec-websocket-key"):
			key = value
		}
	}
	if !upgrade || !connection || !version || len(key) != 24 {
		return
	}
	digest: [sha1.DIGEST_SIZE]u8
	ctx: sha1.Context
	sha1.init(&ctx)
	sha1.update(&ctx, transmute([]u8)key)
	sha1.update(&ctx, transmute([]u8)string(WS_GUID))
	sha1.final(&ctx, digest[:])
	_base64(digest[:], accept[:])
	return accept, true
}

@(private)
_base64 :: proc(src: []u8, dst: []u8) {
	TABLE := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	o := 0
	for i := 0; i < len(src); i += 3 {
		b0 := u32(src[i])
		b1 := u32(src[i + 1]) if i + 1 < len(src) else 0
		b2 := u32(src[i + 2]) if i + 2 < len(src) else 0
		v := b0 << 16 | b1 << 8 | b2
		dst[o] = TABLE[v >> 18 & 63]
		dst[o + 1] = TABLE[v >> 12 & 63]
		dst[o + 2] = TABLE[v >> 6 & 63] if i + 1 < len(src) else '='
		dst[o + 3] = TABLE[v & 63] if i + 2 < len(src) else '='
		o += 4
	}
}

ws_pending :: proc "contextless" (w: ^Ws) -> bool {
	return w.opos < len(w.out)
}

ws_flush :: proc(w: ^Ws, fd: prim.Fd) -> Error {
	for w.opos < len(w.out) {
		n, err := _send(fd, w.out[w.opos:], false)
		if err != .None {
			return err
		}
		w.opos += n
	}
	clear(&w.out)
	w.opos = 0
	if cap(w.out) > WS_OUT_MAX {
		shrink(&w.out)
	}
	return .None
}

@(private)
_ws_frame :: proc(w: ^Ws, opcode: u8, payload: []u8) {
	h: [10]u8
	h[0] = 0x80 | opcode
	n := 2
	switch {
	case len(payload) < 126:
		h[1] = u8(len(payload))
	case len(payload) <= 0xffff:
		h[1] = 126
		h[2] = u8(len(payload) >> 8)
		h[3] = u8(len(payload))
		n = 4
	case:
		h[1] = 127
		for i in 0 ..< 8 {
			h[2 + i] = u8(u64(len(payload)) >> (8 * u64(7 - i)))
		}
		n = 10
	}
	append(&w.out, ..h[:n])
	append(&w.out, ..payload)
}

ws_send :: proc(w: ^Ws, fd: prim.Fd, data: []u8) -> (used: int, err: Error) {
	if w.closed {
		return 0, .Closed
	}
	ws_flush(w, fd) or_return
	for used < len(data) && len(w.out) < WS_OUT_MAX {
		k := min(len(data) - used, WS_FRAME_MAX)
		_ws_frame(w, 2, data[used:][:k])
		used += k
	}
	if ferr := ws_flush(w, fd); ferr != .None && ferr != .Would_Block {
		return used, ferr
	}
	return used, .None
}

ws_recv :: proc(w: ^Ws, fd: prim.Fd, buf: []u8) -> (out: int, err: Error) {
	for out < len(buf) {
		if w.closed {
			break
		}
		if w.left > 0 && w.ipos < len(w.inb) && (w.opcode == 0 || w.opcode == 2) {
			k := int(min(w.left, i64(len(w.inb) - w.ipos), i64(len(buf) - out)))
			for i in 0 ..< k {
				buf[out + i] = w.inb[w.ipos + i] ~ w.mask[w.mpos & 3]
				w.mpos += 1
			}
			w.ipos += k
			out += k
			w.left -= i64(k)
			continue
		}
		if w.left == 0 || (w.opcode != 0 && w.opcode != 2) {
			done, perr := _ws_header(w, fd)
			if perr != .None {
				if out > 0 {
					break
				}
				_ws_compact(w)
				return 0, perr
			}
			if done {
				continue
			}
		}
		if out > 0 {
			break
		}
		_ws_fill(w, fd) or_return
	}
	_ws_compact(w)
	if out == 0 && w.closed {
		return 0, .Closed
	}
	return out, .None
}

@(private)
_ws_fill :: proc(w: ^Ws, fd: prim.Fd) -> Error {
	_ws_compact(w)
	tmp: [WS_READ]u8
	n, err := _recv(fd, tmp[:])
	if err != .None {
		return err
	}
	append(&w.inb, ..tmp[:n])
	return .None
}

@(private)
_ws_compact :: proc(w: ^Ws) {
	if w.ipos == 0 {
		return
	}
	rest := len(w.inb) - w.ipos
	if rest > 0 {
		copy(w.inb[:rest], w.inb[w.ipos:])
	}
	resize(&w.inb, rest)
	w.ipos = 0
	if rest == 0 {
		shrink(&w.inb)
	}
}

@(private)
_ws_header :: proc(w: ^Ws, fd: prim.Fd) -> (done: bool, err: Error) {
	for {
		avail := w.inb[w.ipos:]
		if len(avail) < 2 {
			_ws_fill(w, fd) or_return
			continue
		}
		b0, b1 := avail[0], avail[1]
		if b0 & 0x70 != 0 || b1 & 0x80 == 0 {
			return false, .Protocol
		}
		opcode := b0 & 0x0f
		n := 2
		length := i64(b1 & 0x7f)
		if length == 126 {
			n = 4
		} else if length == 127 {
			n = 10
		}
		if len(avail) < n + 4 {
			_ws_fill(w, fd) or_return
			continue
		}
		if length == 126 {
			length = i64(avail[2]) << 8 | i64(avail[3])
		} else if length == 127 {
			v: u64
			for i in 0 ..< 8 {
				v = v << 8 | u64(avail[2 + i])
			}
			if v >= u64(WS_PAYLOAD_LIMIT) {
				return false, .Protocol
			}
			length = i64(v)
		}
		mask: [4]u8
		copy(mask[:], avail[n:n + 4])
		switch opcode {
		case 0, 2:
			w.ipos += n + 4
			w.opcode = opcode
			w.left = length
			w.mask = mask
			w.mpos = 0
			return true, .None
		case 8, 9, 10:
			if length > 125 || b0 & 0x80 == 0 {
				return false, .Protocol
			}
			if i64(len(avail)) < i64(n + 4) + length {
				_ws_fill(w, fd) or_return
				continue
			}
			payload := avail[n + 4:][:length]
			for i in 0 ..< len(payload) {
				payload[i] ~= mask[i & 3]
			}
			w.ipos += n + 4 + int(length)
			switch opcode {
			case 8:
				_ws_frame(w, 8, payload[:min(len(payload), 2)])
				_ = ws_flush(w, fd)
				w.closed = true
				return false, .Closed
			case 9:
				_ws_frame(w, 10, payload)
				if ferr := ws_flush(w, fd); ferr != .None && ferr != .Would_Block {
					return false, ferr
				}
			}
			continue
		case:
			return false, .Protocol
		}
	}
}
