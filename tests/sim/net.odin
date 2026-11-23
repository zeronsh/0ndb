package sim

import eng "../../src/engine"
import "../../src/prim"
import osync "../../src/sync"

Conn_State :: enum u8 {
	Down,
	Up,
	Dead,
}

Conn :: struct {
	w:            ^World,
	id:           u64,
	node:         ^Node,
	inc:          int,
	link:         eng.Link,
	space:        prim.Id,
	gen:          u64,
	state:        Conn_State,
	ref:          osync.Conn_Ref,
	attached:     bool,
	engine_closed: bool,
	to_relay:     int,
	to_node:      int,
	node_blocked: bool,
	relay_blocked: bool,
	relay_paused: bool,
	held:         [dynamic][]u8,
	last_relay:   i64,
	last_node:    i64,
	backoff:      i64,
	latency:      i64,
	byz_buf:      [dynamic]u8,
	byz_hold:     [dynamic]u8,
	tap_up:       Tap,
	tap_down:     Tap,
}

@(private = "file")
_delay :: proc(c: ^Conn) -> i64 {
	w := c.w
	d := c.latency + rng_range(&w.net_rng, 0, c.latency)
	if rng_chance(&w.net_rng, 1, 50) {
		d += rng_range(&w.net_rng, 0, w.cfg.max_delay)
	}
	return d
}

_t_open :: proc(data: rawptr, e: ^eng.Engine, link: eng.Link, peer: eng.Peer) -> (conn: rawptr, err: eng.Error) {
	n := (^Node)(data)
	w := n.w
	c := new(Conn, w.allocator)
	w.conn_ids += 1
	c.w = w
	c.id = w.conn_ids
	c.node = n
	c.inc = n.incarnation
	c.link = link
	c.space = peer.space
	c.state = .Down
	c.backoff = 50_000_000
	c.latency = rng_range(&w.net_rng, 200_000, 20_000_000)
	c.held = make([dynamic][]u8, w.allocator)
	c.byz_buf = make([dynamic]u8, w.allocator)
	c.byz_hold = make([dynamic]u8, w.allocator)
	c.tap_up.buf = make([dynamic]u8, w.allocator)
	c.tap_down.buf = make([dynamic]u8, w.allocator)
	append(&w.conns, c)
	append(&n.conns, c)
	schedule(w, Sim_Event{at = w.now + _delay(c), kind = .Connect, conn = c, gen = c.gen})
	return c, .None
}

_t_send :: proc(data: rawptr, conn: rawptr, bytes: []u8) -> (int, eng.Error) {
	c := (^Conn)(conn)
	w := c.w
	if c.state == .Dead || c.engine_closed {
		return 0, .Closed
	}
	if c.state != .Up {
		c.node_blocked = true
		return 0, .Busy
	}
	room := w.cfg.window - c.to_relay
	if room <= 0 {
		c.node_blocked = true
		w.stats.backpressure += 1
		return 0, .Busy
	}
	k := min(room, len(bytes))
	if k < len(bytes) {
		c.node_blocked = true
		w.stats.backpressure += 1
	}
	c.to_relay += k
	tap_feed(w, c, &c.tap_up, bytes[:k], false)
	_emit_chunks(c, bytes[:k], .To_Relay)
	return k, .None
}

_t_close :: proc(data: rawptr, conn: rawptr) {
	c := (^Conn)(conn)
	w := c.w
	if c.state == .Dead {
		return
	}
	c.engine_closed = true
	if w.phase != .Check {
		w.stats.engine_close += 1
	}
	world_note(w, "%s engine closed conn %d", c.node.name, c.id)
	_relay_side_close(c)
	c.state = .Dead
	c.gen += 1
}

@(private = "file")
_emit_chunks :: proc(c: ^Conn, bytes: []u8, kind: Ev_Kind) {
	w := c.w
	w.stats.bytes_net += u64(len(bytes))
	w.trace = mix_bytes(mix64(w.trace, u64(kind) ~ c.id << 8), bytes)
	pos := 0
	for pos < len(bytes) {
		left := len(bytes) - pos
		k := left
		if left > 1 && rng_chance(&w.net_rng, 1, 3) {
			k = 1 + rng_int(&w.net_rng, left)
		}
		b := make([]u8, k, w.allocator)
		copy(b, bytes[pos:pos + k])
		at := w.now + _delay(c)
		if kind == .To_Relay {
			at = max(at, c.last_relay)
			c.last_relay = at
		} else {
			at = max(at, c.last_node)
			c.last_node = at
		}
		schedule(w, Sim_Event{at = at, kind = kind, conn = c, gen = c.gen, bytes = b})
		pos += k
	}
}

@(private = "file")
_r_send :: proc(data: rawptr, bytes: []u8, more: bool) -> (int, osync.Error) {
	c := (^Conn)(data)
	w := c.w
	if !c.attached || c.state != .Up {
		return 0, .Closed
	}
	room := w.cfg.window - c.to_node
	if room <= 0 {
		c.relay_blocked = true
		w.stats.backpressure += 1
		return 0, .Would_Block
	}
	k := min(room, len(bytes))
	if k < len(bytes) {
		c.relay_blocked = true
		w.stats.backpressure += 1
	}
	out := bytes[:k]
	if frame_filtering() {
		out = run_frame_filters(w, c, out)
	}
	if w.cfg.byzantine {
		_byzantine(c, out)
		return k, .None
	}
	tap_feed(w, c, &c.tap_down, bytes[:k], true)
	if len(out) == 0 {
		return k, .None
	}
	c.to_node += len(out)
	_emit_chunks(c, out, .To_Node)
	return k, .None
}

@(private = "file")
_byzantine :: proc(c: ^Conn, bytes: []u8) {
	w := c.w
	append(&c.byz_buf, ..bytes)
	out := make([dynamic]u8, context.temp_allocator)
	pos := 0
	for len(c.byz_buf) - pos >= 5 {
		n := int(u32(c.byz_buf[pos]) | u32(c.byz_buf[pos + 1]) << 8 | u32(c.byz_buf[pos + 2]) << 16 | u32(c.byz_buf[pos + 3]) << 24)
		if len(c.byz_buf) - pos < 5 + n {
			break
		}
		frame := c.byz_buf[pos:pos + 5 + n]
		kind := frame[4]
		pos += 5 + n
		active := w.phase == .Workload && kind != 0x81
		r := &w.net_rng
		if active && (kind == 0x83 || kind == 0x84) && n == 40 && rng_chance(r, 1, 8) {
			w.stats.tampered += 1
			t := make([]u8, len(frame), context.temp_allocator)
			copy(t, frame)
			claimed := prim.get_u64le(t[37:]) + 1 + u64(rng_int(r, 4096))
			prim.put_u64le(t[37:], claimed)
			stat_add(w, STAT_LENGTH_LIES)
			world_note(w, "byzantine relay claims length %d in a %x frame to %s", claimed, kind, c.node.name)
			append(&out, ..t)
			continue
		}
		if active && rng_chance(r, 1, 25) {
			act := rng_int(r, 4)
			w.stats.tampered += 1
			switch act {
			case 0:
				world_note(w, "byzantine relay withholds a %x frame (%d bytes) from %s", kind, n, c.node.name)
				continue
			case 1:
				world_note(w, "byzantine relay duplicates a %x frame to %s", kind, c.node.name)
				append(&out, ..frame)
			case 2:
				if len(c.byz_hold) == 0 {
					world_note(w, "byzantine relay delays a %x frame to %s behind the next one", kind, c.node.name)
					append(&c.byz_hold, ..frame)
					continue
				}
			case 3:
				if kind == 0x85 && n > 48 {
					at := 5 + 48 + rng_int(r, n - 48)
					bit := u8(1) << u8(rng_int(r, 8))
					world_note(w, "byzantine relay flips a bit in record bytes of a Data frame to %s", c.node.name)
					t := make([]u8, len(frame), context.temp_allocator)
					copy(t, frame)
					t[at] ~= bit
					append(&out, ..t)
					continue
				}
			}
		}
		append(&out, ..frame)
		if len(c.byz_hold) > 0 {
			append(&out, ..c.byz_hold[:])
			clear(&c.byz_hold)
		}
	}
	remove_range(&c.byz_buf, 0, pos)
	if len(out) > 0 {
		c.to_node += len(out)
		_emit_chunks(c, out[:], .To_Node)
	}
}

@(private = "file")
_r_sendfile :: proc(data: rawptr, fd: prim.Fd, off: i64, n: int) -> (int, osync.Error) {
	c := (^Conn)(data)
	w := c.w
	k := min(n, max(w.cfg.window - c.to_node, 0), 64 * 1024)
	if k <= 0 {
		c.relay_blocked = true
		return 0, .Would_Block
	}
	buf := make([]u8, k, context.temp_allocator)
	got, err := prim.read_at(disk_vfs(&w.relay.disk), fd, buf, off)
	if err != .None {
		return 0, .Io
	}
	return _r_send(data, buf[:got], false)
}

@(private = "file")
_r_close :: proc(data: rawptr) {
	c := (^Conn)(data)
	w := c.w
	if !c.attached {
		return
	}
	c.attached = false
	w.stats.relay_close += 1
	world_note(w, "relay closed conn %d of %s", c.id, c.node.name)
	gen := c.gen
	schedule(w, Sim_Event{at = max(w.now + _delay(c), c.last_node), kind = .Fin_To_Node, conn = c, gen = gen})
}

@(private = "file")
_r_pause :: proc(data: rawptr, paused: bool) {
	c := (^Conn)(data)
	w := c.w
	c.relay_paused = paused
	if !paused && len(c.held) > 0 {
		schedule(w, Sim_Event{at = w.now, kind = .To_Relay, conn = c, gen = c.gen, arg = 1})
	}
}

@(private = "file")
_relay_side_close :: proc(c: ^Conn) {
	w := c.w
	if c.attached && w.relay.alive {
		c.attached = false
		_relay_detach(w, c)
	}
	c.attached = false
	for b in c.held {
		delete(b, w.allocator)
	}
	clear(&c.held)
	clear(&c.byz_buf)
	clear(&c.byz_hold)
	c.relay_paused = false
}

conn_reset :: proc(c: ^Conn, reconnect: bool) {
	w := c.w
	if c.state == .Dead {
		return
	}
	was := c.state
	_relay_side_close(c)
	c.gen += 1
	c.to_relay = 0
	c.to_node = 0
	c.node_blocked = false
	c.relay_blocked = false
	c.state = .Down
	if was == .Up && c.node.alive && c.inc == c.node.incarnation {
		_node_link(c.node, c, .Down)
	}
	if reconnect && c.state != .Dead {
		c.backoff = min(c.backoff * 2, 5_000_000_000)
		at := w.now + c.backoff / 2 + rng_range(&w.net_rng, 0, c.backoff / 2)
		schedule(w, Sim_Event{at = at, kind = .Connect, conn = c, gen = c.gen})
	}
}

conns_drop_node :: proc(w: ^World, n: ^Node) {
	for c in n.conns {
		if c.state == .Dead {
			continue
		}
		_relay_side_close(c)
		c.state = .Dead
		c.gen += 1
	}
	clear(&n.conns)
}

conns_drop_relay :: proc(w: ^World) {
	for c in w.conns {
		if c.state == .Dead {
			continue
		}
		c.attached = false
		for b in c.held {
			delete(b, w.allocator)
		}
		clear(&c.held)
		clear(&c.byz_buf)
		clear(&c.byz_hold)
	}
	for c in w.conns {
		if c.state == .Up {
			w.stats.resets += 1
			c.gen += 1
			c.to_relay = 0
			c.to_node = 0
			c.node_blocked = false
			c.relay_blocked = false
			c.relay_paused = false
			c.state = .Down
			n := c.node
			if n.alive && c.inc == n.incarnation {
				schedule(w, Sim_Event{at = w.now + _delay(c), kind = .Fin_To_Node, conn = c, gen = c.gen, arg = 1})
			}
		}
	}
}

CONNECT_TIMEOUT :: i64(3_000_000_000)

net_event :: proc(w: ^World, ev: ^Sim_Event) {
	c := ev.conn
	switch ev.kind {
	case .Connect:
		if c.state != .Down || ev.gen != c.gen || c.engine_closed {
			return
		}
		n := c.node
		if !n.alive || c.inc != n.incarnation {
			c.state = .Dead
			return
		}
		if n.partitioned || !w.relay.alive {
			switch n.connect_fault {
			case .None:
			case .Refused:
				_node_link(n, c, .Down)
			case .Timeout:
				schedule(w, Sim_Event{at = w.now + CONNECT_TIMEOUT, kind = .Connect_Fail, conn = c, gen = c.gen})
				return
			case .Close_Early:
				_node_link(n, c, .Up)
				schedule(w, Sim_Event{at = w.now + _delay(c), kind = .Connect_Fail, conn = c, gen = c.gen})
				return
			}
			at := w.now + c.backoff / 2 + rng_range(&w.net_rng, 0, c.backoff / 2)
			c.backoff = min(c.backoff * 2, 5_000_000_000)
			schedule(w, Sim_Event{at = at, kind = .Connect, conn = c, gen = c.gen})
			return
		}
		ref, err := _relay_attach(w, c)
		if err != .None || !w.relay.alive {
			world_note(w, "relay refused attach for %s: %v", n.name, err)
			at := w.now + c.backoff
			c.backoff = min(c.backoff * 2, 5_000_000_000)
			schedule(w, Sim_Event{at = at, kind = .Connect, conn = c, gen = c.gen})
			return
		}
		c.ref = ref
		c.attached = true
		c.state = .Up
		c.backoff = 50_000_000
		n.attaches[c.space] += 1
		c.last_node = w.now
		c.last_relay = w.now
		_node_link(n, c, .Up)
	case .Connect_Fail:
		if c.state != .Down || ev.gen != c.gen || c.engine_closed {
			return
		}
		n := c.node
		if n.alive && c.inc == n.incarnation {
			_node_link(n, c, .Down)
		}
		at := w.now + c.backoff / 2 + rng_range(&w.net_rng, 0, c.backoff / 2)
		c.backoff = min(c.backoff * 2, 5_000_000_000)
		schedule(w, Sim_Event{at = at, kind = .Connect, conn = c, gen = c.gen})
	case .To_Relay:
		if ev.gen != c.gen || !c.attached || !w.relay.alive {
			return
		}
		if ev.arg == 1 {
			if c.relay_paused {
				return
			}
			for len(c.held) > 0 && !c.relay_paused && c.attached {
				b := c.held[0]
				ordered_remove(&c.held, 0)
				_to_relay(w, c, b)
				delete(b, w.allocator)
			}
			return
		}
		if c.relay_paused || len(c.held) > 0 {
			b := make([]u8, len(ev.bytes), w.allocator)
			copy(b, ev.bytes)
			append(&c.held, b)
			return
		}
		_to_relay(w, c, ev.bytes)
	case .To_Node:
		if ev.gen != c.gen || c.state != .Up {
			return
		}
		n := c.node
		if !n.alive || c.inc != n.incarnation {
			return
		}
		c.to_node -= len(ev.bytes)
		w.stats.deliveries += 1
		_node_input(n, c, ev.bytes)
		if c.relay_blocked && c.to_node < w.cfg.window && c.attached {
			c.relay_blocked = false
			schedule(w, Sim_Event{at = w.now, kind = .Writable_Relay, conn = c, gen = c.gen})
		}
	case .Fin_To_Node:
		if ev.gen != c.gen {
			return
		}
		if ev.arg == 1 {
			n := c.node
			if n.alive && c.inc == n.incarnation {
				_node_link(n, c, .Down)
			}
			at := w.now + c.backoff / 2 + rng_range(&w.net_rng, 0, c.backoff / 2)
			schedule(w, Sim_Event{at = at, kind = .Connect, conn = c, gen = c.gen})
			return
		}
		conn_reset(c, true)
	case .Writable_Node:
		if ev.gen != c.gen || c.state != .Up {
			return
		}
		n := c.node
		if !n.alive || c.inc != n.incarnation {
			return
		}
		_node_link(n, c, .Dead)
	case .Writable_Relay:
		if ev.gen != c.gen || !c.attached || !w.relay.alive {
			return
		}
		_relay_writable(w, c)
	case .Op, .Reset, .Fault, .Restart, .Relay_Restart, .Relay_Pack_Job, .Heal, .Watch, .Pack_Job, .Stream_Step, .Git_Fetch:
	}
}

@(private = "file")
_to_relay :: proc(w: ^World, c: ^Conn, bytes: []u8) {
	c.to_relay -= len(bytes)
	w.stats.deliveries += 1
	_relay_input(w, c, bytes)
	if c.node_blocked && c.to_relay < w.cfg.window && c.state == .Up {
		c.node_blocked = false
		schedule(w, Sim_Event{at = w.now, kind = .Writable_Node, conn = c, gen = c.gen})
	}
}

@(private = "file")
_relay_attach :: proc(w: ^World, c: ^Conn) -> (osync.Conn_Ref, osync.Error) {
	context = instance_context(&w.relay.inst)
	ref, err := osync.relay_core_attach(&w.relay.r, osync.Link{data = c, send = _r_send, sendfile = _r_sendfile, close = _r_close, pause = _r_pause}, true)
	relay_after(&w.relay)
	return ref, err
}

@(private = "file")
_relay_input :: proc(w: ^World, c: ^Conn, bytes: []u8) {
	context = instance_context(&w.relay.inst)
	osync.relay_core_input(&w.relay.r, c.ref, bytes)
	relay_after(&w.relay)
}

@(private = "file")
_relay_writable :: proc(w: ^World, c: ^Conn) {
	context = instance_context(&w.relay.inst)
	osync.relay_core_writable(&w.relay.r, c.ref)
	relay_after(&w.relay)
}

@(private = "file")
_relay_detach :: proc(w: ^World, c: ^Conn) {
	context = instance_context(&w.relay.inst)
	osync.relay_core_detach(&w.relay.r, c.ref)
	relay_after(&w.relay)
}

@(private = "file")
_node_link :: proc(n: ^Node, c: ^Conn, what: Conn_State) {
	context = instance_context(&n.inst)
	switch what {
	case .Up:
		eng.link_up(&n.e, c.link)
	case .Down:
		eng.link_down(&n.e, c.link)
	case .Dead:
		eng.link_writable(&n.e, c.link)
	}
	node_after(n)
}

@(private = "file")
_node_input :: proc(n: ^Node, c: ^Conn, bytes: []u8) {
	context = instance_context(&n.inst)
	eng.link_input(&n.e, c.link, bytes)
	node_after(n)
}

byzantine_flush :: proc(w: ^World) {
	for c in w.conns {
		if len(c.byz_hold) > 0 && c.state == .Up && c.attached {
			c.to_node += len(c.byz_hold)
			_emit_chunks(c, c.byz_hold[:], .To_Node)
		}
		clear(&c.byz_hold)
	}
}

RECONNECT_QUIET_MAX :: 2

attaches_snapshot :: proc(w: ^World) -> []map[prim.Id]int {
	out := make([]map[prim.Id]int, len(w.nodes), w.allocator)
	for n, i in w.nodes {
		out[i] = make(map[prim.Id]int, w.allocator)
		for k, v in n.attaches {
			out[i][k] = v
		}
	}
	return out
}

check_reconnects :: proc(w: ^World, before: []map[prim.Id]int, what: string) {
	for n, i in w.nodes {
		for k, v in n.attaches {
			if d := v - before[i][k]; d > RECONNECT_QUIET_MAX {
				world_fail(w, "reconnects: %s attached to space %s %d times during %s with no membership change", n.name, id_short(k), d, what)
			}
		}
		delete(before[i])
	}
	delete(before, w.allocator)
}
