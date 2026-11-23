package sim

import "core:fmt"
import "core:os"
import "core:testing"
import osync "../../src/sync"
import "../../src/prim"

STAT_EARLY_AHEAD: Stat
STAT_EARLY_CRASH: Stat
STAT_EARLY_BYTES: Stat

@(private = "file")
EV_EARLY: Ev_Kind

@(private = "file")
_early_on: bool

@(private = "file")
Early_Key :: struct {
	node:  int,
	space: prim.Id,
}

@(private = "file")
_early_seen: map[Early_Key]u64

@(private = "file")
EARLY_TICK :: 1_000_000

@(private = "file")
_early_init :: proc(w: ^World) {
	if !_early_on {
		return
	}
	w.cfg.byzantine = false
	_early_seen = make(map[Early_Key]u64, w.allocator)
	schedule(w, Sim_Event{at = w.now + EARLY_TICK, kind = EV_EARLY})
}

@(private = "file")
_early_destroy :: proc(w: ^World) {
	if _early_on {
		delete(_early_seen)
		_early_seen = nil
	}
}

@(private = "file")
_relay_length :: proc(w: ^World, id: osync.Stream_Id) -> (i64, bool) {
	if !w.relay.alive {
		return 0, false
	}
	for mk1_ in prim.sorted_keys(w.relay.r.spaces) {
		if mk1_ not_in w.relay.r.spaces {
			continue
		}
		sp := w.relay.r.spaces[mk1_]
		if st, ok := sp.streams[id]; ok && st.h != nil {
			return st.length, true
		}
	}
	return 0, false
}

@(private = "file")
_early_event :: proc(w: ^World, ev: ^Sim_Event) {
	for n, i in w.nodes {
		if !n.alive || !n.e_open {
			continue
		}
		for id, sp in n.e.spaces {
			if !sp.repl_on {
				continue
			}
			r := &sp.repl
			k := Early_Key{i, id}
			if r.ahead_n <= _early_seen[k] {
				continue
			}
			_early_seen[k] = r.ahead_n
			stat_add(w, STAT_EARLY_AHEAD)
			length, ok := _relay_length(w, r.ahead_id)
			if ok && length < r.ahead_to && rng_chance(&w.fault_rng, 1, 2) {
				world_note(w, "%s holds pushed bytes to %d while the relay's durable length is %d: crashing the relay", n.name, r.ahead_to, length)
				stat_add(w, STAT_EARLY_CRASH)
				relay_crashed(&w.relay)
			}
		}
	}
	if w.cfg.ops > 0 {
		schedule(w, Sim_Event{at = w.now + EARLY_TICK, kind = EV_EARLY})
	}
}

@(private = "file")
_early_check :: proc(w: ^World) {
	if !_early_on || !w.relay.alive {
		return
	}
	rn := &w.relay
	context = instance_context(&rn.inst)
	defer relay_after(rn)
	st := rn.r.store
	for n in w.nodes {
		if !n.alive || !n.e_open {
			continue
		}
		for sid, sp in n.e.spaces {
			if !sp.repl_on {
				continue
			}
			ns, _, nerr := st.namespace_open(st.data, sid)
			if nerr != .None {
				continue
			}
			defer st.namespace_close(st.data, ns)
			for id, rm in sp.repl.remotes {
				h, length, oerr := st.stream_open(st.data, ns, id, false)
				if oerr != .None {
					continue
				}
				defer st.stream_close(st.data, h)
				for g in rm.rep.have {
					hi := min(g.to, length)
					for at := g.from; at < hi; {
						k := min(hi - at, 64 * 1024)
						a := make([]u8, k, context.temp_allocator)
						b := make([]u8, k, context.temp_allocator)
						na, ea := prim.read_at(sp.repl.vfs, rm.rep.fd, a, at)
						nb, eb := st.stream_read(st.data, h, at, b)
						if ea != .None || eb != .None || i64(na) != k || i64(nb) != k {
							break
						}
						for x in 0 ..< int(k) {
							if a[x] != b[x] && a[x] != 0 && b[x] != 0 {
								world_fail(w, "early pushes: %s's replica of %s differs from the relay's durable stream at offset %d", n.name, rm.name, at + i64(x))
								return
							}
						}
						stat_add(w, STAT_EARLY_BYTES, u64(k))
						at += k
					}
				}
			}
		}
	}
}

@(init)
_early_hooks :: proc "contextless" () {
	register_world(80, _early_init, _early_destroy)
	EV_EARLY = register_event(_early_event)
	register_final_check(120, _early_check)
	register_stat_line(60, "early_pushes")
	STAT_EARLY_AHEAD = register_stat(60, 0, "ahead")
	STAT_EARLY_CRASH = register_stat(60, 1, "relay_crashes")
	STAT_EARLY_BYTES = register_stat(60, 2, "replica_bytes_checked")
}

@(test)
early_push_crash :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	_early_on = true
	defer _early_on = false
	ahead, crashes, checked: u64
	for seed in ([]u64{10, 14, 26, 32}) {
		res := run_seed(seed, false, nil, "early", true)
		ahead += stat_get(&res.stats, STAT_EARLY_AHEAD)
		crashes += stat_get(&res.stats, STAT_EARLY_CRASH)
		checked += stat_get(&res.stats, STAT_EARLY_BYTES)
		for f in res.failures {
			fmt.eprintf("early_push_crash seed %d: %s\n", seed, f)
		}
		testing.expectf(t, len(res.failures) == 0, "early_push_crash seed %d failed", seed)
		free_result(&res)
	}
	testing.expect(t, crashes > 0, "no relay crash fell between an early push and its commit")
	fmt.eprintfln("early_push_crash: %d landings past the relay's durable length, %d relay crashes before the commit, %d replica bytes matched the relay", ahead, crashes, checked)
}
