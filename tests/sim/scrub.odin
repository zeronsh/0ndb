package sim

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import "../../src/odb"

@(private = "file")
SCRUB_REPO :: "/scrub/repo.git"

@(private = "file")
_scrub_case :: proc() -> string {
	d: Disk
	disk_init(&d, "scrub", runtime.heap_allocator())
	defer disk_destroy(&d)
	v := disk_vfs(&d)
	secret := transmute([]u8)string("a token that was redacted\n")
	kept := transmute([]u8)string("a file that stays\n")
	s_oid, k_oid: odb.Oid
	hb: [odb.MAX_HEX]u8
	{
		db: odb.Odb
		if err := odb.open_store(&db, v, SCRUB_REPO); err != .None {
			return fmt.tprintf("setup: open_store %v", err)
		}
		defer odb.close(&db)
		err: odb.Error
		s_oid, err = odb.write(&db, .Blob, secret)
		if err == .None {
			k_oid, err = odb.write(&db, .Blob, kept)
		}
		tree: odb.Oid
		if err == .None {
			entries := [2]odb.Tree_Entry{{name = "a.txt", oid = s_oid, mode = 0o100644}, {name = "b.txt", oid = k_oid, mode = 0o100644}}
			tree, err = odb.write_tree(&db, entries[:])
		}
		commit: odb.Oid
		if err == .None {
			sig := odb.Signature{name = "sim", email = "sim@0ndb.invalid", time = 1}
			body, cerr := odb.commit_encode(odb.Commit{tree = tree, author = sig, committer = sig, message = "c\n"}, .Sha1, context.temp_allocator)
			err = cerr
			if err == .None {
				commit, err = odb.write(&db, .Commit, body)
			}
		}
		if err == .None {
			err = odb.update_ref(&db, "refs/0ndb/scrub", commit)
		}
		if err == .None {
			err = odb.barrier(&db)
		}
		if err != .None {
			return fmt.tprintf("setup: %v", err)
		}
		hex := odb.oid_to_string(s_oid, .Sha1, &hb)
		d.fail_unlink = fmt.tprintf("%s/%s", hex[:2], hex[2:])
		_, st, rerr := odb.redact(&db, {s_oid}, "refs/0ndb/", nil, true, context.temp_allocator)
		d.fail_unlink = ""
		if rerr == .None && odb.exists(&db, s_oid) {
			return "odb.redact reported success while the redacted blob is still in the store"
		}
		if rerr == .None {
			return "setup: the removal fault never fired"
		}
		if len(st.unreached) != 1 || st.unreached[0].oid != s_oid || st.unreached[0].reason != .Left {
			return fmt.tprintf("a failed removal is not reported as left: %v", st.unreached)
		}
	}
	rng: Rng
	rng_init(&rng, 1, 1)
	disk_crash(&d, .Power, &rng)
	db: odb.Odb
	if err := odb.open_store(&db, v, SCRUB_REPO); err != .None {
		return fmt.tprintf("recovery: open_store %v", err)
	}
	defer odb.close(&db)
	if !odb.scrub_pending(&db) {
		return "a redaction whose removal failed left no durable scrub intent"
	}
	if _, err := odb.scrub_resume(&db, context.temp_allocator); err != .None {
		return fmt.tprintf("recovery: scrub_resume %v", err)
	}
	if odb.exists(&db, s_oid) {
		return "the redacted blob is still in the store after the scrub resumed"
	}
	if odb.scrub_pending(&db) {
		return "the scrub intent outlived a verified scrub"
	}
	_, data, kerr := odb.read(&db, k_oid, context.temp_allocator)
	if kerr != .None || string(data) != string(kept) {
		return fmt.tprintf("the scrub lost an object that was not redacted (%v)", kerr)
	}
	pushed := transmute([]u8)string("a token the user also committed\n")
	p_oid, perr := odb.write(&db, .Blob, pushed)
	tree: odb.Oid
	if perr == .None {
		entries := [1]odb.Tree_Entry{{name = "c.txt", oid = p_oid, mode = 0o100644}}
		tree, perr = odb.write_tree(&db, entries[:])
	}
	commit: odb.Oid
	if perr == .None {
		sig := odb.Signature{name = "sim", email = "sim@0ndb.invalid", time = 2}
		body, cerr := odb.commit_encode(odb.Commit{tree = tree, author = sig, committer = sig, message = "u\n"}, .Sha1, context.temp_allocator)
		perr = cerr
		if perr == .None {
			commit, perr = odb.write(&db, .Commit, body)
		}
	}
	if perr == .None {
		perr = odb.update_ref(&db, "refs/0ndb/pushed", commit)
	}
	if perr == .None {
		perr = odb.update_ref(&db, "refs/heads/main", commit)
	}
	if perr != .None {
		return fmt.tprintf("setup: the user's branch: %v", perr)
	}
	_, pst, prerr := odb.redact(&db, {p_oid}, "refs/0ndb/", nil, true, context.temp_allocator)
	if prerr != .None {
		return fmt.tprintf("redacting a blob the user's branch reaches: %v", prerr)
	}
	if len(pst.unreached) != 1 || pst.unreached[0].reason != .Protected || pst.unreached[0].ref != "refs/heads/main" || pst.unreached[0].commit != commit {
		return fmt.tprintf("a blob the user's branch reaches is not reported with its ref and commit: %v", pst.unreached)
	}
	if !odb.exists(&db, p_oid) {
		return "redaction rewrote the user's own branch"
	}
	return ""
}

@(test)
scrub_failed_removal :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	if msg := _scrub_case(); len(msg) > 0 {
		testing.expectf(t, false, "odb scrub: %s", msg)
	}
	free_all(context.temp_allocator)
}
