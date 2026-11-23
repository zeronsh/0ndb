package sim

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:testing"
import "../../src/pack"
import "../../src/prim"

@(private = "file")
STALE_PACK :: "/data/pack"

@(private = "file")
STALE_FILE :: STALE_PACK + "/s/f"

@(private = "file")
STALE_SIZE :: 8192

@(private = "file")
HOLE_AT :: 3000

@(private = "file")
HOLE_LEN :: 2000

@(private = "file")
_stale_fill :: proc(seed: u8, n: int) -> []u8 {
	b := make([]u8, n, context.temp_allocator)
	x := u32(seed) * 2654435761 + 1
	for i in 0 ..< n {
		x ~= x << 13
		x ~= x >> 17
		x ~= x << 5
		b[i] = u8(x)
	}
	return b
}

@(private = "file")
_stale_open :: proc(d: ^Disk, pk: ^pack.Pack, a: runtime.Allocator) -> bool {
	base := disk_vfs(d)
	if prim.mkdir_all(base, STALE_PACK, 0o700) != .None {
		return false
	}
	opts := pack.DEFAULT_OPTIONS
	opts.container_size = 16 << 10
	opts.roll_min = 4096
	return pack.open(pk, base, STALE_PACK, opts, a) == .None
}

@(private = "file")
_stale_settle :: proc(pk: ^pack.Pack) -> bool {
	for _ in 0 ..< 64 {
		more, err := pack.compact_all(pk)
		if err != .None {
			return false
		}
		if !more {
			break
		}
	}
	return pack.sync(pk) == .None
}

@(private = "file")
_stale_punch :: proc(pk: ^pack.Pack) -> bool {
	v := pack.vfs(pk)
	fd, err := prim.open_file(v, STALE_FILE, {.Write}, 0o600)
	if err != .None {
		return false
	}
	defer prim.close_file(v, fd)
	return prim.punch_hole(v, fd, HOLE_AT, HOLE_LEN) == .None && prim.datasync(v, fd) == .None
}

@(private = "file")
_stale_case :: proc(k: u64) -> (msg: string, crashed: bool, moved: u64) {
	d: Disk
	disk_init(&d, "stale", runtime.heap_allocator())
	defer disk_destroy(&d)
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return "setup: arena", false, 0
	}
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	old := _stale_fill(11, STALE_SIZE)
	mid := _stale_fill(23, 4096)
	pk: pack.Pack
	if !_stale_open(&d, &pk, a) {
		return "setup: the pack did not open", false, 0
	}
	v := pack.vfs(&pk)
	if prim.mkdir_all(v, STALE_PACK + "/s", 0o700) != .None {
		return "setup: mkdir", false, 0
	}
	fd, oerr := prim.open_file(v, STALE_FILE, {.Write, .Create}, 0o600)
	if oerr != .None {
		return fmt.tprintf("setup: open %v", oerr), false, 0
	}
	if prim.write_at(v, fd, old, 0) != .None || prim.datasync(v, fd) != .None {
		return "setup: the first write did not sync", false, 0
	}
	if prim.write_at(v, fd, mid, 2048) != .None || prim.datasync(v, fd) != .None {
		return "setup: the overwrite did not sync", false, 0
	}
	filler := _stale_fill(37, 64 << 10)
	gfd, gerr := prim.open_file(v, STALE_PACK + "/s/g", {.Write, .Create}, 0o600)
	if gerr != .None || prim.write_at(v, gfd, filler, 0) != .None || prim.datasync(v, gfd) != .None {
		return "setup: the filler did not sync", false, 0
	}
	prim.close_file(v, gfd)
	prim.close_file(v, fd)
	if pack.sync(&pk) != .None {
		return "setup: sync", false, 0
	}
	d.crash_at = d.stats.ops + k
	ok := _stale_punch(&pk) && pack.sync(&pk) == .None && _stale_settle(&pk)
	if !d.dead && ok {
		d.crash_at = 0
		moved = pack.stats(&pk).compact_moved
		pack.close(&pk)
	} else {
		crashed = true
		rng: Rng
		rng_init(&rng, 1, k)
		disk_crash(&d, .Power, &rng)
	}
	pk2: pack.Pack
	if !_stale_open(&d, &pk2, a) {
		return "recovery: the pack did not reopen", crashed, moved
	}
	defer pack.close(&pk2)
	if !_stale_punch(&pk2) || pack.sync(&pk2) != .None {
		return "recovery: the punch did not complete", crashed, moved
	}
	if m := _stale_survivor(&d, old, mid); len(m) > 0 {
		return fmt.tprintf("before compaction: %s", m), crashed, moved
	}
	if !_stale_settle(&pk2) {
		return "recovery: compaction did not complete", crashed, moved
	}
	if m := _stale_survivor(&d, old, mid); len(m) > 0 {
		return fmt.tprintf("after compaction: %s", m), crashed, moved
	}
	v2 := pack.vfs(&pk2)
	fd2, rerr := prim.open_file(v2, STALE_FILE, {}, 0)
	if rerr != .None {
		return fmt.tprintf("recovery: open %v", rerr), crashed, moved
	}
	defer prim.close_file(v2, fd2)
	want := make([]u8, STALE_SIZE, context.temp_allocator)
	copy(want, old)
	copy(want[2048:], mid)
	for i in HOLE_AT ..< HOLE_AT + HOLE_LEN {
		want[i] = 0
	}
	got := make([]u8, STALE_SIZE, context.temp_allocator)
	n, gerr2 := prim.read_at(v2, fd2, got, 0)
	if gerr2 != .None || n != STALE_SIZE || string(got) != string(want) {
		return "the file's bytes after the punch are not its content with the hole zeroed", crashed, moved
	}
	return "", crashed, moved
}

@(private = "file")
_stale_survivor :: proc(d: ^Disk, old, mid: []u8) -> string {
	for src in ([][]u8{old, mid}) {
		base := HOLE_AT if len(src) == STALE_SIZE else HOLE_AT - 2048
		for at := base; at + 32 <= base + HOLE_LEN; at += 256 {
			if p, found := disk_contains(d, src[at:at + 32]); found {
				return fmt.tprintf("a punched copy survives in %s (bytes %d..%d of the %s write)", p, at, at + 32, "first" if len(src) == STALE_SIZE else "overwriting")
			}
		}
	}
	return ""
}

@(test)
pack_stale_crash :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	points := 0
	for k in u64(1) ..< 4000 {
		msg, crashed, moved := _stale_case(k)
		if len(msg) > 0 {
			testing.expectf(t, false, "crash at disk op %d of a punch and its compaction: %s", k, msg)
			break
		}
		free_all(context.temp_allocator)
		if !crashed {
			testing.expectf(t, moved > 0, "the punch's compaction relocated nothing, so the check proves nothing")
			break
		}
		points += 1
	}
	testing.expectf(t, points > 0, "no crash point was swept, so the check proves nothing")
}
