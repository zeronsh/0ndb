package sim

import "core:fmt"
import "core:os"
import "core:testing"
import eng "../../src/engine"
import "../../src/convo"
import "../../src/obj"

back_path_run :: proc(seed: u64) -> (failures: [dynamic]string) {
	failures = make([dynamic]string)
	cfg := default_config(seed)
	cfg.nodes = 1
	cfg.spaces = 0
	cfg.ops = 0
	cfg.crash_rate = 0
	cfg.fault_rate = 0
	cfg.io_rate = 0
	cfg.byzantine = false
	cfg.bulk = false
	cfg.mem_max = 1500
	cfg.verbose = env_u64("SIM_VERBOSE", 0) != 0
	w := new(World)
	world_init(w, cfg)
	_back_path(w)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_back_path :: proc(w: ^World) {
	if !relay_start(&w.relay) {
		world_fail(w, "relay start")
		return
	}
	a := w.nodes[0]
	if !node_start(a) {
		world_fail(w, "node start")
		return
	}
	o: eng.Object
	m1, m2: obj.Rid
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		space, err := eng.space_create(&a.e, "back")
		if err != .None {
			world_fail(w, "back path: space_create: %v", err)
			return
		}
		if oerr := eng.space_open(&a.e, space); oerr != .None {
			world_fail(w, "back path: space_open: %v", oerr)
			return
		}
		o, err = eng.convo_create(&a.e, space, eng.Convo_Settings{title = "back"})
		if err != .None {
			world_fail(w, "back path: convo_create: %v", err)
			return
		}
		serr: eng.Error
		m1, serr = eng.convo_send(&a.e, o, "first")
		if serr != .None && serr != .Pending {
			world_fail(w, "back path: send first: %v", serr)
			return
		}
	}
	run_until(w, w.now + 500_000_000, true)
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		serr: eng.Error
		m2, serr = eng.convo_send(&a.e, o, "second")
		if serr != .None && serr != .Pending {
			world_fail(w, "back path: send second: %v", serr)
			return
		}
	}
	run_until(w, w.now + 500_000_000, true)
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		if _, berr := eng.convo_move(&a.e, o, .Switch, m1); berr != .None && berr != .Pending {
			world_fail(w, "back path: back to the first message: %v", berr)
			return
		}
	}
	run_until(w, w.now + 500_000_000, true)
	m3: obj.Rid
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		st, err := eng.convo_status(&a.e, o)
		if err != .None {
			world_fail(w, "back path: convo_status: %v", err)
			return
		}
		if st.head != m2 {
			world_fail(w, "back path: the head is %v, the second message is %v", st.head, m2)
		}
		if st.position != m1 || !st.browsing {
			world_fail(w, "back path: after back to the first message the position is %v (browsing %v), want %v", st.position, st.browsing, m1)
		}
		serr: eng.Error
		m3, serr = eng.convo_send(&a.e, o, "third")
		if serr != .None && serr != .Pending {
			world_fail(w, "back path: send third: %v", serr)
			return
		}
	}
	run_until(w, w.now + 500_000_000, true)
	context = instance_context(&a.inst)
	defer node_after(a)
	msg, merr := eng.convo_message(&a.e, o, convo.Position{msg = m3}, context.temp_allocator)
	if merr != .None {
		world_fail(w, "back path: read the third message: %v", merr)
		return
	}
	if msg.parent != m1 {
		world_fail(w, "back path: a send after back to the first message is parented on %v, want %v", msg.parent, m1)
	}
}

@(test)
back_path :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	failures := back_path_run(1)
	for f in failures {
		fmt.eprintf("back_path: %s\n", f)
		delete(f)
	}
	testing.expect(t, len(failures) == 0, "back_path failed")
	delete(failures)
}
