package osync

import "base:runtime"
import "core:crypto"
import "core:crypto/argon2id"
import "core:crypto/blake2b"
import "core:crypto/ed25519"
import "../prim"

ACCOUNT_RECORD :: 0x41
ACCOUNT_VERSION :: 1
WRAPPER_SEALED_LEN :: 32 + 16
RECOVERY_SECRET_LEN :: 20
RECOVERY_CREDENTIAL :: "0ndb-recovery"
ACCOUNT_LABEL_MAX :: 128
ACCOUNT_WRAPPERS_MAX :: 64
ACCOUNT_SPACES_MAX :: 4096
RECOVERY_MEMORY_KIB :: 64 * 1024
RECOVERY_PASSES :: 3

Ecosystem :: enum u8 {
	Unknown,
	Apple,
	Google,
	Microsoft,
	One_Password,
	Bitwarden,
	Security_Key,
	Recovery,
	Test,
}

Pool_Access :: enum u8 {
	Off,
	Everything,
	Workspace,
	Only_Sent,
}

Wrapper :: struct {
	credential: []u8,
	label:      string,
	ecosystem:  Ecosystem,
	salt:       [32]u8,
	sealed:     [WRAPPER_SEALED_LEN]u8,
	added_by:   Public_Key,
	added_at:   u64,
}

Account_Space :: struct {
	space:        Space_Id,
	name:         string,
	relay:        string,
	relay_public: Public_Key,
}

Account_Record :: struct {
	sign:         Public_Key,
	box:          Public_Key,
	seq:          u64,
	relay:        string,
	relay_public: Public_Key,
	pool:         Pool_Access,
	pool_sign:    Public_Key,
	pool_box:     Public_Key,
	wrappers:     [dynamic]Wrapper,
	raw:          []u8,
	allocator:    runtime.Allocator,
}

Unlock_Option :: struct {
	credential: []u8,
	salt:       [32]u8,
}

Unlock_Mode :: enum u8 {
	Local,
	Cross_Device,
}

Plug_Reply :: struct {
	record:     []u8,
	entries:    [][]u8,
	credential: []u8,
	prf:        [32]u8,
	ecosystem:  Ecosystem,
	lease_ms:   u64,
}

Plug_Done :: struct {
	data: rawptr,
	call: proc(data: rawptr, err: Error, reply: ^Plug_Reply),
}

Unlock :: struct {
	data:     rawptr,
	unlock:   proc(data: rawptr, rp_user: []u8, options: []Unlock_Option, mode: Unlock_Mode, reply: ^Plug_Reply, done: Plug_Done) -> Error,
	register: proc(data: rawptr, rp_user: []u8, label: string, salt: [32]u8, reply: ^Plug_Reply, done: Plug_Done) -> Error,
	cancel:   proc(data: rawptr, done: Plug_Done),
}

Sealed_Store :: struct {
	data:   rawptr,
	get:    proc(data: rawptr, subject: []u8, reply: ^Plug_Reply, done: Plug_Done) -> Error,
	put:    proc(data: rawptr, subject: []u8, record: []u8, prev_seq: u64, reply: ^Plug_Reply, done: Plug_Done) -> Error,
	add:    proc(data: rawptr, subject: []u8, entry: []u8, reply: ^Plug_Reply, done: Plug_Done) -> Error,
	cancel: proc(data: rawptr, done: Plug_Done),
}

Account_Key :: struct {
	device:  Device,
	keyring: File_Keyring,
	seed:    [32]u8,
}

account_key_new :: proc(a: ^Account_Key, random := prim.Random{}) -> Error {
	prim.random_fill(random, a.seed[:])
	return account_key_from_seed(a, a.seed, random)
}

account_key_from_seed :: proc(a: ^Account_Key, seed: [32]u8, random := prim.Random{}) -> Error {
	a.seed = seed
	d := device_from_seed(a.seed[:]) or_return
	a.device = d
	a.keyring = File_Keyring{device = d, random = random}
	return .None
}

account_key_clear :: proc(a: ^Account_Key) {
	device_clear(&a.device)
	device_clear(&a.keyring.device)
	crypto.zero_explicit(a, size_of(Account_Key))
}

account_keyring :: proc(a: ^Account_Key) -> Keyring {
	return file_keyring(&a.keyring)
}

account_identity :: proc(a: ^Account_Key) -> Identity {
	return device_identity(&a.device)
}

account_signer :: proc(a: ^Account_Key) -> Member_Signer {
	return Member_Signer{data = &a.keyring, public = a.device.public, sign = _fk_sign}
}

@(private)
_account_wrap_key :: proc(secret: []u8, credential: []u8, salt: [32]u8) -> (k: [32]u8) {
	ctx := make([]u8, len(credential) + 32, context.temp_allocator)
	copy(ctx, credential)
	s := salt
	copy(ctx[len(credential):], s[:])
	_derive(secret, "0ndb account wrap", ctx, k[:])
	return
}

wrapper_seal :: proc(w: ^Wrapper, secret: []u8, seed: ^[32]u8) {
	k := _account_wrap_key(secret, w.credential, w.salt)
	defer crypto.zero_explicit(&k, size_of(k))
	aead_seal(k[:], w.credential, seed[:], w.sealed[:])
}

wrapper_open :: proc(w: ^Wrapper, secret: []u8, seed: ^[32]u8) -> bool {
	k := _account_wrap_key(secret, w.credential, w.salt)
	defer crypto.zero_explicit(&k, size_of(k))
	return aead_open(k[:], w.credential, w.sealed[:], seed[:])
}

recovery_secret_new :: proc(random := prim.Random{}) -> (s: [RECOVERY_SECRET_LEN]u8) {
	prim.random_fill(random, s[:])
	return
}

recovery_encode :: proc(s: [RECOVERY_SECRET_LEN]u8, allocator := context.allocator) -> string {
	raw: [RECOVERY_SECRET_LEN + 2]u8
	x := s
	copy(raw[:], x[:])
	sum := _recovery_check(x[:])
	raw[RECOVERY_SECRET_LEN] = sum[0]
	raw[RECOVERY_SECRET_LEN + 1] = sum[1]
	alphabet := B32
	out := make([dynamic]u8, 0, 48, allocator)
	acc: u32
	bits: u32
	n := 0
	for b in raw {
		acc = acc << 8 | u32(b)
		bits += 8
		for bits >= 5 {
			bits -= 5
			if n > 0 && n % 4 == 0 {
				append(&out, '-')
			}
			append(&out, alphabet[(acc >> bits) & 31])
			n += 1
		}
	}
	if bits > 0 {
		append(&out, alphabet[(acc << (5 - bits)) & 31])
	}
	crypto.zero_explicit(&raw, size_of(raw))
	return string(out[:])
}

recovery_decode :: proc(text: string) -> (s: [RECOVERY_SECRET_LEN]u8, err: Error) {
	raw: [RECOVERY_SECRET_LEN + 4]u8
	defer crypto.zero_explicit(&raw, size_of(raw))
	n := 0
	acc: u32
	bits: u32
	for i in 0 ..< len(text) {
		c := text[i]
		switch c {
		case ' ', '-', '\t', '\n', '\r':
			continue
		case 'A' ..= 'Z':
			c += 'a' - 'A'
		}
		switch c {
		case 'o':
			c = '0'
		case 'i', 'l':
			c = '1'
		}
		v := _b32_value(c)
		if v < 0 {
			return {}, .Invalid
		}
		acc = acc << 5 | u32(v)
		bits += 5
		if bits >= 8 {
			bits -= 8
			if n >= len(raw) {
				return {}, .Invalid
			}
			raw[n] = u8(acc >> bits)
			n += 1
		}
	}
	if n != RECOVERY_SECRET_LEN + 2 {
		return {}, .Invalid
	}
	sum := _recovery_check(raw[:RECOVERY_SECRET_LEN])
	if sum[0] != raw[RECOVERY_SECRET_LEN] || sum[1] != raw[RECOVERY_SECRET_LEN + 1] {
		return {}, .Corrupt
	}
	copy(s[:], raw[:RECOVERY_SECRET_LEN])
	return s, .None
}

@(private)
_recovery_check :: proc(data: []u8) -> (sum: [2]u8) {
	ctx: blake2b.Context
	blake2b.init_mac(&ctx, transmute([]u8)string("0ndb recovery"), 2)
	blake2b.update(&ctx, data)
	blake2b.final(&ctx, sum[:])
	return
}

recovery_stretch :: proc(secret: [RECOVERY_SECRET_LEN]u8, salt: [32]u8, out: ^[32]u8) -> Error {
	p := argon2id.Parameters {
		memory_size = RECOVERY_MEMORY_KIB,
		passes      = RECOVERY_PASSES,
		parallelism = 1,
	}
	s, x := secret, salt
	if argon2id.derive(&p, s[:], x[:], out[:], allocator = context.allocator) != nil {
		return .No_Memory
	}
	crypto.zero_explicit(&s, size_of(s))
	return .None
}

account_record_new :: proc(rec: ^Account_Record, a: ^Account_Key, relay: string, relay_public: Public_Key, allocator := context.allocator) {
	rec^ = {
		sign         = a.device.public,
		box          = a.device.noise_public,
		relay        = relay,
		relay_public = relay_public,
		allocator    = allocator,
	}
	rec.wrappers = make([dynamic]Wrapper, allocator)
}

account_record_destroy :: proc(rec: ^Account_Record) {
	delete(rec.wrappers)
	rec^ = {}
}

account_record_encode :: proc(rec: ^Account_Record, a: ^Account_Key, out: ^[dynamic]u8) -> Error {
	if len(rec.wrappers) > ACCOUNT_WRAPPERS_MAX || a.device.public != rec.sign {
		return .Invalid
	}
	w := prim.writer(out)
	prim.write_u8(&w, ACCOUNT_RECORD)
	prim.write_u8(&w, ACCOUNT_VERSION)
	prim.write_raw(&w, rec.sign[:])
	prim.write_raw(&w, rec.box[:])
	prim.write_u64le(&w, rec.seq)
	prim.write_str(&w, rec.relay)
	prim.write_raw(&w, rec.relay_public[:])
	prim.write_u8(&w, u8(rec.pool))
	prim.write_raw(&w, rec.pool_sign[:])
	prim.write_raw(&w, rec.pool_box[:])
	prim.write_uvarint(&w, u64(len(rec.wrappers)))
	for &x in rec.wrappers {
		prim.write_bytes(&w, x.credential)
		prim.write_str(&w, x.label)
		prim.write_u8(&w, u8(x.ecosystem))
		prim.write_raw(&w, x.salt[:])
		prim.write_raw(&w, x.sealed[:])
		prim.write_raw(&w, x.added_by[:])
		prim.write_u64le(&w, x.added_at)
	}
	if w.err != .None {
		return .No_Memory
	}
	msg := make([]u8, len(out) + 16, context.temp_allocator)
	copy(msg, "0ndb account v1\x00")
	copy(msg[16:], out[:])
	sig: [64]u8
	ed25519.sign(&a.device.sign, msg, sig[:])
	prim.write_raw(&w, sig[:])
	return .No_Memory if w.err != .None else .None
}

account_record_decode :: proc(data: []u8, rec: ^Account_Record, allocator := context.allocator) -> Error {
	if len(data) < 64 + 2 {
		return .Corrupt
	}
	body := data[:len(data) - 64]
	r := prim.reader(body)
	if prim.read_u8(&r) != ACCOUNT_RECORD || prim.read_u8(&r) != ACCOUNT_VERSION {
		return .Corrupt
	}
	rec^ = {allocator = allocator, raw = data}
	prim.read_fixed(&r, rec.sign[:])
	prim.read_fixed(&r, rec.box[:])
	rec.seq = prim.read_u64le(&r)
	rec.relay = prim.read_str(&r)
	prim.read_fixed(&r, rec.relay_public[:])
	pa := prim.read_u8(&r)
	prim.read_fixed(&r, rec.pool_sign[:])
	prim.read_fixed(&r, rec.pool_box[:])
	n := prim.read_uvarint(&r)
	if !prim.reader_ok(&r) || pa > u8(max(Pool_Access)) || n > ACCOUNT_WRAPPERS_MAX {
		return .Corrupt
	}
	rec.pool = Pool_Access(pa)
	rec.wrappers = make([dynamic]Wrapper, 0, int(n), allocator)
	for _ in 0 ..< int(n) {
		x: Wrapper
		x.credential = prim.read_bytes(&r)
		x.label = prim.read_str(&r)
		e := prim.read_u8(&r)
		prim.read_fixed(&r, x.salt[:])
		prim.read_fixed(&r, x.sealed[:])
		prim.read_fixed(&r, x.added_by[:])
		x.added_at = prim.read_u64le(&r)
		if !prim.reader_ok(&r) || e > u8(max(Ecosystem)) {
			delete(rec.wrappers)
			return .Corrupt
		}
		x.ecosystem = Ecosystem(e)
		append(&rec.wrappers, x)
	}
	if !prim.reader_ok(&r) || !prim.reader_done(&r) {
		delete(rec.wrappers)
		return .Corrupt
	}
	msg := make([]u8, len(body) + 16, context.temp_allocator)
	copy(msg, "0ndb account v1\x00")
	copy(msg[16:], body)
	if !signature_verify(rec.sign, msg, data[len(data) - 64:]) {
		delete(rec.wrappers)
		return .Auth
	}
	return .None
}

account_unlock_options :: proc(rec: ^Account_Record, allocator := context.temp_allocator) -> []Unlock_Option {
	out := make([dynamic]Unlock_Option, 0, len(rec.wrappers), allocator)
	for &w in rec.wrappers {
		if w.ecosystem != .Recovery {
			append(&out, Unlock_Option{credential = w.credential, salt = w.salt})
		}
	}
	return out[:]
}

account_open_with :: proc(rec: ^Account_Record, credential: []u8, secret: []u8, a: ^Account_Key, random := prim.Random{}) -> Error {
	for &w in rec.wrappers {
		if string(w.credential) != string(credential) {
			continue
		}
		seed: [32]u8
		defer crypto.zero_explicit(&seed, size_of(seed))
		if !wrapper_open(&w, secret, &seed) {
			return .Auth
		}
		account_key_from_seed(a, seed, random) or_return
		if a.device.public != rec.sign {
			account_key_clear(a)
			return .Corrupt
		}
		return .None
	}
	return .Not_Found
}

account_open_recovery :: proc(rec: ^Account_Record, secret: [RECOVERY_SECRET_LEN]u8, a: ^Account_Key, random := prim.Random{}) -> Error {
	for &w in rec.wrappers {
		if w.ecosystem != .Recovery {
			continue
		}
		k: [32]u8
		defer crypto.zero_explicit(&k, size_of(k))
		recovery_stretch(secret, w.salt, &k) or_return
		if account_open_with(rec, w.credential, k[:], a, random) == .None {
			return .None
		}
	}
	return .Auth
}

account_add_wrapper :: proc(rec: ^Account_Record, a: ^Account_Key, credential: []u8, label: string, ecosystem: Ecosystem, salt: [32]u8, secret: []u8, added_by: Public_Key, at: u64, allocator := context.allocator) -> Error {
	if len(rec.wrappers) >= ACCOUNT_WRAPPERS_MAX || len(credential) == 0 || len(credential) > 1024 || len(label) > ACCOUNT_LABEL_MAX {
		return .Invalid
	}
	for i := 0; i < len(rec.wrappers); {
		if string(rec.wrappers[i].credential) == string(credential) {
			ordered_remove(&rec.wrappers, i)
		} else {
			i += 1
		}
	}
	c := make([]u8, len(credential), allocator)
	copy(c, credential)
	l := _clone_string(label, allocator) or_return
	w := Wrapper{credential = c, label = l, ecosystem = ecosystem, salt = salt, added_by = added_by, added_at = at}
	wrapper_seal(&w, secret, &a.seed)
	append(&rec.wrappers, w)
	return .None
}

account_add_recovery :: proc(rec: ^Account_Record, a: ^Account_Key, secret: [RECOVERY_SECRET_LEN]u8, added_by: Public_Key, at: u64, random := prim.Random{}, allocator := context.allocator) -> Error {
	salt: [32]u8
	prim.random_fill(random, salt[:])
	k: [32]u8
	defer crypto.zero_explicit(&k, size_of(k))
	recovery_stretch(secret, salt, &k) or_return
	for i := 0; i < len(rec.wrappers); {
		if rec.wrappers[i].ecosystem == .Recovery {
			ordered_remove(&rec.wrappers, i)
		} else {
			i += 1
		}
	}
	return account_add_wrapper(rec, a, transmute([]u8)string(RECOVERY_CREDENTIAL), "recovery key", .Recovery, salt, k[:], added_by, at, allocator)
}

account_remove_wrapper :: proc(rec: ^Account_Record, credential: []u8) -> bool {
	for w, i in rec.wrappers {
		if string(w.credential) == string(credential) {
			ordered_remove(&rec.wrappers, i)
			return true
		}
	}
	return false
}

Manifest_Entry :: struct {
	space:          Space_Id,
	name:           string,
	relay:          string,
	relay_public:   Public_Key,
	anchor:         Record_Id,
	anchor_lamport: u64,
	author:         Public_Key,
	left:           bool,
}

manifest_entry_encode :: proc(account: Identity, device: ^Keyring, cert: [64]u8, me: Manifest_Entry, out: ^[dynamic]u8, random := prim.Random{}) -> Error {
	plain := make([dynamic]u8, context.temp_allocator)
	w := prim.writer(&plain)
	prim.write_id(&w, prim.Id(me.space))
	prim.write_str(&w, me.name)
	prim.write_str(&w, me.relay)
	x := me
	prim.write_raw(&w, x.relay_public[:])
	prim.write_raw(&w, x.anchor[:])
	prim.write_u64le(&w, me.anchor_lamport)
	if me.left {
		prim.write_u8(&w, 1)
	}
	if w.err != .None {
		return .No_Memory
	}
	id := device.identity(device.data)
	sealed := make([dynamic]u8, context.temp_allocator)
	acc := account
	seal_bundle_to(&acc, plain[:], transmute([]u8)string("0ndb manifest"), &sealed, random) or_return
	ow := prim.writer(out)
	prim.write_raw(&ow, id.sign[:])
	c := cert
	prim.write_raw(&ow, c[:])
	prim.write_bytes(&ow, sealed[:])
	if ow.err != .None {
		return .No_Memory
	}
	sig: [64]u8
	device.sign(device.data, out[:], &sig) or_return
	prim.write_raw(&ow, sig[:])
	return .No_Memory if ow.err != .None else .None
}

manifest_entry_decode :: proc(data: []u8, account: Public_Key, keyring: ^Keyring, me: ^Manifest_Entry, allocator := context.allocator) -> Error {
	if len(data) < 32 + 64 + 64 + 1 {
		return .Corrupt
	}
	body := data[:len(data) - 64]
	r := prim.reader(body)
	prim.read_fixed(&r, me.author[:])
	cert := prim.read_raw(&r, 64)
	sealed := prim.read_bytes(&r)
	if !prim.reader_ok(&r) || !prim.reader_done(&r) {
		return .Corrupt
	}
	if !device_cert_verify(account, me.author, cert) && me.author != account {
		return .Auth
	}
	if !signature_verify(me.author, body, data[len(data) - 64:]) {
		return .Auth
	}
	if len(sealed) <= WRAP_LEN + 16 {
		return .Corrupt
	}
	plain := make([]u8, len(sealed) - WRAP_LEN - 16, allocator)
	open_bundle(keyring, sealed, transmute([]u8)string("0ndb manifest"), plain) or_return
	pr := prim.reader(plain)
	me.space = Space_Id(prim.read_id(&pr))
	me.name = prim.read_str(&pr)
	me.relay = prim.read_str(&pr)
	prim.read_fixed(&pr, me.relay_public[:])
	prim.read_fixed(&pr, me.anchor[:])
	me.anchor_lamport = prim.read_u64le(&pr)
	if prim.reader_remaining(&pr) > 0 {
		me.left = prim.read_u8(&pr) == 1
	}
	if !prim.reader_ok(&pr) || !prim.reader_done(&pr) {
		return .Corrupt
	}
	return .None
}

device_cert :: proc(a: ^Account_Key, device: Public_Key) -> (sig: [64]u8) {
	msg: [17 + 32]u8
	copy(msg[:], "0ndb device cert\x00")
	d := device
	copy(msg[17:], d[:])
	ed25519.sign(&a.device.sign, msg[:], sig[:])
	return
}

device_cert_verify :: proc(account: Public_Key, device: Public_Key, sig: []u8) -> bool {
	msg: [17 + 32]u8
	copy(msg[:], "0ndb device cert\x00")
	d := device
	copy(msg[17:], d[:])
	return signature_verify(account, msg[:], sig)
}

APPROVE_REQUEST :: u8(1)
APPROVE_GRANT :: u8(2)
APPROVE_DENY :: u8(3)
APPROVE_ASK :: u8(4)
APPROVE_TAG :: u64(0x306e_6462_6170_7072)
APPROVE_CODE_LEN :: 8

Approval_Request :: struct {
	card:  [CARD_LEN]u8,
	nonce: [16]u8,
	label: string,
}

approval_code :: proc(card: []u8, nonce: [16]u8) -> (code: [APPROVE_CODE_LEN]u8) {
	h: [8]u8
	ctx: blake2b.Context
	blake2b.init(&ctx, 8)
	blake2b.update(&ctx, transmute([]u8)string("0ndb approval code"))
	blake2b.update(&ctx, card)
	n := nonce
	blake2b.update(&ctx, n[:])
	blake2b.final(&ctx, h[:])
	alphabet := B32
	acc := prim.get_u64le(h[:])
	for i in 0 ..< APPROVE_CODE_LEN {
		code[i] = alphabet[acc & 31]
		acc >>= 5
	}
	return
}

approval_request_encode :: proc(req: ^Approval_Request, out: ^[dynamic]u8) -> Error {
	w := prim.writer(out)
	prim.write_u8(&w, APPROVE_REQUEST)
	prim.write_raw(&w, req.card[:])
	prim.write_raw(&w, req.nonce[:])
	prim.write_str(&w, req.label)
	return .No_Memory if w.err != .None else .None
}

approval_request_decode :: proc(data: []u8, req: ^Approval_Request) -> Error {
	r := prim.reader(data)
	if prim.read_u8(&r) != APPROVE_REQUEST {
		return .Invalid
	}
	prim.read_fixed(&r, req.card[:])
	prim.read_fixed(&r, req.nonce[:])
	req.label = prim.read_str(&r)
	if !prim.reader_ok(&r) || !prim.reader_done(&r) || len(req.label) > ACCOUNT_LABEL_MAX {
		return .Corrupt
	}
	_, err := card_verify(req.card[:])
	return err
}

approval_grant_encode :: proc(req: ^Approval_Request, a: ^Account_Key, out: ^[dynamic]u8, random := prim.Random{}) -> Error {
	id := card_verify(req.card[:]) or_return
	append(out, APPROVE_GRANT)
	ctx := _approve_ctx(req.nonce)
	return seal_bundle_to(&id, a.seed[:], ctx[:], out, random)
}

approval_grant_open :: proc(data: []u8, nonce: [16]u8, keyring: ^Keyring, a: ^Account_Key, random := prim.Random{}) -> Error {
	if len(data) < 1 || data[0] != APPROVE_GRANT {
		return .Invalid
	}
	seed: [32]u8
	defer crypto.zero_explicit(&seed, size_of(seed))
	ctx := _approve_ctx(nonce)
	open_bundle(keyring, data[1:], ctx[:], seed[:]) or_return
	return account_key_from_seed(a, seed, random)
}

@(private)
_approve_ctx :: proc(nonce: [16]u8) -> (ctx: [16 + 16]u8) {
	copy(ctx[:16], "0ndb approval\x00\x00\x00")
	n := nonce
	copy(ctx[16:], n[:])
	return
}

idp_salt :: proc(subject: []u8) -> (salt: [32]u8) {
	ctx: blake2b.Context
	blake2b.init(&ctx, 32)
	blake2b.update(&ctx, transmute([]u8)string("0ndb idp prf salt"))
	blake2b.update(&ctx, subject)
	blake2b.final(&ctx, salt[:])
	return
}
