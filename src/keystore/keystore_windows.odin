#+build windows
package keystore

import "core:crypto"
import win "core:sys/windows"

foreign import ncrypt "system:ncrypt.lib"
foreign import crypt32 "system:crypt32.lib"

@(private)
_PREFERENCE :: [?]Kind{.Tpm, .Dpapi, .File}

@(private = "file")
Handle :: uintptr

@(private = "file")
Oaep_Padding :: struct {
	alg:       [^]u16,
	label:     [^]u8,
	label_len: u32,
}

@(private = "file")
PAD_OAEP :: 0x4
@(private = "file")
SILENT :: 0x40
@(private = "file")
ALLOW_DECRYPT :: 0x1
@(private = "file")
RSA_BITS :: 2048
@(private = "file")
RSA_BYTES :: RSA_BITS / 8
@(private = "file")
UI_FORBIDDEN :: 0x1
@(private = "file")
DPAPI_ENTROPY :: "0ndb keystore dpapi v1"
@(private = "file")
MAX_DPAPI_PAYLOAD :: 4096

@(private = "file")
NTE_BAD_DATA :: u32(0x8009_0005)
@(private = "file")
NTE_NO_MEMORY :: u32(0x8009_000E)
@(private = "file")
NTE_PERM :: u32(0x8009_0010)
@(private = "file")
NTE_NOT_FOUND :: u32(0x8009_0011)
@(private = "file")
NTE_BAD_KEYSET :: u32(0x8009_0016)
@(private = "file")
NTE_SILENT_CONTEXT :: u32(0x8009_0022)
@(private = "file")
NTE_INVALID_PARAMETER :: u32(0x8009_0027)
@(private = "file")
NTE_USER_CANCELLED :: u32(0x8009_0036)
@(private = "file")
NTE_BUFFER_TOO_SMALL :: u32(0x8009_0028)
@(private = "file")
NTE_PROV_TYPE_NOT_DEF :: u32(0x8009_0017)
@(private = "file")
NTE_KEYSET_NOT_DEF :: u32(0x8009_0019)
@(private = "file")
NTE_PROVIDER_DLL_FAIL :: u32(0x8009_001D)
@(private = "file")
NTE_PROV_DLL_NOT_FOUND :: u32(0x8009_001E)
@(private = "file")
NTE_NOT_SUPPORTED :: u32(0x8009_0029)
@(private = "file")
NTE_DEVICE_NOT_READY :: u32(0x8009_0030)
@(private = "file")
NTE_DEVICE_NOT_FOUND :: u32(0x8009_0035)
@(private = "file")
TBS_BASE :: u32(0x8028_4000)
@(private = "file")
TPM_20_BASE :: u32(0x8028_0000)
@(private = "file")
PCP_BASE :: u32(0x8029_0100)
@(private = "file")
PCP_AUTHENTICATION_FAILED :: u32(0x8029_0108)

@(private = "file")
@(default_calling_convention = "system")
foreign ncrypt {
	NCryptOpenStorageProvider :: proc(provider: ^Handle, name: [^]u16, flags: u32) -> i32 ---
	NCryptCreatePersistedKey :: proc(provider: Handle, key: ^Handle, alg: [^]u16, name: [^]u16, legacy_spec: u32, flags: u32) -> i32 ---
	NCryptOpenKey :: proc(provider: Handle, key: ^Handle, name: [^]u16, legacy_spec: u32, flags: u32) -> i32 ---
	NCryptSetProperty :: proc(object: Handle, property: [^]u16, input: [^]u8, input_len: u32, flags: u32) -> i32 ---
	NCryptGetProperty :: proc(object: Handle, property: [^]u16, output: [^]u8, output_len: u32, result: ^u32, flags: u32) -> i32 ---
	NCryptFinalizeKey :: proc(key: Handle, flags: u32) -> i32 ---
	NCryptEncrypt :: proc(key: Handle, input: [^]u8, input_len: u32, padding: rawptr, output: [^]u8, output_len: u32, result: ^u32, flags: u32) -> i32 ---
	NCryptDecrypt :: proc(key: Handle, input: [^]u8, input_len: u32, padding: rawptr, output: [^]u8, output_len: u32, result: ^u32, flags: u32) -> i32 ---
	NCryptDeleteKey :: proc(key: Handle, flags: u32) -> i32 ---
	NCryptFreeObject :: proc(object: Handle) -> i32 ---
}

@(private = "file")
@(default_calling_convention = "system")
foreign crypt32 {
	CryptProtectData :: proc(input: ^win.DATA_BLOB, description: [^]u16, entropy: ^win.DATA_BLOB, reserved: rawptr, prompt: rawptr, flags: u32, output: ^win.DATA_BLOB) -> win.BOOL ---
	CryptUnprotectData :: proc(input: ^win.DATA_BLOB, description: ^[^]u16, entropy: ^win.DATA_BLOB, reserved: rawptr, prompt: rawptr, flags: u32, output: ^win.DATA_BLOB) -> win.BOOL ---
}

@(private)
_available :: proc(kind: Kind, opts: Options, probe: bool) -> Error {
	if opts.user_presence {
		return .Unavailable
	}
	#partial switch kind {
	case .Tpm:
		prov := _provider() or_return
		defer NCryptFreeObject(prov)
		if !probe {
			return .None
		}
		prop := _wide("PCP_PLATFORM_TYPE")
		buf: [256]u8
		got: u32
		return _status(NCryptGetProperty(prov, &prop[0], &buf[0], size_of(buf), &got, 0))
	case .Dpapi:
		return .None
	}
	return .Unavailable
}

@(private)
_bind :: proc(ks: ^Keystore) {
	#partial switch ks.kind {
	case .Tpm:
		ks.seal = _tpm_win_seal
		ks.unseal = _tpm_win_unseal
		ks.forget = _tpm_win_forget
	case .Dpapi:
		ks.seal = _dpapi_seal
		ks.unseal = _dpapi_unseal
		ks.forget = _nothing_to_forget
	}
}

@(private = "file")
Wide :: [MAX_NAME + 40]u16

@(private = "file")
_wide :: proc(s: string) -> (w: Wide) {
	for i in 0 ..< min(len(s), len(w) - 1) {
		w[i] = u16(s[i])
	}
	return
}

@(private = "file")
_status :: proc(code: i32) -> Error {
	s := u32(code)
	switch {
	case s == 0:
		return .None
	case s == NTE_BAD_KEYSET || s == NTE_NOT_FOUND:
		return .Not_Found
	case s == NTE_PERM || s == NTE_SILENT_CONTEXT || s == NTE_USER_CANCELLED || s == PCP_AUTHENTICATION_FAILED:
		return .Denied
	case s == NTE_NO_MEMORY:
		return .No_Memory
	case s == NTE_BAD_DATA || s == NTE_INVALID_PARAMETER || s == NTE_BUFFER_TOO_SMALL:
		return .Corrupt
	case s & 0xFFFF_F000 == TPM_20_BASE:
		return _tpm_rc_error(s & 0xFFF)
	case s & 0xFFFF_FF00 == PCP_BASE, s & 0xFFFF_F000 == TBS_BASE:
		return .Unavailable
	case s == NTE_PROV_TYPE_NOT_DEF, s == NTE_KEYSET_NOT_DEF, s == NTE_PROVIDER_DLL_FAIL, s == NTE_PROV_DLL_NOT_FOUND:
		return .Unavailable
	case s == NTE_NOT_SUPPORTED, s == NTE_DEVICE_NOT_READY, s == NTE_DEVICE_NOT_FOUND:
		return .Unavailable
	}
	return .Io
}

@(private = "file")
_provider :: proc() -> (prov: Handle, err: Error) {
	name := _wide("Microsoft Platform Crypto Provider")
	if code := NCryptOpenStorageProvider(&prov, &name[0], 0); code != 0 {
		e := _status(code)
		return 0, e == .Io || e == .Not_Found ? .Unavailable : e
	}
	return prov, .None
}

@(private = "file")
_oaep :: proc(alg: ^Wide) -> Oaep_Padding {
	return Oaep_Padding{alg = &alg[0]}
}

@(private = "file")
_tpm_win_create :: proc(prov: Handle, name: []u8) -> (key: Handle, err: Error) {
	wname := _wide(string(name))
	alg := _wide("RSA")
	_status(NCryptCreatePersistedKey(prov, &key, &alg[0], &wname[0], 0, 0)) or_return
	ok := false
	defer if !ok {
		NCryptFreeObject(key)
	}
	bits := u32(RSA_BITS)
	usage := u32(ALLOW_DECRYPT)
	length := _wide("Length")
	key_usage := _wide("Key Usage")
	_status(NCryptSetProperty(key, &length[0], ([^]u8)(&bits), size_of(bits), 0)) or_return
	_status(NCryptSetProperty(key, &key_usage[0], ([^]u8)(&usage), size_of(usage), 0)) or_return
	_status(NCryptFinalizeKey(key, SILENT)) or_return
	ok = true
	return key, .None
}

@(private = "file")
_tpm_win_seal :: proc(data: rawptr, label: string, inner: []u8, out: ^[dynamic]u8) -> Error {
	prov := _provider() or_return
	defer NCryptFreeObject(prov)
	name: [MAX_NAME]u8
	nn := _item_name(name[:], label)
	key := _tpm_win_create(prov, name[:nn]) or_return
	ct: [RSA_BYTES]u8
	got: u32
	hash := _wide("SHA256")
	pad := _oaep(&hash)
	code := NCryptEncrypt(key, raw_data(inner), u32(len(inner)), &pad, &ct[0], size_of(ct), &got, PAD_OAEP | SILENT)
	if code != 0 || got != RSA_BYTES {
		_discard_key(key)
		return code != 0 ? _status(code) : .Io
	}
	head := [1]u8{u8(nn)}
	_, e1 := append(out, ..head[:])
	_, e2 := append(out, ..name[:nn])
	_, e3 := append(out, ..ct[:])
	if e1 != nil || e2 != nil || e3 != nil {
		_discard_key(key)
		return .No_Memory
	}
	NCryptFreeObject(key)
	return .None
}

@(private = "file")
_discard_key :: proc(key: Handle) {
	if NCryptDeleteKey(key, 0) != 0 {
		NCryptFreeObject(key)
	}
}

@(private = "file")
_tpm_win_parse :: proc(payload: []u8) -> (name: []u8, ct: []u8, err: Error) {
	if len(payload) < 1 {
		return nil, nil, .Corrupt
	}
	nn := int(payload[0])
	if 1 + nn + RSA_BYTES != len(payload) || !_name_ok(payload[1:1 + nn]) {
		return nil, nil, .Corrupt
	}
	return payload[1:1 + nn], payload[1 + nn:], .None
}

@(private = "file")
_tpm_win_open :: proc(prov: Handle, name: []u8) -> (key: Handle, err: Error) {
	wname := _wide(string(name))
	_status(NCryptOpenKey(prov, &key, &wname[0], 0, SILENT)) or_return
	return key, .None
}

@(private = "file")
_tpm_win_unseal :: proc(data: rawptr, payload: []u8, out: []u8) -> (n: int, err: Error) {
	name, ct := _tpm_win_parse(payload) or_return
	prov := _provider() or_return
	defer NCryptFreeObject(prov)
	key := _tpm_win_open(prov, name) or_return
	defer NCryptFreeObject(key)
	plain: [RSA_BYTES]u8
	defer crypto.zero_explicit(&plain, size_of(plain))
	got: u32
	hash := _wide("SHA256")
	pad := _oaep(&hash)
	code := NCryptDecrypt(key, raw_data(ct), u32(len(ct)), &pad, &plain[0], size_of(plain), &got, PAD_OAEP | SILENT)
	if code != 0 {
		e := _status(code)
		return 0, e == .Io ? .Corrupt : e
	}
	if int(got) > len(out) {
		return 0, .Corrupt
	}
	return copy(out, plain[:got]), .None
}

@(private = "file")
_tpm_win_forget :: proc(data: rawptr, payload: []u8) -> Error {
	name, _ := _tpm_win_parse(payload) or_return
	prov := _provider() or_return
	defer NCryptFreeObject(prov)
	key, err := _tpm_win_open(prov, name)
	if err == .Not_Found {
		return .None
	}
	if err != .None {
		return err
	}
	if code := NCryptDeleteKey(key, 0); code != 0 {
		NCryptFreeObject(key)
		return _status(code)
	}
	return .None
}

@(private = "file")
_dpapi_error :: proc() -> Error {
	code := win.GetLastError()
	switch code {
	case 5:
		return .Denied
	case 8, 14:
		return .No_Memory
	case 13, 87:
		return .Corrupt
	}
	e := _status(i32(code))
	return e == .Io ? .Corrupt : e
}

@(private = "file")
_dpapi_entropy :: proc() -> win.DATA_BLOB {
	e := DPAPI_ENTROPY
	return win.DATA_BLOB{cbData = u32(len(e)), pbData = raw_data(e)}
}

@(private = "file")
_dpapi_seal :: proc(data: rawptr, label: string, inner: []u8, out: ^[dynamic]u8) -> Error {
	input := win.DATA_BLOB{cbData = u32(len(inner)), pbData = raw_data(inner)}
	entropy := _dpapi_entropy()
	blob: win.DATA_BLOB
	if !CryptProtectData(&input, nil, &entropy, nil, nil, UI_FORBIDDEN, &blob) {
		e := _dpapi_error()
		return e == .Corrupt ? .Io : e
	}
	defer win.LocalFree(blob.pbData)
	if blob.cbData == 0 || blob.cbData > MAX_DPAPI_PAYLOAD {
		return .Io
	}
	if _, aerr := append(out, ..blob.pbData[:blob.cbData]); aerr != nil {
		return .No_Memory
	}
	return .None
}

@(private = "file")
_dpapi_unseal :: proc(data: rawptr, payload: []u8, out: []u8) -> (n: int, err: Error) {
	if len(payload) == 0 || len(payload) > MAX_DPAPI_PAYLOAD {
		return 0, .Corrupt
	}
	input := win.DATA_BLOB{cbData = u32(len(payload)), pbData = raw_data(payload)}
	entropy := _dpapi_entropy()
	blob: win.DATA_BLOB
	if !CryptUnprotectData(&input, nil, &entropy, nil, nil, UI_FORBIDDEN, &blob) {
		return 0, _dpapi_error()
	}
	defer win.LocalFree(blob.pbData)
	plain := blob.pbData[:blob.cbData]
	defer crypto.zero_explicit(raw_data(plain), len(plain))
	if len(plain) > len(out) {
		return 0, .Corrupt
	}
	return copy(out, plain), .None
}
