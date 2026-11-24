package sim

import "core:fmt"
import "core:os"
import "core:testing"
import eng "../../src/engine"
import "../../src/prim"

@(private = "file")
_ric_case :: proc(seed: u64, k: u64) -> (crashed: bool, changed: int, failures: [dynamic]string) {
	failures = make([dynamic]string)
	cfg := default_config(seed)
	cfg.nodes = 2
	cfg.spaces = 0
	cfg.ops = 0
	cfg.crash_rate = 0
	cfg.fault_rate = 0
	cfg.io_rate = 0
	cfg.byzantine = false
	cfg.bulk = false
	cfg.durability = .Async
	cfg.mem_max = 1500
	cfg.verbose = env_u64("SIM_VERBOSE", 0) != 0
	w := new(World)
	world_init(w, cfg)
	w.node_cfg = reissue_hold
	crashed, changed = _ric_run(w, k)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_ric_read :: proc(w: ^World, n: ^Node, tree: eng.Object) -> (data: string, ok: bool) {
	context = instance_context(&n.inst)
	defer node_after(n)
	b, err := eng.tree_read(&n.e, tree, "a.txt", w.allocator)
	if err != .None {
		return "", false
	}
	return string(b), true
}

@(private = "file")
_ric_run :: proc(w: ^World, k: u64) -> (crashed: bool, changed: int) {
	lost := false
	seen := make([dynamic]Reissue_Batch, w.allocator)
	if !relay_start(&w.relay) {
		world_fail(w, "reissue: relay start")
		return
	}
	a, b := w.nodes[0], w.nodes[1]
	if !node_start(a) || !node_start(b) {
		world_fail(w, "reissue: node start")
		return
	}
	space: prim.Id
	tree: eng.Object
	proof: []u8
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		err: eng.Error
		if space, err = eng.space_create(&a.e, "reissue", "relay", w.relay.public); err != .None {
			world_fail(w, "reissue: space_create: %v", err)
			return
		}
		if err = eng.space_open(&a.e, space); err != .None {
			world_fail(w, "reissue: space_open: %v", err)
			return
		}
		if tree, err = eng.tree_create(&a.e, space, "work"); err != .None {
			world_fail(w, "reissue: tree_create: %v", err)
			return
		}
		if err = eng.tree_write(&a.e, tree, "a.txt", transmute([]u8)string("one\n"), tree_base(&a.e, tree)); err != .None {
			world_fail(w, "reissue: n0 tree_write: %v", err)
			return
		}
		if proof, err = eng.member_add(&a.e, space, b.identity, .Device, .Admin, .Approval, 0, w.allocator); err != .None {
			world_fail(w, "reissue: member_add: %v", err)
			return
		}
	}
	{
		context = instance_context(&b.inst)
		defer node_after(b)
		if _, err := eng.space_join_enrollment(&b.e, space, proof, "reissue", "relay", w.relay.public); err != .None {
			world_fail(w, "reissue: space_join_enrollment: %v", err)
			return
		}
		if err := eng.space_open(&b.e, space); err != .None {
			world_fail(w, "reissue: n1 space_open: %v", err)
			return
		}
	}
	run_until(w, w.now + 20_000_000_000, true)
	ready := false
	for _ in 0 ..< 40 {
		if got, ok := _ric_read(w, b, tree); ok && got == "one\n" {
			ready = true
			break
		}
		run_until(w, w.now + 1_000_000_000, true)
	}
	if !ready {
		world_fail(w, "reissue: n1 never read n0's write")
		return
	}
	crashes := w.stats.crashes
	{
		context = instance_context(&b.inst)
		base := tree_base(&b.e, tree)
		b.disk.crash_at = b.disk.stats.ops + k
		err := eng.tree_write(&b.e, tree, "a.txt", transmute([]u8)string("two\n"), base)
		if err != .None && !b.disk.dead {
			world_fail(w, "reissue: n1 tree_write before the crash: %v", err)
			return
		}
		reissue_see(w, b, tree, &seen)
		node_after(b)
	}
	reissue_watch(w, b, tree, &seen, w.now + 5_000_000_000)
	run_until(w, w.now + 5_000_000_000, true)
	b.disk.crash_at = 0
	crashed = w.stats.crashes > crashes
	if !reissue_restarted(w, b) {
		world_fail(w, "reissue: n1 did not restart after the crash at op %d", k)
		return
	}
	run_until(w, w.now + 5_000_000_000, true)
	if got, ok := _ric_read(w, b, tree); ok {
		lost = got != "two\n"
	}
	if seen, ok := _ric_read(w, a, tree); ok && lost && seen == "two\n" {
		world_fail(w, "reissue: crash at op %d: n0 holds n1's write \"two\" that n1 lost, before n1 re-issues its sequence", k)
	}
	werr := eng.Error.Missing
	for _ in 0 ..< 40 {
		context = instance_context(&b.inst)
		werr = eng.tree_write(&b.e, tree, "a.txt", transmute([]u8)string("three\n"), tree_base(&b.e, tree))
		node_after(b)
		if werr != .Missing && werr != .Busy {
			break
		}
		run_until(w, w.now + 1_000_000_000, true)
	}
	if werr != .None {
		world_fail(w, "reissue: n1 tree_write after the crash at op %d: %v", k, werr)
	}
	run_until(w, w.now + 20_000_000_000, true)
	ga, oka := _ric_read(w, a, tree)
	gb, okb := _ric_read(w, b, tree)
	if !oka || !okb {
		world_fail(w, "reissue: crash at op %d: a.txt unreadable (n0 %v, n1 %v)", k, oka, okb)
		return
	}
	if gb != "three\n" {
		world_fail(w, "reissue: crash at op %d: n1 reads %q after writing \"three\"", k, gb)
	}
	if ga != gb {
		world_fail(w, "reissue: crash at op %d (n1 lost its write: %v): n0 reads %q but n1 reads %q", k, lost, ga, gb)
	}
	_, changed = reissue_settle(w, fmt.tprintf("reissue: crash at op %d", k), a, b, tree, seen[:])
	check_uploaded(w)
	check_derived(a, fmt.tprintf("reissue crash at op %d, n0", k))
	check_derived(b, fmt.tprintf("reissue crash at op %d, n1", k))
	return
}

@(test)
reissue_crash :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	points, changed_points := 0, 0
	for seed in u64(1) ..= 2 {
		for k := u64(1); k < 4000; k += 1 {
			crashed, changed, failures := _ric_case(seed, k)
			if crashed {
				points += 1
				changed_points += 1 if changed > 0 else 0
			}
			for f in failures {
				fmt.eprintf("reissue_crash seed %d crash %d: %s\n", seed, k, f)
				delete(f)
			}
			testing.expectf(t, len(failures) == 0, "reissue_crash seed %d crash at op %d failed", seed, k)
			n := len(failures)
			delete(failures)
			if !crashed || n > 0 {
				break
			}
		}
	}
	testing.expect(t, changed_points > 0, "reissue_crash never re-issued a sequence")
	fmt.eprintf("reissue_crash: %d crash points, %d re-issued a lost sequence with other operations\n", points, changed_points)
	free_all(context.temp_allocator)
}
