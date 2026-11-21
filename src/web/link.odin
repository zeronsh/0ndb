package web

import "core:crypto"
import osync "../sync"

Link_State :: enum u8 {
	Down,
	Handshake,
	Ready,
	Failed,
}

Link :: struct {
	state:  Link_State,
	client: osync.Client,
	tx:     osync.Tls_Dir,
	rx:     osync.Tls_Dir,
	inbuf:  [dynamic]u8,
	out:    [dynamic]u8,
}

link_init :: proc(l: ^Link, allocator := context.allocator) {
	l^ = {}
	osync.client_init(&l.client, allocator)
	l.inbuf = make([dynamic]u8, allocator)
	l.out = make([dynamic]u8, allocator)
}

link_destroy :: proc(l: ^Link) {
	link_reset(l)
	osync.client_destroy(&l.client)
	delete(l.inbuf)
	delete(l.out)
	l^ = {}
}

link_reset :: proc(l: ^Link) {
	osync.tls_dir_reset(&l.tx)
	osync.tls_dir_reset(&l.rx)
	osync.client_reset(&l.client)
	crypto.zero_explicit(raw_data(l.inbuf), len(l.inbuf))
	clear(&l.inbuf)
	clear(&l.out)
	l.state = .Down
}

link_begin :: proc(l: ^Link, device: ^osync.Device, relay_public: osync.Public_Key) -> osync.Error {
	link_reset(l)
	buf: [2 + osync.MSG1_LEN]u8
	n := osync.client_begin(&l.client, &device.noise, relay_public, buf[:]) or_return
	append(&l.out, ..buf[:n])
	l.state = .Handshake
	return .None
}

link_input :: proc(l: ^Link, data: []u8, creds: ^osync.Credentials, handler: osync.Client_Handler, user: rawptr) -> (hello: bool, err: osync.Error) {
	rest := data
	if l.state == .Handshake {
		for len(rest) > 0 && l.state == .Handshake {
			need := osync.client_handshake_need(&l.client)
			n := min(need, len(rest))
			done, ferr := osync.client_handshake_feed(&l.client, rest[:n])
			rest = rest[n:]
			if ferr != .None {
				l.state = .Failed
				return false, ferr
			}
			if done {
				keys := osync.client_keys(&l.client)
				osync.tls_dir_init(&l.tx, &keys.tx)
				osync.tls_dir_init(&l.rx, &keys.rx)
				if herr := osync.client_hello(&l.client, creds); herr != .None {
					l.state = .Failed
					return false, herr
				}
				l.state = .Ready
				hello = true
				link_flush(l)
			}
		}
	}
	if l.state != .Ready || len(rest) == 0 {
		return hello, .None
	}
	append(&l.inbuf, ..rest)
	pos := 0
	for len(l.inbuf) - pos >= osync.TLS_HEADER {
		total := osync.tls_record_len(l.inbuf[pos:pos + osync.TLS_HEADER]) or_return
		if len(l.inbuf) - pos < total {
			break
		}
		plain, oerr := osync.tls_open(&l.rx, l.inbuf[pos:pos + total])
		if oerr != .None {
			l.state = .Failed
			return hello, oerr
		}
		pos += total
		if len(plain) > 0 {
			if ferr := osync.client_feed(&l.client, plain, handler, user); ferr != .None {
				l.state = .Failed
				return hello, ferr
			}
		}
	}
	if pos > 0 {
		left := len(l.inbuf) - pos
		copy(l.inbuf[:left], l.inbuf[pos:])
		crypto.zero_explicit(raw_data(l.inbuf[left:]), pos)
		resize(&l.inbuf, left)
	}
	if len(l.inbuf) == 0 && cap(l.inbuf) > 1 << 20 {
		delete(l.inbuf)
		l.inbuf = make([dynamic]u8, l.client.allocator)
	}
	return hello, .None
}

link_flush :: proc(l: ^Link) {
	if l.state != .Ready {
		return
	}
	for {
		p := osync.client_pending(&l.client)
		if len(p) == 0 {
			return
		}
		n := min(len(p), osync.TLS_MAX_PLAIN)
		start := len(l.out)
		resize(&l.out, start + n + osync.TLS_OVERHEAD)
		w := osync.tls_seal(&l.tx, l.out[start:], p[:n])
		resize(&l.out, start + w)
		osync.client_consumed(&l.client, n)
	}
}
