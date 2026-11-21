package thread

import "base:runtime"
import "../journal"
import "../prim"

@(private)
CHILD_SYNC_BYTES :: 1024 * 1024
@(private)
BUF_KEEP :: 64 * 1024
@(private)
META_MAX :: 4096

Writer :: struct {
	j:         journal.Journal,
	jr:        journal.Reader,
	rd:        Reader,
	kids:      Children,
	lock:      prim.Fd,
	thread:    prim.Id,
	links:     Links,
	leaf:      i64,
	fork_head: i64,
	buf:       Block_Buf,
	updates:   [dynamic]Child_Update,
	allocator: runtime.Allocator,
}

@(private)
Block_Buf :: struct {
	active: bool,
	start:  bool,
	msg:    i64,
	index:  u32,
	kind:   Block_Kind,
	flags:  Block_Flags,
	id_len: int,
	meta:   [dynamic]u8,
	data:   [dynamic]u8,
}

@(private)
Child_Update :: struct {
	msg:   i64,
	child: i64,
	seal:  i64,
}

Msg_Spec :: struct {
	role:             Role,
	parent:           i64,
	cmd:              prim.Id,
	hlc:              prim.Hlc,
	version:          []u8,
	git_branch:       string,
	git_commit:       []u8,
	provider_session: string,
	provider_msg:     string,
}

Head_Spec :: struct {
	thread:   prim.Id,
	created:  prim.Hlc,
	worktree: prim.Id,
	provider: string,
	model:    string,
	title:    string,
}

writer_create :: proc(w: ^Writer, path: string, head: Head_Spec, allocator := context.allocator) -> Error {
	_writer_zero(w, allocator)
	lock, lerr := prim.lock_file(path)
	if lerr != .None {
		return _perr(lerr)
	}
	w.lock = lock
	if err := _jerr(journal.journal_open(&w.j, path, allocator)); err != .None {
		_writer_release(w)
		return err
	}
	_writer_attach(w)
	if journal.journal_len(&w.j) != 0 {
		_writer_release(w)
		return .Exists
	}
	h := Head{
		version  = FORMAT_VERSION,
		thread   = head.thread,
		created  = head.created,
		worktree = head.worktree,
		provider = head.provider,
		model    = head.model,
		title    = head.title,
	}
	l: Links
	if _, err := _append(w, &l, h); err != .None {
		_writer_release(w)
		return err
	}
	if err := _jerr(journal.journal_commit(&w.j)); err != .None {
		_writer_release(w)
		return err
	}
	w.thread = head.thread
	kp, perr := _kids_path(path, context.temp_allocator)
	if perr != .None {
		_writer_release(w)
		return perr
	}
	if err := children_create(&w.kids, kp, w.thread, allocator); err != .None {
		_writer_release(w)
		return err
	}
	w.kids.covered = journal.journal_durable_len(&w.j)
	if err := children_sync(&w.kids); err != .None {
		_writer_release(w)
		return err
	}
	return .None
}

writer_open :: proc(w: ^Writer, path: string, allocator := context.allocator) -> Error {
	_writer_zero(w, allocator)
	if !prim.exists(path) {
		return .Not_Found
	}
	lock, lerr := prim.lock_file(path)
	if lerr != .None {
		return _perr(lerr)
	}
	w.lock = lock
	if err := _jerr(journal.journal_open(&w.j, path, allocator)); err != .None {
		_writer_release(w)
		return err
	}
	_writer_attach(w)
	if err := _writer_recover(w, path); err != .None {
		_writer_release(w)
		return err
	}
	return .None
}

writer_close :: proc(w: ^Writer) -> Error {
	err := writer_commit(w)
	if w.kids.fd >= 0 {
		if e := children_sync(&w.kids); e != .None && err == .None {
			err = e
		}
	}
	if w.j.fd >= 0 {
		if e := _jerr(journal.journal_close(&w.j)); e != .None && err == .None {
			err = e
		}
	}
	_writer_release(w)
	return err
}

writer_commit :: proc(w: ^Writer) -> Error {
	_flush(w) or_return
	_jerr(journal.journal_commit(&w.j)) or_return
	if len(w.updates) == 0 {
		w.kids.covered = journal.journal_durable_len(&w.j)
		return .None
	}
	applied := 0
	err: Error
	for u in w.updates {
		if err = children_put(&w.kids, u.msg, u.child, u.seal); err != .None {
			if err == .Corrupt {
				err = _kids_rebuild(w)
				if err == .None {
					applied = len(w.updates)
				}
			}
			break
		}
		applied += 1
	}
	remove_range(&w.updates, 0, applied)
	if err != .None {
		return err
	}
	w.kids.covered = journal.journal_durable_len(&w.j)
	if w.kids.covered - w.kids.synced >= CHILD_SYNC_BYTES {
		return children_sync(&w.kids)
	}
	return .None
}

writer_flush :: proc(w: ^Writer) -> Error {
	return _flush(w)
}

writer_len :: proc "contextless" (w: ^Writer) -> i64 {
	return journal.journal_len(&w.j) + (i64(len(w.buf.data)) if w.buf.active else 0)
}

writer_durable_len :: proc "contextless" (w: ^Writer) -> i64 {
	return journal.journal_durable_len(&w.j)
}

writer_leaf :: proc "contextless" (w: ^Writer) -> i64 {
	return w.leaf
}

writer_links :: proc "contextless" (w: ^Writer) -> Links {
	return w.links
}

writer_reader :: proc(w: ^Writer) -> ^Reader {
	return &w.rd
}

writer_tail :: proc(w: ^Writer) -> (t: Tail, err: Error) {
	_flush(w) or_return
	reader_reset(&w.rd)
	return read_tail(&w.rd)
}

writer_message :: proc(w: ^Writer, spec: Msg_Spec) -> (msg: i64, err: Error) {
	return _message(w, spec, 0, 0)
}

writer_block :: proc(w: ^Writer, msg: i64, kind: Block_Kind, data: []u8 = nil, id := "", name := "", failed := false) -> (index: u32, err: Error) {
	i := _running(w, msg) or_return
	if u8(kind) < 1 || kind > max(Block_Kind) {
		return 0, .Invalid
	}
	if len(id) + len(name) > META_MAX || ((kind == .Tool_Result || kind == .Image) && len(data) > INLINE_MAX) {
		return 0, .Too_Large
	}
	if w.links.open[i].blocks == max(u32) {
		return 0, .Limit
	}
	_flush(w) or_return
	i = links_find(&w.links, msg)
	b := &w.buf
	clear(&b.meta)
	clear(&b.data)
	if _, e := append(&b.meta, id); e != nil {
		return 0, .No_Memory
	}
	if _, e := append(&b.meta, name); e != nil {
		return 0, .No_Memory
	}
	if _, e := append(&b.data, ..data); e != nil {
		return 0, .No_Memory
	}
	index = w.links.open[i].blocks
	w.links.open[i].blocks += 1
	b.active = true
	b.start = true
	b.msg = msg
	b.index = index
	b.kind = kind
	b.flags = {.Failed} if failed else {}
	b.id_len = len(id)
	if len(b.data) >= CHUNK_MAX {
		_flush_full(w, false) or_return
	}
	return index, .None
}

writer_chunk :: proc(w: ^Writer, msg: i64, index: u32, data: []u8) -> Error {
	i := _running(w, msg) or_return
	o := w.links.open[i]
	if index + 1 != o.blocks {
		return .Invalid
	}
	if len(data) == 0 {
		return .None
	}
	b := &w.buf
	if !(b.active && b.msg == msg && b.index == index) {
		_flush(w) or_return
		if o.last == 0 {
			return .Invalid
		}
		body, _ := _get(&w.rd, o.last) or_return
		rec := decode(body, o.last, w.rd.scratch) or_return
		blk, ok := rec.body.(Block)
		if !ok || blk.msg != msg || blk.index != index {
			return .Invalid
		}
		if .Start in blk.flags && (.Ref in blk.flags || blk.kind == .Tool_Result || blk.kind == .Image) {
			return .Invalid
		}
		clear(&b.meta)
		clear(&b.data)
		b.active = true
		b.start = false
		b.msg = msg
		b.index = index
		b.flags = {}
		b.id_len = 0
	}
	if _, e := append(&b.data, ..data); e != nil {
		return .No_Memory
	}
	if len(b.data) >= CHUNK_MAX {
		return _flush_full(w, false)
	}
	return .None
}

writer_block_ref :: proc(w: ^Writer, msg: i64, kind: Block_Kind, ref: Ref, id := "", name := "", failed := false) -> (index: u32, err: Error) {
	i := _running(w, msg) or_return
	if u8(kind) < 1 || kind > max(Block_Kind) || (len(ref.oid) != 20 && len(ref.oid) != 32) {
		return 0, .Invalid
	}
	if len(id) + len(name) > META_MAX || len(ref.preview) > INLINE_MAX {
		return 0, .Too_Large
	}
	if w.links.open[i].blocks == max(u32) {
		return 0, .Limit
	}
	_flush(w) or_return
	i = links_find(&w.links, msg)
	l := w.links
	o := &l.open[i]
	off := journal.journal_len(&w.j)
	flags := Block_Flags{.Start, .Ref}
	if failed {
		flags += {.Failed}
	}
	blk := Block{
		msg   = msg,
		prev  = o.last,
		index = o.blocks,
		flags = flags,
		kind  = kind,
		id    = id,
		name  = name,
		ref   = ref,
	}
	index = o.blocks
	o.blocks += 1
	o.last = off
	_append(w, &l, blk) or_return
	w.links = l
	return index, .None
}

writer_seal :: proc(w: ^Writer, msg: i64, status: Seal_Status, usage: Usage = {}, provider_msg := "", cmd: prim.Id = {}) -> (off: i64, err: Error) {
	if status == .Open || status > max(Seal_Status) {
		return 0, .Invalid
	}
	_running(w, msg) or_return
	_flush(w) or_return
	i := links_find(&w.links, msg)
	l := w.links
	last := l.open[i].last
	off = journal.journal_len(&w.j)
	_links_remove(&l, i)
	if msg == w.leaf {
		l.leaf_seal = off
	}
	s := Seal{
		msg          = msg,
		last_block   = last,
		status       = status,
		usage        = usage,
		provider_msg = provider_msg,
		cmd          = cmd,
	}
	_append(w, &l, s) or_return
	w.links = l
	_update(w, {msg = msg, seal = off}) or_return
	return off, .None
}

writer_set_leaf :: proc(w: ^Writer, msg: i64, cmd: prim.Id = {}) -> (off: i64, err: Error) {
	_flush(w) or_return
	if msg <= 0 || msg >= journal.journal_len(&w.j) {
		return 0, .Invalid
	}
	if _, e := _node(&w.rd, msg); e != .None {
		return 0, .Invalid if e == .Corrupt else e
	}
	seal := _seal_of(w, msg) or_return
	l := w.links
	off = journal.journal_len(&w.j)
	l.leaf_event = off
	l.leaf_seal = seal
	f := Leaf{
		msg             = msg,
		prev_leaf_event = w.links.leaf_event,
		fork_head       = w.fork_head,
		cmd             = cmd,
	}
	_append(w, &l, f) or_return
	w.links = l
	w.leaf = msg
	return off, .None
}

writer_switch :: proc(w: ^Writer, sibling: i64, cmd: prim.Id = {}) -> (leaf: i64, off: i64, err: Error) {
	_flush(w) or_return
	if sibling <= 0 || sibling >= journal.journal_len(&w.j) {
		return 0, 0, .Invalid
	}
	if _, e := _node(&w.rd, sibling); e != .None {
		return 0, 0, .Invalid if e == .Corrupt else e
	}
	t := Tail{
		length    = journal.journal_len(&w.j),
		links     = w.links,
		leaf      = w.leaf,
		fork_head = w.fork_head,
	}
	reader_reset(&w.rd)
	leaf = switch_target(&w.rd, &t, sibling) or_return
	off = writer_set_leaf(w, leaf, cmd) or_return
	return leaf, off, .None
}

writer_queue :: proc(w: ^Writer, cmd: prim.Id, mode: Queue_Mode, text: string, attachments: []Attachment = nil) -> (item: i64, err: Error) {
	_check_queue(mode, attachments) or_return
	_flush(w) or_return
	list := _current_pending(w) or_return
	if len(list) >= MAX_PENDING {
		return 0, .Limit
	}
	off := journal.journal_len(&w.j)
	next := make([]Pending_Entry, len(list) + 1, context.temp_allocator)
	copy(next, list)
	next[len(list)] = {off, off}
	q := Queue{
		cmd          = cmd,
		item         = off,
		mode         = mode,
		text         = text,
		attachments  = attachments,
		prev_pending = w.links.pending,
		list         = next,
	}
	l := w.links
	l.pending = off
	_append(w, &l, q) or_return
	w.links = l
	return off, .None
}

writer_edit_queued :: proc(w: ^Writer, item: i64, cmd: prim.Id, mode: Queue_Mode, text: string, attachments: []Attachment = nil) -> (off: i64, err: Error) {
	_check_queue(mode, attachments) or_return
	_flush(w) or_return
	list := _current_pending(w) or_return
	k := _pending_index(list, item)
	if k < 0 {
		return 0, .Not_Found
	}
	off = journal.journal_len(&w.j)
	next := make([]Pending_Entry, len(list), context.temp_allocator)
	copy(next, list)
	next[k].latest = off
	q := Queue{
		cmd          = cmd,
		item         = item,
		mode         = mode,
		text         = text,
		attachments  = attachments,
		prev_pending = w.links.pending,
		list         = next,
	}
	l := w.links
	l.pending = off
	_append(w, &l, q) or_return
	w.links = l
	return off, .None
}

writer_unqueue :: proc(w: ^Writer, item: i64, outcome: Outcome, msg: i64 = 0, cmd: prim.Id = {}) -> (off: i64, err: Error) {
	if u8(outcome) < 1 || outcome > max(Outcome) {
		return 0, .Invalid
	}
	_flush(w) or_return
	if msg < 0 || msg >= journal.journal_len(&w.j) {
		return 0, .Invalid
	}
	list := _current_pending(w) or_return
	k := _pending_index(list, item)
	if k < 0 {
		return 0, .Not_Found
	}
	off = journal.journal_len(&w.j)
	next := make([]Pending_Entry, len(list) - 1, context.temp_allocator)
	copy(next, list[:k])
	copy(next[k:], list[k + 1:])
	u := Unqueue{
		cmd          = cmd,
		item         = item,
		outcome      = outcome,
		msg          = msg,
		prev_pending = w.links.pending,
		list         = next,
	}
	l := w.links
	l.pending = off
	_append(w, &l, u) or_return
	w.links = l
	return off, .None
}

writer_pending :: proc(w: ^Writer, allocator := context.allocator) -> (items: []Queue_Item, err: Error) {
	_flush(w) or_return
	reader_reset(&w.rd)
	t := Tail{
		length = journal.journal_len(&w.j),
		links  = w.links,
	}
	return pending_items(&w.rd, &t, allocator)
}

writer_scope :: proc(w: ^Writer, msg: i64, kind: Scope_Kind, id: prim.Id, actor: prim.Id, before, after: []u8, cmd: prim.Id = {}) -> (off: i64, err: Error) {
	if u8(kind) < 1 || kind > max(Scope_Kind) {
		return 0, .Invalid
	}
	_flush(w) or_return
	if msg <= 0 || msg >= journal.journal_len(&w.j) {
		return 0, .Invalid
	}
	s := Scope{
		msg    = msg,
		kind   = kind,
		id     = id,
		actor  = actor,
		before = before,
		after  = after,
		cmd    = cmd,
	}
	l := w.links
	return _append(w, &l, s)
}

writer_interrupt_open :: proc(w: ^Writer, now_ms: i64, cmd: prim.Id = {}) -> (count: int, err: Error) {
	_flush(w) or_return
	for {
		i := -1
		for k in 0 ..< w.links.open_len {
			if w.links.open[k].state == .Running {
				i = k
				break
			}
		}
		if i < 0 {
			return count, .None
		}
		o := w.links.open[i]
		body, _ := _get(&w.rd, o.msg) or_return
		m := _decode_msg(body, o.msg) or_return
		age := now_ms - prim.hlc_ms(m.hlc)
		revive := o.attempt < MAX_REVIVALS && age <= REVIVE_WINDOW_MS
		l := w.links
		off := journal.journal_len(&w.j)
		if revive {
			l.open[i].state = .Revive
		} else {
			_links_remove(&l, i)
		}
		if o.msg == w.leaf {
			l.leaf_seal = off
		}
		rec := Interrupted{
			msg        = o.msg,
			last_block = o.last,
			attempt    = o.attempt,
			revive     = revive,
			cmd        = cmd,
		}
		_append(w, &l, rec) or_return
		w.links = l
		_update(w, {msg = o.msg, seal = off}) or_return
		count += 1
	}
}

writer_revivable :: proc "contextless" (w: ^Writer) -> (out: [MAX_OPEN]Open, n: int) {
	for o in links_open(&w.links) {
		if o.state == .Revive {
			out[n] = o
			n += 1
		}
	}
	return
}

writer_revive :: proc(w: ^Writer, msg: i64, spec: Msg_Spec) -> (reply: i64, err: Error) {
	i := links_find(&w.links, msg)
	if i < 0 || w.links.open[i].state != .Revive {
		return 0, .Invalid
	}
	attempt := w.links.open[i].attempt
	if attempt >= 63 {
		return 0, .Limit
	}
	_flush(w) or_return
	s := spec
	s.parent = msg
	if s.role == Role(0) {
		s.role = .Assistant
	}
	_check_spec(&s) or_return
	l := w.links
	rv := Revived{
		msg     = msg,
		attempt = attempt + 1,
		cmd     = spec.cmd,
	}
	_append(w, &l, rv) or_return
	return _message(w, s, msg, attempt + 1)
}

writer_decline :: proc(w: ^Writer, msg: i64, cmd: prim.Id = {}) -> (off: i64, err: Error) {
	i := links_find(&w.links, msg)
	if i < 0 || w.links.open[i].state != .Revive {
		return 0, .Invalid
	}
	_flush(w) or_return
	i = links_find(&w.links, msg)
	l := w.links
	_links_remove(&l, i)
	rv := Revived{
		msg = msg,
		cmd = cmd,
	}
	off = _append(w, &l, rv) or_return
	w.links = l
	return off, .None
}

@(private)
_writer_zero :: proc(w: ^Writer, allocator: runtime.Allocator) {
	w^ = {
		lock      = prim.INVALID_FD,
		allocator = allocator,
	}
	w.j.fd = prim.INVALID_FD
	w.kids.fd = prim.INVALID_FD
}

@(private)
_writer_attach :: proc(w: ^Writer) {
	journal.journal_reader(&w.j, &w.jr, w.allocator)
	reader_init(&w.rd, &w.jr, w.allocator)
	w.rd.w = w
	w.buf.meta = make([dynamic]u8, w.allocator)
	w.buf.data = make([dynamic]u8, w.allocator)
	w.updates = make([dynamic]Child_Update, w.allocator)
}

@(private)
_writer_release :: proc(w: ^Writer) {
	if w.j.fd >= 0 {
		journal.journal_abort(&w.j)
		journal.journal_close(&w.j)
	}
	if w.jr.win != nil || w.jr.out != nil {
		journal.reader_close(&w.jr)
	}
	children_close(&w.kids)
	reader_destroy(&w.rd)
	delete(w.buf.meta)
	delete(w.buf.data)
	delete(w.updates)
	if w.lock >= 0 {
		prim.close(w.lock)
	}
	_writer_zero(w, w.allocator)
}

@(private)
_kids_path :: proc(path: string, allocator: runtime.Allocator) -> (string, Error) {
	out, err := make([]u8, len(path) + len(".children"), allocator)
	if err != nil {
		return "", .No_Memory
	}
	n := copy(out, path)
	copy(out[n:], ".children")
	return string(out), .None
}

@(private)
_writer_recover :: proc(w: ^Writer, path: string) -> Error {
	end := journal.journal_len(&w.j)
	if end == 0 {
		return .Not_Found
	}
	head := read_head(&w.rd, context.temp_allocator) or_return
	w.thread = head.thread
	body, off, jerr := journal.record_before(&w.jr, end)
	if jerr != .None {
		return _jerr(jerr)
	}
	_, links := decode_links_only(body, off) or_return
	w.links = links
	if links.leaf_event != 0 {
		lb, _ := _get(&w.rd, links.leaf_event) or_return
		rec := decode(lb, links.leaf_event, w.rd.scratch) or_return
		#partial switch v in rec.body {
		case Msg:
			w.leaf = links.leaf_event
			w.fork_head = v.fork_head
		case Leaf:
			w.leaf = v.msg
			w.fork_head = v.fork_head
		case:
			return .Corrupt
		}
	}
	kp := _kids_path(path, context.temp_allocator) or_return
	if children_open(&w.kids, kp, w.thread, w.allocator) == .None && w.kids.covered <= end {
		if _kids_catch_up(w, w.kids.covered) == .None {
			return .None
		}
	}
	children_close(&w.kids)
	children_create(&w.kids, kp, w.thread, w.allocator) or_return
	return _kids_catch_up(w, 0)
}

@(private)
_kids_rebuild :: proc(w: ^Writer) -> Error {
	buf: prim.Path_Buf
	if len(w.kids.path) >= len(buf) {
		return .Invalid
	}
	n := copy(buf[:], w.kids.path)
	kp := string(buf[:n])
	children_close(&w.kids)
	children_create(&w.kids, kp, w.thread, w.allocator) or_return
	return _kids_catch_up(w, 0)
}

@(private)
_kids_catch_up :: proc(w: ^Writer, from: i64) -> Error {
	end := journal.journal_durable_len(&w.j)
	pos := from
	for pos < end {
		body, next, jerr := journal.record_at(&w.jr, pos)
		if jerr != .None {
			return .Corrupt
		}
		rd := prim.reader(body)
		kind := Kind(prim.read_u8(&rd))
		l: Links
		decode_links(&rd, pos, &l)
		msg, child, seal: i64
		#partial switch kind {
		case .Msg:
			m := decode_msg(&rd, pos)
			msg, child = m.parent, pos
		case .Seal:
			s := decode_seal(&rd, pos)
			msg, seal = s.msg, pos
		case .Interrupted:
			s := decode_interrupted(&rd, pos)
			msg, seal = s.msg, pos
		case .Head:
			if pos != 0 {
				return .Corrupt
			}
		}
		if rd.err != .None {
			return .Corrupt
		}
		if child != 0 || seal != 0 {
			children_put(&w.kids, msg, child, seal) or_return
		}
		pos = next
	}
	w.kids.covered = end
	return children_sync(&w.kids)
}

@(private)
_writer_newest_child :: proc(w: ^Writer, p: i64) -> (child: i64, err: Error) {
	#reverse for u in w.updates {
		if u.msg == p && u.child != 0 {
			return u.child, .None
		}
	}
	child, _, err = children_get(&w.kids, p)
	if err == .Corrupt {
		_kids_rebuild(w) or_return
		child, _, err = children_get(&w.kids, p)
	}
	return child, err
}

@(private)
_seal_of :: proc(w: ^Writer, m: i64) -> (seal: i64, err: Error) {
	if i := links_find(&w.links, m); i >= 0 && w.links.open[i].state == .Running {
		return 0, .None
	}
	#reverse for u in w.updates {
		if u.msg == m && u.seal != 0 {
			return u.seal, .None
		}
	}
	_, seal, err = children_get(&w.kids, m)
	if err == .Corrupt {
		_kids_rebuild(w) or_return
		_, seal, err = children_get(&w.kids, m)
	}
	return seal, err
}

@(private)
_update :: proc(w: ^Writer, u: Child_Update) -> Error {
	if _, e := append(&w.updates, u); e != nil {
		return .No_Memory
	}
	if len(w.updates) >= MAX_UPDATES {
		return writer_commit(w)
	}
	return .None
}

@(private)
_running :: proc(w: ^Writer, msg: i64) -> (index: int, err: Error) {
	i := links_find(&w.links, msg)
	if i < 0 || w.links.open[i].state != .Running {
		return -1, .Invalid
	}
	return i, .None
}

@(private)
_check_spec :: proc(s: ^Msg_Spec) -> Error {
	if u8(s.role) < 1 || s.role > max(Role) {
		return .Invalid
	}
	if len(s.git_commit) != 0 && len(s.git_commit) != 20 && len(s.git_commit) != 32 {
		return .Invalid
	}
	return .None
}

@(private)
_check_queue :: proc(mode: Queue_Mode, attachments: []Attachment) -> Error {
	if u8(mode) < 1 || mode > max(Queue_Mode) {
		return .Invalid
	}
	for a in attachments {
		if len(a.oid) != 0 && len(a.oid) != 20 && len(a.oid) != 32 {
			return .Invalid
		}
	}
	return .None
}

@(private)
_current_pending :: proc(w: ^Writer) -> (list: []Pending_Entry, err: Error) {
	if w.links.pending == 0 {
		return nil, .None
	}
	return _pending_list(&w.rd, w.links.pending)
}

@(private)
_pending_index :: proc(list: []Pending_Entry, item: i64) -> int {
	for e, i in list {
		if e.item == item {
			return i
		}
	}
	return -1
}

@(private)
_message :: proc(w: ^Writer, spec: Msg_Spec, retire: i64, attempt: u8) -> (msg: i64, err: Error) {
	s := spec
	_check_spec(&s) or_return
	_flush(w) or_return
	end := journal.journal_len(&w.j)
	p := w.leaf if s.parent == LEAF else s.parent
	if p < 0 || p >= end {
		return 0, .Invalid
	}
	depth, jump, jump_depth: i64 = 1, 0, 0
	if p != 0 {
		np, e := _node(&w.rd, p)
		if e != .None {
			return 0, .Invalid if e == .Corrupt else e
		}
		depth = np.depth + 1
		jump, jump_depth = p, np.depth
		if np.jump != 0 {
			nj := _node(&w.rd, np.jump) or_return
			if np.depth - np.jump_depth == np.jump_depth - nj.jump_depth {
				jump, jump_depth = nj.jump, nj.jump_depth
			}
		}
	}
	prev := _writer_newest_child(w, p) or_return
	pseal: i64
	if p != 0 {
		pseal = _seal_of(w, p) or_return
	}
	off := journal.journal_len(&w.j)
	fork := off if prev != 0 else w.fork_head
	l := w.links
	if retire != 0 {
		if k := links_find(&l, retire); k >= 0 {
			_links_remove(&l, k)
		}
	}
	if l.open_len >= MAX_OPEN {
		return 0, .Limit
	}
	l.open[l.open_len] = Open{
		msg     = off,
		state   = .Running,
		attempt = attempt,
	}
	l.open_len += 1
	l.leaf_event = off
	l.leaf_seal = 0
	m := Msg{
		role             = s.role,
		parent           = p,
		depth            = depth,
		jump             = jump,
		jump_depth       = jump_depth,
		prev_sibling     = prev,
		fork_head        = fork,
		prev_leaf_event  = w.links.leaf_event,
		parent_seal      = pseal,
		cmd              = s.cmd,
		hlc              = s.hlc,
		version          = s.version,
		git_branch       = s.git_branch,
		git_commit       = s.git_commit,
		provider_session = s.provider_session,
		provider_msg     = s.provider_msg,
	}
	_append(w, &l, m) or_return
	w.links = l
	w.leaf = off
	w.fork_head = fork
	_update(w, {msg = p, child = off}) or_return
	return off, .None
}

@(private)
_flush :: proc(w: ^Writer) -> Error {
	if !w.buf.active {
		return .None
	}
	return _flush_full(w, true)
}

@(private)
_flush_full :: proc(w: ^Writer, all: bool) -> Error {
	b := &w.buf
	for b.active && (len(b.data) >= CHUNK_MAX || all) {
		i := links_find(&w.links, b.msg)
		if i < 0 {
			b.active = false
			return .Invalid
		}
		n := min(len(b.data), CHUNK_MAX)
		l := w.links
		o := &l.open[i]
		off := journal.journal_len(&w.j)
		blk := Block{
			msg   = b.msg,
			prev  = o.last,
			index = b.index,
			data  = b.data[:n],
		}
		if b.start {
			blk.flags = b.flags + {.Start}
			blk.kind = b.kind
			blk.id = string(b.meta[:b.id_len])
			blk.name = string(b.meta[b.id_len:])
		}
		o.last = off
		_append(w, &l, blk) or_return
		w.links = l
		b.start = false
		remove_range(&b.data, 0, n)
		if len(b.data) == 0 {
			b.active = false
		}
	}
	if !b.active {
		if cap(b.data) > BUF_KEEP {
			delete(b.data)
			b.data = make([dynamic]u8, w.allocator)
		}
		clear(&b.meta)
	}
	return .None
}

@(private)
_append :: proc(w: ^Writer, l: ^Links, body: Body) -> (off: i64, err: Error) {
	off = journal.journal_len(&w.j)
	pw, jerr := journal.journal_begin(&w.j)
	if jerr != .None {
		return 0, _jerr(jerr)
	}
	switch v in body {
	case Head:
		h := v
		encode_head(&pw, &h)
	case Msg:
		m := v
		encode_msg(&pw, off, l, &m)
	case Block:
		b := v
		encode_block(&pw, off, l, &b)
	case Seal:
		s := v
		encode_seal(&pw, off, l, &s)
	case Leaf:
		f := v
		encode_leaf(&pw, off, l, &f)
	case Queue:
		q := v
		encode_queue(&pw, off, l, &q)
	case Unqueue:
		u := v
		encode_unqueue(&pw, off, l, &u)
	case Scope:
		s := v
		encode_scope(&pw, off, l, &s)
	case Interrupted:
		s := v
		encode_interrupted(&pw, off, l, &s)
	case Revived:
		s := v
		encode_revived(&pw, off, l, &s)
	case:
		journal.journal_abort(&w.j)
		return 0, .Invalid
	}
	got, eerr := journal.journal_end(&w.j, &pw)
	if eerr != .None {
		return 0, _jerr(eerr)
	}
	if got != off {
		return 0, .Io
	}
	return off, .None
}
