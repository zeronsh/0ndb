package sim

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import "../../src/obj"
import "../../src/odb"
import "../../src/prim"

@(private = "file")
LOST_REPO :: "/lost/repo.git"

@(private = "file")
LOST_SLOTS :: "/lost/slots"

@(private = "file")
_lost_fill :: proc(seed: u64, n: int) -> []u8 {
	b := make([]u8, n, context.temp_allocator)
	x := seed * 0x9e37_79b9_7f4a_7c15 + 1
	for i in 0 ..< n {
		x ~= x << 13
		x ~= x >> 7
		x ~= x << 17
		b[i] = u8(x)
	}
	return b
}

@(private = "file")
_lost_file :: proc(v: prim.Vfs, path: string, data: []u8) -> bool {
	fd, err := prim.open_file(v, path, {.Write, .Create, .Exclusive}, 0o644)
	if err != .None {
		return false
	}
	defer prim.close_file(v, fd)
	return prim.write_at(v, fd, data, 0) == .None && prim.datasync(v, fd) == .None
}

@(private = "file")
_lost_pack_case :: proc() -> string {
	d: Disk
	disk_init(&d, "lost-pack", runtime.heap_allocator())
	defer disk_destroy(&d)
	d.lose_shrinks = true
	v := disk_vfs(&d)
	if prim.mkdir_all(v, "/lost/files", 0o755) != .None {
		return "setup: mkdir"
	}
	big := _lost_fill(1, 3 * 65536 + 777)
	small := _lost_fill(2, 300)
	tail := _lost_fill(3, 100)
	if !_lost_file(v, "/lost/files/big", big) || !_lost_file(v, "/lost/files/small", small) {
		return "setup: the source files did not write"
	}
	oids: [3]odb.Oid
	{
		db: odb.Odb
		if err := odb.open_store(&db, v, LOST_REPO); err != .None {
			return fmt.tprintf("setup: open_store %v", err)
		}
		defer odb.close(&db)
		b: odb.Pack_Builder
		if err := odb.pack_begin(&b, &db); err != .None {
			return fmt.tprintf("setup: pack_begin %v", err)
		}
		err: odb.Error
		oids[0], err = odb.pack_add(&b, .Blob, big)
		if err == .None {
			_, err = odb.pack_add_file(&b, "/lost/files/big")
		}
		if err == .None {
			oids[1], err = odb.pack_add(&b, .Blob, small)
		}
		if err == .None {
			_, err = odb.pack_add_file(&b, "/lost/files/small")
		}
		if err == .None {
			oids[2], err = odb.pack_add(&b, .Blob, tail)
		}
		if err != .None {
			odb.pack_abort(&b)
			return fmt.tprintf("setup: pack_add %v", err)
		}
		if _, ferr := odb.pack_finish(&b); ferr != .None {
			return fmt.tprintf("setup: pack_finish %v", ferr)
		}
		if berr := odb.barrier(&db); berr != .None {
			return fmt.tprintf("setup: barrier %v", berr)
		}
	}
	rng: Rng
	rng_init(&rng, 1, 1)
	disk_crash(&d, .Power, &rng)
	db: odb.Odb
	if err := odb.open_store(&db, v, LOST_REPO); err != .None {
		return fmt.tprintf("recovery: open_store %v", err)
	}
	defer odb.close(&db)
	want := [3][]u8{big, small, tail}
	for oid, i in oids {
		kind, data, err := odb.read(&db, oid, context.temp_allocator)
		if err != .None || kind != .Blob || string(data) != string(want[i]) {
			return fmt.tprintf("a pack installed and synced before the power cut lost object %d: %v", i, err)
		}
	}
	return ""
}

@(private = "file")
_lost_slots_case :: proc() -> string {
	d: Disk
	disk_init(&d, "lost-slots", runtime.heap_allocator())
	defer disk_destroy(&d)
	d.lose_shrinks = true
	v := disk_vfs(&d)
	if prim.mkdir_all(v, LOST_SLOTS, 0o755) != .None {
		return "setup: mkdir"
	}
	owner: prim.Id
	owner[0] = 7
	kids :: LOST_SLOTS + "/kids"
	keys := 200
	{
		c: obj.Slots
		if err := obj.slots_create(&c, v, LOST_SLOTS + "/other", owner, context.temp_allocator); err != .None {
			return fmt.tprintf("setup: slots_create %v", err)
		}
		for k in 1 ..= keys {
			if err := obj.slots_put(&c, u64(k), i64(k) * 10, 0); err != .None {
				obj.slots_close(&c)
				return fmt.tprintf("setup: slots_put %v", err)
			}
		}
		serr := obj.slots_sync(&c)
		obj.slots_close(&c)
		if serr != .None {
			return fmt.tprintf("setup: slots_sync %v", serr)
		}
	}
	if prim.rename(v, LOST_SLOTS + "/other", kids + ".new") != .None || prim.sync_dir(v, LOST_SLOTS) != .None {
		return "setup: leaving a stale .new"
	}
	rng: Rng
	rng_init(&rng, 1, 1)
	disk_crash(&d, .Power, &rng)
	{
		c: obj.Slots
		if err := obj.slots_create(&c, v, kids, owner, context.temp_allocator); err != .None {
			return fmt.tprintf("slots_create over a stale .new: %v", err)
		}
		serr := obj.slots_sync(&c)
		obj.slots_close(&c)
		if serr != .None {
			return fmt.tprintf("slots_sync: %v", serr)
		}
	}
	disk_crash(&d, .Power, &rng)
	c: obj.Slots
	if err := obj.slots_open(&c, v, kids, owner, context.temp_allocator); err != .None {
		return fmt.tprintf("recovery: slots_open %v", err)
	}
	defer obj.slots_close(&c)
	for k in 1 ..= keys {
		child, _, err := obj.slots_get(&c, u64(k))
		if err != .None || child != 0 {
			return fmt.tprintf("a fresh slots file holds key %d with child %d from the stale .new (%v)", k, child, err)
		}
	}
	return ""
}

@(test)
lost_shrink_crash :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	if msg := _lost_pack_case(); len(msg) > 0 {
		testing.expectf(t, false, "odb pack rewind: %s", msg)
	}
	if msg := _lost_slots_case(); len(msg) > 0 {
		testing.expectf(t, false, "obj slots: %s", msg)
	}
	free_all(context.temp_allocator)
}
