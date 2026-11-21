#+build darwin
package keystore

import "core:c"
import "core:crypto"

foreign import corefoundation "system:CoreFoundation.framework"
foreign import security "system:Security.framework"

@(private)
_PREFERENCE :: [?]Kind{.Secure_Enclave, .Keychain, .File}

@(private = "file")
Ref :: rawptr

@(private = "file")
NUMBER_SINT32 :: 3
@(private = "file")
STRING_UTF8 :: 0x0800_0100
@(private = "file")
ACCESS_USER_PRESENCE :: c.ulong(1 << 0)
@(private = "file")
ACCESS_PRIVATE_KEY_USAGE :: c.ulong(1 << 30)
@(private = "file")
SERVICE :: "dev.0ndb.keystore"
@(private = "file")
TOKEN_OID :: "toid"
@(private = "file")
KEYCHAIN_DATA_PROTECTION :: 1
@(private = "file")
MAX_SE_PAYLOAD :: 4096

@(private = "file")
ERR_ITEM_NOT_FOUND :: -25300
@(private = "file")
ERR_DUPLICATE_ITEM :: -25299
@(private = "file")
ERR_AUTH_FAILED :: -25293
@(private = "file")
ERR_INTERACTION_NOT_ALLOWED :: -25308
@(private = "file")
ERR_USER_CANCELED :: -128
@(private = "file")
ERR_MISSING_ENTITLEMENT :: -34018
@(private = "file")
ERR_NOT_AVAILABLE :: -25291
@(private = "file")
ERR_ALLOCATE :: -108
@(private = "file")
ERR_DECODE :: -26275
@(private = "file")
ERR_PARAM :: -50
@(private = "file")
ERR_UNIMPLEMENTED :: -4
@(private = "file")
DOMAIN_TOKEN :: "CryptoTokenKit"
@(private = "file")
DOMAIN_LA :: "com.apple.LocalAuthentication"

@(private = "file")
@(default_calling_convention = "c")
foreign corefoundation {
	CFDictionaryCreateMutable :: proc(alloc: Ref, capacity: c.long, keys: rawptr, values: rawptr) -> Ref ---
	CFDictionarySetValue :: proc(dict: Ref, key: Ref, value: Ref) ---
	CFDictionaryGetValue :: proc(dict: Ref, key: Ref) -> Ref ---
	CFDataCreate :: proc(alloc: Ref, bytes: [^]u8, length: c.long) -> Ref ---
	CFDataCreateWithBytesNoCopy :: proc(alloc: Ref, bytes: [^]u8, length: c.long, dealloc: Ref) -> Ref ---
	CFDataGetBytePtr :: proc(data: Ref) -> [^]u8 ---
	CFDataGetLength :: proc(data: Ref) -> c.long ---
	CFDataGetTypeID :: proc() -> c.ulong ---
	CFGetTypeID :: proc(obj: Ref) -> c.ulong ---
	CFStringCreateWithBytes :: proc(alloc: Ref, bytes: [^]u8, n: c.long, encoding: u32, external: b8) -> Ref ---
	CFNumberCreate :: proc(alloc: Ref, type: c.long, value: rawptr) -> Ref ---
	CFErrorGetCode :: proc(err: Ref) -> c.long ---
	CFErrorGetDomain :: proc(err: Ref) -> Ref ---
	CFEqual :: proc(a: Ref, b: Ref) -> b8 ---
	CFRelease :: proc(obj: Ref) ---
	kCFTypeDictionaryKeyCallBacks: u8
	kCFTypeDictionaryValueCallBacks: u8
	kCFBooleanTrue: Ref
	kCFBooleanFalse: Ref
	kCFAllocatorNull: Ref
}

@(private = "file")
@(default_calling_convention = "c")
foreign security {
	SecKeyCreateRandomKey :: proc(params: Ref, err: ^Ref) -> Ref ---
	SecKeyCopyPublicKey :: proc(key: Ref) -> Ref ---
	SecKeyCopyAttributes :: proc(key: Ref) -> Ref ---
	SecKeyCreateWithData :: proc(data: Ref, attrs: Ref, err: ^Ref) -> Ref ---
	SecKeyCreateEncryptedData :: proc(key: Ref, alg: Ref, plaintext: Ref, err: ^Ref) -> Ref ---
	SecKeyCreateDecryptedData :: proc(key: Ref, alg: Ref, ciphertext: Ref, err: ^Ref) -> Ref ---
	SecAccessControlCreateWithFlags :: proc(alloc: Ref, protection: Ref, flags: c.ulong, err: ^Ref) -> Ref ---
	SecItemAdd :: proc(attrs: Ref, result: ^Ref) -> i32 ---
	SecItemCopyMatching :: proc(query: Ref, result: ^Ref) -> i32 ---
	SecItemDelete :: proc(query: Ref) -> i32 ---
	kSecAttrKeyType: Ref
	kSecAttrKeyTypeECSECPrimeRandom: Ref
	kSecAttrKeySizeInBits: Ref
	kSecAttrKeyClass: Ref
	kSecAttrKeyClassPrivate: Ref
	kSecAttrTokenID: Ref
	kSecAttrTokenIDSecureEnclave: Ref
	kSecPrivateKeyAttrs: Ref
	kSecAttrIsPermanent: Ref
	kSecAttrAccessControl: Ref
	kSecAttrAccessible: Ref
	kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly: Ref
	kSecAttrAccessibleWhenUnlockedThisDeviceOnly: Ref
	kSecKeyAlgorithmECIESEncryptionCofactorVariableIVX963SHA256AESGCM: Ref
	kSecClass: Ref
	kSecClassGenericPassword: Ref
	kSecAttrService: Ref
	kSecAttrAccount: Ref
	kSecAttrLabel: Ref
	kSecValueData: Ref
	kSecReturnData: Ref
	kSecMatchLimit: Ref
	kSecMatchLimitOne: Ref
	kSecUseAuthenticationUI: Ref
	kSecUseAuthenticationUIFail: Ref
	kSecUseDataProtectionKeychain: Ref
}

@(private)
_available :: proc(kind: Kind, opts: Options, probe: bool) -> Error {
	#partial switch kind {
	case .Secure_Enclave:
		if !probe {
			return .None
		}
		key := _se_create(opts) or_return
		CFRelease(key)
		return .None
	case .Keychain:
		if opts.user_presence {
			return .Unavailable
		}
		return .None
	}
	return .Unavailable
}

@(private)
_bind :: proc(ks: ^Keystore) {
	#partial switch ks.kind {
	case .Secure_Enclave:
		ks.seal = _se_seal
		ks.unseal = _se_unseal
		ks.forget = _nothing_to_forget
	case .Keychain:
		ks.seal = _kc_seal
		ks.unseal = _kc_unseal
		ks.forget = _kc_forget
	}
}

@(private = "file")
_status_error :: proc(status: c.long) -> Error {
	switch status {
	case 0:
		return .None
	case ERR_ITEM_NOT_FOUND:
		return .Not_Found
	case ERR_AUTH_FAILED, ERR_INTERACTION_NOT_ALLOWED, ERR_USER_CANCELED:
		return .Denied
	case ERR_MISSING_ENTITLEMENT, ERR_NOT_AVAILABLE, ERR_UNIMPLEMENTED:
		return .Unavailable
	case ERR_ALLOCATE:
		return .No_Memory
	case ERR_DECODE, ERR_PARAM:
		return .Corrupt
	}
	return .Io
}

@(private = "file")
_cf_error :: proc(err: Ref) -> Error {
	if err == nil {
		return .Io
	}
	defer CFRelease(err)
	code := CFErrorGetCode(err)
	domain := CFErrorGetDomain(err)
	if _domain_is(domain, DOMAIN_TOKEN) {
		switch code {
		case -3, -8:
			return .Corrupt
		case -4, -5, -9:
			return .Denied
		case -1, -7:
			return .Unavailable
		case -6:
			return .Not_Found
		}
		return .Io
	}
	if _domain_is(domain, DOMAIN_LA) {
		switch code {
		case -5, -6, -7:
			return .Unavailable
		}
		return .Denied
	}
	e := _status_error(code)
	return e == .None ? .Io : e
}

@(private = "file")
_domain_is :: proc(domain: Ref, name: string) -> bool {
	if domain == nil {
		return false
	}
	s := _string(name)
	if s == nil {
		return false
	}
	defer CFRelease(s)
	return bool(CFEqual(domain, s))
}

@(private = "file")
_dict :: proc() -> Ref {
	return CFDictionaryCreateMutable(nil, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks)
}

@(private = "file")
_string :: proc(s: string) -> Ref {
	return CFStringCreateWithBytes(nil, raw_data(s), c.long(len(s)), STRING_UTF8, false)
}

@(private = "file")
_data_view :: proc(b: []u8) -> Ref {
	return CFDataCreateWithBytesNoCopy(nil, raw_data(b), c.long(len(b)), kCFAllocatorNull)
}

@(private = "file")
_data_bytes :: proc(d: Ref) -> []u8 {
	if d == nil || CFGetTypeID(d) != CFDataGetTypeID() {
		return nil
	}
	return CFDataGetBytePtr(d)[:CFDataGetLength(d)]
}

@(private = "file")
_release :: proc(refs: ..Ref) {
	for r in refs {
		if r != nil {
			CFRelease(r)
		}
	}
}

@(private = "file")
_se_create :: proc(opts: Options) -> (key: Ref, err: Error) {
	cferr: Ref
	protection := kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
	flags := ACCESS_PRIVATE_KEY_USAGE
	if opts.user_presence {
		protection = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
		flags |= ACCESS_USER_PRESENCE
	}
	acl := SecAccessControlCreateWithFlags(nil, protection, flags, &cferr)
	if acl == nil {
		return nil, _cf_error(cferr)
	}
	bits := i32(256)
	size := CFNumberCreate(nil, NUMBER_SINT32, &bits)
	private := _dict()
	params := _dict()
	defer _release(acl, size, private, params)
	if size == nil || private == nil || params == nil {
		return nil, .No_Memory
	}
	CFDictionarySetValue(private, kSecAttrIsPermanent, kCFBooleanFalse)
	CFDictionarySetValue(private, kSecAttrAccessControl, acl)
	CFDictionarySetValue(params, kSecAttrKeyType, kSecAttrKeyTypeECSECPrimeRandom)
	CFDictionarySetValue(params, kSecAttrKeySizeInBits, size)
	CFDictionarySetValue(params, kSecAttrTokenID, kSecAttrTokenIDSecureEnclave)
	CFDictionarySetValue(params, kSecPrivateKeyAttrs, private)
	key = SecKeyCreateRandomKey(params, &cferr)
	if key == nil {
		return nil, _cf_error(cferr)
	}
	return key, .None
}

@(private = "file")
_se_restore :: proc(token: []u8) -> (key: Ref, err: Error) {
	toid := _data_view(token)
	name := _string(TOKEN_OID)
	attrs := _dict()
	empty := CFDataCreate(nil, nil, 0)
	defer _release(toid, name, attrs, empty)
	if toid == nil || name == nil || attrs == nil || empty == nil {
		return nil, .No_Memory
	}
	CFDictionarySetValue(attrs, kSecAttrTokenID, kSecAttrTokenIDSecureEnclave)
	CFDictionarySetValue(attrs, name, toid)
	CFDictionarySetValue(attrs, kSecAttrKeyType, kSecAttrKeyTypeECSECPrimeRandom)
	CFDictionarySetValue(attrs, kSecAttrKeyClass, kSecAttrKeyClassPrivate)
	cferr: Ref
	key = SecKeyCreateWithData(empty, attrs, &cferr)
	if key == nil {
		e := _cf_error(cferr)
		return nil, e == .Io ? .Corrupt : e
	}
	return key, .None
}

@(private = "file")
_se_seal :: proc(data: rawptr, label: string, inner: []u8, out: ^[dynamic]u8) -> Error {
	st := (^State)(data)
	key := _se_create(st.opts) or_return
	attrs := SecKeyCopyAttributes(key)
	public := SecKeyCopyPublicKey(key)
	name := _string(TOKEN_OID)
	plain := _data_view(inner)
	defer _release(key, attrs, public, name, plain)
	if attrs == nil || public == nil || name == nil || plain == nil {
		return .Io
	}
	token := _data_bytes(CFDictionaryGetValue(attrs, name))
	if len(token) == 0 || len(token) > 0xFFFF {
		return .Unavailable
	}
	cferr: Ref
	sealed := SecKeyCreateEncryptedData(public, kSecKeyAlgorithmECIESEncryptionCofactorVariableIVX963SHA256AESGCM, plain, &cferr)
	if sealed == nil {
		return _cf_error(cferr)
	}
	defer CFRelease(sealed)
	ct := _data_bytes(sealed)
	if len(ct) == 0 || 2 + len(token) + len(ct) > MAX_SE_PAYLOAD {
		return .Io
	}
	n := [2]u8{u8(len(token)), u8(len(token) >> 8)}
	if _, aerr := append(out, ..n[:]); aerr != nil {
		return .No_Memory
	}
	if _, aerr := append(out, ..token); aerr != nil {
		return .No_Memory
	}
	if _, aerr := append(out, ..ct); aerr != nil {
		return .No_Memory
	}
	return .None
}

@(private = "file")
_se_unseal :: proc(data: rawptr, payload: []u8, out: []u8) -> (n: int, err: Error) {
	if len(payload) < 2 || len(payload) > MAX_SE_PAYLOAD {
		return 0, .Corrupt
	}
	tn := int(payload[0]) | int(payload[1]) << 8
	if tn == 0 || 2 + tn >= len(payload) {
		return 0, .Corrupt
	}
	key := _se_restore(payload[2:2 + tn]) or_return
	ct := _data_view(payload[2 + tn:])
	defer _release(key, ct)
	if ct == nil {
		return 0, .No_Memory
	}
	cferr: Ref
	plain := SecKeyCreateDecryptedData(key, kSecKeyAlgorithmECIESEncryptionCofactorVariableIVX963SHA256AESGCM, ct, &cferr)
	if plain == nil {
		e := _cf_error(cferr)
		return 0, e == .Io ? .Corrupt : e
	}
	defer CFRelease(plain)
	b := _data_bytes(plain)
	defer crypto.zero_explicit(raw_data(b), len(b))
	if len(b) > len(out) {
		return 0, .Corrupt
	}
	return copy(out, b), .None
}

@(private = "file")
_kc_query :: proc(name: []u8, data_protection: bool) -> (query: Ref, err: Error) {
	service := _string(SERVICE)
	account := _string(string(name))
	query = _dict()
	defer _release(service, account)
	if service == nil || account == nil || query == nil {
		_release(query)
		return nil, .No_Memory
	}
	CFDictionarySetValue(query, kSecClass, kSecClassGenericPassword)
	CFDictionarySetValue(query, kSecAttrService, service)
	CFDictionarySetValue(query, kSecAttrAccount, account)
	if data_protection {
		CFDictionarySetValue(query, kSecUseDataProtectionKeychain, kCFBooleanTrue)
	}
	return query, .None
}

@(private = "file")
_kc_add :: proc(name: []u8, inner: []u8, data_protection: bool) -> Error {
	item := _kc_query(name, data_protection) or_return
	value := _data_view(inner)
	label := _string("0ndb device key")
	defer _release(item, value, label)
	if value == nil || label == nil {
		return .No_Memory
	}
	CFDictionarySetValue(item, kSecValueData, value)
	CFDictionarySetValue(item, kSecAttrLabel, label)
	CFDictionarySetValue(item, kSecAttrAccessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
	status := SecItemAdd(item, nil)
	if status == ERR_DUPLICATE_ITEM {
		return .Io
	}
	return _status_error(c.long(status))
}

@(private = "file")
_kc_seal :: proc(data: rawptr, label: string, inner: []u8, out: ^[dynamic]u8) -> Error {
	name: [MAX_NAME]u8
	nn := _item_name(name[:], label)
	flags := u8(KEYCHAIN_DATA_PROTECTION)
	err := _kc_add(name[:nn], inner, true)
	if err == .Unavailable {
		flags = 0
		err = _kc_add(name[:nn], inner, false)
	}
	if err != .None {
		return err
	}
	head := [2]u8{flags, u8(nn)}
	_, e1 := append(out, ..head[:])
	_, e2 := append(out, ..name[:nn])
	if e1 != nil || e2 != nil {
		_ = _kc_delete(name[:nn], flags & KEYCHAIN_DATA_PROTECTION != 0)
		return .No_Memory
	}
	return .None
}

@(private = "file")
_kc_parse :: proc(payload: []u8) -> (name: []u8, data_protection: bool, err: Error) {
	if len(payload) < 2 || payload[0] & ~u8(KEYCHAIN_DATA_PROTECTION) != 0 || 2 + int(payload[1]) != len(payload) {
		return nil, false, .Corrupt
	}
	name = payload[2:]
	if !_name_ok(name) {
		return nil, false, .Corrupt
	}
	return name, payload[0] & KEYCHAIN_DATA_PROTECTION != 0, .None
}

@(private = "file")
_kc_unseal :: proc(data: rawptr, payload: []u8, out: []u8) -> (n: int, err: Error) {
	name, dp := _kc_parse(payload) or_return
	query := _kc_query(name, dp) or_return
	defer CFRelease(query)
	CFDictionarySetValue(query, kSecReturnData, kCFBooleanTrue)
	CFDictionarySetValue(query, kSecMatchLimit, kSecMatchLimitOne)
	CFDictionarySetValue(query, kSecUseAuthenticationUI, kSecUseAuthenticationUIFail)
	result: Ref
	status := SecItemCopyMatching(query, &result)
	if status != 0 {
		return 0, _status_error(c.long(status))
	}
	defer CFRelease(result)
	b := _data_bytes(result)
	defer crypto.zero_explicit(raw_data(b), len(b))
	if len(b) == 0 || len(b) > len(out) {
		return 0, .Corrupt
	}
	return copy(out, b), .None
}

@(private = "file")
_kc_delete :: proc(name: []u8, data_protection: bool) -> Error {
	query := _kc_query(name, data_protection) or_return
	defer CFRelease(query)
	status := SecItemDelete(query)
	if status == ERR_ITEM_NOT_FOUND {
		return .None
	}
	return _status_error(c.long(status))
}

@(private = "file")
_kc_forget :: proc(data: rawptr, payload: []u8) -> Error {
	name, dp := _kc_parse(payload) or_return
	return _kc_delete(name, dp)
}
