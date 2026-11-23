package sim

import "base:runtime"
import "core:fmt"
import "core:strings"
import api "../../src/capi/api"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/pack"
import "../../src/prim"
import osync "../../src/sync"

EPOCH_NS :: i64(1_790_000_000) * 1_000_000_000

Connect_Fault :: enum u8 {
	None,
	Refused,
	Timeout,
	Close_Early,
}

Ev_Kind :: enum u8 {
	Op,
	Connect,
	Connect_Fail,
	To_Relay,
	To_Node,
	Fin_To_Node,
	Reset,
	Writable_Node,
	Writable_Relay,
	Fault,
	Restart,
	Relay_Restart,
	Relay_Pack_Job,
	Heal,
	Watch,
	Pack_Job,
	Stream_Step,
	Git_Fetch,
}

Sim_Event :: struct {
	at:    i64,
	seq:   u64,
	kind:  Ev_Kind,
	node:  int,
	conn:  ^Conn,
	gen:   u64,
	bytes: []u8,
	arg:   u64,
}

Node_Clock :: struct {
	w:        ^World,
	mono_off: i64,
	wall_off: i64,
}

Instance :: struct {
	main:     Region,
	temp:     Region,
	loop:     prim.Loop,
	loop_on:  bool,
	reserved: bool,
}

Sim_Checkpoint :: struct {
	object: eng.Object,
	scope:  osync.Scope,
	oid:    [32]u8,
}

Node :: struct {
	w:           ^World,
	idx:         int,
	name:        string,
	disk:        Disk,
	clock:       Node_Clock,
	alive:       bool,
	connects:    int,
	connect_fault: Connect_Fault,
	persist_fail: int,
	ckpt_window: proc(n: ^Node, e: ^eng.Engine, object: eng.Object, stage: eng.Checkpoint_Stage),
	persist_outage: bool,
	unavailable: int,
	incarnation: int,
	inst:        Instance,
	e:           eng.Engine,
	e_open:      bool,
	keyring:     osync.File_Keyring,
	key_open:    bool,
	rng:         Rng,
	ids:         Rng,
	pack_rng:    Rng,
	conns:       [dynamic]^Conn,
	attaches:    map[prim.Id]int,
	partitioned: bool,
	durable:     u64,
	failures:    int,
	last_wake:   u64,
	identity:    osync.Identity,
	caps:        [8]eng.Cap_Credentials,
	restart_pending: bool,
	probed:      bool,
	sent:        map[string]i64,
	boot:        u64,
	observed:    int,
	agent_paths: map[string][dynamic]prim.Id,
	mounts:      [dynamic]Sim_Mount,
	writers:     map[string]Writer_Info,
	reg:         ^fs.Registry,
	watch_scheduled: bool,
	api:         api.Api,
	api_on:      bool,
	agent_pending: [dynamic]Agent_Pending,
}

Relay_Node :: struct {
	fills_seen: u64,
	red_check: bool,
	w:      ^World,
	disk:   Disk,
	clock:  Node_Clock,
	alive:  bool,
	inst:   Instance,
	r:      osync.Relay_Core,
	fs:     osync.File_Store,
	pk:     pack.Pack,
	packed: bool,
	async:  bool,
	ts:     osync.Tier_Store,
	objs:   osync.Dir_Object_Store,
	slow:   Sim_Objects,
	tiered: bool,
	wake:   prim.Timer,
	r_on:   bool,
	rng:    Rng,
	public: osync.Public_Key,
	mauth:  osync.Member_Authorizer,
	cauth:  osync.Cap_Authorizer,
}

World_Stats :: struct {
	events:       u64,
	steps:        u64,
	ops:          u64,
	ops_failed:   u64,
	crashes:      u64,
	relay_crash:  u64,
	resets:       u64,
	partitions:   u64,
	jumps:        u64,
	bytes_net:    u64,
	deliveries:   u64,
	engine_close: u64,
	relay_close:  u64,
	backpressure: u64,
	detected:     u64,
	tampered:     u64,
	io_errors:    u64,
	stalls:       u64,
	conflict_pairs: u64,
	search_models:  u64,
	extra:          [STATS_MAX]u64,
}

Config :: struct {
	seed:        u64,
	nodes:       int,
	spaces:      int,
	ops:         int,
	op_gap_ms:   i64,
	crash_rate:  int,
	fault_rate:  int,
	fault_gap_ms: i64,
	max_delay:   i64,
	window:      int,
	settle_ms:   i64,
	verbose:     bool,
	quiet:       bool,
	trace_limit: int,
	disabled:    bit_set[Op_Kind],
	share_access: eng.Access_Set,
	rid_probe:   bool,
	io_rate:     u64,
	byzantine:   bool,
	train_min:   int,
	bulk:        bool,
	dict_sample_min: int,
	mem_max:     u64,
	keep_ops:    Filter,
	keep_faults: Filter,
	storage:     eng.Storage_Mode,
	durability:  eng.Durability,
	promote:     i64,
	persist_fault: bool,
	marks:       bool,
	index_trust: bool,
}

World :: struct {
	cfg:       Config,
	now:       i64,
	seq:       u64,
	queue:     [dynamic]Sim_Event,
	rng:       Rng,
	net_rng:   Rng,
	fault_rng: Rng,
	sched_rng: Rng,
	op_index:  int,
	probe_crash: int,
	fault_index: int,
	cur_op:    int,
	cur_fault: int,
	nodes:     [dynamic]^Node,
	relay:     Relay_Node,
	conn_ids:  u64,
	conns:     [dynamic]^Conn,
	trace:     u64,
	marks:     [dynamic]Ev_Mark,
	stats:     World_Stats,
	failures:  [dynamic]string,
	log:       [dynamic]string,
	model:     Model,
	allocator: runtime.Allocator,
	phase:     Phase,
	ctx:       runtime.Context,
	aborted:   bool,
	cipher:    Cipher_Watch,
	mem_checks: u64,
	quarantines: [dynamic]Quarantine,
	checkpoints: [dynamic]Sim_Checkpoint,
	promos:    [dynamic]Promo_Rec,
	live:      [dynamic]^Live_Read,
	bufs:      [dynamic]^Sim_Buffer,
	anchors:   [dynamic]Sim_Anchor,
	buf_group: u64,
	streams:   [dynamic]^M_Stream,
	watches:   [dynamic]^Watch,
	node_cfg:  proc(n: ^Node, cfg: ^eng.Config),
	remote:    Sim_Remote,
	attrib_crashed: bool,
	attrib_chained: bool,
}

Quarantine :: struct {
	node:   int,
	object: prim.Id,
}

Phase :: enum u8 {
	Workload,
	Quiesce,
	Check,
}

clock_mono :: proc(data: rawptr) -> i64 {
	c := (^Node_Clock)(data)
	return c.w.now + c.mono_off
}

clock_wall :: proc(data: rawptr) -> i64 {
	c := (^Node_Clock)(data)
	return EPOCH_NS + c.w.now + c.wall_off
}

node_clock :: proc(c: ^Node_Clock) -> prim.Clock {
	return prim.Clock{data = c, mono_ns = clock_mono, wall_ns = clock_wall}
}

world_fail :: proc(w: ^World, format: string, args: ..any) {
	context = w.ctx
	s := fmt.aprintf(format, ..args, allocator = w.allocator)
	append(&w.failures, s)
	world_note(w, "FAIL %s", s)
}

world_note :: proc(w: ^World, format: string, args: ..any) {
	context = w.ctx
	s := fmt.tprintf(format, ..args)
	w.trace = mix_str(w.trace, s)
	if w.cfg.verbose && !w.cfg.quiet {
		fmt.eprintf("[%9.3f] %s\n", f64(w.now) / 1e6, s)
	}
	if len(w.log) < w.cfg.trace_limit {
		append(&w.log, strings.clone(s, w.allocator))
	}
}

schedule :: proc(w: ^World, ev: Sim_Event) {
	x := ev
	w.seq += 1
	x.seq = w.seq
	append(&w.queue, x)
	i := len(w.queue) - 1
	for i > 0 {
		p := (i - 1) / 2
		if !_ev_less(w.queue[i], w.queue[p]) {
			break
		}
		w.queue[i], w.queue[p] = w.queue[p], w.queue[i]
		i = p
	}
}

@(private = "file")
_ev_less :: proc(a, b: Sim_Event) -> bool {
	if a.at != b.at {
		return a.at < b.at
	}
	return a.seq < b.seq
}

pop_event :: proc(w: ^World) -> Sim_Event {
	top := w.queue[0]
	last := pop(&w.queue)
	if len(w.queue) > 0 {
		w.queue[0] = last
		i := 0
		n := len(w.queue)
		for {
			l := 2 * i + 1
			if l >= n {
				break
			}
			m := l
			if l + 1 < n && _ev_less(w.queue[l + 1], w.queue[l]) {
				m = l + 1
			}
			if !_ev_less(w.queue[m], w.queue[i]) {
				break
			}
			w.queue[i], w.queue[m] = w.queue[m], w.queue[i]
			i = m
		}
	}
	return top
}

instance_reserve :: proc(inst: ^Instance, slot: int) -> (ok: bool, why: string) {
	base := REGION_BASE + uintptr(slot) * region_stride()
	if mok, mwhy := region_map(&inst.main, base, region_main_size, false); !mok {
		return false, fmt.tprintf("main region at %p: %s", rawptr(base), mwhy)
	}
	tbase := base + uintptr(region_main_size)
	if tok, twhy := region_map(&inst.temp, tbase, region_temp_size, true); !tok {
		region_unmap(&inst.main)
		return false, fmt.tprintf("temp region at %p: %s", rawptr(tbase), twhy)
	}
	inst.reserved = true
	return true, ""
}

instance_release :: proc(inst: ^Instance) {
	if inst.loop_on || inst.main.sites != nil {
		instance_kill(inst)
	}
	region_unmap(&inst.main)
	region_unmap(&inst.temp)
	inst^ = {}
}

world_reserve :: proc(w: ^World) -> bool {
	for n in w.nodes {
		if n.inst.reserved {
			continue
		}
		if ok, why := instance_reserve(&n.inst, n.idx); !ok {
			world_fail(w, "%s could not reserve its deterministic memory region (%d MiB at slot %d): %s", n.name, region_stride() >> 20, n.idx, why)
			return false
		}
	}
	if !w.relay.inst.reserved {
		if ok, why := instance_reserve(&w.relay.inst, RELAY_SLOT); !ok {
			world_fail(w, "relay could not reserve its deterministic memory region (%d MiB at slot %d): %s", region_stride() >> 20, RELAY_SLOT, why)
			return false
		}
	}
	return true
}

instance_begin :: proc(inst: ^Instance, slot: int) -> (ok: bool, why: string) {
	if !inst.reserved {
		return false, fmt.tprintf("slot %d has no reserved region", slot)
	}
	region_reset(&inst.main)
	region_reset(&inst.temp)
	if leak_sites {
		inst.main.sites = new(map[uintptr]runtime.Source_Code_Location, runtime.heap_allocator())
		inst.main.sites^ = make(map[uintptr]runtime.Source_Code_Location, runtime.heap_allocator())
	}
	return true, ""
}

instance_context :: proc(inst: ^Instance) -> runtime.Context {
	c := context
	c.allocator = region_allocator(&inst.main)
	c.temp_allocator = region_allocator(&inst.temp)
	return c
}

instance_kill :: proc(inst: ^Instance) {
	if inst.loop_on {
		for s in inst.loop.slots {
			if u8(s.kind) == 1 && s.fd >= 0 {
				prim.close(s.fd)
			}
		}
		context = instance_context(inst)
		prim.loop_destroy(&inst.loop)
		inst.loop_on = false
	}
	if inst.main.sites != nil {
		delete(inst.main.sites^)
		free(inst.main.sites, runtime.heap_allocator())
		inst.main.sites = nil
	}
	region_reset(&inst.main)
	region_reset(&inst.temp)
	main, temp, reserved := inst.main, inst.temp, inst.reserved
	inst^ = {}
	inst.main, inst.temp, inst.reserved = main, temp, reserved
}

leak_sites := false

instance_leaks :: proc(inst: ^Instance) -> (n: int, bytes: int) {
	return inst.main.live, inst.main.bytes
}

world_init :: proc(w: ^World, cfg: Config) {
	w^ = {}
	w.cfg = cfg
	w.allocator = runtime.heap_allocator()
	w.ctx = context
	w.ctx.allocator = runtime.heap_allocator()
	w.queue = make([dynamic]Sim_Event, w.allocator)
	w.nodes = make([dynamic]^Node, w.allocator)
	w.conns = make([dynamic]^Conn, w.allocator)
	w.failures = make([dynamic]string, w.allocator)
	w.log = make([dynamic]string, w.allocator)
	w.quarantines = make([dynamic]Quarantine, w.allocator)
	w.checkpoints = make([dynamic]Sim_Checkpoint, w.allocator)
	cipher_init(w)
	w.promos = make([dynamic]Promo_Rec, w.allocator)
	w.live = make([dynamic]^Live_Read, w.allocator)
	w.streams = make([dynamic]^M_Stream, w.allocator)
	w.watches = make([dynamic]^Watch, w.allocator)
	rng_init(&w.rng, cfg.seed, 1)
	rng_init(&w.net_rng, cfg.seed, 2)
	rng_init(&w.fault_rng, cfg.seed, 3)
	rng_init(&w.sched_rng, cfg.seed, 4)
	model_init(&w.model, w)
	remote_init(w)
	w.relay.w = w
	disk_init(&w.relay.disk, "relay", w.allocator)
	w.relay.disk.ghost_root = RELAY_DIR
	w.relay.clock = Node_Clock{w = w, mono_off = rng_range(&w.rng, 0, 1 << 40), wall_off = rng_range(&w.rng, -5_000_000_000, 5_000_000_000)}
	w.relay.disk.wall = clock_wall
	w.relay.disk.wall_data = &w.relay.clock
	for i in 0 ..< cfg.nodes {
		n := new(Node, w.allocator)
		n.w = w
		n.idx = i
		n.name = fmt.aprintf("n%d", i, allocator = w.allocator)
		disk_init(&n.disk, n.name, w.allocator)
		n.disk.ghost_root = NODE_DIR
		n.clock = Node_Clock{w = w, mono_off = rng_range(&w.rng, 0, 1 << 40), wall_off = rng_range(&w.rng, -30_000_000_000, 30_000_000_000)}
		n.disk.verbose = cfg.verbose && !cfg.quiet
		n.disk.fail_rate = cfg.io_rate
		rng_init(&n.disk.fail_rng, cfg.seed, 5000 + u64(i))
		n.disk.wall = clock_wall
		n.disk.wall_data = &n.clock
		n.conns = make([dynamic]^Conn, w.allocator)
		n.attaches = make(map[prim.Id]int, w.allocator)
		n.mounts = make([dynamic]Sim_Mount, w.allocator)
		n.writers = make(map[string]Writer_Info, w.allocator)
		n.agent_paths = make(map[string][dynamic]prim.Id, w.allocator)
		append(&w.nodes, n)
	}
	if !world_reserve(w) {
		w.aborted = true
	}
	run_world_init(w)
}

world_destroy :: proc(w: ^World) {
	delete(w.marks)
	run_world_destroy(w)
	for n in w.nodes {
		if n.alive {
			node_kill(n)
		}
		instance_release(&n.inst)
		node_mounts_drop(w, n)
		delete(n.mounts)
		delete(n.writers)
		agent_paths_clear(w, n)
		delete(n.agent_paths)
		for k in n.sent {
			delete(k, w.allocator)
		}
		delete(n.sent)
		disk_destroy(&n.disk)
		delete(n.conns)
		delete(n.attaches)
		for pa in n.agent_pending {
			agent_pending_free(w, pa)
		}
		delete(n.agent_pending)
		delete(n.name, w.allocator)
		free(n, w.allocator)
	}
	delete(w.nodes)
	if w.relay.alive {
		relay_kill(&w.relay)
	}
	instance_release(&w.relay.inst)
	disk_destroy(&w.relay.disk)
	for c in w.conns {
		for b in c.held {
			delete(b, w.allocator)
		}
		delete(c.held)
		delete(c.byz_buf)
		delete(c.byz_hold)
		delete(c.tap_up.buf)
		delete(c.tap_down.buf)
		free(c, w.allocator)
	}
	delete(w.conns)
	for ev in w.queue {
		delete(ev.bytes, w.allocator)
	}
	delete(w.queue)
	for s in w.failures {
		delete(s, w.allocator)
	}
	delete(w.failures)
	for s in w.log {
		delete(s, w.allocator)
	}
	delete(w.log)
	delete(w.quarantines)
	delete(w.checkpoints)
	cipher_destroy(w)
	for r in w.live {
		free(r, w.allocator)
	}
	delete(w.live)
	streams_destroy(w)
	model_destroy(&w.model)
	remote_destroy(w)
}

loop_deadline :: proc(l: ^prim.Loop) -> (at: i64, ok: bool) {
	if len(l.heap) == 0 {
		return 0, false
	}
	return l.timers[l.heap[0]].deadline, true
}

loop_armed :: proc(l: ^prim.Loop) -> int {
	return len(l.heap)
}
