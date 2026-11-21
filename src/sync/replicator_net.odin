#+build linux, darwin
package osync

import "base:runtime"
import csync "core:sync"
import "core:thread"
import "../prim"

Resolver :: struct {
	thread:   ^thread.Thread,
	notifier: _Notifier,
	watch:    prim.Watch,
	input:    Endpoint,
	output:   Endpoint,
	err:      Error,
	done:     bool,
	mutex:    csync.Mutex,
}

@(private)
_resolver_main :: proc(data: rawptr) {
	r := cast(^Replicator)data
	res := &r.resolver
	out, err := endpoint_resolve(&res.input)
	csync.mutex_lock(&res.mutex)
	res.output = out
	res.err = err
	res.done = true
	csync.mutex_unlock(&res.mutex)
	_notifier_signal(&res.notifier)
	free_all(context.temp_allocator)
}

@(private)
_resolver_start :: proc(r: ^Replicator) -> Error {
	res := &r.resolver
	_notifier_open(&res.notifier) or_return
	w, werr := prim.watch(r.loop, _notifier_fd(&res.notifier), {.Read}, r, _on_resolved)
	if werr != .None {
		_notifier_close(&res.notifier)
		return _from_prim(werr)
	}
	res.watch = w
	res.input = r.endpoint
	res.done = false
	res.thread = thread.create_and_start_with_data(r, _resolver_main, init_context = runtime.default_context())
	if res.thread == nil {
		prim.unwatch(r.loop, w)
		_notifier_close(&res.notifier)
		res.watch = 0
		return .No_Memory
	}
	return .None
}

@(private)
_resolver_stop :: proc(r: ^Replicator) {
	res := &r.resolver
	if res.thread != nil {
		thread.join(res.thread)
		thread.destroy(res.thread)
		res.thread = nil
	}
	if res.watch != 0 {
		prim.unwatch(r.loop, res.watch)
		res.watch = 0
		_notifier_close(&res.notifier)
	}
}

@(private)
_on_resolved :: proc(l: ^prim.Loop, fd: prim.Fd, events: prim.Events, data: rawptr) {
	r := cast(^Replicator)data
	_enter(r)
	defer _leave(r)
	res := &r.resolver
	_notifier_drain(&res.notifier)
	csync.mutex_lock(&res.mutex)
	done := res.done
	ep := res.output
	err := res.err
	csync.mutex_unlock(&res.mutex)
	if !done {
		return
	}
	_resolver_stop(r)
	if r.phase != .Resolving {
		return
	}
	if err != .None {
		_repl_fail(r, err)
		return
	}
	_repl_dial(r, &ep)
}

@(private)
_repl_connect :: proc(r: ^Replicator) {
	if r.timer != 0 {
		prim.timer_cancel(r.loop, r.timer)
		r.timer = 0
	}
	if r.endpoint.family == .Host {
		r.phase = .Resolving
		r.timer = prim.timer(r.loop, CONNECT_TIMEOUT, r, _on_connect_timeout)
		if err := _resolver_start(r); err != .None {
			_repl_fail(r, err)
		}
		return
	}
	ep := r.endpoint
	r.timer = prim.timer(r.loop, CONNECT_TIMEOUT, r, _on_connect_timeout)
	_repl_dial(r, &ep)
}

@(private)
_repl_dial :: proc(r: ^Replicator, ep: ^Endpoint) {
	fd, pending, err := _connect(ep)
	if err != .None {
		_repl_fail(r, err)
		return
	}
	r.fd = fd
	transport_init_plain(&r.tr, fd, r.allocator)
	if ep.family != .Unix {
		_tune_tcp(fd)
	}
	w, werr := prim.watch(r.loop, fd, {.Read, .Write}, r, _on_repl_io)
	if werr != .None {
		_repl_fail(r, _from_prim(werr))
		return
	}
	r.watch = w
	r.phase = .Connecting
	if !pending {
		_repl_connected(r)
	}
}

@(private)
_repl_connected :: proc(r: ^Replicator) {
	if r.endpoint.family == .Unix {
		client_begin_plain(&r.client)
		_repl_hello(r)
		return
	}
	buf: [2 + MSG1_LEN]u8
	n, err := client_begin(&r.client, &r.static, r.cfg.relay_public, buf[:], r.cfg.random)
	if err != .None {
		_repl_fail(r, err)
		return
	}
	w, serr := _send(r.fd, buf[:n], false)
	if serr != .None || w != n {
		_repl_fail(r, .Closed if serr == .None else serr)
		return
	}
	r.phase = .Handshake
}

@(private)
_repl_hello :: proc(r: ^Replicator) {
	if !r.client.unix {
		transport_init_secure(&r.tr, r.fd, client_keys(&r.client), r.cfg.kernel_tls, r.allocator)
	}
	if err := client_hello(&r.client, &r.cfg.credentials); err != .None {
		_repl_fail(r, err)
		return
	}
	r.phase = .Hello
	_repl_flush(r)
}

@(private)
_on_connect_timeout :: proc(l: ^prim.Loop, data: rawptr) {
	r := cast(^Replicator)data
	_enter(r)
	defer _leave(r)
	r.timer = 0
	switch r.phase {
	case .Resolving, .Connecting, .Handshake, .Hello:
		_repl_fail(r, .Timeout)
	case .Waiting:
		_repl_connect(r)
	case .Stopped, .Ready:
	}
}

@(private)
_on_repl_io :: proc(l: ^prim.Loop, fd: prim.Fd, events: prim.Events, data: rawptr) {
	r := cast(^Replicator)data
	_enter(r)
	defer _leave(r)
	if r.phase == .Connecting {
		if .Write not_in events && .Error not_in events && .Hangup not_in events {
			return
		}
		if err := _socket_error(r.fd); err != .None {
			_repl_fail(r, err)
			return
		}
		_repl_connected(r)
		if r.phase == .Waiting {
			return
		}
	}
	if r.phase == .Handshake {
		for r.phase == .Handshake {
			buf: [2 + MSG2_LEN]u8
			need := client_handshake_need(&r.client)
			n, err := _recv(r.fd, buf[:need])
			if err == .Would_Block {
				return
			}
			if err != .None {
				_repl_fail(r, err)
				return
			}
			done, ferr := client_handshake_feed(&r.client, buf[:n])
			if ferr != .None {
				_repl_fail(r, ferr)
				return
			}
			if done {
				_repl_hello(r)
			}
		}
	}
	if r.phase != .Hello && r.phase != .Ready {
		return
	}
	_repl_read(r)
	if r.phase == .Hello || r.phase == .Ready {
		_repl_pump(r)
	}
}

@(private)
_repl_read :: proc(r: ^Replicator) {
	if r.rbuf == nil {
		b, aerr := make([]u8, RSCRATCH, r.allocator)
		if aerr != nil {
			_repl_fail(r, .No_Memory)
			return
		}
		r.rbuf = b
	}
	for r.phase == .Hello || r.phase == .Ready {
		n, err := transport_recv(&r.tr, r.rbuf)
		if err == .Would_Block {
			return
		}
		if err != .None {
			_repl_fail(r, err)
			return
		}
		if ferr := client_feed(&r.client, r.rbuf[:n], _on_event, r); ferr != .None {
			_repl_fail(r, ferr)
			return
		}
	}
}

@(private)
_repl_flush :: proc(r: ^Replicator) {
	if r.phase != .Hello && r.phase != .Ready {
		return
	}
	for {
		if !r.external && transport_pending(&r.tr) {
			err := transport_flush(&r.tr)
			if err == .Would_Block {
				return
			}
			if err != .None {
				_repl_fail(r, err)
				return
			}
		}
		b := client_pending(&r.client)
		if len(b) == 0 {
			if r.objs.active != nil && r.phase == .Ready && !r.pumping {
				_objs_fill(r)
				if len(client_pending(&r.client)) > 0 {
					continue
				}
			}
			return
		}
		n: int
		err: Error
		if r.external {
			n, err = r.cfg.link.send(r.cfg.link.data, b)
		} else {
			n, err = transport_send(&r.tr, b)
		}
		if err == .Would_Block {
			return
		}
		if err != .None {
			_repl_fail(r, err)
			return
		}
		client_consumed(&r.client, n)
	}
}

replicator_link_up :: proc(r: ^Replicator, binding: []u8 = nil) -> Error {
	_enter(r)
	defer _leave(r)
	if !r.external {
		return .Invalid
	}
	_repl_close(r)
	client_begin_plain(&r.client, binding)
	r.phase = .Waiting
	_repl_hello(r)
	return .None
}

replicator_input :: proc(r: ^Replicator, data: []u8) -> Error {
	_enter(r)
	defer _leave(r)
	if !r.external || (r.phase != .Hello && r.phase != .Ready) {
		return .Closed
	}
	if err := client_feed(&r.client, data, _on_event, r); err != .None {
		_repl_fail(r, err)
		return err
	}
	if r.phase == .Hello || r.phase == .Ready {
		_repl_pump(r)
	}
	return .None
}

replicator_writable :: proc(r: ^Replicator) {
	_enter(r)
	defer _leave(r)
	_repl_pump(r)
}

replicator_link_down :: proc(r: ^Replicator, err: Error = .Closed) {
	_enter(r)
	defer _leave(r)
	if !r.external || r.phase == .Stopped {
		return
	}
	was := r.phase
	_repl_close(r)
	r.phase = .Stopped
	if was == .Ready {
		_emit(r, Repl_Event{kind = .Disconnected, err = err})
	}
}

@(private)
_repl_close :: proc(r: ^Replicator) {
	if r.deadline != 0 {
		prim.timer_cancel(r.loop, r.deadline)
		r.deadline = 0
	}
	if r.watch != 0 {
		prim.unwatch(r.loop, r.watch)
		r.watch = 0
	}
	if r.tr.fd >= 0 {
		transport_close(&r.tr)
	} else if r.fd >= 0 {
		prim.close(r.fd)
	}
	r.fd = prim.INVALID_FD
	r.tr.fd = prim.INVALID_FD
	if r.locals != nil {
		_repl_reset_state(r)
	}
	client_reset(&r.client)
}

@(private)
_repl_fail :: proc(r: ^Replicator, err: Error) {
	if r.external {
		live := r.phase != .Stopped
		replicator_link_down(r, err)
		if live && r.cfg.link.close != nil {
			r.cfg.link.close(r.cfg.link.data)
		}
		return
	}
	was := r.phase
	_repl_close(r)
	_resolver_stop(r)
	if len(r.endpoints) > 1 {
		r.relay_at = (r.relay_at + 1) % len(r.endpoints)
		r.endpoint = r.endpoints[r.relay_at]
		r.cfg.relay_public = r.publics[r.relay_at]
		r.feed_cursor = -1
		r.listed = false
		r.cursor = 0
	}
	if r.timer != 0 {
		prim.timer_cancel(r.loop, r.timer)
		r.timer = 0
	}
	if was == .Stopped {
		return
	}
	r.phase = .Waiting
	jitter: [2]u8
	prim.random_fill(r.cfg.random, jitter[:])
	delay := r.backoff * 3 / 4 + r.backoff * i64(u16(jitter[0]) | u16(jitter[1]) << 8) / (2 * 65536)
	r.backoff = min(r.backoff * 2, BACKOFF_MAX)
	r.timer = prim.timer(r.loop, delay, r, _on_connect_timeout)
	if was == .Ready {
		_emit(r, Repl_Event{kind = .Disconnected, err = err})
	}
}
