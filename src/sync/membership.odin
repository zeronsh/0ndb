package osync

import "base:runtime"
import "core:crypto"
import "../prim"

MEMBERSHIP_SECRETS_VERSION :: 1
@(private)
TREE_CACHE :: 4

Membership :: struct {
	space:       Space_Id,
	raws:        [dynamic][]u8,
	records:     [dynamic]Member_Record,
	ids:         map[Record_Id]int,
	roster:      Roster,
	resolved:    bool,
	stale:       bool,
	keys:        [dynamic]Epoch_Keys,
	naming:      [32]u8,
	have_naming: bool,
	opened:      int,
	cache:       [TREE_CACHE]Tree_Slot,
	tick:        u64,
	allocator:   runtime.Allocator,
}

@(private)
Tree_Slot :: struct {
	epoch: Record_Id,
	tree:  Ratchet_Tree,
	used:  u64,
	ok:    bool,
}

Opener :: struct {
	keyring: ^Keyring,
	self:    Identity,
}

membership_init :: proc(m: ^Membership, space: Space_Id, allocator := context.allocator) {
	m^ = {
		space     = space,
		allocator = allocator,
	}
	m.raws = make([dynamic][]u8, allocator)
	m.records = make([dynamic]Member_Record, allocator)
	m.ids = make(map[Record_Id]int, allocator)
	m.keys = make([dynamic]Epoch_Keys, allocator)
}

membership_destroy :: proc(m: ^Membership) {
	if m.resolved {
		roster_destroy(&m.roster)
	}
	for &r in m.records {
		member_record_free(&r, m.allocator)
	}
	for raw in m.raws {
		delete(raw, m.allocator)
	}
	for &k in m.keys {
		epoch_keys_clear(&k)
	}
	for &s in m.cache {
		if s.ok {
			tree_destroy(&s.tree)
		}
	}
	delete(m.raws)
	delete(m.records)
	delete(m.ids)
	delete(m.keys)
	crypto.zero_explicit(&m.naming, size_of(m.naming))
	m^ = {}
}

membership_ingest :: proc(m: ^Membership, raw: []u8) -> (fresh: bool, err: Error) {
	id := record_hash(raw)
	if id in m.ids {
		return false, .None
	}
	own := make([]u8, len(raw), m.allocator)
	copy(own, raw)
	rec: Member_Record
	if derr := member_decode(own, &rec, true, m.allocator); derr != .None {
		delete(own, m.allocator)
		return false, derr
	}
	if rec.op != .Genesis && rec.space != m.space {
		member_record_free(&rec, m.allocator)
		delete(own, m.allocator)
		return false, .Invalid
	}
	if rec.op == .Genesis && space_id_of(rec.id) != m.space {
		member_record_free(&rec, m.allocator)
		delete(own, m.allocator)
		return false, .Invalid
	}
	append(&m.raws, own)
	m.ids[rec.id] = len(m.records)
	append(&m.records, rec)
	m.stale = true
	return true, .None
}

membership_resolve :: proc(m: ^Membership) -> Error {
	if m.resolved {
		roster_destroy(&m.roster)
		m.resolved = false
	}
	m.stale = false
	err := roster_resolve(&m.roster, m.space, m.records[:], m.allocator)
	if err != .None {
		roster_destroy(&m.roster)
		return err
	}
	m.resolved = true
	return .None
}

membership_keys :: proc "contextless" (m: ^Membership, id: Record_Id) -> ^Epoch_Keys {
	for &k in m.keys {
		if k.id == id {
			return &k
		}
	}
	return nil
}

membership_keys_number :: proc "contextless" (m: ^Membership, number: u32) -> ^Epoch_Keys {
	var: ^Epoch_Keys
	for &k in m.keys {
		if k.number == number {
			if var == nil || string(k.id[:]) > string(var.id[:]) {
				var = &k
			}
		}
	}
	return var
}

@(private)
_tree_for :: proc(m: ^Membership, epoch: int) -> (tree: ^Ratchet_Tree, err: Error) {
	id := m.roster.epochs[epoch].id
	m.tick += 1
	for &s in m.cache {
		if s.ok && s.epoch == id {
			s.used = m.tick
			return &s.tree, .None
		}
	}
	slot := &m.cache[0]
	for &s in m.cache {
		if !s.ok {
			slot = &s
			break
		}
		if s.used < slot.used {
			slot = &s
		}
	}
	if slot.ok {
		tree_destroy(&slot.tree)
		slot.ok = false
	}
	zero: Record_Id
	base := m.roster.epochs[epoch].base
	if base != zero {
		bi := roster_epoch(&m.roster, base)
		if bi < 0 {
			return nil, .Corrupt
		}
		for &s in m.cache {
			if s.ok && s.epoch == base && &s != slot {
				tree_clone(&slot.tree, &s.tree, m.allocator) or_return
				b: Commit_Body
				rec := &m.roster.records[m.roster.epochs[epoch].record]
				if e := commit_decode(rec.payload, &b); e != .None {
					tree_destroy(&slot.tree)
					return nil, e
				}
				if e := commit_apply_delta(&slot.tree, &b); e != .None {
					tree_destroy(&slot.tree)
					return nil, e
				}
				if e := commit_apply_path(&slot.tree, &b); e != .None {
					tree_destroy(&slot.tree)
					return nil, e
				}
				slot.epoch = id
				slot.used = m.tick
				slot.ok = true
				return &slot.tree, .None
			}
		}
	}
	roster_leaves(&m.roster, epoch, &slot.tree, m.allocator) or_return
	slot.epoch = id
	slot.used = m.tick
	slot.ok = true
	return &slot.tree, .None
}

membership_open :: proc(m: ^Membership, o: Opener) -> (gained: int, err: Error) {
	if !m.resolved || m.stale {
		membership_resolve(m) or_return
	}
	r := &m.roster
	for &ep, ei in r.epochs {
		if membership_keys(m, ep.id) != nil {
			continue
		}
		rec := &r.records[ep.record]
		b: Commit_Body
		if commit_decode(rec.payload, &b) != .None {
			continue
		}
		zero: Record_Id
		t: Ratchet_Tree
		base: ^Epoch_Keys
		if b.base != zero {
			bi := roster_epoch(r, b.base)
			if bi < 0 {
				continue
			}
			bt, terr := _tree_for(m, bi)
			if terr != .None {
				continue
			}
			tree_clone(&t, bt, m.allocator) or_return
			base = membership_keys(m, b.base)
		} else {
			tree_init(&t, 1, m.allocator) or_return
		}
		k: Epoch_Keys
		oerr := commit_open(&t, &b, m.space, Commit_Opener{keyring = o.keyring, self = o.self, base = base}, &k, m.allocator)
		tree_destroy(&t)
		if oerr != .None {
			continue
		}
		k.id = ep.id
		_ = ei
		append(&m.keys, k)
		gained += 1
	}
	gained += _membership_backfill(m)
	_membership_naming(m)
	return gained, .None
}

membership_open_seals :: proc(m: ^Membership, o: Opener) -> (gained: int) {
	if !m.resolved || m.stale {
		if membership_resolve(m) != .None {
			return 0
		}
	}
	r := &m.roster
	for s in r.seals {
		if s.subject != o.self.sign {
			continue
		}
		b, err := seal_decode(r.records[s.record].payload)
		if err == .None && _open_self_bundle(m, o, b.wrap) {
			gained += 1
		}
	}
	for &mm in r.members {
		if mm.sign == o.self.sign && len(mm.seal) > 0 && !mm.removed {
			if _open_self_bundle(m, o, mm.seal) {
				gained += 1
			}
		}
	}
	gained += _membership_backfill(m)
	return
}

@(private)
_open_self_bundle :: proc(m: ^Membership, o: Opener, wrap: []u8) -> bool {
	buf: [96]u8
	defer crypto.zero_explicit(&buf, size_of(buf))
	ctx := _seal_ctx(m.space, o.self.sign)
	if open_bundle(o.keyring, wrap, ctx[:], buf[:]) != .None {
		return false
	}
	id: Record_Id
	copy(id[:], buf[:32])
	if membership_keys(m, id) != nil {
		return false
	}
	ei := roster_epoch(&m.roster, id)
	if ei < 0 {
		return false
	}
	k := Epoch_Keys{id = id, number = m.roster.epochs[ei].number}
	copy(k.secret[:], buf[32:64])
	if !m.have_naming {
		copy(m.naming[:], buf[64:])
		m.have_naming = true
	}
	append(&m.keys, k)
	return true
}

@(private)
_seal_ctx :: proc(space: Space_Id, subject: Public_Key) -> (ctx: [16 + 32 + 8]u8) {
	s, p := space, subject
	copy(ctx[:16], s[:])
	copy(ctx[16:48], p[:])
	copy(ctx[48:], "0ndb key")
	return
}

membership_bundle :: proc(m: ^Membership, keys: ^Epoch_Keys, subject: Identity, out: ^[dynamic]u8, random := prim.Random{}) -> Error {
	if !m.have_naming {
		return .Permission
	}
	buf: [96]u8
	defer crypto.zero_explicit(&buf, size_of(buf))
	copy(buf[:32], keys.id[:])
	copy(buf[32:64], keys.secret[:])
	copy(buf[64:], m.naming[:])
	ctx := _seal_ctx(m.space, subject.sign)
	s := subject
	return seal_bundle_to(&s, buf[:], ctx[:], out, random)
}

membership_seal_payload :: proc(m: ^Membership, keys: ^Epoch_Keys, subject: Identity, out: ^[dynamic]u8, random := prim.Random{}) -> Error {
	wrap := make([dynamic]u8, context.temp_allocator)
	membership_bundle(m, keys, subject, &wrap, random) or_return
	return seal_encode(Seal_Body{subject = subject.sign, epoch = keys.id, wrap = wrap[:]}, out)
}

@(private)
_membership_backfill :: proc(m: ^Membership) -> int {
	r := &m.roster
	gained := 0
	changed := true
	for changed {
		changed = false
		for &ep in r.epochs {
			k := membership_keys(m, ep.id)
			if k == nil {
				continue
			}
			b: Commit_Body
			if commit_decode(r.records[ep.record].payload, &b) != .None {
				continue
			}
			for bk in b.backs {
				if membership_keys(m, bk.epoch) != nil {
					continue
				}
				bi := roster_epoch(r, bk.epoch)
				if bi < 0 {
					continue
				}
				s: [32]u8
				if !commit_back(&b, k, bk.epoch, &s) {
					continue
				}
				append(&m.keys, Epoch_Keys{id = bk.epoch, number = r.epochs[bi].number, secret = s})
				crypto.zero_explicit(&s, size_of(s))
				gained += 1
				changed = true
			}
		}
	}
	return gained
}

@(private)
_membership_naming :: proc(m: ^Membership) {
	if m.have_naming {
		return
	}
	r := &m.roster
	for &ep in r.epochs {
		k := membership_keys(m, ep.id)
		if k == nil {
			continue
		}
		b: Commit_Body
		if commit_decode(r.records[ep.record].payload, &b) != .None {
			continue
		}
		if commit_naming(&b, m.space, k, &m.naming) {
			m.have_naming = true
			return
		}
	}
}

Membership_Status :: struct {
	epoch:    int,
	number:   u32,
	eligible: bool,
	missing:  int,
	held:     bool,
}

membership_status :: proc(m: ^Membership, now_ms: u64) -> (s: Membership_Status, err: Error) {
	if !m.resolved || m.stale {
		membership_resolve(m) or_return
	}
	s.epoch = roster_effective(&m.roster)
	if s.epoch < 0 {
		return s, .None
	}
	s.number = m.roster.epochs[s.epoch].number
	t := _tree_for(m, s.epoch) or_return
	s.eligible = roster_eligible(&m.roster, t, now_ms)
	s.missing = roster_missing_leaves(&m.roster, t, now_ms)
	s.held = membership_keys(m, m.roster.epochs[s.epoch].id) != nil
	return s, .None
}

membership_current :: proc(m: ^Membership, now_ms: u64) -> ^Epoch_Keys {
	s, err := membership_status(m, now_ms)
	if err != .None || s.epoch < 0 || !s.eligible || !s.held {
		return nil
	}
	return membership_keys(m, m.roster.epochs[s.epoch].id)
}

membership_frontier :: proc(m: ^Membership) -> (parents: []Record_Id, lamport: u64) {
	if !m.resolved || m.stale {
		if membership_resolve(m) != .None {
			return nil, 1
		}
	}
	hs := m.roster.heads[:]
	if len(hs) > MEMBER_PARENTS_MAX {
		hs = hs[len(hs) - MEMBER_PARENTS_MAX:]
	}
	return hs, m.roster.lamport + 1
}

membership_append :: proc(m: ^Membership, op: Member_Op, signer: Member_Signer, hlc: u64, payload: []u8) -> (raw: []u8, err: Error) {
	parents, lamport := membership_frontier(m)
	ps := make([]Record_Id, len(parents), context.temp_allocator)
	copy(ps, parents)
	tmp, _, eerr := member_encode(op, m.space, signer, lamport, ps, hlc, payload, context.temp_allocator)
	if eerr != .None {
		return nil, eerr
	}
	membership_ingest(m, tmp) or_return
	membership_resolve(m) or_return
	return m.raws[len(m.raws) - 1], .None
}

genesis_create :: proc(m: ^Membership, signer: Member_Signer, self: Add_Body, hlc: u64, random := prim.Random{}, allocator := context.allocator) -> (raw: []u8, space: Space_Id, err: Error) {
	b := self
	b.sign = signer.public
	b.role = .Owner
	b.method = .Genesis
	payload := make([dynamic]u8, context.temp_allocator)
	add_encode(b, &payload) or_return
	nonce: [16]u8
	prim.random_fill(random, nonce[:])
	ns: Space_Id
	copy(ns[:], nonce[:])
	tmp, id, eerr := member_encode(.Genesis, ns, signer, 0, nil, hlc, payload[:], context.temp_allocator)
	if eerr != .None {
		return nil, {}, eerr
	}
	space = space_id_of(id)
	membership_init(m, space, allocator)
	prim.random_fill(random, m.naming[:])
	m.have_naming = true
	membership_ingest(m, tmp) or_return
	return m.raws[0], space, .None
}

membership_add :: proc(m: ^Membership, signer: Member_Signer, b: Add_Body, hlc: u64) -> (raw: []u8, err: Error) {
	payload := make([dynamic]u8, context.temp_allocator)
	add_encode(b, &payload) or_return
	return membership_append(m, .Add, signer, hlc, payload[:])
}

membership_remove :: proc(m: ^Membership, signer: Member_Signer, subject: Public_Key, hlc: u64) -> (raw: []u8, err: Error) {
	payload := make([dynamic]u8, context.temp_allocator)
	key32_encode(subject, &payload) or_return
	return membership_append(m, .Remove, signer, hlc, payload[:])
}

membership_update :: proc(m: ^Membership, signer: Member_Signer, box: Public_Key, hlc: u64) -> (raw: []u8, err: Error) {
	payload := make([dynamic]u8, context.temp_allocator)
	key32_encode(box, &payload) or_return
	return membership_append(m, .Update, signer, hlc, payload[:])
}

membership_renew :: proc(m: ^Membership, signer: Member_Signer, expires: u64, hlc: u64) -> (raw: []u8, err: Error) {
	payload := make([dynamic]u8, context.temp_allocator)
	renew_encode(Renew_Body{expires = expires}, &payload) or_return
	return membership_append(m, .Renew, signer, hlc, payload[:])
}

membership_revoke :: proc(m: ^Membership, signer: Member_Signer, grant: Record_Id, hlc: u64) -> (raw: []u8, err: Error) {
	g := grant
	return membership_append(m, .Revoke, signer, hlc, g[:])
}

membership_seal :: proc(m: ^Membership, signer: Member_Signer, subject: Identity, hlc: u64, now_ms: u64, random := prim.Random{}) -> (raw: []u8, err: Error) {
	k := membership_current(m, now_ms)
	if k == nil {
		return nil, .Permission
	}
	payload := make([dynamic]u8, context.temp_allocator)
	membership_seal_payload(m, k, subject, &payload, random) or_return
	return membership_append(m, .Seal, signer, hlc, payload[:])
}

membership_commit :: proc(m: ^Membership, signer: Member_Signer, self: Identity, hlc: u64, now_ms: u64, history := true, random := prim.Random{}) -> (raw: []u8, err: Error) {
	if !m.resolved || m.stale {
		membership_resolve(m) or_return
	}
	if !m.have_naming {
		return nil, .Permission
	}
	r := &m.roster
	me := roster_find(r, signer.public)
	if me < 0 || !member_active(&r.members[me], now_ms) || !member_leaf_kind(r.members[me].kind) {
		return nil, .Permission
	}
	base := roster_effective(r)
	t: Ratchet_Tree
	in_ := Commit_Input {
		space   = m.space,
		history = history,
		naming  = &m.naming,
		random  = random,
	}
	if base >= 0 {
		bt := _tree_for(m, base) or_return
		tree_clone(&t, bt, context.temp_allocator) or_return
		in_.base = r.epochs[base].id
		in_.number = r.epochs[base].number + 1
	} else {
		tree_init(&t, 1, context.temp_allocator) or_return
	}
	blanks := make([dynamic]u32, context.temp_allocator)
	sets := make([dynamic]Commit_Set, context.temp_allocator)
	taken := make([dynamic]u32, context.temp_allocator)
	for i := u32(0); i < t.width; i += 1 {
		n := &t.nodes[2 * i]
		if !n.present {
			continue
		}
		x := roster_find(r, n.sign)
		if x < 0 || !member_active(&r.members[x], now_ms) || !member_leaf_kind(r.members[x].kind) || len(r.members[x].scope) > 0 || r.members[x].box != n.pub {
			append(&blanks, i)
		}
	}
	for x in blanks {
		tree_blank_leaf(&t, x)
	}
	for &mm in r.members {
		if !member_active(&mm, now_ms) || !member_leaf_kind(mm.kind) || len(mm.scope) > 0 {
			continue
		}
		if _, ok := tree_find_leaf(&t, mm.sign); ok {
			continue
		}
		leaf := tree_free_leaf(&t, taken[:])
		append(&taken, leaf)
		append(&sets, Commit_Set{leaf = leaf, sign = mm.sign, box = mm.box})
	}
	committer, found := tree_find_leaf(&t, signer.public)
	if !found {
		for s in sets {
			if s.sign == signer.public {
				committer = s.leaf
				found = true
			}
		}
	}
	if !found {
		return nil, .Corrupt
	}
	if len(t.nodes) > 0 {
		tree_destroy(&t)
	}
	if base >= 0 {
		bt := _tree_for(m, base) or_return
		tree_clone(&t, bt, context.temp_allocator) or_return
	} else {
		tree_init(&t, 1, context.temp_allocator) or_return
	}
	backs := make([dynamic]Epoch_Keys, context.temp_allocator)
	if history {
		for &ep in r.epochs {
			if k := membership_keys(m, ep.id); k != nil && _is_head_epoch(r, ep.id) {
				append(&backs, Epoch_Keys{id = k.id, number = k.number, secret = k.secret})
			}
		}
	}
	in_.blanks = blanks[:]
	in_.sets = sets[:]
	in_.committer = committer
	in_.backs = backs[:]
	payload := make([dynamic]u8, context.temp_allocator)
	k: Epoch_Keys
	cerr := commit_create(&t, in_, &payload, &k, m.allocator)
	for &bk in backs {
		crypto.zero_explicit(&bk.secret, size_of(bk.secret))
	}
	if cerr != .None {
		epoch_keys_clear(&k)
		return nil, cerr
	}
	raw, err = membership_append(m, .Commit, signer, hlc, payload[:])
	if err != .None {
		epoch_keys_clear(&k)
		return nil, err
	}
	k.id = record_hash(raw)
	append(&m.keys, k)
	return raw, .None
}

@(private)
_is_head_epoch :: proc(r: ^Roster, id: Record_Id) -> bool {
	for &e in r.epochs {
		if e.base == id {
			return false
		}
	}
	return true
}

membership_secrets_encode :: proc(m: ^Membership, out: ^[dynamic]u8) -> Error {
	w := prim.writer(out)
	prim.write_u8(&w, MEMBERSHIP_SECRETS_VERSION)
	prim.write_bool(&w, m.have_naming)
	prim.write_raw(&w, m.naming[:])
	prim.write_uvarint(&w, u64(len(m.keys)))
	for &k in m.keys {
		prim.write_raw(&w, k.id[:])
		prim.write_u32le(&w, k.number)
		prim.write_raw(&w, k.secret[:])
		prim.write_uvarint(&w, u64(len(k.path)))
		for &p in k.path {
			prim.write_u32le(&w, p.node)
			prim.write_raw(&w, p.secret[:])
		}
	}
	return .No_Memory if w.err != .None else .None
}

membership_secrets_decode :: proc(m: ^Membership, data: []u8) -> Error {
	r := prim.reader(data)
	if prim.read_u8(&r) != MEMBERSHIP_SECRETS_VERSION {
		return .Corrupt
	}
	m.have_naming = prim.read_bool(&r)
	prim.read_fixed(&r, m.naming[:])
	n := prim.read_uvarint(&r)
	if !prim.reader_ok(&r) || n > u64(prim.reader_remaining(&r) / 69) {
		return .Corrupt
	}
	for _ in 0 ..< int(n) {
		k: Epoch_Keys
		prim.read_fixed(&r, k.id[:])
		k.number = prim.read_u32le(&r)
		prim.read_fixed(&r, k.secret[:])
		np := prim.read_uvarint(&r)
		if !prim.reader_ok(&r) || np > 64 {
			return .Corrupt
		}
		if np > 0 {
			k.path = make([dynamic]Path_Secret, 0, int(np), m.allocator)
			for _ in 0 ..< int(np) {
				p: Path_Secret
				p.node = prim.read_u32le(&r)
				prim.read_fixed(&r, p.secret[:])
				append(&k.path, p)
			}
		}
		if membership_keys(m, k.id) == nil {
			append(&m.keys, k)
		} else {
			epoch_keys_clear(&k)
		}
	}
	if !prim.reader_ok(&r) || !prim.reader_done(&r) {
		return .Corrupt
	}
	return .None
}

MEMBERSHIP_PATH_WINDOW :: 64

membership_prune_paths :: proc(m: ^Membership) {
	newest: u32
	for &k in m.keys {
		newest = max(newest, k.number)
	}
	for &k in m.keys {
		if len(k.path) > 0 && k.number + MEMBERSHIP_PATH_WINDOW < newest {
			for &p in k.path {
				crypto.zero_explicit(&p.secret, size_of(p.secret))
			}
			delete(k.path)
			k.path = nil
		}
	}
}
