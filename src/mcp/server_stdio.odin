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
	batches:   [dynamic]Ss_Batch,
	next_batch: u64,
	shared:    bool,
	released:  bool,
}

@(private)
Ss_Batch :: struct {
	stream:   Stream_Id,
	expected: int,
	got:      int,
	buf:      Buf,
}

stdio_server_open :: proc(ss: ^Stdio_Server, s: ^Server, loop: ^prim.Loop, in_fd := prim.Fd(0), out_fd := prim.Fd(1), on_close: proc(data: rawptr, ss: ^Stdio_Server) = nil, data: rawptr = nil, max_line := DEFAULT_MAX_LINE) -> prim.Error {
	ss^ = {}
	ss.server = s
	ss.loop = loop
	ss.in_fd = in_fd
	ss.out_fd = out_fd
	ss.on_close = on_close
	ss.data = data
	ss.shared = in_fd == out_fd
	ss.batches = make([dynamic]Ss_Batch, s.allocator)
	ss.next_batch = 1
	prim.line_buffer_init(&ss.lb, 64 * 1024, max_line, s.allocator)
	prim.set_nonblocking(in_fd)
	if !ss.shared {
		prim.set_nonblocking(out_fd)
	}
	ss.conn = server_conn_open(s, Server_Sink{data = ss, send = _ss_send}, false)
	w, err := prim.watch(loop, in_fd, {.Read}, ss, _ss_on_io)
	if err != .None {
		if ss.shared {
			server_conn_close(s, ss.conn)
			prim.line_buffer_destroy(&ss.lb)
			delete(ss.batches)
			return err
		}
		ss.poll_t = prim.timer(loop, 0, ss, _ss_on_poll)
	} else {
		ss.w_in = w
	}
	if ss.shared {
		ss.w_out = ss.w_in
		ss.outq.base = {.Read}
		return .None
	}
	wo, oerr := prim.watch(loop, out_fd, {}, ss, _ss_on_io)
	if oerr != .None {
		ss.sync_out = true
	} else {
		ss.w_out = wo
	}
	return .None
}

@(private)
_ss_send :: proc(data: rawptr, s: ^Server, conn: Conn_Id, stream: Stream_Id, body: []u8, final: bool, status: int) {
	ss := (^Stdio_Server)(data)
	if ss.released {
		return
	}
	if final && stream != 0 {
		for &bt, i in ss.batches {
			if bt.stream != stream {
				continue
			}
			bt.got += 1
			if len(body) > 0 {
				w_sep(&bt.buf)
				append(&bt.buf, ..body)
			}
			if bt.got < bt.expected {
				return
			}
			out := make(Buf, 0, len(bt.buf) + 2, context.temp_allocator)
			append(&out, '[')
			append(&out, ..bt.buf[:])
			append(&out, ']')
			delete(bt.buf)
			ordered_remove(&ss.batches, i)
			if len(out) > 2 {
				_ss_write(ss, out[:])
			}
			return
		}
	}
	_ss_write(ss, body)
}

@(private)
_ss_write :: proc(ss: ^Stdio_Server, body: []u8) {
	nl := [1]u8{'\n'}
	if ss.sync_out {
		_ss_write_sync(ss.out_fd, body)
		_ss_write_sync(ss.out_fd, nl[:])
		return
	}
	if err := out_write(&ss.outq, ss.loop, ss.w_out, ss.out_fd, body, nl[:]); err != .None {
		out_destroy(&ss.outq)
		_ss_close(ss)
		_ss_release(ss)
	}
}

@(private)
_ss_write_sync :: proc(fd: prim.Fd, data: []u8) {
	rest := data
	for len(rest) > 0 {
		n, err := prim.write(fd, rest)
		if err == .Interrupted || err == .Would_Block {
			continue
		}
		if err != .None {
			return
		}
		rest = rest[n:]
	}
}

@(private)
_ss_on_io :: proc(l: ^prim.Loop, fd: prim.Fd, events: prim.Events, data: rawptr) {
	ss := (^Stdio_Server)(data)
	if fd == ss.out_fd && (.Write in events || .Error in events || .Hangup in events) && out_pending(&ss.outq) > 0 {
		if err := out_flush(&ss.outq, l, ss.w_out, fd); err != .None {
			out_destroy(&ss.outq)
			_ss_close(ss)
			_ss_release(ss)
			return
		}
		if ss.closed && out_pending(&ss.outq) == 0 {
			_ss_release(ss)
			return
		}
	}
	if fd == ss.in_fd && !ss.closed {
		_ss_read(ss)
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
			if json_kind(text) == .Array {
				count := server_batch_responses(text)
				stream := Stream_Id(0)
				if count > 0 {
					stream = Stream_Id(1 << 48 + ss.next_batch)
					ss.next_batch += 1
					append(&ss.batches, Ss_Batch{stream = stream, expected = count, buf = make(Buf, ss.server.allocator)})
				}
				server_feed(ss.server, ss.conn, stream, transmute([]u8)text)
			} else {
				server_feed(ss.server, ss.conn, 0, transmute([]u8)text)
			}
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
	if ss.poll_t != 0 {
		prim.timer_cancel(ss.loop, ss.poll_t)
		ss.poll_t = 0
	}
	if ss.shared {
		ss.outq.base = {}
		prim.watch_modify(ss.loop, ss.w_in, {.Write} if out_pending(&ss.outq) > 0 else {})
	} else if ss.w_in != 0 {
		prim.unwatch(ss.loop, ss.w_in)
		ss.w_in = 0
	}
	server_shutdown(ss.server, ss.conn)
	server_conn_close(ss.server, ss.conn)
	ss.conn = 0
	if out_pending(&ss.outq) == 0 {
		_ss_release(ss)
	}
}

@(private)
_ss_release :: proc(ss: ^Stdio_Server) {
	if ss.released {
		return
	}
	ss.released = true
	ss.closed = true
	if ss.poll_t != 0 {
		prim.timer_cancel(ss.loop, ss.poll_t)
		ss.poll_t = 0
	}
	if ss.w_out != 0 {
		prim.unwatch(ss.loop, ss.w_out)
	}
	if ss.w_in != 0 && ss.w_in != ss.w_out {
		prim.unwatch(ss.loop, ss.w_in)
	}
	ss.w_in = 0
	ss.w_out = 0
	if ss.conn != 0 {
		server_conn_close(ss.server, ss.conn)
		ss.conn = 0
	}
	out_destroy(&ss.outq)
	prim.line_buffer_destroy(&ss.lb)
	for bt in ss.batches {
		delete(bt.buf)
	}
	delete(ss.batches)
	ss.batches = nil
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

stdio_server_released :: proc "contextless" (ss: ^Stdio_Server) -> bool {
	return ss.released
}

stdio_server_destroy :: proc(ss: ^Stdio_Server) {
	_ss_close(ss)
	on_close := ss.on_close
	ss.on_close = nil
	_ss_release(ss)
	ss.on_close = on_close
}
