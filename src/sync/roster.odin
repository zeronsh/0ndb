package osync

import "base:runtime"
import "core:slice"
import "../prim"

Member :: struct {
	sign:        Public_Key,
	box:         Public_Key,
	device:      Device_Id,
	kind:        Member_Kind,
	role:        Role,
	method:      Enroll_Method,
	person:      Public_Key,
	expires:     u64,
	lease_ms:    u64,
	history:     bool,
	scope:       []prim.Id,
	label:       []u8,
	attestation: []u8,
	seal:        []u8,
	added_by:    Public_Key,
	added:       Record_Id,
	added_hlc:   u64,
	seniority:   int,
	removed:     bool,
	removed_by:  Public_Key,
	removal:     Record_Id,
}

Epoch_Info :: struct {
	id:        Record_Id,
	number:    u32,
	base:      Record_Id,
	committer: Public_Key,
	record:    int,
	order:     int,
	history:   bool,
}

Runner_Seal :: struct {
	subject: Public_Key,
	epoch:   Record_Id,
	record:  int,
}

Roster :: struct {
	space:     Space_Id,
	genesis:   Record_Id,
	records:   []Member_Record,
	valid:     []bool,
	order:     [dynamic]int,
	members:   [dynamic]Member,
	epochs:    [dynamic]Epoch_Info,
	seals:     [dynamic]Runner_Seal,
	revoked:   [dynamic]Record_Id,
	heads:     [dynamic]Record_Id,
	lamport:   u64,
	held:      int,
	allocator: runtime.Allocator,
}

roster_destroy :: proc(r: ^Roster) {
	for &m in r.members {
		delete(m.scope, r.allocator)
	}
	delete(r.valid, r.allocator)
	delete(r.order)
	delete(r.members)
	delete(r.epochs)
	delete(r.seals)
	delete(r.revoked)
	delete(r.heads)
	r^ = {}
}

roster_find :: proc "contextless" (r: ^Roster, sign: Public_Key) -> int {
	for i := len(r.members) - 1; i >= 0; i -= 1 {
		if r.members[i].sign == sign {
			return i
		}
	}
	return -1
}

roster_find_device :: proc "contextless" (r: ^Roster, device: Device_Id) -> int {
	for i := len(r.members) - 1; i >= 0; i -= 1 {
		if r.members[i].device == device {
			return i
		}
	}
	return -1
}

member_active :: proc "contextless" (m: ^Member, now_ms: u64) -> bool {
	if m.removed {
		return false
	}
	return m.expires == 0 || now_ms <= m.expires
}

member_leaf_kind :: proc "contextless" (k: Member_Kind) -> bool {
	switch k {
	case .Device, .Account, .Recovery, .Custodian, .Pool, .Directory:
		return true
	case .Runner, .Guest:
	}
	return false
}

roster_effective :: proc "contextless" (r: ^Roster) -> int {
	best := -1
	for e, i in r.epochs {
		if best < 0 || e.number > r.epochs[best].number || e.number == r.epochs[best].number && e.order > r.epochs[best].order {
			best = i
		}
	}
	return best
}

roster_epoch :: proc "contextless" (r: ^Roster, id: Record_Id) -> int {
	for e, i in r.epochs {
		if e.id == id {
			return i
		}
	}
	return -1
}

@(private)
Ready :: struct {
	rank:     u8,
	senior:   int,
	lamport:  u64,
	id:       Record_Id,
	idx:      int,
}

@(private)
_ready_less :: proc(a, b: Ready) -> bool {
	if a.rank != b.rank {
		return a.rank < b.rank
	}
	if a.senior != b.senior {
		return a.senior < b.senior
	}
	if a.lamport != b.lamport {
		return a.lamport < b.lamport
	}
	x, y := a.id, b.id
	return string(x[:]) < string(y[:])
}

@(private)
_heap_push :: proc(h: ^[dynamic]Ready, v: Ready) {
	append(h, v)
	i := len(h) - 1
	for i > 0 {
		p := (i - 1) / 2
		if !_ready_less(h[i], h[p]) {
			break
		}
		h[i], h[p] = h[p], h[i]
		i = p
	}
}

@(private)
_heap_pop :: proc(h: ^[dynamic]Ready) -> Ready {
	top := h[0]
	last := pop(h)
	if len(h) > 0 {
		h[0] = last
		i := 0
		for {
			l, rr := 2 * i + 1, 2 * i + 2
			m := i
			if l < len(h) && _ready_less(h[l], h[m]) {
				m = l
			}
			if rr < len(h) && _ready_less(h[rr], h[m]) {
				m = rr
			}
			if m == i {
				break
			}
			h[i], h[m] = h[m], h[i]
			i = m
		}
	}
	return top
}

@(private)
Graph :: struct {
	parents:  [][]int,
	children: [][dynamic]int,
	known:    []bool,
}

@(private)
Ban :: struct {
	subject: Public_Key,
	removal: int,
}

roster_resolve :: proc(r: ^Roster, space: Space_Id, records: []Member_Record, allocator := context.allocator) -> Error {
	r^ = {
		space     = space,
		records   = records,
		allocator = allocator,
	}
	n := len(records)
	r.valid = make([]bool, n, allocator)
	r.order = make([dynamic]int, 0, n, allocator)
	r.members = make([dynamic]Member, allocator)
	r.epochs = make([dynamic]Epoch_Info, allocator)
	r.seals = make([dynamic]Runner_Seal, allocator)
	r.revoked = make([dynamic]Record_Id, allocator)
	r.heads = make([dynamic]Record_Id, allocator)
	index := make(map[Record_Id]int, n, context.temp_allocator)
	genesis := -1
	for &rec, i in records {
		index[rec.id] = i
		r.lamport = max(r.lamport, rec.lamport)
		if rec.op == .Genesis && space_id_of(rec.id) == space && len(rec.parents) == 0 {
			if genesis < 0 || string(rec.id[:]) < string(records[genesis].id[:]) {
				genesis = i
			}
		}
	}
	if genesis < 0 {
		return .Not_Found
	}
	r.genesis = records[genesis].id
	g := Graph{}
	g.parents = make([][]int, n, context.temp_allocator)
	g.children = make([][dynamic]int, n, context.temp_allocator)
	g.known = make([]bool, n, context.temp_allocator)
	for &rec, i in records {
		ps := make([]int, len(rec.parents), context.temp_allocator)
		ok := rec.space == space || i == genesis
		for p, j in rec.parents {
			k, found := index[p]
			if !found || k == i {
				ok = false
				break
			}
			ps[j] = k
		}
		if ok && i != genesis && len(rec.parents) == 0 {
			ok = false
		}
		g.parents[i] = ps
		g.known[i] = ok
	}
	changed := true
	for changed {
		changed = false
		for i in 0 ..< n {
			if !g.known[i] {
				continue
			}
			for p in g.parents[i] {
				if !g.known[p] {
					g.known[i] = false
					changed = true
					break
				}
			}
		}
	}
	for i in 0 ..< n {
		if !g.known[i] {
			r.held += 1
			continue
		}
		for p in g.parents[i] {
			if g.children[p] == nil {
				g.children[p] = make([dynamic]int, context.temp_allocator)
			}
			append(&g.children[p], i)
		}
	}
	pasts := make(map[int][]u64, context.temp_allocator)
	words := (n + 63) / 64
	for i in 0 ..< n {
		if g.known[i] && records[i].op == .Remove {
			bits := make([]u64, words, context.temp_allocator)
			stack := make([dynamic]int, 0, 16, context.temp_allocator)
			append(&stack, i)
			for len(stack) > 0 {
				x := pop(&stack)
				if bits[x / 64] & (1 << u64(x % 64)) != 0 {
					continue
				}
				bits[x / 64] |= 1 << u64(x % 64)
				for p in g.parents[x] {
					append(&stack, p)
				}
			}
			pasts[i] = bits
		}
	}
	bans := make([dynamic]Ban, context.temp_allocator)
	seen := make([dynamic]Ban, context.temp_allocator)
	limit := len(pasts) + 2
	for iter := 0; ; iter += 1 {
		applied := _roster_pass(r, &g, genesis, bans[:], pasts)
		next := make([dynamic]Ban, context.temp_allocator)
		for x in applied {
			b, _ := remove_subject(&records[x])
			append(&next, Ban{subject = b, removal = x})
			found := false
			for s in seen {
				if s.subject == b && s.removal == x {
					found = true
				}
			}
			if !found {
				append(&seen, Ban{subject = b, removal = x})
			}
		}
		if _bans_equal(next[:], bans[:]) {
			break
		}
		if iter >= limit {
			clear(&bans)
			append(&bans, ..seen[:])
			_roster_pass(r, &g, genesis, bans[:], pasts)
			break
		}
		clear(&bans)
		append(&bans, ..next[:])
	}
	for i in 0 ..< n {
		if g.known[i] && len(g.children[i]) == 0 {
			append(&r.heads, records[i].id)
		}
	}
	slice.sort_by(r.heads[:], proc(a, b: Record_Id) -> bool {
		x, y := a, b
		return string(x[:]) < string(y[:])
	})
	return .None
}

remove_subject :: proc(rec: ^Member_Record) -> (Public_Key, Error) {
	return key32_decode(rec.payload)
}

@(private)
_bans_equal :: proc(a, b: []Ban) -> bool {
	if len(a) != len(b) {
		return false
	}
	for x in a {
		found := false
		for y in b {
			if x == y {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}

@(private)
_rank :: proc(r: ^Roster, author: Public_Key) -> (u8, int) {
	i := roster_find(r, author)
	if i < 0 || r.members[i].removed {
		return 255, max(int)
	}
	return u8(r.members[i].role), r.members[i].seniority
}

@(private)
_roster_reset :: proc(r: ^Roster) {
	for &m in r.members {
		delete(m.scope, r.allocator)
	}
	clear(&r.members)
	clear(&r.epochs)
	clear(&r.seals)
	clear(&r.revoked)
	clear(&r.order)
	for &v in r.valid {
		v = false
	}
}

@(private)
_roster_pass :: proc(r: ^Roster, g: ^Graph, genesis: int, bans: []Ban, pasts: map[int][]u64) -> []int {
	_roster_reset(r)
	n := len(r.records)
	indeg := make([]int, n, context.temp_allocator)
	for i in 0 ..< n {
		if g.known[i] {
			indeg[i] = len(g.parents[i])
		}
	}
	heap := make([dynamic]Ready, 0, 64, context.temp_allocator)
	applied := make([dynamic]int, context.temp_allocator)
	_heap_push(&heap, Ready{rank = 0, idx = genesis, id = r.records[genesis].id})
	seniority := 0
	for len(heap) > 0 {
		top := _heap_pop(&heap)
		i := top.idx
		rec := &r.records[i]
		ok := true
		for b in bans {
			if b.subject == rec.author && b.removal != i {
				bits := pasts[b.removal]
				if bits[i / 64] & (1 << u64(i % 64)) == 0 {
					ok = false
					break
				}
			}
		}
		if ok {
			ok = _roster_apply(r, i, rec, &seniority)
		}
		r.valid[i] = ok
		append(&r.order, i)
		if ok && rec.op == .Remove {
			append(&applied, i)
		}
		for c in g.children[i] {
			indeg[c] -= 1
			if indeg[c] == 0 {
				cr := &r.records[c]
				rank, senior := _rank(r, cr.author)
				_heap_push(&heap, Ready{rank = rank, senior = senior, lamport = cr.lamport, id = cr.id, idx = c})
			}
		}
	}
	return applied[:]
}

@(private)
_roster_apply :: proc(r: ^Roster, i: int, rec: ^Member_Record, seniority: ^int) -> bool {
	if rec.op == .Genesis {
		if r.records[i].id != r.genesis || len(r.members) != 0 {
			return false
		}
		b: Add_Body
		if add_decode(rec.payload, &b, r.allocator) != .None || b.sign != rec.author || !member_leaf_kind(b.kind) {
			delete(b.scope, r.allocator)
			return false
		}
		_member_add(r, rec, &b, .Owner, .Genesis, seniority)
		return true
	}
	ai := roster_find(r, rec.author)
	if ai < 0 || r.members[ai].removed {
		return false
	}
	author := r.members[ai]
	if rec.lamport == 0 {
		return false
	}
	switch rec.op {
	case .Genesis:
		return false
	case .Add:
		b: Add_Body
		if add_decode(rec.payload, &b, r.allocator) != .None {
			return false
		}
		if !_may_add(&author, &b) {
			delete(b.scope, r.allocator)
			return false
		}
		if x := roster_find(r, b.sign); x >= 0 && !r.members[x].removed {
			delete(b.scope, r.allocator)
			return false
		}
		_member_add(r, rec, &b, b.role, b.method, seniority)
		return true
	case .Remove:
		subject, err := remove_subject(rec)
		if err != .None {
			return false
		}
		x := roster_find(r, subject)
		if x < 0 || r.members[x].removed {
			return false
		}
		target := &r.members[x]
		allowed := subject == rec.author
		switch author.role {
		case .Owner:
			allowed = true
		case .Admin:
			allowed ||= target.role != .Owner
		case .Member, .Reader:
		}
		if author.kind == .Pool && (target.kind == .Runner || target.kind == .Guest) && target.added_by == author.sign {
			allowed = true
		}
		if !allowed {
			return false
		}
		target.removed = true
		target.removed_by = rec.author
		target.removal = rec.id
		return true
	case .Commit:
		if !member_leaf_kind(author.kind) || len(author.scope) > 0 {
			return false
		}
		b: Commit_Body
		if commit_decode(rec.payload, &b) != .None {
			return false
		}
		zero: Record_Id
		if b.base == zero {
			if b.number != 0 {
				return false
			}
		} else {
			bi := roster_epoch(r, b.base)
			if bi < 0 || r.epochs[bi].number + 1 != b.number {
				return false
			}
		}
		append(&r.epochs, Epoch_Info{id = rec.id, number = b.number, base = b.base, committer = rec.author, record = i, order = len(r.order), history = b.history})
		return true
	case .Update:
		box, err := key32_decode(rec.payload)
		if err != .None {
			return false
		}
		r.members[ai].box = box
		return true
	case .Renew:
		b, err := renew_decode(rec.payload)
		if err != .None || author.kind != .Runner || author.lease_ms == 0 {
			return false
		}
		cap := rec.hlc + author.lease_ms
		r.members[ai].expires = max(author.expires, min(b.expires, cap))
		return true
	case .Seal:
		b, err := seal_decode(rec.payload)
		if err != .None || !(author.kind == .Pool || member_leaf_kind(author.kind)) {
			return false
		}
		x := roster_find(r, b.subject)
		if x < 0 || r.members[x].removed {
			return false
		}
		append(&r.seals, Runner_Seal{subject = b.subject, epoch = b.epoch, record = i})
		return true
	case .Scope:
		b, err := scope_decode(rec.payload)
		if err != .None {
			return false
		}
		x := roster_find(r, b.subject)
		if x < 0 || r.members[x].removed || r.members[x].kind != .Guest {
			return false
		}
		target := &r.members[x]
		if b.add {
			ab := Add_Body{kind = .Guest, role = target.role}
			if !_may_add(&author, &ab) {
				return false
			}
		} else {
			allowed := b.subject == rec.author
			switch author.role {
			case .Owner:
				allowed = true
			case .Admin:
				allowed ||= target.role != .Owner
			case .Member, .Reader:
			}
			if author.kind == .Pool && target.added_by == author.sign {
				allowed = true
			}
			if !allowed {
				return false
			}
		}
		at := -1
		for o, k in target.scope {
			if o == b.object {
				at = k
			}
		}
		if b.add == (at >= 0) {
			return true
		}
		n := len(target.scope) + 1 if b.add else len(target.scope) - 1
		next := make([]prim.Id, n, r.allocator)
		j := 0
		for o, k in target.scope {
			if k != at {
				next[j] = o
				j += 1
			}
		}
		if b.add {
			next[j] = b.object
		}
		delete(target.scope, r.allocator)
		target.scope = next
		return true
	case .Revoke:
		b, err := revoke_decode(rec.payload)
		if err != .None || author.role > .Admin {
			return false
		}
		append(&r.revoked, b.grant)
		return true
	}
	return false
}

@(private)
_may_add :: proc(author: ^Member, b: ^Add_Body) -> bool {
	if author.kind == .Runner || author.kind == .Guest {
		return false
	}
	if author.kind == .Pool {
		return b.kind == .Runner && b.method == .Pool && b.role >= .Member && b.lease_ms > 0
	}
	switch author.role {
	case .Owner:
		return true
	case .Admin:
		return b.role >= .Admin
	case .Member:
		return b.role >= .Member && (b.kind == .Device || b.kind == .Guest)
	case .Reader:
	}
	return false
}

@(private)
_member_add :: proc(r: ^Roster, rec: ^Member_Record, b: ^Add_Body, role: Role, method: Enroll_Method, seniority: ^int) {
	m := Member {
		sign        = b.sign,
		box         = b.box,
		device      = device_id(b.sign),
		kind        = b.kind,
		role        = role,
		method      = method,
		person      = b.person,
		expires     = b.expires,
		lease_ms    = b.lease_ms,
		history     = b.history,
		scope       = b.scope,
		label       = b.label,
		attestation = b.attestation,
		seal        = b.seal,
		added_by    = rec.author,
		added       = rec.id,
		added_hlc   = rec.hlc,
		seniority   = seniority^,
	}
	if b.lease_ms > 0 && b.expires == 0 {
		m.expires = rec.hlc + b.lease_ms
	}
	seniority^ += 1
	append(&r.members, m)
}

roster_leaves :: proc(r: ^Roster, epoch: int, t: ^Ratchet_Tree, allocator := context.temp_allocator) -> Error {
	chain := make([dynamic]int, 0, 16, context.temp_allocator)
	zero: Record_Id
	for e := epoch; e >= 0; {
		append(&chain, e)
		if r.epochs[e].base == zero {
			break
		}
		e = roster_epoch(r, r.epochs[e].base)
		if e < 0 {
			return .Corrupt
		}
	}
	tree_init(t, 1, allocator) or_return
	for k := len(chain) - 1; k >= 0; k -= 1 {
		ep := &r.epochs[chain[k]]
		rec := &r.records[ep.record]
		b: Commit_Body
		if err := commit_decode(rec.payload, &b); err != .None {
			tree_destroy(t)
			return err
		}
		if err := commit_apply_delta(t, &b); err != .None {
			tree_destroy(t)
			return err
		}
		if t.nodes[2 * b.committer].sign != rec.author {
			tree_destroy(t)
			return .Corrupt
		}
		if err := commit_apply_path(t, &b); err != .None {
			tree_destroy(t)
			return err
		}
	}
	return .None
}

roster_eligible :: proc(r: ^Roster, t: ^Ratchet_Tree, now_ms: u64) -> bool {
	for i := u32(0); i < t.width; i += 1 {
		n := &t.nodes[2 * i]
		if !n.present {
			continue
		}
		m := roster_find(r, n.sign)
		if m < 0 || !member_active(&r.members[m], now_ms) || !member_leaf_kind(r.members[m].kind) || r.members[m].box != n.pub {
			return false
		}
	}
	return true
}

roster_missing_leaves :: proc(r: ^Roster, t: ^Ratchet_Tree, now_ms: u64) -> int {
	n := 0
	for &m in r.members {
		if !member_active(&m, now_ms) || !member_leaf_kind(m.kind) || len(m.scope) > 0 {
			continue
		}
		if _, ok := tree_find_leaf(t, m.sign); !ok {
			n += 1
		}
	}
	return n
}
