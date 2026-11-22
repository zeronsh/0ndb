package relayvec

import "core:crypto/blake2b"
import "core:fmt"
import "../../src/journal"
import "../../src/prim"
import osync "../../src/sync"

Key :: struct {
	signer: osync.Key_Signer,
	ms:     osync.Member_Signer,
	pub:    osync.Public_Key,
	dev:    osync.Device_Id,
}

Space :: struct {
	m:       osync.Membership,
	id:      osync.Space_Id,
	genesis: []u8,
	wall:    u64,
}

scenarios :: proc() -> []Scenario {
	@(static) list := [?]Scenario {
		{"hello", "Hello acceptance and every rejection: version, signature binding, unknown credential, non-member, frame before Hello, empty Hello, local sockets skip the signature, inadmissible proof.", sc_hello},
		{"append", "Appends are acknowledged only once durable; conflicts, zero-length appends, ownership, reads, tails, reads past the end and frames split across deliveries.", sc_append},
		{"quota", "Quota refusals for appends and objects count stored bytes plus in-flight reservations; Account reports the space's accounting.", sc_quota},
		{"follow", "Follow, watch (Created), live Data pushes, FOLLOW_END, Unfollow and reserved stream ids.", sc_follow},
		{"feed", "The announce feed: snapshot from 0, live entries, resume at aligned and unaligned offsets, past-the-end, filters and additive filters.", sc_feed},
		{"list", "Listing returns each stream once, newest first, with its current length.", sc_list},
		{"probe", "Probe answers lengths for streams, unknown streams and the feed, preceded by Hollow for based segments.", sc_probe},
		{"objects", "Put, deduplicated Put, Get, Missing, Forget and reader refusals.", sc_objects},
		{"drop", "Drop notifies followers and watchers once, appends FEED_DROPPED, refuses non-owners and busy streams.", sc_drop},
		{"redact", "Redaction zero-fills whole records in place, keeps offsets, logs the range in the feed, refuses readers and misaligned ranges.", sc_redact},
		{"hollow", "Hollow segments: Note, Noted, Hollow to followers and readers, Fill backward, mismatched Fill, appends after a hollow prefix.", sc_hollow},
		{"pipe", "Peer pipe: Pull, Pulled, Serve, Served, final, none, unmatched frames, absent and self holders, duplicate tags, holder disconnect.", sc_pipe},
		{"presence", "Presence snapshots and up/down transitions per device across several connections; direct messages and Undelivered.", sc_presence},
		{"membership", "Authorization follows the signed membership log: an Add appended to a members stream admits, a proof by a non-member is ignored, a Remove revokes live connections.", sc_membership},
		{"account", "Account namespace: request and account credentials may only see presence and exchange direct messages; requesters are limited to two connections.", sc_account},
		{"embedder", "An embedder authorizer maps unknown credential types to principals; the relay enforces the access it grants.", sc_embedder},
		{"malformed", "Malformed input is fatal: oversize frames, unknown kinds, relay-only kinds, short payloads, count mismatches, inverted ranges, bad bulk headers, oversize direct payloads, a second Hello; bytes after the error are ignored.", sc_malformed},
		{"compaction", "Feed compaction folds the feed into a snapshot of current lengths plus the redaction log; followers and late readers resume from the new base.", sc_compaction},
		{"trim", "Trim drops stored content below a base an archive covers: owner only, acknowledged once durable, idempotent, never lowers base, refused at or past the length; readers, probes and follows get Trimmed; Fill below a trim stores nothing.", sc_trim},
		{"limits", "Per-principal connection limit and per-connection follow limit.", sc_limits},
		{"live", "Live drafts (feature bit 3): live-only follows, Live forwarded unstored to live followers only, owner check, Unfollow leaving live interest, LIVE removal, draft pulls through the peer pipe, malformed Live.", sc_live},
	}
	return list[:]
}

@(private)
_fill_random :: proc(data: rawptr, out: []u8) {
	seed := cast(^u8)data
	for i in 0 ..< len(out) {
		out[i] = seed^ + u8(i)
	}
}

key_make :: proc(seed: u8) -> ^Key {
	k := new(Key)
	s: [32]u8
	for i in 0 ..< 32 {
		s[i] = seed
	}
	osync.key_signer_from_seed(&k.signer, s[:])
	k.ms = osync.key_signer(&k.signer)
	k.pub = k.ms.public
	k.dev = osync.device_id(k.pub)
	return k
}

space_make :: proc(v: ^Vector, founder: ^Key, nonce: u8) -> ^Space {
	sp := new(Space)
	sp.wall = u64(v.cfg.wall_ms)
	n := nonce
	b := osync.Add_Body{box = founder.pub, kind = .Device}
	raw, id, _ := osync.genesis_create(&sp.m, founder.ms, b, sp.wall, prim.Random{data = &n, fill = _fill_random})
	sp.id = id
	sp.genesis = _clone(raw)
	vector_track(v, id)
	return sp
}

space_add :: proc(sp: ^Space, by: ^Key, who: ^Key, role: osync.Role) -> []u8 {
	raw, _ := osync.membership_add(&sp.m, by.ms, osync.Add_Body{sign = who.pub, box = who.pub, kind = .Device, role = role, method = .Approval}, sp.wall)
	return _clone(raw)
}

forge_add :: proc(sp: ^Space, by: ^Key, who: ^Key) -> []u8 {
	payload := make([dynamic]u8, context.temp_allocator)
	osync.add_encode(osync.Add_Body{sign = who.pub, box = who.pub, kind = .Device, role = .Owner, method = .Approval}, &payload)
	gid := osync.record_hash(sp.genesis)
	raw, _, _ := osync.member_encode(.Add, sp.id, by.ms, 1, {gid}, sp.wall, payload[:])
	return raw
}

space_remove :: proc(sp: ^Space, by: ^Key, who: ^Key) -> []u8 {
	raw, _ := osync.membership_remove(&sp.m, by.ms, who.pub, sp.wall)
	return _clone(raw)
}

@(private)
_clone :: proc(b: []u8) -> []u8 {
	out := make([]u8, len(b))
	copy(out, b)
	return out
}

binding :: proc(conn: string) -> []u8 {
	out := make([]u8, 64, context.temp_allocator)
	ctx: blake2b.Context
	blake2b.init(&ctx, 64)
	blake2b.update(&ctx, transmute([]u8)string("0ndb relay vector binding "))
	blake2b.update(&ctx, transmute([]u8)conn)
	blake2b.final(&ctx, out)
	return out
}

cat :: proc(parts: ..[]u8) -> []u8 {
	n := 0
	for p in parts {
		n += len(p)
	}
	out := make([]u8, n, context.temp_allocator)
	pos := 0
	for p in parts {
		pos += copy(out[pos:], p)
	}
	return out
}

le64 :: proc(v: u64) -> []u8 {
	out := make([]u8, 8, context.temp_allocator)
	prim.put_u64le(out, v)
	return out
}

le16 :: proc(v: int) -> []u8 {
	out := make([]u8, 2, context.temp_allocator)
	out[0] = u8(v)
	out[1] = u8(v >> 8)
	return out
}

one :: proc(v: u8) -> []u8 {
	out := make([]u8, 1, context.temp_allocator)
	out[0] = v
	return out
}

ids :: proc(id: [32]u8) -> []u8 {
	out := make([]u8, 32, context.temp_allocator)
	v := id
	copy(out, v[:])
	return out
}

dev16 :: proc(d: osync.Device_Id) -> []u8 {
	out := make([]u8, 16, context.temp_allocator)
	v := d
	copy(out, v[:])
	return out
}

frame :: proc(k: osync.Kind, parts: ..[]u8) -> []u8 {
	body := cat(..parts)
	out := make([]u8, 5 + len(body), context.temp_allocator)
	prim.put_u32le(out, u32(len(body)))
	out[4] = u8(k)
	copy(out[5:], body)
	return out
}

raw_header :: proc(k: u8, n: u32) -> []u8 {
	out := make([]u8, 5, context.temp_allocator)
	prim.put_u32le(out, n)
	out[4] = k
	return out
}

stream :: proc(k: ^Key, tag: u8) -> [32]u8 {
	id: [32]u8
	d := k.dev
	copy(id[:16], d[:])
	for i in 16 ..< 32 {
		id[i] = tag
	}
	return id
}

okey :: proc(tag: u8) -> [32]u8 {
	id: [32]u8
	for i in 0 ..< 32 {
		id[i] = tag ~ u8(i)
	}
	return id
}

rec :: proc(text: string, off: i64) -> []u8 {
	out := make([]u8, len(text) + journal.OVERHEAD, context.temp_allocator)
	journal.encode_record(out, transmute([]u8)text, off)
	return out
}

recs :: proc(off: i64, texts: ..string) -> []u8 {
	parts := make([dynamic][]u8, context.temp_allocator)
	pos := off
	for t in texts {
		r := rec(t, pos)
		append(&parts, r)
		pos += i64(len(r))
	}
	return cat(..parts[:])
}

sign_hello :: proc(k: ^Key, b: []u8) -> []u8 {
	buf: [16 + osync.HASH_LEN]u8
	msg := osync.hello_message(b, &buf)
	sig := make([]u8, 64, context.temp_allocator)
	s: [64]u8
	k.ms.sign(k.ms.data, msg, &s)
	copy(sig, s[:])
	return sig
}

member_cred :: proc(space: osync.Space_Id, k: ^Key, b: []u8, proofs: ..[]u8) -> []u8 {
	out := make([dynamic]u8, context.temp_allocator)
	w := prim.writer(&out)
	prim.write_u8(&w, osync.MEMBER_CREDENTIAL)
	s := space
	prim.write_raw(&w, s[:])
	p := k.pub
	prim.write_raw(&w, p[:])
	prim.write_raw(&w, sign_hello(k, b))
	prim.write_uvarint(&w, u64(len(proofs)))
	for pr in proofs {
		prim.write_bytes(&w, pr)
	}
	return out[:]
}

request_cred :: proc(account: ^Key, k: ^Key, b: []u8) -> []u8 {
	return cat(one(osync.REQUEST_CREDENTIAL), ids(account.pub), ids(k.pub), sign_hello(k, b))
}

account_cred :: proc(account: ^Key, k: ^Key, b: []u8) -> []u8 {
	msg: [17 + 32]u8
	copy(msg[:], "0ndb device cert\x00")
	d := k.pub
	copy(msg[17:], d[:])
	cert: [64]u8
	account.ms.sign(account.ms.data, msg[:], &cert)
	return cat(one(osync.ACCOUNT_CREDENTIAL), ids(account.pub), cert[:], ids(k.pub), sign_hello(k, b))
}

stub_cred :: proc(space: osync.Space_Id, k: ^Key, flags: u8) -> []u8 {
	s := space
	return cat(one(STUB_CREDENTIAL), s[:], dev16(k.dev), one(flags))
}

hello :: proc(cred: []u8) -> []u8 {
	return frame(.Hello, one(osync.PROTOCOL_VERSION), cred)
}

f_append :: proc(id: [32]u8, at: i64, data: []u8) -> []u8 {
	return frame(.Append, ids(id), le64(u64(at)), data)
}

f_read :: proc(id: [32]u8, from, to: i64) -> []u8 {
	return frame(.Read, ids(id), le64(u64(from)), le64(u64(to)))
}

f_tail :: proc(id: [32]u8, n: i64) -> []u8 {
	return frame(.Tail, ids(id), le64(u64(n)))
}

Follow_Entry :: struct {
	id:  [32]u8,
	off: u64,
}

f_follow :: proc(watch: bool, entries: ..Follow_Entry) -> []u8 {
	parts := make([dynamic][]u8, context.temp_allocator)
	append(&parts, one(1 if watch else 0), le16(len(entries)))
	for e in entries {
		append(&parts, ids(e.id), le64(e.off))
	}
	return frame(.Follow, ..parts[:])
}

f_idlist :: proc(k: osync.Kind, list: ..[32]u8) -> []u8 {
	parts := make([dynamic][]u8, context.temp_allocator)
	append(&parts, le16(len(list)))
	for id in list {
		append(&parts, ids(id))
	}
	return frame(k, ..parts[:])
}

f_feed :: proc(from: u64, flags: u8 = 0, patterns: ..osync.Feed_Pattern) -> []u8 {
	parts := make([dynamic][]u8, context.temp_allocator)
	append(&parts, le64(from))
	if flags != 0 || len(patterns) > 0 {
		append(&parts, one(flags))
		if flags & osync.FEED_FILTERED != 0 {
			append(&parts, le16(len(patterns)))
			for p in patterns {
				b := p.bytes
				append(&parts, one(u8(p.kind)), cat(b[:32] if p.kind == .Exact else b[:16]))
			}
		}
	}
	return frame(.Feed, ..parts[:])
}

f_redact :: proc(id: [32]u8, from, to: i64) -> []u8 {
	return frame(.Redact, ids(id), le64(u64(from)), le64(u64(to)))
}

f_put :: proc(key: [32]u8, data: []u8) -> []u8 {
	return frame(.Put, ids(key), data)
}

f_note :: proc(id: [32]u8, length: i64) -> []u8 {
	return frame(.Note, ids(id), le64(u64(length)))
}

f_fill :: proc(id: [32]u8, at: i64, data: []u8) -> []u8 {
	return frame(.Fill, ids(id), le64(u64(at)), data)
}

f_trim :: proc(id: [32]u8, base: i64) -> []u8 {
	return frame(.Trim, ids(id), le64(u64(base)))
}

f_pull :: proc(holder: osync.Device_Id, tag: u64, id: [32]u8, from, to: i64) -> []u8 {
	return frame(.Pull, dev16(holder), le64(tag), ids(id), le64(u64(from)), le64(u64(to)))
}

f_serve :: proc(requester: osync.Device_Id, tag: u64, id: [32]u8, at: i64, word: u64, data: []u8) -> []u8 {
	return frame(.Serve, dev16(requester), le64(tag), ids(id), le64(u64(at)), le64(word), data)
}

f_pull_draft :: proc(holder: osync.Device_Id, tag: u64, id: [32]u8, msg, from: u64) -> []u8 {
	return frame(.Pull, dev16(holder), le64(tag), ids(id), le64(osync.PULL_DRAFT | msg), le64(from))
}

f_live :: proc(id: [32]u8, msg, at: u64, data: []u8) -> []u8 {
	return frame(.Live, ids(id), le64(msg), le64(at), data)
}

f_follow_live :: proc(streams: ..[32]u8) -> []u8 {
	parts := make([dynamic][]u8, context.temp_allocator)
	append(&parts, []u8{osync.FOLLOW_LIVE, u8(len(streams)), 0})
	for s in streams {
		append(&parts, ids(s), le64(0))
	}
	return frame(.Follow, ..parts[:])
}

f_unfollow_live :: proc(id: [32]u8) -> []u8 {
	return frame(.Follow, []u8{osync.FOLLOW_LIVE, 1, 0}, ids(id), le64(osync.FOLLOW_END))
}

f_unfollow1 :: proc(id: [32]u8) -> []u8 {
	return frame(.Unfollow, []u8{1, 0}, ids(id))
}

f_direct :: proc(to: osync.Device_Id, tag: u64, payload: []u8) -> []u8 {
	return frame(.Direct, dev16(to), le64(tag), payload)
}

connect :: proc(v: ^Vector, conn: string, local := false) {
	vector_step(v, Step{kind = .Connect, conn = conn, local = local, binding = binding(conn)})
}

send :: proc(v: ^Vector, conn: string, bytes: []u8, comment := "") {
	vector_step(v, Step{kind = .Send, conn = conn, bytes = bytes, comment = comment})
}

durable :: proc(v: ^Vector, comment := "") {
	vector_step(v, Step{kind = .Durable, comment = comment})
}

disconnect :: proc(v: ^Vector, conn: string) {
	vector_step(v, Step{kind = .Close, conn = conn})
}

clock :: proc(v: ^Vector, wall_ms, mono_ms: i64) {
	vector_step(v, Step{kind = .Clock, wall_ms = wall_ms, mono_ms = mono_ms})
}

join :: proc(v: ^Vector, conn: string, sp: ^Space, k: ^Key, proofs: ..[]u8) {
	connect(v, conn)
	send(v, conn, hello(member_cred(sp.id, k, binding(conn), ..proofs)), "Hello")
}

sc_hello :: proc(v: ^Vector) {
	alice, bob, mallory := key_make(1), key_make(2), key_make(4)
	sp := space_make(v, alice, 0x10)
	join(v, "alice", sp, alice, sp.genesis)
	connect(v, "version")
	send(v, "version", frame(.Hello, one(2), member_cred(sp.id, alice, binding("version"))), "Hello with protocol version 2")
	connect(v, "binding")
	send(v, "binding", hello(member_cred(sp.id, alice, binding("other"))), "Hello signed over another connection's binding")
	connect(v, "unknown")
	send(v, "unknown", hello(cat(one(0x09), ids(alice.pub))), "Hello with an unknown credential type")
	connect(v, "stranger")
	send(v, "stranger", hello(member_cred(sp.id, bob, binding("stranger"))), "Hello by a device that is not a member")
	connect(v, "early")
	send(v, "early", frame(.List, le64(0)), "List before Hello")
	connect(v, "empty")
	send(v, "empty", frame(.Hello), "empty Hello")
	connect(v, "local", true)
	bad := member_cred(sp.id, alice, binding("nothing"))
	for i in 1 + 16 + 32 ..< 1 + 16 + 32 + 64 {
		bad[i] = 0
	}
	send(v, "local", hello(bad), "Hello on a local socket with a zero signature")
	forged := forge_add(sp, mallory, mallory)
	connect(v, "forged")
	send(v, "forged", hello(member_cred(sp.id, mallory, binding("forged"), forged)), "Hello whose proof is an Add signed by a non-member")
	send(v, "alice", frame(.Probe, le16(0)), "empty Probe after the rejections")
}

sc_append :: proc(v: ^Vector) {
	alice, bob := key_make(1), key_make(2)
	sp := space_make(v, alice, 0x11)
	join(v, "alice", sp, alice, sp.genesis)
	a1, a2 := stream(alice, 1), stream(alice, 2)
	body := recs(0, "first record", "second record")
	n := i64(len(body))
	send(v, "alice", f_append(a1, 0, body), "Append two records at 0")
	durable(v, "Appended only after the write is durable")
	send(v, "alice", f_append(a1, 0, rec("again", 0)), "Append at a stale offset")
	durable(v, "the conflict re-announces the current length")
	send(v, "alice", f_append(a2, 5, rec("gap", 5)), "Append at a non-zero offset to a new stream")
	send(v, "alice", f_append(a1, n, nil), "zero-length Append at the current length")
	send(v, "alice", f_read(a1, 0, n), "Read the whole stream")
	send(v, "alice", f_read(a1, 4, 30), "Read a sub-range")
	send(v, "alice", f_read(a1, n + 5, n + 9), "Read past the end")
	send(v, "alice", f_tail(a1, 10), "Tail 10 bytes")
	send(v, "alice", f_read(stream(alice, 9), 0, 100), "Read a stream that does not exist")
	send(v, "alice", f_append(stream(bob, 1), 0, rec("not mine", 0)), "Append to another device's stream")
	split := f_append(a1, n, rec("third record", n))
	send(v, "alice", split[:3], "first 3 bytes of an Append")
	send(v, "alice", split[3:50], "header rest and part of the body")
	send(v, "alice", split[50:], "the rest of the body")
	durable(v)
	send(v, "alice", cat(f_read(a1, n, n + 100), f_tail(a1, 1)), "two requests in one delivery")
}

sc_quota :: proc(v: ^Vector) {
	cfg := default_config()
	cfg.quota = 150
	vector_config(v, cfg)
	alice := key_make(1)
	sp := space_make(v, alice, 0x12)
	join(v, "alice", sp, alice, sp.genesis)
	a1 := stream(alice, 1)
	first := rec("0123456789012345678901234567890123456789012345678901234567890123456789", 0)
	send(v, "alice", f_append(a1, 0, first), "Append within quota")
	send(v, "alice", f_append(stream(alice, 2), 0, rec("0123456789012345678901234567890123456789012345678901234567890123456789", 0)), "a second Append while the first is in flight counts the reservation")
	durable(v)
	send(v, "alice", f_put(okey(1), make([]u8, 120, context.temp_allocator)), "Put beyond the quota")
	send(v, "alice", f_put(okey(2), make([]u8, 40, context.temp_allocator)), "Put within the quota")
	durable(v)
	send(v, "alice", frame(.Account), "Account: per-space accounting")
	send(v, "alice", frame(.Account, one(0)), "Account with a payload is malformed")
}

sc_follow :: proc(v: ^Vector) {
	alice, bob := key_make(1), key_make(2)
	sp := space_make(v, alice, 0x13)
	add := space_add(sp, alice, bob, .Member)
	join(v, "alice", sp, alice, sp.genesis)
	join(v, "bob", sp, bob, add)
	a1, a2 := stream(alice, 1), stream(alice, 2)
	r0 := rec("zero", 0)
	send(v, "alice", f_append(a1, 0, r0))
	durable(v)
	send(v, "bob", f_follow(true, {a1, 0}), "Follow with watch from 0")
	r1 := rec("one", i64(len(r0)))
	send(v, "alice", f_append(a1, i64(len(r0)), r1))
	durable(v, "followers get the new bytes")
	send(v, "alice", f_append(a2, 0, rec("new stream", 0)))
	durable(v, "watchers get Created")
	send(v, "bob", f_follow(false, {a2, osync.FOLLOW_END}), "Follow from the end")
	send(v, "alice", f_append(a2, i64(len(rec("new stream", 0))), rec("more", i64(len(rec("new stream", 0))))))
	durable(v)
	send(v, "bob", f_idlist(.Unfollow, a1), "Unfollow")
	l := i64(len(r0) + len(r1))
	send(v, "alice", f_append(a1, l, rec("unseen", l)))
	durable(v, "an unfollowed stream sends nothing")
	send(v, "bob", f_follow(false, {cast([32]u8)osync.reserved_id(osync.FEED_TAG, 0), 0}), "Follow a reserved id")
}

sc_feed :: proc(v: ^Vector) {
	alice, bob := key_make(1), key_make(2)
	sp := space_make(v, alice, 0x14)
	add := space_add(sp, alice, bob, .Member)
	join(v, "alice", sp, alice, sp.genesis)
	a1, a2 := stream(alice, 1), stream(alice, 2)
	r := rec("a", 0)
	send(v, "alice", f_append(a1, 0, r))
	send(v, "alice", f_append(a2, 0, r))
	durable(v)
	join(v, "bob", sp, bob, add)
	send(v, "bob", f_feed(0), "Feed from 0")
	send(v, "alice", f_append(a1, i64(len(r)), rec("b", i64(len(r)))))
	durable(v, "live feed entry")
	join(v, "bob2", sp, bob, add)
	send(v, "bob2", f_feed(40), "resume at an entry boundary")
	join(v, "bob3", sp, bob, add)
	send(v, "bob3", f_feed(45), "resume inside an entry rounds down")
	join(v, "bob4", sp, bob, add)
	send(v, "bob4", f_feed(1 << 40), "resume past the end starts at the end")
	join(v, "bob5", sp, bob, add)
	p: osync.Feed_Pattern
	p.kind = .Exact
	copy(p.bytes[:], ids(a2))
	send(v, "bob5", f_feed(0, osync.FEED_FILTERED, p), "filtered Feed with one exact id")
	q: osync.Feed_Pattern
	q.kind = .Prefix
	d := alice.dev
	copy(q.bytes[:16], d[:])
	send(v, "bob5", f_feed(0, osync.FEED_FILTERED | osync.FEED_ADD, q), "additive filter: no restart")
	send(v, "alice", f_append(a1, 2 * i64(len(r)), rec("c", 2 * i64(len(r)))))
	durable(v, "the additive prefix now matches")
}

sc_list :: proc(v: ^Vector) {
	alice := key_make(1)
	sp := space_make(v, alice, 0x15)
	join(v, "alice", sp, alice, sp.genesis)
	a1, a2 := stream(alice, 1), stream(alice, 2)
	r := rec("a", 0)
	send(v, "alice", f_append(a1, 0, r))
	durable(v)
	send(v, "alice", f_append(a2, 0, r))
	durable(v)
	send(v, "alice", f_append(a1, i64(len(r)), rec("b", i64(len(r)))))
	durable(v)
	send(v, "alice", frame(.List, le64(0)), "List since 0")
	send(v, "alice", frame(.List, le64(80)), "List since the second entry")
}

sc_probe :: proc(v: ^Vector) {
	alice := key_make(1)
	sp := space_make(v, alice, 0x16)
	join(v, "alice", sp, alice, sp.genesis)
	a1, h1 := stream(alice, 1), stream(alice, 3)
	send(v, "alice", f_append(a1, 0, rec("a", 0)))
	send(v, "alice", f_note(h1, 4096))
	durable(v)
	send(v, "alice", f_idlist(.Probe, a1, stream(alice, 9), h1, cast([32]u8)osync.reserved_id(osync.FEED_TAG, 0)), "Probe a stream, an unknown stream, a hollow stream and the feed")
}

sc_objects :: proc(v: ^Vector) {
	alice, carol := key_make(1), key_make(3)
	sp := space_make(v, alice, 0x17)
	add := space_add(sp, alice, carol, .Reader)
	join(v, "alice", sp, alice, sp.genesis)
	join(v, "carol", sp, carol, add)
	data := transmute([]u8)string("an opaque object body")
	send(v, "alice", f_put(okey(1), data), "Put")
	durable(v, "Stored once durable")
	send(v, "alice", f_put(okey(1), data), "Put of an existing key")
	send(v, "carol", f_idlist(.Get, okey(1), okey(2)), "Get an object and a missing key")
	send(v, "carol", f_put(okey(3), data), "Put by a reader")
	send(v, "carol", f_idlist(.Forget, okey(1)), "Forget by a reader")
	send(v, "alice", f_idlist(.Forget, okey(1)), "Forget")
	durable(v)
	send(v, "alice", f_idlist(.Get, okey(1)), "Get after Forget")
}

sc_drop :: proc(v: ^Vector) {
	alice, bob := key_make(1), key_make(2)
	sp := space_make(v, alice, 0x18)
	add := space_add(sp, alice, bob, .Member)
	join(v, "alice", sp, alice, sp.genesis)
	join(v, "bob", sp, bob, add)
	a1, b1 := stream(alice, 1), stream(bob, 1)
	r := rec("a", 0)
	send(v, "alice", f_append(a1, 0, r))
	send(v, "bob", f_append(b1, 0, r))
	durable(v)
	send(v, "bob", f_follow(true, {a1, 0}), "bob follows and watches")
	send(v, "alice", f_append(a1, i64(len(r)), rec("b", i64(len(r)))), "Append in flight")
	send(v, "alice", frame(.Drop, ids(a1)), "Drop while an append is in flight")
	durable(v)
	send(v, "alice", frame(.Drop, ids(b1)), "Drop another device's stream")
	send(v, "alice", frame(.Drop, ids(a1)), "Drop")
	durable(v, "Dropped to the owner after the feed entry is durable, once to bob")
	join(v, "bob2", sp, bob, add)
	send(v, "bob2", f_feed(0), "the feed carries FEED_DROPPED")
	send(v, "bob2", f_read(a1, 0, 100), "Read a dropped stream")
}

sc_redact :: proc(v: ^Vector) {
	alice, bob, carol := key_make(1), key_make(2), key_make(3)
	sp := space_make(v, alice, 0x19)
	addb := space_add(sp, alice, bob, .Member)
	addc := space_add(sp, alice, carol, .Reader)
	join(v, "alice", sp, alice, sp.genesis)
	join(v, "carol", sp, carol, addb, addc)
	a1 := stream(alice, 1)
	r0 := rec("keep me", 0)
	r1 := rec("delete me", i64(len(r0)))
	r2 := rec("keep me too", i64(len(r0) + len(r1)))
	all := cat(r0, r1, r2)
	send(v, "alice", f_append(a1, 0, all))
	durable(v)
	from, to := i64(len(r0)), i64(len(r0) + len(r1))
	send(v, "carol", f_redact(a1, from, to), "Redact by a reader")
	send(v, "alice", f_redact(a1, from + 1, to), "Redact a range that starts inside a record")
	durable(v, "misaligned ranges are refused and nothing changes")
	send(v, "alice", f_redact(a1, from, to), "Redact the middle record")
	durable(v, "Redacted once zero-filled and logged")
	send(v, "alice", f_read(a1, 0, i64(len(all))), "the record keeps its framing, its tag marks it redacted and its body is zero")
	send(v, "alice", f_redact(stream(alice, 7), 0, 10), "Redact a stream that does not exist")
	join(v, "bob", sp, bob, addb)
	send(v, "bob", f_feed(0), "the feed carries the redaction pair")
}

sc_hollow :: proc(v: ^Vector) {
	alice, bob, carol := key_make(1), key_make(2), key_make(3)
	sp := space_make(v, alice, 0x1a)
	addb := space_add(sp, alice, bob, .Member)
	addc := space_add(sp, alice, carol, .Reader)
	join(v, "alice", sp, alice, sp.genesis)
	join(v, "bob", sp, bob, addb)
	join(v, "carol", sp, carol, addc)
	h1 := stream(alice, 3)
	send(v, "alice", f_note(h1, 1000), "Note a device-only segment")
	durable(v)
	send(v, "bob", f_follow(false, {h1, 0}), "Follow a hollow segment")
	send(v, "alice", f_note(h1, 1500), "Note a longer length")
	durable(v, "followers get Hollow")
	send(v, "alice", f_note(h1, 1200), "Note a shorter length")
	fill := make([]u8, 100, context.temp_allocator)
	for i in 0 ..< len(fill) {
		fill[i] = u8(i)
	}
	send(v, "bob", f_fill(h1, 1400, fill), "Fill backward from base by a member")
	durable(v)
	send(v, "alice", f_fill(h1, 1000, fill[:50]), "Fill that does not end at base")
	send(v, "carol", f_fill(h1, 1300, fill), "Fill by a reader")
	send(v, "carol", f_read(h1, 0, 1500), "Read below base is clamped")
	send(v, "alice", f_append(h1, 1500, rec("stored", 1500)), "Append after the stored suffix")
	durable(v)
	send(v, "alice", f_note(h1, 4000), "Note on a segment with stored content")
	send(v, "alice", f_fill(stream(alice, 8), 0, fill), "Fill a segment that does not exist")
}

sc_trim :: proc(v: ^Vector) {
	alice, bob, carol := key_make(1), key_make(2), key_make(3)
	sp := space_make(v, alice, 0x1f)
	addb := space_add(sp, alice, bob, .Member)
	addc := space_add(sp, alice, carol, .Reader)
	join(v, "alice", sp, alice, sp.genesis)
	join(v, "bob", sp, bob, addb)
	join(v, "carol", sp, carol, addc)
	s1 := stream(alice, 3)
	first := recs(0, "archived one", "archived two", "kept three")
	send(v, "alice", f_append(s1, 0, first), "Append three records")
	durable(v)
	b1 := i64(len(rec("archived one", 0)))
	b2 := b1 + i64(len(rec("archived two", b1)))
	length := i64(len(first))
	send(v, "bob", f_follow(false, {s1, 0}), "Follow from 0")
	send(v, "bob", f_trim(s1, b1), "Trim another member's segment")
	send(v, "carol", f_trim(s1, b1), "Trim by a reader")
	send(v, "alice", f_trim(s1, b2), "Trim below the second record boundary")
	durable(v, "Noted once durable")
	send(v, "alice", f_trim(s1, b2), "Trim again at the same base")
	send(v, "alice", f_trim(s1, b1), "Trim below base never lowers it")
	send(v, "alice", f_trim(s1, length), "Trim at the length")
	send(v, "carol", f_read(s1, 0, length), "Read below a trimmed base")
	send(v, "carol", f_idlist(.Probe, s1), "Probe a trimmed segment")
	send(v, "carol", f_follow(false, {s1, 0}), "Follow a trimmed segment from 0")
	send(v, "bob", f_fill(s1, 0, first[:b2]), "Fill below a trim stores nothing")
	send(v, "alice", f_append(s1, length, rec("after trim", length)), "Append after a trim")
	durable(v)
	send(v, "alice", f_redact(s1, 0, length), "Redaction is clamped to the stored suffix")
	durable(v)
	send(v, "alice", f_trim(stream(alice, 9), 10), "Trim a segment that does not exist")
}

sc_pipe :: proc(v: ^Vector) {
	alice, bob, carol := key_make(1), key_make(2), key_make(3)
	sp := space_make(v, alice, 0x1b)
	addb := space_add(sp, alice, bob, .Member)
	join(v, "alice", sp, alice, sp.genesis)
	join(v, "bob", sp, bob, addb)
	h1 := stream(alice, 3)
	send(v, "alice", f_note(h1, 1000))
	durable(v)
	send(v, "bob", f_pull(alice.dev, 7, h1, 0, 1000), "Pull from the writer")
	part := make([]u8, 500, context.temp_allocator)
	for i in 0 ..< len(part) {
		part[i] = u8(i * 7)
	}
	send(v, "alice", f_serve(bob.dev, 7, h1, 0, 1000, part), "Serve the first half")
	send(v, "alice", f_serve(bob.dev, 7, h1, 500, osync.SERVE_FINAL | 1000, part), "Serve the final half")
	send(v, "alice", f_serve(bob.dev, 7, h1, 0, 1000, part[:10]), "Serve after the pipe closed is dropped")
	send(v, "bob", f_pull(carol.dev, 8, h1, 0, 10), "Pull from an absent device")
	send(v, "bob", f_pull(bob.dev, 9, h1, 0, 10), "Pull from yourself")
	send(v, "bob", f_pull(alice.dev, 10, h1, 0, 10), "Pull")
	send(v, "alice", f_serve(bob.dev, 10, h1, 0, osync.SERVE_NONE | 1000, nil), "Serve none")
	send(v, "bob", f_pull(alice.dev, 11, h1, 0, 10), "Pull")
	send(v, "bob", f_pull(alice.dev, 11, h1, 0, 10), "Pull with a tag already open")
	send(v, "alice", f_serve(carol.dev, 11, h1, 0, 1000, part[:4]), "Serve to the wrong requester is dropped")
	disconnect(v, "alice")
}

sc_live :: proc(v: ^Vector) {
	alice, bob, carol := key_make(1), key_make(2), key_make(3)
	sp := space_make(v, alice, 0x21)
	addb := space_add(sp, alice, bob, .Member)
	addc := space_add(sp, alice, carol, .Member)
	join(v, "alice", sp, alice, sp.genesis)
	join(v, "bob", sp, bob, addb)
	join(v, "carol", sp, carol, addc)
	h := stream(alice, 4)
	d1 := rec("draft one", 0)
	d2 := rec("draft two", i64(len(d1)))
	send(v, "alice", f_live(h, 96, 0, d1), "Live with no live followers goes nowhere")
	send(v, "bob", f_follow_live(h), "bob follows alice's segment live: no Length, no storage read")
	send(v, "alice", f_live(h, 96, 0, d1), "Live is forwarded at once as Lived, with no acknowledgement and nothing stored")
	send(v, "carol", f_follow_live(h, h), "carol follows live; a repeated id is registered once")
	send(v, "alice", f_live(h, 96, u64(len(d1)), d2), "Lived to every live follower")
	send(v, "bob", f_live(h, 96, 0, d1), "Live on another device's segment is refused")
	send(v, "bob", f_unfollow1(h), "Unfollow ends read follows only: live interest stays")
	send(v, "alice", f_live(h, 96, 0, d1), "bob and carol still receive it")
	send(v, "bob", f_unfollow_live(h), "a LIVE Follow entry with offset 2^64 - 1 ends live interest")
	send(v, "alice", f_live(h, 96, 0, d1), "only carol still receives it")
	durable(v, "Live writes nothing")
	send(v, "carol", f_pull_draft(alice.dev, 3, h, 96, 0), "a draft pull: from = DRAFT | msg, to = first draft offset wanted")
	both := cat(d1, d2)
	send(v, "alice", f_serve(carol.dev, 3, h, 0, osync.SERVE_FINAL | u64(len(both)), both), "the writer serves its draft through the pipe")
	send(v, "carol", f_pull_draft(alice.dev, 4, h, 97, 0), "a draft pull for a message without a draft")
	send(v, "alice", f_serve(carol.dev, 4, h, 0, osync.SERVE_NONE | osync.SERVE_FINAL, nil), "answered none")
	disconnect(v, "carol")
	send(v, "alice", f_live(h, 96, 0, d1), "a closed connection's live interest is gone")
	send(v, "bob", f_live(stream(bob, 4), osync.DRAFT_MSG_MAX, 0, d1), "msg at or past 2^62 is a protocol error")
}

sc_presence :: proc(v: ^Vector) {
	alice, bob, carol := key_make(1), key_make(2), key_make(3)
	sp := space_make(v, alice, 0x1c)
	addb := space_add(sp, alice, bob, .Member)
	join(v, "alice", sp, alice, sp.genesis)
	send(v, "alice", f_feed(osync.FEED_DROPPED, osync.FEED_PRESENCE), "Feed from the end with presence")
	clock(v, v.cfg.wall_ms + 1000, v.cfg.mono_ms + 1000)
	join(v, "bob", sp, bob, addb)
	send(v, "bob", f_feed(osync.FEED_DROPPED, osync.FEED_PRESENCE), "bob follows presence")
	send(v, "bob", f_direct(alice.dev, 5, transmute([]u8)string("hello alice")), "Direct to a present device")
	send(v, "bob", f_direct(carol.dev, 6, transmute([]u8)string("hello carol")), "Direct to an absent device")
	join(v, "alice2", sp, alice, sp.genesis)
	send(v, "bob", f_direct(alice.dev, 7, transmute([]u8)string("again")), "Direct goes to a connection that follows presence")
	join(v, "bob2", sp, bob, addb)
	disconnect(v, "bob")
	clock(v, v.cfg.wall_ms + 5000, v.cfg.mono_ms + 5000)
	disconnect(v, "bob2")
}

sc_membership :: proc(v: ^Vector) {
	alice, bob, carol, mallory := key_make(1), key_make(2), key_make(3), key_make(4)
	sp := space_make(v, alice, 0x1d)
	m := osync.members_stream(sp.id, alice.dev)
	join(v, "alice", sp, alice, sp.genesis)
	g := rec(string(sp.genesis), 0)
	send(v, "alice", f_append(cast([32]u8)m, 0, g), "alice uploads the genesis to her members stream")
	durable(v)
	addb := space_add(sp, alice, bob, .Member)
	r := rec(string(addb), i64(len(g)))
	send(v, "alice", f_append(cast([32]u8)m, i64(len(g)), r), "alice appends Add(bob)")
	durable(v, "the relay ingests the record")
	join(v, "bob", sp, bob)
	addc := space_add(sp, alice, carol, .Member)
	join(v, "carol", sp, carol, addc)
	forged := forge_add(sp, mallory, mallory)
	join(v, "mallory", sp, mallory, forged)
	rem := space_remove(sp, alice, bob)
	off := i64(len(g) + len(r))
	send(v, "alice", f_append(cast([32]u8)m, off, rec(string(rem), off)), "alice appends Remove(bob)")
	durable(v, "bob is refused on his live connection")
	join(v, "bob2", sp, bob)
}

sc_account :: proc(v: ^Vector) {
	account, laptop, phone := key_make(5), key_make(6), key_make(7)
	ns := osync.account_namespace(account.pub)
	vector_track(v, ns)
	connect(v, "requester")
	send(v, "requester", hello(request_cred(account, laptop, binding("requester"))), "request credential")
	send(v, "requester", f_read(stream(laptop, 1), 0, 10), "a requester cannot read")
	send(v, "requester", f_feed(osync.FEED_DROPPED, osync.FEED_PRESENCE), "a requester may follow presence")
	connect(v, "approver")
	send(v, "approver", hello(account_cred(account, phone, binding("approver"))), "account credential")
	send(v, "approver", f_feed(osync.FEED_DROPPED, osync.FEED_PRESENCE), "the approver follows presence")
	send(v, "requester", f_direct(phone.dev, 1, transmute([]u8)string("REQUEST")), "request to the approver")
	send(v, "approver", f_direct(laptop.dev, 1, transmute([]u8)string("GRANT")), "grant to the requester")
	connect(v, "requester2")
	send(v, "requester2", hello(request_cred(account, laptop, binding("requester2"))), "second requester connection")
	connect(v, "requester3")
	send(v, "requester3", hello(request_cred(account, laptop, binding("requester3"))), "third requester connection")
	connect(v, "badcert")
	c := account_cred(account, phone, binding("badcert"))
	c[40] ~= 1
	send(v, "badcert", hello(c), "account credential with a broken device cert")
}

sc_embedder :: proc(v: ^Vector) {
	alice, bot := key_make(1), key_make(8)
	sp := space_make(v, alice, 0x1e)
	join(v, "alice", sp, alice, sp.genesis)
	a1 := stream(alice, 1)
	send(v, "alice", f_append(a1, 0, rec("visible", 0)))
	durable(v)
	connect(v, "reader")
	send(v, "reader", hello(stub_cred(sp.id, bot, 1)), "embedder credential granting read")
	send(v, "reader", f_read(a1, 0, 100), "read is granted")
	send(v, "reader", f_append(stream(bot, 1), 0, rec("x", 0)), "append is not")
	send(v, "reader", f_put(okey(1), transmute([]u8)string("x")), "objects are not")
	connect(v, "writer")
	send(v, "writer", hello(stub_cred(sp.id, bot, 2 | 4)), "embedder credential granting own appends and objects")
	send(v, "writer", f_append(stream(bot, 1), 0, rec("mine", 0)), "append to its own stream")
	send(v, "writer", f_put(okey(1), transmute([]u8)string("x")), "Put")
	durable(v)
	send(v, "writer", f_read(a1, 0, 100), "read is not granted")
	send(v, "writer", frame(.Account), "Account needs List access")
}

sc_malformed :: proc(v: ^Vector) {
	alice := key_make(1)
	sp := space_make(v, alice, 0x1f)
	a1 := stream(alice, 1)
	cases := [?]struct {
		name:  string,
		bytes: []u8,
	} {
		{"control frame longer than 64 KiB", raw_header(u8(osync.Kind.List), 70000)},
		{"unknown frame kind", frame(osync.Kind(0x55), le64(0))},
		{"relay-to-client kind sent by a client", frame(.Welcome, le64(0))},
		{"Read with a short payload", frame(.Read, ids(a1), le64(0))[:5 + 39]},
		{"Follow count does not match the entries", frame(.Follow, one(0), le16(2), ids(a1), le64(0))},
		{"Redact with to < from", f_redact(a1, 10, 5)},
		{"Append shorter than its fixed part", cat(raw_header(u8(osync.Kind.Append), 10), make([]u8, 10, context.temp_allocator))},
		{"Serve none with bytes", f_serve(alice.dev, 1, a1, 0, osync.SERVE_NONE, transmute([]u8)string("abc"))},
		{"Direct payload over DIRECT_MAX", f_direct(alice.dev, 1, make([]u8, osync.DIRECT_MAX + 1, context.temp_allocator))},
		{"a second Hello", hello(member_cred(sp.id, alice, binding("x")))},
		{"Note longer than 2^62", f_note(a1, i64(1) << 62 + 1)},
		{"Probe count does not match", frame(.Probe, le16(3), ids(a1))},
	}
	for c, i in cases {
		conn := fmt.tprintf("m%d", i)
		join(v, conn, sp, alice, sp.genesis)
		send(v, conn, cat(c.bytes, f_idlist(.Probe, a1)), c.name)
	}
	join(v, "fine", sp, alice, sp.genesis)
	send(v, "fine", f_read(a1, 4, 2), "Read with to < from answers an empty Data")
}

sc_compaction :: proc(v: ^Vector) {
	cfg := default_config()
	cfg.feed_compact = 400
	vector_config(v, cfg)
	alice, bob := key_make(1), key_make(2)
	sp := space_make(v, alice, 0x20)
	addb := space_add(sp, alice, bob, .Member)
	join(v, "alice", sp, alice, sp.genesis)
	join(v, "bob", sp, bob, addb)
	send(v, "bob", f_feed(0), "bob follows the feed from 0")
	lens: [4]i64
	for i in 0 ..< 12 {
		s := u8(i % 4)
		r := rec(fmt.tprintf("record %d", i), lens[s])
		send(v, "alice", f_append(stream(alice, 1 + s), lens[s], r))
		lens[s] += i64(len(r))
		if i == 5 {
			send(v, "alice", f_redact(stream(alice, 2), 0, i64(len(rec("record 1", 0)))), "a redaction before compaction")
		}
		durable(v)
	}
	join(v, "bob2", sp, bob, addb)
	send(v, "bob2", f_feed(0), "a late reader starts at the compacted base")
	send(v, "bob2", frame(.List, le64(0)), "List after compaction")
}

sc_limits :: proc(v: ^Vector) {
	cfg := default_config()
	cfg.principal_conns = 2
	cfg.max_follows = 2
	vector_config(v, cfg)
	alice := key_make(1)
	sp := space_make(v, alice, 0x21)
	join(v, "a1", sp, alice, sp.genesis)
	join(v, "a2", sp, alice, sp.genesis)
	join(v, "a3", sp, alice, sp.genesis)
	send(v, "a1", f_follow(false, {stream(alice, 1), 0}, {stream(alice, 2), 0}, {stream(alice, 3), 0}), "three follows with a limit of two")
	disconnect(v, "a2")
	join(v, "a4", sp, alice, sp.genesis)
}
