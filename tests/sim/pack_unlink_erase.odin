package sim

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import "../../src/pack"
import "../../src/prim"

@(private = "file")
UE_PACK :: "/data/pack"

@(private = "file")
UE_FILE :: UE_PACK + "/s/big"

@(private = "file")
UE_SIZE :: 300 << 10

@(private = "file")
_ue_bytes :: proc() -> []u8 {
	b := make([]u8, UE_SIZE, context.temp_allocator)
	x := u32(77)
	for i in 0 ..< UE_SIZE {
		x ~= x << 13
		x ~= x >> 17
		x ~= x << 5
		b[i] = u8(x)
	}
	return b
}

@(private = "file")
_ue_open :: proc(d: ^Disk, pk: ^pack.Pack) -> bool {
	v := disk_vfs(d)
	if prim.mkdir_all(v, UE_PACK, 0o700) != .None {
		return false
	}
	return pack.open(pk, v, UE_PACK, pack.DEFAULT_OPTIONS, runtime.heap_allocator()) == .None
}

@(private = "file")
_ue_left :: proc(d: ^Disk, b: []u8) -> string {
	for at := 0; at + 32 <= len(b); at += 4096 {
		if p, found := disk_contains(d, b[at:at + 32]); found {
			return fmt.tprintf("bytes %d..%d of the deleted file survive in %s", at, at + 32, p)
		}
	}
	return ""
}

@(private = "file")
_ue_exists :: proc(pk: ^pack.Pack) -> bool {
	v := pack.vfs(pk)
	fd, err := prim.open_file(v, UE_FILE, {}, 0)
	if err != .None {
		return false
	}
	prim.close_file(v, fd)
	return true
}

@(private = "file")
_ue_case :: proc(k: u64) -> (msg: string, crashed: bool) {
	d: Disk
	disk_init(&d, "unlink-erase", runtime.heap_allocator())
	defer disk_destroy(&d)
	b := _ue_bytes()
	pk: pack.Pack
	if !_ue_open(&d, &pk) {
		return "setup: open", false
	}
	v := pack.vfs(&pk)
	if prim.mkdir_all(v, UE_PACK + "/s", 0o700) != .None {
		return "setup: mkdir", false
	}
	fd, err := prim.open_file(v, UE_FILE, {.Write, .Create}, 0o600)
	if err != .None || prim.write_at(v, fd, b, 0) != .None || prim.datasync(v, fd) != .None {
		return "setup: write", false
	}
	prim.close_file(v, fd)
	if pack.sync(&pk) != .None || len(_ue_left(&d, b)) == 0 {
		return "setup: the file's bytes are not on disk, so the check proves nothing", false
	}
	d.crash_at = d.stats.ops + k
	ok := prim.remove(v, UE_FILE) == .None && pack.sync(&pk) == .None
	if ok && !d.dead {
		d.crash_at = 0
		if m := _ue_left(&d, b); len(m) > 0 {
			return fmt.tprintf("after the delete's sync: %s", m), false
		}
		pack.close(&pk)
	} else {
		crashed = true
		pack.close(&pk)
		rng: Rng
		rng_init(&rng, 2, k)
		disk_crash(&d, .Power, &rng)
		d.crash_at = 0
	}
	pk2: pack.Pack
	if !_ue_open(&d, &pk2) {
		return "recovery: the pack did not reopen", crashed
	}
	defer pack.close(&pk2)
	if _ue_exists(&pk2) {
		if prim.remove(pack.vfs(&pk2), UE_FILE) != .None || pack.sync(&pk2) != .None {
			return "recovery: deleting again failed", crashed
		}
	}
	if m := _ue_left(&d, b); len(m) > 0 {
		return fmt.tprintf("after reopening: %s", m), crashed
	}
	return "", crashed
}

@(test)
pack_unlink_erase :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	points := 0
	for k in u64(1) ..< 400 {
		msg, crashed := _ue_case(k)
		free_all(context.temp_allocator)
		if len(msg) > 0 {
			testing.expectf(t, false, "crash at disk op %d of a delete: %s", k, msg)
			return
		}
		if !crashed {
			break
		}
		points += 1
	}
	testing.expectf(t, points > 3, "only %d crash points were swept", points)
}
