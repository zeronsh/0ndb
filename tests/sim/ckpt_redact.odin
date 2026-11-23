package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"

@(private = "file")
CKPT_SECRET :: "<ckpt-secret-7f3a>"

@(private = "file")
Ckpt_Race :: struct {
	stage:    eng.Checkpoint_Stage,
	text:     eng.Object,
	at:       int,
	armed:    bool,
	fired:    bool,
	err:      eng.Error,
}

@(private = "file")
ckpt_race: Ckpt_Race

@(private = "file")
_ckpt_filler :: proc(tag: string, n: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	i := 0
	for strings.builder_len(b) < n {
		fmt.sbprintf(&b, "%s line %d of filler text\n", tag, i)
		i += 1
	}
	return strings.to_string(b)
}

@(private = "file")
_ckpt_type :: proc(w: ^World, a: ^Node, tag: string, n: int) {
	for i in 0 ..< n {
		{
			context = instance_context(&a.inst)
			defer node_after(a)
			data, rerr := eng.text_read(&a.e, ckpt_race.text, context.temp_allocator)
			if rerr != .None {
				world_fail(w, "ckpt: text_read while typing: %v", rerr)
				return
			}
			line := fmt.tprintf("%s typed line %d of the checkpointed text\n", tag, i)
			if ierr := eng.text_edit(&a.e, ckpt_race.text, len(data), 0, line); ierr != .None {
				world_fail(w, "ckpt: text_edit: %v", ierr)
				return
			}
		}
		if i % 100 == 99 {
			run_until(w, w.now + 500_000_000, true)
		}
	}
}

@(private = "file")
_ckpt_window :: proc(n: ^Node, e: ^eng.Engine, object: eng.Object, stage: eng.Checkpoint_Stage) {
	r := &ckpt_race
	if !r.armed || r.fired || object.id != r.text.id || stage != r.stage {
		return
	}
	r.fired = true
	r.err = eng.text_redact(e, r.text, r.at, len(CKPT_SECRET))
}

ckpt_redact_run :: proc(seed: u64, stage: eng.Checkpoint_Stage) -> (failures: [dynamic]string) {
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
	_ckpt_redact(w, stage)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_ckpt_redact :: proc(w: ^World, stage: eng.Checkpoint_Stage) {
	ckpt_race = {stage = stage}
	if !relay_start(&w.relay) {
		world_fail(w, "relay start")
		return
	}
	a := w.nodes[0]
	if !node_start(a) {
		world_fail(w, "node start")
		return
	}
	a.ckpt_window = _ckpt_window
	defer a.ckpt_window = nil
	defer ckpt_race = {}
	head := _ckpt_filler("before", 4 * 1024)
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		space, err := eng.space_create(&a.e, "ckpt")
		if err != .None {
			world_fail(w, "ckpt: space_create: %v", err)
			return
		}
		if oerr := eng.space_open(&a.e, space); oerr != .None {
			world_fail(w, "ckpt: space_open: %v", oerr)
			return
		}
		if rerr := eng.space_set_relay(&a.e, space, "relay", w.relay.public); rerr != .None {
			world_fail(w, "ckpt: space_set_relay: %v", rerr)
			return
		}
		initial := strings.concatenate({head, CKPT_SECRET, "\n"}, context.temp_allocator)
		ckpt_race.at = len(head)
		ckpt_race.text, err = eng.text_create(&a.e, space, "notes", initial)
		if err != .None {
			world_fail(w, "ckpt: text_create: %v", err)
			return
		}
		if data, rerr := eng.text_read(&a.e, ckpt_race.text, context.temp_allocator); rerr != .None || len(data) != len(initial) {
			world_fail(w, "ckpt: text_read after create: %v (%d of %d bytes)", rerr, len(data), len(initial))
			return
		}
	}
	_ckpt_type(w, a, "first", 3200)
	for _ in 0 ..< 60 {
		if len(w.checkpoints) > 0 {
			break
		}
		run_until(w, w.now + 2_000_000_000, true)
	}
	if len(w.checkpoints) == 0 {
		world_fail(w, "ckpt: no checkpoint of the text was ever published")
		return
	}
	run_until(w, w.now + 20_000_000_000, true)
	if _, found := relay_checkpoint_contains(w, transmute([]u8)string(CKPT_SECRET)); !found {
		world_fail(w, "ckpt: the relay scan cannot open the published checkpoint, so it would miss a stale one")
		return
	}
	published := len(w.checkpoints)
	ckpt_race.armed = true
	_ckpt_type(w, a, "second", 3200)
	for _ in 0 ..< 60 {
		if ckpt_race.fired && len(w.checkpoints) > published {
			break
		}
		run_until(w, w.now + 2_000_000_000, true)
	}
	run_until(w, w.now + 30_000_000_000, true)
	if !ckpt_race.fired {
		world_fail(w, "ckpt: no checkpoint write reached the %v stage after the second write", stage)
		return
	}
	if ckpt_race.err != .None {
		world_fail(w, "ckpt: the redaction inside the checkpoint write failed: %v", ckpt_race.err)
	}
	needle := transmute([]u8)string(CKPT_SECRET)
	if p, found := disk_contains(&a.disk, needle); found {
		world_fail(w, "ckpt: a redaction at the %v stage left the text on disk in %s", stage, p)
	}
	if p, found := relay_checkpoint_contains(w, needle); found {
		world_fail(w, "ckpt: a redaction at the %v stage left the text in %s", stage, p)
	}
	context = instance_context(&a.inst)
	defer node_after(a)
	if data, rerr := eng.text_read(&a.e, ckpt_race.text, context.temp_allocator); rerr != .None || strings.contains(string(data), CKPT_SECRET) {
		world_fail(w, "ckpt: the text still reads the secret after the redaction (%v)", rerr)
	}
}

@(test)
ckpt_redact :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for stage in ([]eng.Checkpoint_Stage{.Bundled, .Installed}) {
		failures := ckpt_redact_run(1, stage)
		for f in failures {
			fmt.eprintf("ckpt_redact %v: %s\n", stage, f)
			delete(f)
		}
		testing.expectf(t, len(failures) == 0, "ckpt_redact %v failed", stage)
		delete(failures)
	}
}
