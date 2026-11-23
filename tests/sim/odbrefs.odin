package sim

import "core:strings"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/journal"
import "../../src/odb"

STAT_OWN_REFS: Stat
STAT_BLOB_CRASHES: Stat
STAT_REOPEN_FAILS: Stat
STAT_TMP_SYNC_FAILS: Stat
STAT_REG_CRASHES: Stat

@(init)
_odbrefs_init :: proc "contextless" () {
	register_restarted(25, check_own_refs)
	register_world(25, _odbrefs_world)
	register_collect(25, _odbrefs_collect)
	register_restarted(27, _content_check)
	register_stat_line(62, "own_refs")
	STAT_OWN_REFS = register_stat(62, 0, "checked")
	STAT_BLOB_CRASHES = register_stat(62, 1, "crashes_after_blob_sync")
	STAT_REOPEN_FAILS = register_stat(62, 5, "reopens_failed_after_pack")
	STAT_TMP_SYNC_FAILS = register_stat(62, 3, "failed_temp_syncs")
	STAT_REG_CRASHES = register_stat(62, 4, "crashes_after_pack_commit")
}

check_own_refs :: proc(w: ^World, n: ^Node) {
	if !n.alive || n.disk.dead || !n.e_open || !n.e.db_open {
		return
	}
	context = instance_context(&n.inst)
	n.disk.probe += 1
	defer n.disk.probe -= 1
	db := &n.e.db
	for ob in w.model.objs {
		if ob.kind != .Tree {
			continue
		}
		h, held := n.e.handles[ob.o.id]
		if !held || h.hist == nil {
			continue
		}
		hist := h.hist
		r: journal.Reader
		journal.journal_reader(&hist.journal, &r, context.temp_allocator)
		end := journal.journal_durable_len(&hist.journal)
		refs := make([dynamic]fs.Content_Ref, context.temp_allocator)
		pos := i64(0)
		for pos < end {
			body, next, jerr := journal.record_at(&r, pos)
			if jerr == .Redacted {
				pos = next
				continue
			}
			if jerr != .None {
				break
			}
			if !journal.is_sig(body) {
				clear(&refs)
				fs.history_record_oids(hist, n.e.self, body, &refs)
				for ref in refs {
					stat_add(w, STAT_OWN_REFS)
					if !ref.opaque && !odb.exists(db, ref.oid) {
						hb: [odb.MAX_HEX]u8
						world_fail(w, "odb: %s tree %s durable own op at %d names object %s, which the device odb does not hold", n.name, id_short(ob.o.id), pos, odb.oid_to_string(ref.oid, .Sha1, &hb))
					}
				}
			}
			pos = next
		}
		journal.reader_close(&r)
	}
}

disk_blob_sync_crash :: proc(d: ^Disk, path: string) -> bool {
	if d.blob_crash == 0 || !strings.contains(path, "/objects/objects/") {
		return false
	}
	d.blob_crash_n += 1
	if d.blob_crash_n % d.blob_crash != 0 {
		return false
	}
	d.blob_crash = 0
	if d.blob_ckpt {
		d.blob_ckpt = false
		d.blob_ckpt_crashes += 1
	}
	return true
}

@(private = "file")
_odbrefs_world :: proc(w: ^World) {
	for n in w.nodes {
		if rng_chance(&w.rng, 1, 4) {
			k := u64(1 + rng_int(&w.rng, 4))
			if w.cfg.crash_rate > 0 {
				n.disk.blob_crash = k
				n.disk.reopen_fail = w.cfg.io_rate > 0
				if w.cfg.io_rate > 0 {
					n.disk.tmp_fail = 1
				}
				n.disk.reg_crash = 6 * k
			}
		}
	}
}

@(private = "file")
_odbrefs_collect :: proc(w: ^World, res: ^Run_Result) {
	for n in w.nodes {
		res.stats.extra[int(STAT_BLOB_CRASHES)] += n.disk.blob_crashes
		res.stats.extra[int(STAT_REOPEN_FAILS)] += n.disk.reopen_fails
		res.stats.extra[int(STAT_TMP_SYNC_FAILS)] += n.disk.tmp_fails
		res.stats.extra[int(STAT_REG_CRASHES)] += n.disk.reg_crashes
	}
}

@(private = "file")
_content_check :: proc(w: ^World, n: ^Node) {
	if !n.alive || !n.e_open || n.disk.dead {
		return
	}
	context = instance_context(&n.inst)
	n.disk.probe += 1
	ids := eng.content_behind(&n.e)
	n.disk.probe -= 1
	for id in ids {
		world_fail(w, "content: %s own File_Tree %s has durable records past its upload target after restart", n.name, id_short(id))
	}
}
