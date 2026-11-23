package sim

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:testing"
import "../../src/pack"
import "../../src/prim"

@(private = "file")
SHRINK_PACK :: "/data/pack"

@(private = "file")
_shrink_fill :: proc(seed: u8, n: int) -> []u8 {
	b := make([]u8, n, context.temp_allocator)
	for i in 0 ..< n {
		b[i] = u8((i * 13 + int(seed) * 7 + i / 97) & 0xff)
	}
	return b
}

@(private = "file")
_shrink_open :: proc(d: ^Disk, pk: ^pack.Pack, a: runtime.Allocator) -> bool {
	base := disk_vfs(d)
	if prim.mkdir_all(base, SHRINK_PACK, 0o700) != .None {
		return false
	}
	opts := pack.DEFAULT_OPTIONS
	opts.promote_size = 4096
	return pack.open(pk, base, SHRINK_PACK, opts, a) == .None
}

@(private = "file")
_shrink_case :: proc(flags: prim.Open_Flags) -> string {
	d: Disk
	disk_init(&d, "shrink", runtime.heap_allocator())
	d.ghost_root = SHRINK_PACK
	defer disk_destroy(&d)
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return "setup: arena"
	}
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	pk: pack.Pack
	if !_shrink_open(&d, &pk, a) {
		return "setup: the pack did not open"
	}
	v := pack.vfs(&pk)
	if prim.mkdir_all(v, SHRINK_PACK + "/s", 0o700) != .None {
		return "setup: mkdir"
	}
	fd, oerr := prim.open_file(v, SHRINK_PACK + "/s/f", flags + {.Write, .Create}, 0o600)
	if oerr != .None {
		return fmt.tprintf("setup: open %v", oerr)
	}
	old := _shrink_fill(1, 12288)
	tail := _shrink_fill(2, 1000)
	if prim.write_at(v, fd, old, 0) != .None || prim.datasync(v, fd) != .None {
		return "setup: the first write did not sync"
	}
	if prim.truncate(v, fd, 6000) != .None || prim.datasync(v, fd) != .None {
		return "setup: the shrink did not sync"
	}
	if prim.write_at(v, fd, tail, 6000) != .None || prim.datasync(v, fd) != .None {
		return "setup: the append did not sync"
	}
	d.force_ghost = true
	rng: Rng
	rng_init(&rng, 1, 1)
	disk_crash(&d, .Power, &rng)
	d.force_ghost = false
	pk2: pack.Pack
	if !_shrink_open(&d, &pk2, a) {
		return "recovery: the pack did not reopen"
	}
	defer pack.close(&pk2)
	v2 := pack.vfs(&pk2)
	fd2, rerr := prim.open_file(v2, SHRINK_PACK + "/s/f", flags + {.Write}, 0o600)
	if rerr != .None {
		return fmt.tprintf("recovery: open %v", rerr)
	}
	defer prim.close_file(v2, fd2)
	size, serr := prim.file_size(v2, fd2)
	if serr != .None || size != 6000 + 1000 {
		return fmt.tprintf("a synced shrink came back: the file is %d bytes after the crash, not %d (%v)", size, 6000 + 1000, serr)
	}
	got := make([]u8, int(size), context.temp_allocator)
	n, gerr := prim.read_at(v2, fd2, got, 0)
	if gerr != .None || n != int(size) || string(got[:6000]) != string(old[:6000]) || string(got[6000:]) != string(tail) {
		return "the file's bytes after the crash are not its last synced content"
	}
	return ""
}

@(test)
promoted_shrink_crash :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	if msg := _shrink_case({.Group_Visible}); len(msg) > 0 {
		testing.expectf(t, false, "promoted file opened sized: %s", msg)
	}
	free_all(context.temp_allocator)
}
