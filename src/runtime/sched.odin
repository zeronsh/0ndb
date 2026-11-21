package rt

import "core:encoding/json"
import "core:strings"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"
import eng "../engine"
import omap "../map"
import "../obj"
import "../prim"

@(private)
SCHED_PREFIX :: "sched/"

Schedule :: struct {
	id:           string,
	owner:        Object,
	prompt:       string,
	cron:         string,
	at:           i64,
	tz:           string,
	conversation: prim.Id,
	fresh:        bool,
	next:         i64,
	last:         i64,
	creator:      prim.Id,
	agent:        prim.Id,
}

Cron :: struct {
	minutes: u64,
	hours:   u32,
	doms:    u32,
	months:  u16,
	dows:    u8,
	dom_any: bool,
	dow_any: bool,
}

schedule_get :: proc(r: ^Runtime, owner: Object, id: string) -> (s: Schedule, found: bool) {
	context = eng.context_for(r.e)
	en, ok := map_read(r, owner, key_of(SCHED_PREFIX, transmute([]u8)id))
	if !ok {
		return {}, false
	}
	s.id = id
	s.owner = owner
	s.prompt = entry_str(&en, 1)
	s.cron = entry_str(&en, 2)
	s.at = i64(entry_u64(&en, 3))
	s.tz = entry_str(&en, 4)
	s.conversation = entry_id(&en, 5)
	s.fresh = entry_bool(&en, 6)
	s.next = i64(entry_u64(&en, 7))
	s.last = i64(entry_u64(&en, 8))
	s.creator = entry_id(&en, 9)
	s.agent = entry_id(&en, 10)
	return s, len(s.prompt) > 0
}

schedule_put :: proc(r: ^Runtime, s: ^Schedule) {
	map_put(r, s.owner, key_of(SCHED_PREFIX, transmute([]u8)s.id), omap.field_str(1, s.prompt), omap.field_str(2, s.cron), omap.field_u64(3, u64(max(s.at, 0))), omap.field_str(4, s.tz), omap.field_id(5, s.conversation), omap.field_bool(6, s.fresh), omap.field_u64(7, u64(max(s.next, 0))), omap.field_u64(8, u64(max(s.last, 0))), omap.field_id(9, s.creator), omap.field_id(10, s.agent))
	_index_put(r, s)
}

@(private)
_index_key :: proc(owner: Object, id: string) -> []u8 {
	oid := owner.id
	return key_of("", oid[:], transmute([]u8)id)
}

@(private)
_index_put :: proc(r: ^Runtime, s: ^Schedule) {
	so := named_w(r, schedules_named(s.owner.space))
	if s.next <= 0 {
		map_clear(r, so, _index_key(s.owner, s.id), 1, 2)
		return
	}
	map_put(r, so, _index_key(s.owner, s.id), omap.field_u64(1, u64(s.next)), omap.field_id(2, s.creator))
}

schedule_remove :: proc(r: ^Runtime, owner: Object, id: string) -> bool {
	context = eng.context_for(r.e)
	_, found := schedule_get(r, owner, id)
	map_clear(r, owner, key_of(SCHED_PREFIX, transmute([]u8)id), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10)
	map_clear(r, schedules_object(owner.space), _index_key(owner, id), 1, 2)
	return found
}

schedule_next :: proc(r: ^Runtime, s: ^Schedule, after_ms: i64) -> i64 {
	if len(s.cron) == 0 {
		return s.at if s.at > after_ms else 0
	}
	c, ok := cron_parse(s.cron)
	if !ok {
		return 0
	}
	return cron_next(r, &c, s.tz, after_ms)
}

@(private)
_on_schedules :: proc(data: rawptr, e: ^eng.Engine, sub: eng.Sub_Id, deltas: []eng.Delta) {
	context = eng.context_for((^Runtime)(data).e)
	r := (^Runtime)(data)
	_sched_rearm(r)
}

@(private)
_sched_rearm :: proc(r: ^Runtime) {
	l := eng.loop(r.e)
	at: i64 = 0
	if r.cfg.runner {
		for sw in r.spaces {
			for &row in map_rows(r, schedules_object(sw.space), nil, 1 << 20) {
				next := i64(entry_u64(&row.entry, 1))
				if next <= 0 {
					continue
				}
				creator := entry_id(&row.entry, 2)
				if !prim.id_is_zero(creator) && creator != r.self && runner_known(r, sw.space, creator) {
					continue
				}
				if at == 0 || next < at {
					at = next
				}
			}
		}
	}
	if at == r.sched_at && (at == 0 || prim.timer_pending(l, r.sched_timer)) {
		return
	}
	if r.sched_timer != 0 {
		prim.timer_cancel(l, r.sched_timer)
		r.sched_timer = 0
	}
	r.sched_at = at
	if at != 0 {
		r.sched_timer = prim.timer(l, max(at - wall_ms(r), 0), r, _on_sched_timer)
	}
}

@(private)
_on_sched_timer :: proc(l: ^prim.Loop, data: rawptr) {
	context = eng.context_for((^Runtime)(data).e)
	r := (^Runtime)(data)
	r.sched_timer = 0
	r.sched_at = 0
	now := wall_ms(r)
	for sw in r.spaces {
		for &row in map_rows(r, schedules_object(sw.space), nil, 1 << 20) {
			next := i64(entry_u64(&row.entry, 1))
			if next <= 0 || next > now || len(row.key) < 17 {
				continue
			}
			creator := entry_id(&row.entry, 2)
			if !prim.id_is_zero(creator) && creator != r.self && runner_known(r, sw.space, creator) {
				continue
			}
			owner := Object{space = sw.space}
			copy(owner.id[:], row.key[:16])
			id := string(row.key[16:])
			s, found := schedule_get(r, owner, id)
			if !found {
				map_clear(r, schedules_object(sw.space), row.key, 1, 2)
				continue
			}
			_sched_fire(r, &s, now)
		}
	}
	_sched_rearm(r)
}

@(private)
_sched_fire :: proc(r: ^Runtime, s: ^Schedule, now: i64) {
	due := s.next
	if due <= 0 || s.last >= due {
		s.next = schedule_next(r, s, max(now, s.last))
		schedule_put(r, s)
		return
	}
	s.last = due
	s.next = schedule_next(r, s, now)
	schedule_put(r, s)
	r.stats.schedules += 1
	target := Object{s.owner.space, s.conversation}
	if prim.id_is_zero(s.conversation) {
		return
	}
	if s.fresh {
		settings, _ := eng.convo_settings(r.e, target, context.temp_allocator)
		title, _ := utf8_clip(s.prompt, 80)
		child, err := eng.convo_create(r.e, target.space, eng.Convo_Settings{title = title, agent = s.agent if !prim.id_is_zero(s.agent) else settings.agent, workspace = settings.workspace, parent = obj.Xref{object = target.id}})
		if err != .None {
			return
		}
		ms, _ := eng.convo_mounts(r.e, target, context.temp_allocator)
		for m in ms {
			eng.convo_mount(r.e, child, m.name, m.tree, m.line, m.path)
		}
		eng.convo_send(r.e, child, s.prompt)
		return
	}
	eng.convo_queue(r.e, target, s.prompt)
}

schedule_tool :: proc(r: ^Runtime, caller: Object, a: ^Agent_Info, v: json.Value, rep: Reply) {
	owner := meta_w(r, caller)
	agent_id: prim.Id
	if a != nil && !prim.id_is_zero(a.object.id) {
		owner = a.object
		agent_id = a.object.id
	}
	if s := jstr(v, "agent"); len(s) > 0 {
		if id, ok := prim.id_parse(s); ok {
			owner = Object{caller.space, id}
			agent_id = id
		}
	}
	switch jstr(v, "action") {
	case "create":
		s := Schedule {
			owner        = owner,
			prompt       = jstr(v, "prompt"),
			cron         = jstr(v, "cron"),
			tz           = jstr(v, "timezone"),
			conversation = caller.id,
			fresh        = jbool(v, "new_conversation"),
			creator      = r.self,
			agent        = agent_id,
		}
		if c := jstr(v, "conversation"); len(c) > 0 {
			if id, ok := prim.id_parse(c); ok {
				s.conversation = id
			}
		}
		if at := jstr(v, "at"); len(at) > 0 {
			ms, ok := rfc3339_parse(at)
			if !ok {
				reply_done(r, rep, "at must be an RFC 3339 time", "", true)
				return
			}
			s.at = ms
		}
		if len(s.prompt) == 0 || (len(s.cron) == 0) == (s.at == 0) {
			reply_done(r, rep, "create needs a prompt and exactly one of cron or at", "", true)
			return
		}
		if len(s.cron) > 0 {
			if _, ok := cron_parse(s.cron); !ok {
				reply_done(r, rep, "the cron expression is invalid", "", true)
				return
			}
		}
		id := jstr(v, "id")
		if len(id) == 0 {
			id = hex(new_id(r))
		}
		s.id = id
		s.next = schedule_next(r, &s, wall_ms(r))
		if s.next == 0 {
			reply_done(r, rep, "the schedule never fires", "", true)
			return
		}
		schedule_put(r, &s)
		_sched_rearm(r)
		b := make(Buf, context.temp_allocator)
		append(&b, `{"schedules":[`)
		_schedule_json(&b, &s)
		append(&b, "]}")
		reply_done(r, rep, concat("scheduled ", id), string(b[:]), false)
	case "remove":
		id := jstr(v, "id")
		removed := schedule_remove(r, owner, id)
		_sched_rearm(r)
		b := make(Buf, context.temp_allocator)
		append(&b, '{')
		jw_kbool(&b, "removed", removed)
		append(&b, '}')
		reply_done(r, rep, "", string(b[:]), !removed)
	case "list":
		b := make(Buf, context.temp_allocator)
		append(&b, `{"schedules":[`)
		for &row in map_rows(r, owner, transmute([]u8)string(SCHED_PREFIX), 10_000) {
			s, found := schedule_get(r, owner, string(row.key[len(SCHED_PREFIX):]))
			if found {
				_schedule_json(&b, &s)
			}
		}
		append(&b, "]}")
		reply_done(r, rep, "", string(b[:]), false)
	case:
		reply_done(r, rep, "action must be create, list or remove", "", true)
	}
}

@(private)
_schedule_json :: proc(b: ^Buf, s: ^Schedule) {
	jw_open(b)
	jw_kstr(b, "id", s.id)
	jw_kstr(b, "prompt", s.prompt)
	if len(s.cron) > 0 {
		jw_kstr(b, "cron", s.cron)
	}
	if s.at > 0 {
		jw_kstr(b, "at", rfc3339(s.at))
	}
	if len(s.tz) > 0 {
		jw_kstr(b, "timezone", s.tz)
	}
	jw_kstr(b, "conversation", hex(s.conversation))
	if s.next > 0 {
		jw_kstr(b, "next", rfc3339(s.next))
	}
	jw_close(b)
}

schedule_create :: proc(r: ^Runtime, owner: Object, id: string, prompt: string, cron: string, at_ms: i64, tz: string, conversation: Object, fresh := false) -> Error {
	context = eng.context_for(r.e)
	s := Schedule {
		id           = id,
		owner        = owner,
		prompt       = prompt,
		cron         = cron,
		at           = at_ms,
		tz           = tz,
		conversation = conversation.id,
		fresh        = fresh,
		creator      = r.self,
	}
	if c, found, _ := eng.catalog_get(r.e, owner, context.temp_allocator); found && c.kind == .Map {
		s.agent = owner.id
	}
	s.next = schedule_next(r, &s, wall_ms(r))
	if s.next == 0 {
		return .Invalid
	}
	schedule_put(r, &s)
	_sched_rearm(r)
	return .None
}

@(private)
_bits :: proc(field: string, lo, hi: int, names: []string) -> (bits: u64, any: bool, ok: bool) {
	if field == "*" || field == "?" {
		for i in lo ..= hi {
			bits |= 1 << u64(i)
		}
		return bits, true, true
	}
	for part in strings.split(field, ",", context.temp_allocator) {
		step := 1
		body := part
		if i := strings.index_byte(part, '/'); i >= 0 {
			n, nok := _atoi(part[i + 1:])
			if !nok || n <= 0 {
				return 0, false, false
			}
			step = n
			body = part[:i]
		}
		a, b := lo, hi
		if body != "*" {
			if j := strings.index_byte(body, '-'); j > 0 {
				x, xok := _cron_value(body[:j], names, lo)
				y, yok := _cron_value(body[j + 1:], names, lo)
				if !xok || !yok {
					return 0, false, false
				}
				a, b = x, y
			} else {
				x, xok := _cron_value(body, names, lo)
				if !xok {
					return 0, false, false
				}
				a = x
				b = x if step == 1 && strings.index_byte(part, '/') < 0 else hi
			}
		}
		if a < lo || b > hi || a > b {
			if !(hi == 6 && b == 7) {
				return 0, false, false
			}
		}
		for v := a; v <= b; v += step {
			x := v
			if hi == 6 && x == 7 {
				x = 0
			}
			bits |= 1 << u64(x)
		}
	}
	return bits, false, bits != 0
}

@(private)
_atoi :: proc(s: string) -> (n: int, ok: bool) {
	if len(s) == 0 {
		return 0, false
	}
	for c in s {
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n * 10 + int(c - '0')
		if n > 1_000_000 {
			return 0, false
		}
	}
	return n, true
}

@(private)
_cron_value :: proc(s: string, names: []string, lo: int) -> (int, bool) {
	if n, ok := _atoi(s); ok {
		return n, true
	}
	low := strings.to_lower(s, context.temp_allocator)
	for nm, i in names {
		if nm == low {
			return i + lo, true
		}
	}
	return 0, false
}

cron_parse :: proc(expr: string) -> (c: Cron, ok: bool) {
	e := strings.trim_space(expr)
	switch e {
	case "@yearly", "@annually":
		e = "0 0 1 1 *"
	case "@monthly":
		e = "0 0 1 * *"
	case "@weekly":
		e = "0 0 * * 0"
	case "@daily", "@midnight":
		e = "0 0 * * *"
	case "@hourly":
		e = "0 * * * *"
	}
	fields := strings.fields(e, context.temp_allocator)
	if len(fields) != 5 {
		return {}, false
	}
	months := []string{"jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"}
	days := []string{"sun", "mon", "tue", "wed", "thu", "fri", "sat"}
	m, _, ok1 := _bits(fields[0], 0, 59, nil)
	h, _, ok2 := _bits(fields[1], 0, 23, nil)
	d, dany, ok3 := _bits(fields[2], 1, 31, nil)
	mo, _, ok4 := _bits(fields[3], 1, 12, months)
	w, wany, ok5 := _bits(fields[4], 0, 6, days)
	if !(ok1 && ok2 && ok3 && ok4 && ok5) {
		return {}, false
	}
	return Cron{minutes = m, hours = u32(h), doms = u32(d), months = u16(mo), dows = u8(w), dom_any = dany, dow_any = wany}, true
}

days_from_civil :: proc(y_in: i64, m: i64, d: i64) -> i64 {
	y := y_in - (1 if m <= 2 else 0)
	era := (y if y >= 0 else y - 399) / 400
	yoe := y - era * 400
	mp := (m + 9) % 12
	doy := (153 * mp + 2) / 5 + d - 1
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	return era * 146097 + doe - 719468
}

civil_from_days :: proc(z_in: i64) -> (y: i64, m: i64, d: i64) {
	z := z_in + 719468
	era := (z if z >= 0 else z - 146096) / 146097
	doe := z - era * 146097
	yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	y = yoe + era * 400
	doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
	mp := (5 * doy + 2) / 153
	d = doy - (153 * mp + 2) / 5 + 1
	m = mp + 3 if mp < 10 else mp - 9
	if m <= 2 {
		y += 1
	}
	return
}

@(private)
Tz :: struct {
	region: ^datetime.TZ_Region,
}

@(private)
_tz_load :: proc(r: ^Runtime, name: string) -> (tz: Tz, ok: bool) {
	if len(name) == 0 || name == "UTC" || name == "Etc/UTC" {
		return {}, true
	}
	if strings.contains(name, "..") {
		return {}, false
	}
	data, err := prim.read_file(r.e.base, concat("/usr/share/zoneinfo/", name), context.temp_allocator)
	if err != .None {
		return {}, false
	}
	reg, rok := timezone.region_load_from_buffer(data, name, context.temp_allocator)
	if !rok {
		return {}, false
	}
	return Tz{region = reg}, true
}

@(private)
_tz_offset :: proc(tz: ^Tz, utc_sec: i64) -> i64 {
	if tz.region == nil {
		return 0
	}
	dt, ok := time.time_to_datetime(time.unix(utc_sec, 0))
	if !ok {
		return 0
	}
	local, lok := timezone.datetime_to_tz(dt, tz.region)
	if !lok {
		return 0
	}
	days := days_from_civil(local.year, i64(local.month), i64(local.day))
	naive := days * 86400 + i64(local.hour) * 3600 + i64(local.minute) * 60 + i64(local.second)
	return naive - utc_sec
}

cron_next :: proc(r: ^Runtime, c: ^Cron, tz_name: string, after_ms: i64) -> i64 {
	tz, ok := _tz_load(r, tz_name)
	if !ok {
		return 0
	}
	start := after_ms / 1000 + 60
	start -= start % 60
	off := _tz_offset(&tz, start)
	local := start + off
	day := local / 86400 if local >= 0 else (local - 86399) / 86400
	first_min := (local - day * 86400) / 60
	for di in 0 ..< i64(366 * 8) {
		dd := day + di
		y, m, d := civil_from_days(dd)
		if c.months & (1 << u16(m)) == 0 {
			continue
		}
		dow := (dd + 4) % 7
		if dow < 0 {
			dow += 7
		}
		dom_ok := c.doms & (1 << u32(d)) != 0
		dow_ok := c.dows & (1 << u8(dow)) != 0
		match := dom_ok && dow_ok
		if !c.dom_any && !c.dow_any {
			match = dom_ok || dow_ok
		} else if c.dom_any {
			match = dow_ok
		} else if c.dow_any {
			match = dom_ok
		}
		if !match {
			continue
		}
		_ = y
		for h in i64(0) ..< 24 {
			if c.hours & (1 << u32(h)) == 0 {
				continue
			}
			for mi in i64(0) ..< 60 {
				if c.minutes & (1 << u64(mi)) == 0 {
					continue
				}
				if di == 0 && h * 60 + mi < first_min {
					continue
				}
				lsec := dd * 86400 + h * 3600 + mi * 60
				utc := lsec - _tz_offset(&tz, lsec - off)
				if utc + _tz_offset(&tz, utc) != lsec {
					continue
				}
				if utc * 1000 > after_ms {
					return utc * 1000
				}
			}
		}
	}
	return 0
}

rfc3339 :: proc(ms: i64) -> string {
	sec := ms / 1000 if ms >= 0 else (ms - 999) / 1000
	day := sec / 86400 if sec >= 0 else (sec - 86399) / 86400
	rem := sec - day * 86400
	y, m, d := civil_from_days(day)
	b := make(Buf, context.temp_allocator)
	pad :: proc(b: ^Buf, v: i64, n: int) {
		tmp: [20]u8
		x := v
		for i := n - 1; i >= 0; i -= 1 {
			tmp[i] = u8('0' + x % 10)
			x /= 10
		}
		append(b, ..tmp[:n])
	}
	pad(&b, y, 4)
	append(&b, '-')
	pad(&b, m, 2)
	append(&b, '-')
	pad(&b, d, 2)
	append(&b, 'T')
	pad(&b, rem / 3600, 2)
	append(&b, ':')
	pad(&b, rem % 3600 / 60, 2)
	append(&b, ':')
	pad(&b, rem % 60, 2)
	append(&b, '.')
	pad(&b, ms - sec * 1000, 3)
	append(&b, 'Z')
	return string(b[:])
}

rfc3339_parse :: proc(s: string) -> (ms: i64, ok: bool) {
	if len(s) < 19 || s[4] != '-' || s[7] != '-' || (s[10] != 'T' && s[10] != 't' && s[10] != ' ') || s[13] != ':' || s[16] != ':' {
		return 0, false
	}
	num :: proc(s: string) -> (i64, bool) {
		n: i64
		for c in s {
			if c < '0' || c > '9' {
				return 0, false
			}
			n = n * 10 + i64(c - '0')
		}
		return n, true
	}
	y, a := num(s[0:4])
	mo, b := num(s[5:7])
	d, c := num(s[8:10])
	h, e := num(s[11:13])
	mi, f := num(s[14:16])
	se, g := num(s[17:19])
	if !(a && b && c && e && f && g) || mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59 || se > 60 {
		return 0, false
	}
	rest := s[19:]
	frac: i64
	if len(rest) > 0 && rest[0] == '.' {
		i := 1
		scale: i64 = 100
		for i < len(rest) && rest[i] >= '0' && rest[i] <= '9' {
			frac += i64(rest[i] - '0') * scale
			scale /= 10
			i += 1
		}
		rest = rest[i:]
	}
	offset: i64
	switch {
	case rest == "Z" || rest == "z" || len(rest) == 0:
	case len(rest) == 6 && (rest[0] == '+' || rest[0] == '-') && rest[3] == ':':
		oh, x := num(rest[1:3])
		om, z := num(rest[4:6])
		if !x || !z {
			return 0, false
		}
		offset = oh * 3600 + om * 60
		if rest[0] == '-' {
			offset = -offset
		}
	case:
		return 0, false
	}
	sec := days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + se - offset
	return sec * 1000 + frac, true
}
