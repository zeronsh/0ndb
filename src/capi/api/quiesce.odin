package api

import rt "../../runtime"

QUIESCE_NAMES := [4]string{"accepted", "run_active", "queued", "relay"}

@(private)
Quiesce_Wait :: struct {
	a:  ^Api,
	id: u64,
}

op_quiesce :: proc(c: ^Call, o: ^Out) -> Status {
	r := _rt(c)
	if r == nil {
		return .Unsupported
	}
	res: rt.Quiesce_Result
	switch c.stage {
	case 0:
		on := !(has(c, "off") && a_bool(c, "off"))
		lift := i64(min(a_u64(c, "lift_ms"), u64(max(i64))))
		w := new(Quiesce_Wait, c.api.allocator)
		w^ = Quiesce_Wait{a = c.api, id = c.id}
		qr, pending := rt.quiesce(r, on, lift, rt.Quiesce_Done{data = w, call = _on_quiesced})
		if !pending {
			free(w, c.api.allocator)
			res = qr
			break
		}
		c.stage = 1
		c.waiting = true
		return .Pending
	case 1:
		if !c.final {
			return .Pending
		}
		rt.quiesce(r, false)
		res = .Relay
	case:
		res = rt.Quiesce_Result(c.scratch[0])
	}
	o_bool(o, "accepted", res == .Accepted)
	o_enum(o, "reason", u64(res), QUIESCE_NAMES[:])
	return .Ok
}

@(private)
_on_quiesced :: proc(data: rawptr, r: ^rt.Runtime, res: rt.Quiesce_Result) {
	w := (^Quiesce_Wait)(data)
	a, id := w.a, w.id
	free(w, a.allocator)
	for c in a.calls {
		if c.id == id && c.stage == 1 {
			c.stage = 2
			c.scratch[0] = u64(res)
			c.waiting = false
			_rerun(c)
			return
		}
	}
}
