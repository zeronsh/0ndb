package model

import "base:runtime"
import "../prim"

KEEPALIVE_DEFAULT_MARGIN_MS :: 30_000
KEEPALIVE_DEFAULT_WINDOW_MS :: 30 * 60 * 1000
KEEPALIVE_MAX_BODY :: 1 << 20

keepalive_ttl_ms :: proc(cfg: ^Config) -> i64 {
	return cfg.cache_ttl == .Long ? ANTHROPIC_CACHE_LONG_MS : ANTHROPIC_CACHE_SHORT_MS
}

keepalive_window :: proc(cfg: ^Config) -> i64 {
	return cfg.keepalive.window_ms > 0 ? cfg.keepalive.window_ms : KEEPALIVE_DEFAULT_WINDOW_MS
}

keepalive_next :: proc(cfg: ^Config, last_call_ns: i64) -> i64 {
	margin := cfg.keepalive.margin_ms > 0 ? cfg.keepalive.margin_ms : KEEPALIVE_DEFAULT_MARGIN_MS
	return last_call_ns + max(keepalive_ttl_ms(cfg) - margin, 1000) * 1_000_000
}

keepalive_build :: proc(r: ^Run, ctx: ^Context, allocator := context.temp_allocator) -> (Http_Request, bool) {
	if !r.cfg.spec.keepalive || r.model.warm_tail == nil {
		return {}, false
	}
	context.allocator = r.allocator
	saved := r.cfg.server_state
	r.cfg.server_state = .Off
	load_context(r, ctx)
	r.cfg.server_state = saved
	if r.t.items == 0 {
		return {}, false
	}
	opts := Request_Opts {
		kind       = .Keepalive,
		compaction = r.t.compaction,
	}
	clear(&r.head)
	r.model.head(&r.model, &r.cfg, &r.ctx, &opts, &r.head)
	clear(&r.tailbuf)
	r.model.tail(&r.model, &r.cfg, .Keepalive, &r.tailbuf)
	clear(&r.extra)
	r.model.warm_tail(&r.t, &r.extra)
	clear(&r.segs)
	append(&r.segs, r.head[:])
	buf := r.t.buf[:]
	marker := r.model.marker(&r.model, &r.cfg)
	if marker != "" && r.t.mark > 0 && r.t.mark < len(buf) {
		append(&r.segs, buf[:r.t.mark])
		append(&r.segs, transmute([]u8)marker)
		append(&r.segs, buf[r.t.mark:])
	} else {
		append(&r.segs, buf)
	}
	append(&r.segs, r.extra[:])
	append(&r.segs, r.tailbuf[:])
	headers := make([dynamic]Header, allocator)
	append(&headers, Header{HEADER_CONTENT_TYPE, JSON_MEDIA_TYPE})
	r.model.auth(&r.model, &r.cfg, &opts, &headers)
	for h in r.cfg.headers {
		append(&headers, h)
	}
	url := r.cfg.url != "" ? r.cfg.url : ANTHROPIC_URL
	return Http_Request{method = "POST", url = url, headers = headers[:], body = r.segs[:], connect_ms = 15_000, stall_ms = 120_000}, true
}

Warm_Supply :: #type proc(data: rawptr, key: u64, cfg: ^Config, ctx: ^Context) -> bool
Warm_Report :: #type proc(data: rawptr, key: u64, usage: Call_Usage, cost: f64, status: int, err: Http_Error)

Warmer :: struct {
	loop:      ^prim.Loop,
	http:      Http,
	allocator: runtime.Allocator,
	heap:      [dynamic]Warm_Slot,
	due:       map[u64]Warm_Slot,
	timer:     prim.Timer,
	timer_at:  i64,
	supply:    Warm_Supply,
	report:    Warm_Report,
	data:      rawptr,
	inflight:  int,
}

Warm_Slot :: struct {
	key:   u64,
	at:    i64,
	until: i64,
}

@(private)
Warm_Call :: struct {
	w:       ^Warmer,
	key:     u64,
	until:   i64,
	started: i64,
	run:     Run,
	status:  int,
	body:    [dynamic]u8,
	cfg_ttl: Config,
}

warmer_init :: proc(w: ^Warmer, l: ^prim.Loop, http: Http, supply: Warm_Supply, report: Warm_Report, data: rawptr, allocator := context.allocator) {
	w^ = {loop = l, http = http, allocator = allocator, supply = supply, report = report, data = data}
	w.heap = make([dynamic]Warm_Slot, allocator)
	w.due = make(map[u64]Warm_Slot, allocator)
}

warmer_destroy :: proc(w: ^Warmer) {
	if w.timer != 0 {
		prim.timer_cancel(w.loop, w.timer)
	}
	delete(w.heap)
	delete(w.due)
	w^ = {}
}

warmer_schedule :: proc(w: ^Warmer, key: u64, at: i64, until: i64) {
	if at >= until {
		warmer_cancel(w, key)
		return
	}
	slot := Warm_Slot{key, at, until}
	w.due[key] = slot
	heap_push(w, slot)
	warmer_arm(w)
}

warmer_cancel :: proc(w: ^Warmer, key: u64) {
	delete_key(&w.due, key)
	warmer_arm(w)
}

warmer_pending :: proc(w: ^Warmer) -> int {
	return len(w.due)
}

@(private)
heap_push :: proc(w: ^Warmer, s: Warm_Slot) {
	append(&w.heap, s)
	i := len(w.heap) - 1
	for i > 0 {
		p := (i - 1) / 2
		if w.heap[p].at <= w.heap[i].at {
			break
		}
		w.heap[p], w.heap[i] = w.heap[i], w.heap[p]
		i = p
	}
}

@(private)
heap_pop :: proc(w: ^Warmer) -> Warm_Slot {
	top := w.heap[0]
	last := pop(&w.heap)
	if len(w.heap) > 0 {
		w.heap[0] = last
		i := 0
		n := len(w.heap)
		for {
			l := 2 * i + 1
			if l >= n {
				break
			}
			m := l
			if l + 1 < n && w.heap[l + 1].at < w.heap[l].at {
				m = l + 1
			}
			if w.heap[i].at <= w.heap[m].at {
				break
			}
			w.heap[i], w.heap[m] = w.heap[m], w.heap[i]
			i = m
		}
	}
	return top
}

@(private)
warmer_live :: proc(w: ^Warmer, s: Warm_Slot) -> bool {
	cur, ok := w.due[s.key]
	return ok && cur.at == s.at
}

@(private)
warmer_arm :: proc(w: ^Warmer) {
	for len(w.heap) > 0 && !warmer_live(w, w.heap[0]) {
		heap_pop(w)
	}
	at: i64 = 0
	if len(w.heap) > 0 {
		at = w.heap[0].at
	}
	if at == w.timer_at && (at == 0 || prim.timer_pending(w.loop, w.timer)) {
		return
	}
	if w.timer != 0 {
		prim.timer_cancel(w.loop, w.timer)
		w.timer = 0
	}
	w.timer_at = at
	if at != 0 {
		w.timer = prim.timer_at(w.loop, at, w, warmer_fire)
	}
}

@(private)
warmer_fire :: proc(l: ^prim.Loop, data: rawptr) {
	w := (^Warmer)(data)
	w.timer = 0
	w.timer_at = 0
	now := prim.mono_ns()
	for len(w.heap) > 0 && w.heap[0].at <= now {
		s := heap_pop(w)
		if !warmer_live(w, s) {
			continue
		}
		delete_key(&w.due, s.key)
		warm_one(w, s.key, s.until, now)
	}
	warmer_arm(w)
}

@(private)
warm_one :: proc(w: ^Warmer, key: u64, until: i64, now: i64) {
	cfg: Config
	ctx: Context
	if w.supply == nil || !w.supply(w.data, key, &cfg, &ctx) {
		return
	}
	c := new(Warm_Call, w.allocator)
	c.w = w
	c.key = key
	c.until = until
	c.started = now
	c.body = make([dynamic]u8, w.allocator)
	run_init(&c.run, cfg, model_for(cfg.spec.api), w.allocator)
	req, ok := keepalive_build(&c.run, &ctx)
	if !ok {
		warm_free(c)
		return
	}
	w.inflight += 1
	if _, err := http_start(&w.http, &req, Http_Sink{data = c, head = warm_head, body = warm_body, done = warm_done}); err != .None {
		w.inflight -= 1
		if w.report != nil {
			w.report(w.data, key, {}, 0, 0, err)
		}
		warm_free(c)
	}
}

@(private)
warm_free :: proc(c: ^Warm_Call) {
	a := c.w.allocator
	run_destroy(&c.run)
	delete(c.body)
	free(c, a)
}

@(private)
warm_head :: proc(data: rawptr, id: Http_Id, status: int, headers: []Header) {
	c := (^Warm_Call)(data)
	c.status = status
}

@(private)
warm_body :: proc(data: rawptr, id: Http_Id, chunk: []u8) -> bool {
	c := (^Warm_Call)(data)
	room := KEEPALIVE_MAX_BODY - len(c.body)
	if room > 0 {
		append(&c.body, ..chunk[:min(room, len(chunk))])
	}
	return true
}

@(private)
warm_done :: proc(data: rawptr, id: Http_Id, err: Http_Error, detail: string) {
	c := (^Warm_Call)(data)
	w := c.w
	w.inflight -= 1
	u: Call_Usage
	cost: f64
	if err == .None && c.status == 200 {
		u = c.run.model.warm_usage(&c.run.model, c.body[:])
		cost = cost_usd(c.run.cfg.spec, u)
	}
	if w.report != nil {
		w.report(w.data, c.key, u, cost, c.status, err)
	}
	if err == .None && c.status == 200 {
		next := keepalive_next(&c.run.cfg, c.started)
		if next < c.until {
			if _, exists := w.due[c.key]; !exists {
				warmer_schedule(w, c.key, next, c.until)
			}
		}
	}
	warm_free(c)
}
