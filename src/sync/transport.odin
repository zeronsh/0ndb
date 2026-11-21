#+build linux, darwin
package osync

import "base:runtime"
import "core:net"
import "core:strconv"
import "../prim"

Family :: enum u8 {
	None,
	Ip4,
	Ip6,
	Unix,
	Host,
}

Endpoint :: struct {
	family:   Family,
	port:     u16,
	addr:     [16]u8,
	path:     [108]u8,
	path_len: int,
	host:     [MAX_ADDR]u8,
	host_len: int,
}

Transport :: struct {
	fd:        prim.Fd,
	secure:    bool,
	ktx:       bool,
	krx:       bool,
	tx:        Tls_Dir,
	rx:        Tls_Dir,
	wbuf:      []u8,
	wpos:      int,
	wlen:      int,
	rbuf:      []u8,
	rlen:      int,
	rec:       int,
	ppos:      int,
	pend:      int,
	ws:        ^Ws,
	allocator: runtime.Allocator,
}

@(private)
WBUF_RECORDS :: 4
@(private)
WBUF_SIZE :: WBUF_RECORDS * (TLS_MAX_PLAIN + TLS_OVERHEAD)
@(private)
RBUF_SIZE :: 2 * TLS_MAX_RECORD

endpoint_parse :: proc(s: string) -> (ep: Endpoint, err: Error) {
	if len(s) > 5 && s[:5] == "unix:" {
		path := s[5:]
		if len(path) == 0 || len(path) >= len(ep.path) {
			return {}, .Invalid
		}
		ep.family = .Unix
		ep.path_len = copy(ep.path[:], path)
		return ep, .None
	}
	if parsed, ok := net.parse_endpoint(s); ok {
		if parsed.port <= 0 || parsed.port > 65535 {
			return {}, .Invalid
		}
		ep.port = u16(parsed.port)
		switch a in parsed.address {
		case net.IP4_Address:
			ep.family = .Ip4
			for i in 0 ..< 4 {
				ep.addr[i] = a[i]
			}
		case net.IP6_Address:
			ep.family = .Ip6
			for i in 0 ..< 8 {
				ep.addr[2 * i] = u8(u16(a[i]) >> 8)
				ep.addr[2 * i + 1] = u8(u16(a[i]))
			}
		case:
			return {}, .Invalid
		}
		return ep, .None
	}
	colon := -1
	for i := len(s) - 1; i >= 0; i -= 1 {
		if s[i] == ':' {
			colon = i
			break
		}
	}
	if colon <= 0 || colon == len(s) - 1 || colon > MAX_ADDR {
		return {}, .Invalid
	}
	port, ok := strconv.parse_u64_of_base(s[colon + 1:], 10)
	if !ok || port == 0 || port > 65535 {
		return {}, .Invalid
	}
	for c in transmute([]u8)s[:colon] {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '.':
		case:
			return {}, .Invalid
		}
	}
	ep.family = .Host
	ep.port = u16(port)
	ep.host_len = copy(ep.host[:], s[:colon])
	return ep, .None
}

endpoint_resolve :: proc(ep: ^Endpoint) -> (out: Endpoint, err: Error) {
	if ep.family != .Host {
		return ep^, .None
	}
	ep4, ep6, nerr := net.resolve(string(ep.host[:ep.host_len]))
	if nerr != nil {
		return {}, .Resolve
	}
	out.port = ep.port
	if a, ok := ep4.address.(net.IP4_Address); ok {
		out.family = .Ip4
		for i in 0 ..< 4 {
			out.addr[i] = a[i]
		}
		return out, .None
	}
	if a, ok := ep6.address.(net.IP6_Address); ok {
		out.family = .Ip6
		for i in 0 ..< 8 {
			out.addr[2 * i] = u8(u16(a[i]) >> 8)
			out.addr[2 * i + 1] = u8(u16(a[i]))
		}
		return out, .None
	}
	return {}, .Resolve
}

transport_init_plain :: proc(t: ^Transport, fd: prim.Fd, allocator := context.allocator) {
	t^ = {
		fd        = fd,
		allocator = allocator,
	}
}

transport_init_secure :: proc(t: ^Transport, fd: prim.Fd, keys: ^Session_Keys, try_kernel: bool, allocator := context.allocator) {
	ws := t.ws
	t^ = {
		fd        = fd,
		secure    = true,
		ws        = ws,
		allocator = allocator,
	}
	if try_kernel && ws == nil {
		t.ktx, t.krx = _ktls_install(fd, keys)
	}
	if !t.ktx {
		tls_dir_init(&t.tx, &keys.tx)
	}
	if !t.krx {
		tls_dir_init(&t.rx, &keys.rx)
	}
}

transport_close :: proc(t: ^Transport) {
	if t.fd >= 0 {
		prim.close(t.fd)
	}
	tls_dir_reset(&t.tx)
	tls_dir_reset(&t.rx)
	if t.wbuf != nil {
		delete(t.wbuf, t.allocator)
	}
	if t.rbuf != nil {
		delete(t.rbuf, t.allocator)
	}
	ws_free(t.ws)
	t^ = {
		fd = prim.INVALID_FD,
	}
}

@(private)
_t_send :: proc(t: ^Transport, data: []u8, more: bool) -> (int, Error) {
	if t.ws != nil {
		return ws_send(t.ws, t.fd, data)
	}
	return _send(t.fd, data, more)
}

@(private)
_t_recv :: proc(t: ^Transport, buf: []u8) -> (int, Error) {
	if t.ws != nil {
		return ws_recv(t.ws, t.fd, buf)
	}
	return _recv(t.fd, buf)
}

transport_user_tx :: proc "contextless" (t: ^Transport) -> bool {
	return t.secure && !t.ktx
}

transport_user_rx :: proc "contextless" (t: ^Transport) -> bool {
	return t.secure && !t.krx
}

transport_flush :: proc(t: ^Transport) -> Error {
	if t.ws != nil {
		ws_flush(t.ws, t.fd) or_return
	}
	for t.wpos < t.wlen {
		n, err := _t_send(t, t.wbuf[t.wpos:t.wlen], false)
		if err != .None {
			return err
		}
		t.wpos += n
	}
	t.wpos = 0
	t.wlen = 0
	if t.wbuf != nil {
		delete(t.wbuf, t.allocator)
		t.wbuf = nil
	}
	return .None
}

transport_pending :: proc "contextless" (t: ^Transport) -> bool {
	return t.wpos < t.wlen || (t.ws != nil && ws_pending(t.ws))
}

transport_send :: proc(t: ^Transport, data: []u8, more := false) -> (used: int, err: Error) {
	if len(data) == 0 {
		return 0, .None
	}
	if !transport_user_tx(t) {
		return _t_send(t, data, more)
	}
	transport_flush(t) or_return
	if t.wbuf == nil {
		b, aerr := make([]u8, WBUF_SIZE, t.allocator)
		if aerr != nil {
			return 0, .No_Memory
		}
		t.wbuf = b
	}
	for used < len(data) && WBUF_SIZE - t.wlen >= TLS_OVERHEAD + 1 {
		room := WBUF_SIZE - t.wlen - TLS_OVERHEAD
		n := min(len(data) - used, TLS_MAX_PLAIN, room)
		t.wlen += tls_seal(&t.tx, t.wbuf[t.wlen:], data[used:][:n])
		used += n
	}
	if ferr := transport_flush(t); ferr != .None && ferr != .Would_Block {
		return used, ferr
	}
	return used, .None
}

transport_sendfile :: proc(t: ^Transport, src: prim.Fd, off: i64, n: int, scratch: []u8) -> (sent: int, err: Error) {
	if n <= 0 {
		return 0, .None
	}
	if !transport_user_tx(t) && t.ws == nil {
		w, serr := _sendfile(t.fd, src, off, n)
		if serr != .Unsupported {
			return w, serr
		}
	}
	if transport_user_tx(t) {
		transport_flush(t) or_return
	}
	want := min(n, len(scratch))
	if transport_user_tx(t) {
		want = min(want, WBUF_RECORDS * TLS_MAX_PLAIN)
	}
	got, rerr := prim.read_at(prim.os_vfs(), src, scratch[:want], off)
	if rerr != .None {
		return 0, _from_prim(rerr)
	}
	if got < want {
		return 0, .Corrupt
	}
	return transport_send(t, scratch[:got], got < n)
}

transport_recv :: proc(t: ^Transport, buf: []u8) -> (int, Error) {
	if !transport_user_rx(t) {
		return _t_recv(t, buf)
	}
	out := 0
	for out < len(buf) {
		if t.ppos < t.pend {
			k := copy(buf[out:], t.rbuf[t.ppos:t.pend])
			t.ppos += k
			out += k
			if t.ppos < t.pend {
				break
			}
			_rx_consume(t)
			continue
		}
		if t.rlen >= TLS_HEADER {
			total, herr := tls_record_len(t.rbuf[:TLS_HEADER])
			if herr != .None {
				return out, herr
			}
			if t.rlen >= total {
				plain, oerr := tls_open(&t.rx, t.rbuf[:total])
				if oerr != .None {
					return out, oerr
				}
				t.rec = total
				t.ppos = TLS_HEADER
				t.pend = TLS_HEADER + len(plain)
				if len(plain) == 0 {
					_rx_consume(t)
				}
				continue
			}
		}
		if out > 0 {
			break
		}
		if t.rbuf == nil {
			b, aerr := make([]u8, RBUF_SIZE, t.allocator)
			if aerr != nil {
				return out, .No_Memory
			}
			t.rbuf = b
		}
		n, err := _t_recv(t, t.rbuf[t.rlen:])
		if err != .None {
			if out > 0 && err == .Would_Block {
				break
			}
			if out > 0 {
				return out, .None
			}
			_rx_release(t)
			return 0, err
		}
		t.rlen += n
	}
	_rx_release(t)
	return out, .None
}

@(private)
_rx_consume :: proc(t: ^Transport) {
	rest := t.rlen - t.rec
	if rest > 0 {
		copy(t.rbuf[:rest], t.rbuf[t.rec:t.rlen])
	}
	t.rlen = rest
	t.rec = 0
	t.ppos = 0
	t.pend = 0
}

@(private)
_rx_release :: proc(t: ^Transport) {
	if t.rbuf != nil && t.rlen == 0 && t.pend == 0 {
		delete(t.rbuf, t.allocator)
		t.rbuf = nil
	}
}
