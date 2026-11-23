package sim

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import omap "../../src/map"

@(private = "file")
FULL_ROUNDS :: 150

disk_full_run :: proc(seed: u64) -> (failures: [dynamic]string) {
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
	cfg.mem_max = 1500
	cfg.verbose = env_u64("SIM_VERBOSE", 0) != 0
	w := new(World)
	world_init(w, cfg)
	_disk_full(w)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_df_keys :: proc(w: ^World, n: ^Node, m: eng.Object) -> (keys: []string, ok: bool) {
	context = instance_context(&n.inst)
	defer node_after(n)
	out := make([dynamic]string, w.allocator)
	cur: eng.Map_Cursor
	defer omap.cursor_destroy(&cur)
	for {
		rows, more, err := eng.map_scan(&n.e, m, transmute([]u8)string("k/"), &cur, 256, context.temp_allocator)
		if err != .None {
			return nil, false
		}
		for r in rows {
			append(&out, strings.clone(string(r.key), w.allocator))
		}
		if !more {
			break
		}
	}
	slice.sort(out[:])
	return out[:], true
}

@(private = "file")
_df_text :: proc(w: ^World, n: ^Node, t: eng.Object) -> (s: string, ok: bool) {
	context = instance_context(&n.inst)
	defer node_after(n)
	b, err := eng.text_read(&n.e, t, context.temp_allocator)
	if err != .None {
		return "", false
	}
	return strings.clone(string(b), w.allocator), true
}

@(private = "file")
_df_write :: proc(w: ^World, n: ^Node, m, t: eng.Object, tag: string, i: int) -> (merr, terr: eng.Error) {
	context = instance_context(&n.inst)
	defer node_after(n)
	key := fmt.tprintf("k/%s/%04d", tag, i)
	f := [1]omap.Field{{tag = 1, value = transmute([]u8)key}}
	_, merr = eng.map_set(&n.e, m, transmute([]u8)key, f[:])
	terr = eng.text_edit(&n.e, t, 0, 0, fmt.tprintf("<%s%04d>", tag, i))
	return
}

@(private = "file")
_disk_full :: proc(w: ^World) {
	if !relay_start(&w.relay) {
		world_fail(w, "relay start")
		return
	}
	a, b := w.nodes[0], w.nodes[1]
	if !node_start(a) || !node_start(b) {
		world_fail(w, "node start")
		return
	}
	m, t: eng.Object
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		space, err := eng.space_create(&a.e, "full", "relay", w.relay.public)
		if err != .None {
			world_fail(w, "disk full: space_create: %v", err)
			return
		}
		if oerr := eng.space_open(&a.e, space); oerr != .None {
			world_fail(w, "disk full: space_open: %v", oerr)
			return
		}
		proof, perr := eng.member_add(&a.e, space, b.identity, .Device, .Admin, .Approval, 0, w.allocator)
		if perr != .None {
			world_fail(w, "disk full: member_add: %v", perr)
			return
		}
		{
			context = instance_context(&b.inst)
			defer node_after(b)
			if _, jerr := eng.space_join_enrollment(&b.e, space, proof, "full", "relay", w.relay.public); jerr != .None {
				world_fail(w, "disk full: join: %v", jerr)
				return
			}
			if berr := eng.space_open(&b.e, space); berr != .None {
				world_fail(w, "disk full: n1 space_open: %v", berr)
				return
			}
		}
		context = instance_context(&a.inst)
		m, err = eng.map_create(&a.e, space, "full map")
		if err != .None {
			world_fail(w, "disk full: map_create: %v", err)
			return
		}
		t, err = eng.text_create(&a.e, space, "full text", "")
		if err != .None {
			world_fail(w, "disk full: text_create: %v", err)
			return
		}
	}
	for i in 0 ..< 5 {
		_df_write(w, a, m, t, "a", i)
		_df_write(w, b, m, t, "b", i)
		run_until(w, w.now + 1_000_000_000, true)
	}
	run_until(w, w.now + 20_000_000_000, true)
	inc := a.incarnation
	peak := a.inst.main.peak
	a.disk.full = true
	accepted := 0
	refused := 0
	for i in 5 ..< 5 + FULL_ROUNDS {
		merr, terr := _df_write(w, a, m, t, "a", i)
		if merr == .None {
			accepted += 1
		} else if merr == .No_Space || merr == .Io {
			refused += 1
		} else {
			world_fail(w, "disk full: n0 map_set returned %v while the disk is full", merr)
		}
		if terr != .None && terr != .No_Space && terr != .Io {
			world_fail(w, "disk full: n0 text_edit returned %v while the disk is full", terr)
		}
		_df_write(w, b, m, t, "b", i)
		run_until(w, w.now + 200_000_000, true)
		if !a.alive || !a.e_open || a.incarnation != inc {
			world_fail(w, "disk full: n0 went down or restarted after %d writes while its disk was full", i - 5)
			return
		}
	}
	grew := a.inst.main.peak - peak
	if grew > 64 << 20 {
		world_fail(w, "disk full: n0 memory peak grew by %d MiB while its disk was full", grew >> 20)
	}
	if refused == 0 {
		world_fail(w, "disk full: no n0 write was refused while its disk was full (%d accepted)", accepted)
	}
	a.disk.full = false
	_df_write(w, a, m, t, "a", 9999)
	_df_write(w, b, m, t, "b", 9999)
	run_until(w, w.now + 120_000_000_000, true)
	if a.incarnation != inc {
		world_fail(w, "disk full: n0 restarted (incarnation %d to %d)", inc, a.incarnation)
	}
	ka, oka := _df_keys(w, a, m)
	kb, okb := _df_keys(w, b, m)
	if !oka || !okb {
		world_fail(w, "disk full: map scan failed after the disk cleared (n0 %v, n1 %v)", oka, okb)
		return
	}
	if !slice.equal(ka, kb) {
		world_fail(w, "disk full: the map differs after the disk cleared: n0 has %d keys, n1 has %d", len(ka), len(kb))
	}
	for i in 0 ..< 5 + FULL_ROUNDS {
		k := fmt.tprintf("k/b/%04d", i)
		if _, found := slice.binary_search(ka, k); !found {
			world_fail(w, "disk full: n0 never applied n1's %s after the disk cleared", k)
			break
		}
	}
	ta, okta := _df_text(w, a, t)
	tb, oktb := _df_text(w, b, t)
	if !okta || !oktb || ta != tb {
		world_fail(w, "disk full: the text differs after the disk cleared (%d vs %d bytes, reads %v %v)", len(ta), len(tb), okta, oktb)
	}
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		notes, err := eng.verify_derived(&a.e, context.temp_allocator)
		if err != .None {
			world_fail(w, "disk full: derived check: %v", err)
		}
		for x in notes {
			world_fail(w, "disk full: %s", x)
		}
	}
}

@(test)
disk_full :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	failures := disk_full_run(1)
	for f in failures {
		fmt.eprintf("disk_full: %s\n", f)
		delete(f)
	}
	testing.expect(t, len(failures) == 0, "disk_full failed")
	delete(failures)
}
