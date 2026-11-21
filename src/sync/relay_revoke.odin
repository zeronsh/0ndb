#+build linux, darwin, windows
package osync

RELAY_OBSERVE_MAX :: 1 << 20

@(private)
_relay_observe :: proc(r: ^Relay, sp: ^Space_State, st: ^Stream_State, from, to: i64) {
	if r.auth.observe == nil || to <= from || to - from > RELAY_OBSERVE_MAX || st.h == nil {
		return
	}
	buf := make([]u8, int(to - from), context.temp_allocator)
	got := 0
	for got < len(buf) {
		n, err := r.store.stream_read(r.store.data, st.h, from + i64(got), buf[got:])
		if err != .None || n <= 0 {
			return
		}
		got += n
	}
	revoked := make([dynamic]Device_Id, context.temp_allocator)
	r.auth.observe(r.auth.data, sp.id, st.id, buf, &revoked)
	for d in revoked {
		relay_revoke(r, sp.id, d)
	}
}

relay_revoke :: proc(r: ^Relay, space: Space_Id, participant: Device_Id) -> int {
	n := 0
	for c in r.conns {
		if c == nil || c.dead || c.closing || c.space == nil {
			continue
		}
		if c.space.id == space && c.principal.participant == participant {
			_fail(c, .Auth)
			_conn_kick(c)
			n += 1
		}
	}
	return n
}
