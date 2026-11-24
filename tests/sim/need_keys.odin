package sim

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import "../../src/convo"
import "../../src/journal"
import "../../src/obj"
import "../../src/prim"
import osync "../../src/sync"

@(private = "file")
NEED_KEYS_TEXT :: "sealed before its key arrived"

@(private = "file")
_need_keys_case :: proc() -> string {
	d: Disk
	disk_init(&d, "need-keys", runtime.heap_allocator())
	defer disk_destroy(&d)
	v := disk_vfs(&d)
	if prim.mkdir_all(v, "/nk", 0o755) != .None {
		return "setup: mkdir"
	}
	object: prim.Id
	object[0] = 1
	object[6] = 0x80
	writer: prim.Id
	writer[0] = 5
	writer[6] = 0x80
	wv: obj.View
	obj.view_init(&wv, object)
	defer obj.view_destroy(&wv)
	w: convo.Writer
	clock := obj.Clock{wall_ms = proc(data: rawptr) -> i64 {return 1_790_000_000_000}}
	if err := convo.writer_create(&w, &wv, v, "/nk/seg", object, writer, 1, prim.Hlc(1 << 20), {}, {}, context.allocator, clock); err != .None {
		return fmt.tprintf("setup: writer_create %v", err)
	}
	msg, merr := convo.writer_message(&w, convo.Msg_Spec{role = .User, author = writer})
	if merr != .None {
		return fmt.tprintf("setup: writer_message %v", merr)
	}
	if _, berr := convo.writer_block(&w, msg, .Text, transmute([]u8)string(NEED_KEYS_TEXT)); berr != .None {
		return fmt.tprintf("setup: writer_block %v", berr)
	}
	if _, serr := convo.writer_seal(&w, msg, .Done); serr != .None {
		return fmt.tprintf("setup: writer_seal %v", serr)
	}
	if cerr := convo.writer_commit(&w); cerr != .None {
		return fmt.tprintf("setup: writer_commit %v", cerr)
	}
	n := obj.writer_durable(&w.core)
	convo.writer_close(&w)
	plain, rerr := prim.read_file(v, "/nk/seg", context.temp_allocator)
	if rerr != .None || i64(len(plain)) < n {
		return fmt.tprintf("setup: read the plain segment: %v (%d of %d bytes)", rerr, len(plain), n)
	}
	root: [32]u8
	root[0] = 7
	tree: osync.Key_Tree
	if err := osync.keytree_init(&tree, root); err != .None {
		return fmt.tprintf("setup: keytree_init %v", err)
	}
	sealed := make([]u8, int(n), context.temp_allocator)
	copy(sealed, plain[:n])
	if err := osync.keytree_seal_range(&tree, sealed, 0); err != .None {
		return fmt.tprintf("setup: seal %v", err)
	}
	osync.keytree_destroy(&tree)
	tree = {}
	fd, oerr := prim.open_file(v, "/nk/replica", {.Write, .Create}, 0o644)
	if oerr != .None {
		return fmt.tprintf("setup: open the replica: %v", oerr)
	}
	if err := prim.write_at(v, fd, sealed, 0); err != .None {
		return fmt.tprintf("setup: write the replica: %v", err)
	}
	defer prim.close_file(v, fd)
	jr: journal.Reader
	journal.reader_init(&jr, v, fd, n)
	defer journal.reader_close(&jr)
	journal.reader_set_keys(&jr, osync.keytree_provider(&tree))
	rv: obj.View
	obj.view_init(&rv, object)
	defer obj.view_destroy(&rv)
	if _, err := obj.view_add(&rv, writer, &jr); err != .None {
		return fmt.tprintf("view_add: %v", err)
	}
	if t, terr := convo.view_tail(&rv, {}, context.temp_allocator); terr == .None {
		if m, e := convo.message(&rv, &t, convo.Position{msg = msg}, context.temp_allocator); e == .None {
			return fmt.tprintf("before its key arrived the message reads as %q (redacted %v), want Missing", msg_text(m), m.redacted)
		} else if e != .Missing {
			return fmt.tprintf("before its key arrived the message answers %v, want Missing", e)
		}
	} else if terr != .Missing {
		return fmt.tprintf("before its key arrived the tail answers %v, want Missing", terr)
	}
	if err := osync.keytree_init(&tree, root); err != .None {
		return fmt.tprintf("keytree_init %v", err)
	}
	defer osync.keytree_destroy(&tree)
	obj.view_reset(&rv)
	if _, err := obj.view_add(&rv, writer, &jr); err != .None {
		return fmt.tprintf("view_add after the key: %v", err)
	}
	t, terr := convo.view_tail(&rv, {}, context.temp_allocator)
	if terr != .None {
		return fmt.tprintf("after its key arrived the tail answers %v", terr)
	}
	m, e := convo.message(&rv, &t, convo.Position{msg = msg}, context.temp_allocator)
	if e != .None || msg_text(m) != NEED_KEYS_TEXT {
		return fmt.tprintf("after its key arrived the message reads %q (%v)", msg_text(m), e)
	}
	return ""
}

@(test)
need_keys :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	if why := _need_keys_case(); why != "" {
		fmt.eprintf("need_keys: %s\n", why)
		testing.fail(t)
	}
}
