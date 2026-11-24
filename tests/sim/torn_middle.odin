package sim

import "base:runtime"
import "core:fmt"
import "core:testing"
import "../../src/journal"
import "../../src/prim"

@(private = "file")
TORN_DIR :: "/torn"

@(private = "file")
TORN_PATH :: "/torn/j.journal"

@(private = "file")
_torn_body :: proc(tag: u8, n: int) -> []u8 {
	b := make([]u8, n, context.temp_allocator)
	for i in 0 ..< n {
		b[i] = tag + u8(i % 7)
	}
	return b
}

@(private = "file")
_torn_case :: proc(seed: u64) -> (shaped: bool, msg: string) {
	d: Disk
	disk_init(&d, "torn", runtime.heap_allocator())
	defer disk_destroy(&d)
	v := disk_vfs(&d)
	if prim.mkdir_all(v, TORN_DIR, 0o755) != .None {
		return false, "setup: mkdir"
	}
	j: journal.Journal
	if err := journal.journal_open(&j, v, TORN_PATH, {}, context.temp_allocator); err != .None {
		return false, fmt.tprintf("setup: open %v", err)
	}
	journal.journal_append(&j, _torn_body(1, 700))
	if err := journal.journal_commit(&j); err != .None {
		journal.journal_close(&j)
		return false, fmt.tprintf("setup: commit %v", err)
	}
	end1 := journal.journal_durable_len(&j)
	off2, _ := journal.journal_append(&j, _torn_body(2, 1500))
	off3, _ := journal.journal_append(&j, _torn_body(3, 700))
	d.crash_at = d.stats.ops + 2
	journal.journal_commit(&j)
	journal.journal_close(&j)
	r: Rng
	rng_init(&r, seed, 31)
	disk_crash(&d, .Power, &r)
	rd: journal.Reader
	if journal.reader_open(&rd, v, TORN_PATH, context.temp_allocator) != .None {
		return false, ""
	}
	_, _, e2 := journal.record_at(&rd, off2)
	_, _, e3 := journal.record_at(&rd, off3)
	journal.reader_close(&rd)
	if e2 == .None || e3 != .None {
		return false, ""
	}
	j2: journal.Journal
	if err := journal.journal_open(&j2, v, TORN_PATH, {}, context.temp_allocator); err != .None {
		return true, fmt.tprintf("a crash that kept record 3 and lost part of record 2, neither synced, made the reopen answer %v instead of cutting back to the synced end %d", err, end1)
	}
	got := journal.journal_durable_len(&j2)
	journal.journal_close(&j2)
	if got != end1 {
		return true, fmt.tprintf("after a torn middle in unsynced records the reopen kept %d bytes; the synced end is %d", got, end1)
	}
	return true, ""
}

@(test)
torn_middle :: proc(t: ^testing.T) {
	test_begin(t)
	defer test_end(t)
	shaped := 0
	for seed in 1 ..= 256 {
		ok, msg := _torn_case(u64(seed))
		if !ok && msg != "" {
			testing.expectf(t, false, "seed %d: %s", seed, msg)
			return
		}
		if ok {
			shaped += 1
			if msg != "" {
				testing.expectf(t, false, "seed %d: %s", seed, msg)
				return
			}
		}
	}
	testing.expectf(t, shaped > 0, "no crash produced a torn middle in 256 tries")
}
