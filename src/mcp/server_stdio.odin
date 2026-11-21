package mcp

import "../prim"

Stdio_Server :: struct {
	server:    ^Server,
	loop:      ^prim.Loop,
	conn:      Conn_Id,
	in_fd:     prim.Fd,
	out_fd:    prim.Fd,
	w_in:      prim.Watch,
	w_out:     prim.Watch,
	lb:        prim.Line_Buffer,
	outq:      Out_Queue,
	poll_t:    prim.Timer,
	sync_out:  bool,
	closed:    bool,
	on_close:  proc(data: rawptr, ss: ^Stdio_Server),
	data:      rawptr,
}

stdio_server_open :: proc(ss: ^Stdio_Server, s: ^Server, loop: ^prim.Loop, in_fd := prim.Fd(0), out_fd := prim.Fd(1), on_close: proc(data: rawptr, ss: ^Stdio_Server) = nil, data: rawptr = nil, max_line := DEFAULT_MAX_LINE) -> prim.Error {
	ss^ = {}
	ss.server = s
	ss.loop = loop
	ss.in_fd = in_fd
	ss.out_fd = out_fd
	ss.on_close = on_close
	ss.data = data
	prim.line_buffer_init(&ss.lb, 64 * 1024, max_line, s.allocator)
	ss.conn = server_conn_open(s, Server_Sink{data = ss, send = _ss_send}, false)
	prim.set_nonblocking(in_fd)
	w, err := prim.watch(loop, in_fd, {.Read}, ss, _ss_on_in)
	if err != .None {
		ss.poll_t = prim.timer(loop, 0, ss, _ss_on_poll)
	} else {
		ss.w_in = w
	}
	prim.set_nonblocking(out_fd)
	wo, oerr := prim.watch(loop, out_fd, {}, ss, _ss_on_out)
	if oerr != .None {
		prim.set_nonblocking(out_fd, false)
		ss.sync_out = true
	} else {
		ss.w_out = wo
	}
	return .None
}

@(private)
_ss_send :: proc(data: rawptr, s: ^Server, conn: Conn_Id, stream: Stream_Id, body: []u8, final: bool, status: int) {
	ss := (^Stdio_Server)(data)
	if ss.closed && ss.out_fd == prim.INVALID_FD {
		return
	}
	nl := [1]u8{'\n'}
	if ss.sync_out {
		prim.write_all(ss.out_fd, body)
		prim.write_all(ss.out_fd, nl[:])
		return
	}
	if err := out_write(&ss.outq, ss.loop, ss.w_out, ss.out_fd, body, nl[:]); err != .None {
		out_destroy(&ss.outq)
		_ss_close(ss)
	}
}

@(private)
_ss_on_out :: proc(l: ^prim.Loop, fd: prim.Fd, events: prim.Events, data: rawptr) {
	ss := (^Stdio_Server)(data)
	if err := out_flush(&ss.outq, l, ss.w_out, fd); err != .None {
		out_destroy(&ss.outq)
		_ss_close(ss)
	}
}

@(private)
_ss_on_poll :: proc(l: ^prim.Loop, data: rawptr) {
	ss := (^Stdio_Server)(data)
	ss.poll_t = 0
	_ss_read(ss)
	if !ss.closed {
		ss.poll_t = prim.timer(l, 0 if !ss.lb.eof else 10, ss, _ss_on_poll)
	}
}

@(private)
_ss_on_in :: proc(l: ^prim.Loop, fd: prim.Fd, events: prim.Events, data: rawptr) {
	_ss_read((^Stdio_Server)(data))
}

@(private)
_ss_read :: proc(ss: ^Stdio_Server) {
	for !ss.closed {
		n, err := prim.line_fill(&ss.lb, ss.in_fd)
		if err == .Would_Block {
			return
		}
		if err == .Interrupted {
			continue
		}
		if err == .Too_Large {
			b := make(Buf, context.temp_allocator)
			write_response_error(&b, "null", JSONRPC_INVALID_REQUEST, "message too large")
			_ss_send(ss, ss.server, ss.conn, 0, b[:], true, 400)
			_ss_close(ss)
			return
		}
		if err != .None {
			prim.line_finish(&ss.lb)
		}
		for line in prim.line_next(&ss.lb) {
			text := json_trim(string(line))
			if len(text) == 0 {
				continue
			}
			server_feed(ss.server, ss.conn, 0, transmute([]u8)text)
			if ss.closed {
				return
			}
		}
		if ss.lb.eof {
			_ss_close(ss)
			return
		}
		if n == 0 {
			return
		}
	}
}

@(private)
_ss_close :: proc(ss: ^Stdio_Server) {
	if ss.closed {
		return
	}
	ss.closed = true
	if ss.w_in != 0 {
		prim.unwatch(ss.loop, ss.w_in)
		ss.w_in = 0
	}
	if ss.poll_t != 0 {
		prim.timer_cancel(ss.loop, ss.poll_t)
		ss.poll_t = 0
	}
	server_shutdown(ss.server)
	server_conn_close(ss.server, ss.conn)
	if ss.on_close != nil {
		ss.on_close(ss.data, ss)
	}
}

stdio_server_pending_output :: proc "contextless" (ss: ^Stdio_Server) -> int {
	return out_pending(&ss.outq)
}

stdio_server_close :: proc(ss: ^Stdio_Server) {
	_ss_close(ss)
}

stdio_server_destroy :: proc(ss: ^Stdio_Server) {
	_ss_close(ss)
	if ss.w_out != 0 {
		prim.unwatch(ss.loop, ss.w_out)
		ss.w_out = 0
	}
	out_destroy(&ss.outq)
	prim.line_buffer_destroy(&ss.lb)
}
