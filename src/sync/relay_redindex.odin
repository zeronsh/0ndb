package osync

import "../journal"
import "../prim"

@(private)
FILL_REDACT_MAX :: 64 * 1024 * 1024

@(private)
_red_index_load :: proc(r: ^Relay_Core, sp: ^Space_State) {
	if sp.red_loaded {
		return
	}
	if _redlog_open(r, sp) != .None || sp.redlog == nil || sp.redlog.h == nil {
		return
	}
	sp.red_loaded = true
	sp.red_index = make(map[Stream_Id][dynamic][2]i64, r.allocator)
	n := sp.redlog.length - sp.redlog.length % REDLOG_RECORD
	chunk := make([]u8, 64 * REDLOG_RECORD, context.temp_allocator)
	for at := i64(0); at < n; {
		want := min(n - at, i64(len(chunk)))
		got, err := r.store.stream_read(r.store.data, sp.redlog.h, at, chunk[:want])
		if err != .None || i64(got) != want {
			break
		}
		_red_index_records(r, sp, chunk[:got])
		at += want
	}
	_red_index_records(r, sp, sp.redlog_flight[:])
	_red_index_records(r, sp, sp.redlog_q[:])
}

@(private)
_red_index_records :: proc(r: ^Relay_Core, sp: ^Space_State, raw: []u8) {
	for k := 0; k + REDLOG_RECORD <= len(raw); k += REDLOG_RECORD {
		rec := raw[k:][:REDLOG_RECORD]
		id: Stream_Id
		copy(id[:], rec[:32])
		_red_index_add(r, sp, id, i64(prim.get_u64le(rec[32:])), i64(prim.get_u64le(rec[40:])))
	}
}

@(private)
_red_index_add :: proc(r: ^Relay_Core, sp: ^Space_State, id: Stream_Id, from, to: i64) {
	if !sp.red_loaded || to <= from {
		return
	}
	l, ok := &sp.red_index[id]
	if !ok {
		sp.red_index[id] = make([dynamic][2]i64, r.allocator)
		l = &sp.red_index[id]
	}
	for x in l {
		if x[0] == from && x[1] == to {
			return
		}
	}
	append(l, [2]i64{from, to})
}

@(private)
_red_overlaps :: proc(r: ^Relay_Core, sp: ^Space_State, id: Stream_Id, lo, hi: i64) -> bool {
	_red_index_load(r, sp)
	for x in sp.red_index[id] {
		if x[0] < hi && x[1] > lo {
			return true
		}
	}
	return false
}

@(private)
_red_fill_apply :: proc(sp: ^Space_State, id: Stream_Id, at: i64, buf: []u8) -> bool {
	hi := at + i64(len(buf))
	for x in sp.red_index[id] {
		lo, top := max(x[0], at), min(x[1], hi)
		if lo >= top {
			continue
		}
		if !_redact_buf(buf, at, lo, top) {
			return false
		}
	}
	return true
}

@(private)
_redact_buf :: proc(buf: []u8, at, from, to: i64) -> bool {
	pos := from
	for pos < to {
		o := int(pos - at)
		if o + journal.OVERHEAD > len(buf) {
			return false
		}
		body := i64(prim.get_u32le(buf[o:]))
		size := body + journal.OVERHEAD
		if body > journal.MAX_BODY || pos + size > to || prim.get_u32le(buf[o + journal.HEADER + int(body):]) != u32(body) {
			return false
		}
		pos += size
	}
	pos = from
	for pos < to {
		o := int(pos - at)
		body := int(prim.get_u32le(buf[o:]))
		tag := journal.redacted_tag(pos, body)
		copy(buf[o + 4:], tag[:])
		for &b in buf[o + journal.HEADER:][:body] {
			b = 0
		}
		pos += i64(body + journal.OVERHEAD)
	}
	return true
}

@(private)
_red_reapply :: proc(r: ^Relay_Core, sp: ^Space_State, st: ^Stream_State) {
	if st.h == nil || _reserved(cast([32]u8)st.id) {
		return
	}
	_red_index_load(r, sp)
	ranges, ok := sp.red_index[st.id]
	if !ok {
		return
	}
	for x in ranges {
		lo, hi := max(x[0], st.base), min(x[1], st.length)
		if lo >= hi || hi - lo > FILL_REDACT_MAX || !_red_needs(r, st, lo, hi) {
			continue
		}
		p, aerr := new(Pending, r.allocator)
		if aerr != nil {
			return
		}
		p^ = {relay = r, kind = .Redact, stream = st, space = sp, total = hi, from = lo, id = cast([32]u8)st.id}
		_stream_ref(st)
		sp.jobs += 1
		st.redacting += 1
		r.store.redact(r.store.data, st.h, lo, hi, _relay_done, p)
	}
}

@(private)
_red_needs :: proc(r: ^Relay_Core, st: ^Stream_State, lo, hi: i64) -> bool {
	buf := make([]u8, int(hi - lo), context.temp_allocator)
	got, err := r.store.stream_read(r.store.data, st.h, lo, buf)
	if err != .None || i64(got) != hi - lo {
		return false
	}
	pos := lo
	for pos < hi {
		o := int(pos - lo)
		if o + journal.OVERHEAD > len(buf) {
			return false
		}
		body := int(prim.get_u32le(buf[o:]))
		size := body + journal.OVERHEAD
		if body > journal.MAX_BODY || o + size > len(buf) {
			return false
		}
		if journal.classify(buf[o:][:size], pos) != .Redacted {
			return true
		}
		pos += i64(size)
	}
	return false
}

Redaction_Violation :: struct {
	space:  Space_Id,
	stream: Stream_Id,
	off:    i64,
}

relay_core_redactions_held :: proc(r: ^Relay_Core, out: ^[dynamic]Redaction_Violation) {
	for _, sp in r.spaces {
		_red_index_load(r, sp)
		for id, ranges in sp.red_index {
			h, length, err := r.store.stream_open(r.store.data, sp.ns, id, false)
			if err != .None || h == nil {
				continue
			}
			base := r.store.stream_base(r.store.data, h)
			for x in ranges {
				lo, hi := max(x[0], base), min(x[1], length)
				if lo >= hi || hi - lo > FILL_REDACT_MAX {
					continue
				}
				buf := make([]u8, int(hi - lo), context.temp_allocator)
				got, rerr := r.store.stream_read(r.store.data, h, lo, buf)
				if rerr != .None || i64(got) != hi - lo {
					continue
				}
				pos := lo
				for pos < hi {
					o := int(pos - lo)
					if o + journal.OVERHEAD > len(buf) {
						break
					}
					body := int(prim.get_u32le(buf[o:]))
					size := body + journal.OVERHEAD
					if body > journal.MAX_BODY || o + size > len(buf) {
						break
					}
					if journal.classify(buf[o:][:size], pos) != .Redacted {
						append(out, Redaction_Violation{sp.id, id, pos})
					}
					pos += i64(size)
				}
			}
			r.store.stream_close(r.store.data, h)
		}
	}
}

relay_core_redacted :: proc(r: ^Relay_Core, space: Space_Id, id: Stream_Id) -> [][2]i64 {
	sp, ok := r.spaces[space]
	if !ok {
		return nil
	}
	_red_index_load(r, sp)
	return sp.red_index[id][:]
}

@(private)
_red_report :: proc(r: ^Relay_Core, sp: ^Space_State, sender: Device_Id, id: Stream_Id, at: i64, buf: []u8) {
	if r.cfg.on_redacted_in == nil {
		return
	}
	hi := at + i64(len(buf))
	for x in sp.red_index[id] {
		lo, top := max(x[0], at), min(x[1], hi)
		if lo < top && _red_live_in(buf, at, lo, top) {
			r.cfg.on_redacted_in(r.cfg.redacted_in_data, sender, sp.id, id, x[0], x[1])
		}
	}
}

@(private)
_red_live_in :: proc(buf: []u8, at, from, to: i64) -> bool {
	pos := from
	for pos < to {
		o := int(pos - at)
		if o + journal.OVERHEAD > len(buf) {
			return false
		}
		body := int(prim.get_u32le(buf[o:]))
		size := body + journal.OVERHEAD
		if body > journal.MAX_BODY || o + size > len(buf) {
			return false
		}
		if journal.classify(buf[o:][:size], pos) != .Redacted {
			return true
		}
		pos += i64(size)
	}
	return false
}
