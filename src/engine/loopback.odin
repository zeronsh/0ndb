package engine

import "base:runtime"
import "core:sync"
import "../prim"
import osync "../sync"

Hub :: struct {
	loop:      ^prim.Loop,
	relay:     ^osync.Relay,
	mu:        sync.Mutex,
	conns:     [dynamic]^Hub_Conn,
	prev_wake: prim.Wake_Proc,
	prev_data: rawptr,
	allocator: runtime.Allocator,
	scratch:   []u8,
}

@(private)
Hub_Conn :: struct {
	hub:        ^Hub,
	e:          ^Engine,
	link:       Link,
	ref:        osync.Conn_Ref,
	attached:   bool,
	want_attach: bool,
	want_detach: bool,
	up:         bool,
	down:       bool,
	dead:       bool,
	to_relay:   [dynamic]u8,
	to_engine:  [dynamic]u8,
	work:       [dynamic]u8,
}

hub_init :: proc(h: ^Hub, relay: ^osync.Relay, relay_loop: ^prim.Loop, allocator := context.allocator) {
	h^ = {
		loop      = relay_loop,
		relay     = relay,
		allocator = allocator,
	}
	h.conns = make([dynamic]^Hub_Conn, allocator)
	h.prev_wake = relay_loop.wake_cb
	h.prev_data = relay_loop.wake_data
	h.scratch = make([]u8, 256 * 1024, allocator)
	prim.loop_on_wake(relay_loop, _hub_wake, h)
}

hub_destroy :: proc(h: ^Hub) {
	if h.loop != nil && h.loop.wake_cb == _hub_wake && h.loop.wake_data == rawptr(h) {
		prim.loop_on_wake(h.loop, h.prev_wake, h.prev_data)
	}
	for c in h.conns {
		if c.attached {
			osync.relay_detach(h.relay, c.ref)
		}
		delete(c.to_relay)
		delete(c.to_engine)
		delete(c.work)
		free(c, h.allocator)
	}
	delete(h.conns)
	delete(h.scratch, h.allocator)
	h^ = {}
}

hub_transport :: proc(h: ^Hub) -> Transport {
	return Transport{data = h, open = _hub_open, send = _hub_send, close = _hub_close}
}

on_wake :: proc(e: ^Engine, call: proc(e: ^Engine, data: rawptr), data: rawptr) {
	context = context_for(e)
	append(&e.wake_hooks, Posted{call, data})
}

@(private)
_hub_open :: proc(data: rawptr, e: ^Engine, link: Link, peer: Peer) -> (conn: rawptr, err: Error) {
	h := (^Hub)(data)
	c := new(Hub_Conn, h.allocator)
	c.hub = h
	c.e = e
	c.link = link
	c.want_attach = true
	c.to_relay = make([dynamic]u8, h.allocator)
	c.to_engine = make([dynamic]u8, h.allocator)
	c.work = make([dynamic]u8, h.allocator)
	registered := false
	for hk in e.wake_hooks {
		registered ||= hk.data == rawptr(h)
	}
	if !registered {
		on_wake(e, _hub_engine_drain, h)
	}
	sync.mutex_lock(&h.mu)
	append(&h.conns, c)
	sync.mutex_unlock(&h.mu)
	prim.wake(h.loop)
	return c, .None
}

@(private)
_hub_send :: proc(data: rawptr, conn: rawptr, bytes: []u8) -> (int, Error) {
	h := (^Hub)(data)
	c := (^Hub_Conn)(conn)
	sync.mutex_lock(&h.mu)
	dead := c.dead || c.want_detach
	if !dead {
		append(&c.to_relay, ..bytes)
	}
	sync.mutex_unlock(&h.mu)
	if dead {
		return 0, .Closed
	}
	prim.wake(h.loop)
	return len(bytes), .None
}

@(private)
_hub_close :: proc(data: rawptr, conn: rawptr) {
	h := (^Hub)(data)
	c := (^Hub_Conn)(conn)
	sync.mutex_lock(&h.mu)
	c.want_detach = true
	c.e = nil
	sync.mutex_unlock(&h.mu)
	prim.wake(h.loop)
}

@(private)
_hub_wake :: proc(l: ^prim.Loop, data: rawptr) {
	h := (^Hub)(data)
	if h.prev_wake != nil {
		h.prev_wake(l, h.prev_data)
	}
	sync.mutex_lock(&h.mu)
	list := make([dynamic]^Hub_Conn, 0, len(h.conns), context.temp_allocator)
	append(&list, ..h.conns[:])
	sync.mutex_unlock(&h.mu)
	for c in list {
		sync.mutex_lock(&h.mu)
		attach := c.want_attach
		c.want_attach = false
		detach := c.want_detach && c.attached
		clear(&c.work)
		append(&c.work, ..c.to_relay[:])
		clear(&c.to_relay)
		sync.mutex_unlock(&h.mu)
		if attach {
			link := osync.Link{data = c, send = _hub_relay_send, sendfile = _hub_relay_sendfile, close = _hub_relay_close, pause = nil}
			ref, err := osync.relay_attach(h.relay, link, true)
			sync.mutex_lock(&h.mu)
			if err == .None {
				c.ref = ref
				c.attached = true
				c.up = true
			} else {
				c.down = true
				c.dead = true
			}
			e := c.e
			sync.mutex_unlock(&h.mu)
			if e != nil {
				prim.wake(e.loop)
			}
		}
		if detach {
			osync.relay_detach(h.relay, c.ref)
			sync.mutex_lock(&h.mu)
			c.attached = false
			c.dead = true
			sync.mutex_unlock(&h.mu)
			continue
		}
		if c.attached && len(c.work) > 0 {
			if osync.relay_input(h.relay, c.ref, c.work[:]) != .None {
				sync.mutex_lock(&h.mu)
				c.attached = false
				c.dead = true
				c.down = true
				e := c.e
				sync.mutex_unlock(&h.mu)
				if e != nil {
					prim.wake(e.loop)
				}
			}
		}
	}
}

@(private)
_hub_relay_send :: proc(data: rawptr, bytes: []u8, more: bool) -> (int, osync.Error) {
	c := (^Hub_Conn)(data)
	h := c.hub
	sync.mutex_lock(&h.mu)
	append(&c.to_engine, ..bytes)
	e := c.e
	sync.mutex_unlock(&h.mu)
	if e != nil {
		prim.wake(e.loop)
	}
	return len(bytes), .None
}

@(private)
_hub_relay_sendfile :: proc(data: rawptr, fd: prim.Fd, off: i64, n: int) -> (int, osync.Error) {
	c := (^Hub_Conn)(data)
	h := c.hub
	want := min(n, len(h.scratch))
	got, err := prim.read_at(h.relay.vfs, fd, h.scratch[:want], off)
	if err != .None {
		return 0, .Io
	}
	return _hub_relay_send(data, h.scratch[:got], false)
}

@(private)
_hub_relay_close :: proc(data: rawptr) {
	c := (^Hub_Conn)(data)
	h := c.hub
	sync.mutex_lock(&h.mu)
	c.dead = true
	c.attached = false
	c.down = true
	e := c.e
	sync.mutex_unlock(&h.mu)
	if e != nil {
		prim.wake(e.loop)
	}
}

@(private)
_hub_engine_drain :: proc(e: ^Engine, data: rawptr) {
	h := (^Hub)(data)
	sync.mutex_lock(&h.mu)
	list := make([dynamic]^Hub_Conn, 0, len(h.conns), context.temp_allocator)
	for c in h.conns {
		if c.e == e {
			append(&list, c)
		}
	}
	sync.mutex_unlock(&h.mu)
	for c in list {
		sync.mutex_lock(&h.mu)
		up := c.up
		down := c.down
		c.up = false
		c.down = false
		bytes := make([]u8, len(c.to_engine), context.temp_allocator)
		copy(bytes, c.to_engine[:])
		clear(&c.to_engine)
		sync.mutex_unlock(&h.mu)
		if up {
			link_up(e, c.link)
		}
		if len(bytes) > 0 {
			link_input(e, c.link, bytes)
		}
		if down {
			link_down(e, c.link)
		}
	}
}

@(private)
_loopback_drain :: proc(e: ^Engine) {
	for hk in e.wake_hooks {
		{
			context = _outer(e)
			hk.call(e, hk.data)
		}
	}
}
