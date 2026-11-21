package http

import "base:intrinsics"
import "base:runtime"
import "core:slice"
import "core:strconv"
import "core:strings"
import win "core:sys/windows"
import "../prim"

@(private)
HINTERNET :: rawptr

@(private)
_Status_Proc :: #type proc "system" (h: HINTERNET, ctx: uintptr, status: u32, info: rawptr, n: u32)

@(private)
_Wh_Api :: struct {
	module:        win.HMODULE,
	open:          proc "system" (agent: win.wstring, access: u32, proxy: win.wstring, bypass: win.wstring, flags: u32) -> HINTERNET,
	close:         proc "system" (h: HINTERNET) -> win.BOOL,
	connect:       proc "system" (s: HINTERNET, server: win.wstring, port: u16, reserved: u32) -> HINTERNET,
	open_request:  proc "system" (c: HINTERNET, verb: win.wstring, object: win.wstring, version: win.wstring, referrer: win.wstring, accept: rawptr, flags: u32) -> HINTERNET,
	set_callback:  proc "system" (h: HINTERNET, cb: _Status_Proc, flags: u32, reserved: uintptr) -> _Status_Proc,
	set_option:    proc "system" (h: HINTERNET, option: u32, buf: rawptr, n: u32) -> win.BOOL,
	query_option:  proc "system" (h: HINTERNET, option: u32, buf: rawptr, n: ^u32) -> win.BOOL,
	set_timeouts:  proc "system" (h: HINTERNET, resolve: i32, connect: i32, send: i32, receive: i32) -> win.BOOL,
	add_headers:   proc "system" (h: HINTERNET, headers: win.wstring, n: u32, modifiers: u32) -> win.BOOL,
	send_request:  proc "system" (h: HINTERNET, headers: win.wstring, hn: u32, optional: rawptr, on: u32, total: u32, ctx: uintptr) -> win.BOOL,
	write_data:    proc "system" (h: HINTERNET, buf: rawptr, n: u32, written: ^u32) -> win.BOOL,
	receive:       proc "system" (h: HINTERNET, reserved: rawptr) -> win.BOOL,
	query_headers: proc "system" (h: HINTERNET, level: u32, name: win.wstring, buf: rawptr, n: ^u32, index: ^u32) -> win.BOOL,
	read_data:     proc "system" (h: HINTERNET, buf: rawptr, n: u32, read: ^u32) -> win.BOOL,
	read_data_ex:  proc "system" (h: HINTERNET, buf: rawptr, n: u32, read: ^u32, flags: u64, prop_n: u32, prop: rawptr) -> u32,
	query_data:    proc "system" (h: HINTERNET, avail: ^u32) -> win.BOOL,
}

@(private)
_Ca_Api :: struct {
	module:         win.HMODULE,
	open_store:     proc "system" (provider: uintptr, encoding: u32, prov: rawptr, flags: u32, para: rawptr) -> win.HCERTSTORE,
	close_store:    proc "system" (store: win.HCERTSTORE, flags: u32) -> win.BOOL,
	add_encoded:    proc "system" (store: win.HCERTSTORE, encoding: u32, data: [^]u8, n: u32, disposition: u32, out: rawptr) -> win.BOOL,
	string_to_bin:  proc "system" (s: [^]u8, n: u32, flags: u32, out: [^]u8, out_n: ^u32, skip: ^u32, got: ^u32) -> win.BOOL,
	create_engine:  proc "system" (config: ^_Chain_Engine_Config, engine: ^rawptr) -> win.BOOL,
	free_engine:    proc "system" (engine: rawptr),
	get_chain:      proc "system" (engine: rawptr, cert: ^win.CERT_CONTEXT, time: rawptr, extra: win.HCERTSTORE, para: ^_Chain_Para, flags: u32, reserved: rawptr, chain: ^rawptr) -> win.BOOL,
	verify_policy:  proc "system" (policy: uintptr, chain: rawptr, para: ^_Policy_Para, status: ^_Policy_Status) -> win.BOOL,
	free_chain:     proc "system" (chain: rawptr),
	free_cert:      proc "system" (cert: ^win.CERT_CONTEXT) -> win.BOOL,
}

@(private)
_Chain_Engine_Config :: struct {
	size:             u32,
	restricted_root:  win.HCERTSTORE,
	restricted_trust: win.HCERTSTORE,
	restricted_other: win.HCERTSTORE,
	additional_n:     u32,
	additional:       ^win.HCERTSTORE,
	flags:            u32,
	url_timeout:      u32,
	max_cached:       u32,
	cycle_modulus:    u32,
	exclusive_root:   win.HCERTSTORE,
	exclusive_people: win.HCERTSTORE,
	exclusive_flags:  u32,
}

@(private)
_Chain_Para :: struct {
	size:        u32,
	usage_type:  u32,
	usage_n:     u32,
	usage_ids:   ^cstring,
}

@(private)
_Ssl_Policy_Para :: struct {
	size:      u32,
	auth_type: u32,
	checks:    u32,
	server:    win.wstring,
}

@(private)
_Policy_Para :: struct {
	size:  u32,
	flags: u32,
	extra: rawptr,
}

@(private)
_Policy_Status :: struct {
	size:          u32,
	error:         u32,
	chain_index:   i32,
	element_index: i32,
	extra:         rawptr,
}

@(private)
_Async_Result :: struct {
	result: uintptr,
	error:  u32,
}

@(private)
WH_ACCESS_DEFAULT_PROXY :: 0
@(private)
WH_ACCESS_AUTOMATIC_PROXY :: 4
@(private)
WH_FLAG_ASYNC :: 0x10000000
@(private)
WH_FLAG_SECURE :: 0x00800000
@(private)
WH_FLAG_ESCAPE_DISABLE :: 0x40
@(private)
WH_FLAG_ESCAPE_DISABLE_QUERY :: 0x80
@(private)
WH_ADDREQ_ADD :: 0x20000000
@(private)
WH_ADDREQ_REPLACE :: 0x80000000
@(private)
WH_IGNORE_TOTAL_LENGTH :: 0

@(private)
WH_STATUS_SENDING_REQUEST :: 0x00000010
@(private)
WH_STATUS_HANDLE_CLOSING :: 0x00000800
@(private)
WH_STATUS_SECURE_FAILURE :: 0x00010000
@(private)
WH_STATUS_HEADERS_AVAILABLE :: 0x00020000
@(private)
WH_STATUS_DATA_AVAILABLE :: 0x00040000
@(private)
WH_STATUS_READ_COMPLETE :: 0x00080000
@(private)
WH_STATUS_WRITE_COMPLETE :: 0x00100000
@(private)
WH_STATUS_REQUEST_ERROR :: 0x00200000
@(private)
WH_STATUS_SENDREQUEST_COMPLETE :: 0x00400000
@(private)
WH_CALLBACK_FLAGS :: WH_STATUS_HANDLE_CLOSING | WH_STATUS_SECURE_FAILURE | WH_STATUS_HEADERS_AVAILABLE | WH_STATUS_DATA_AVAILABLE | WH_STATUS_READ_COMPLETE | WH_STATUS_WRITE_COMPLETE | WH_STATUS_REQUEST_ERROR | WH_STATUS_SENDREQUEST_COMPLETE

@(private)
WH_OPT_SECURITY_FLAGS :: 31
@(private)
WH_OPT_CONTEXT_VALUE :: 45
@(private)
WH_OPT_DISABLE_FEATURE :: 63
@(private)
WH_OPT_SERVER_CERT_CONTEXT :: 78
@(private)
WH_OPT_REDIRECT_POLICY :: 88
@(private)
WH_OPT_MAX_REDIRECTS :: 89
@(private)
WH_OPT_RECEIVE_RESPONSE_TIMEOUT :: 7
@(private)
WH_OPT_ASSURED_NON_BLOCKING :: 111
@(private)
WH_OPT_ENABLE_PROTOCOL :: 133
@(private)
WH_OPT_PROTOCOL_USED :: 134
@(private)
WH_OPT_TCP_KEEPALIVE :: 152
@(private)
WH_PROTOCOL_HTTP2 :: 0x1
@(private)
WH_DISABLE_COOKIES :: 0x1
@(private)
WH_SECURITY_IGNORE_UNKNOWN_CA :: 0x100
@(private)
WH_QUERY_STATUS_CODE :: 19
@(private)
WH_QUERY_RAW_HEADERS_CRLF :: 22
@(private)
WH_QUERY_FLAG_NUMBER :: 0x20000000

@(private)
WH_ERROR_OUT_OF_HANDLES :: 12001
@(private)
WH_ERROR_TIMEOUT :: 12002
@(private)
WH_ERROR_INVALID_URL :: 12005
@(private)
WH_ERROR_UNRECOGNIZED_SCHEME :: 12006
@(private)
WH_ERROR_NAME_NOT_RESOLVED :: 12007
@(private)
WH_ERROR_OPERATION_CANCELLED :: 12017
@(private)
WH_ERROR_CANNOT_CONNECT :: 12029
@(private)
WH_ERROR_CONNECTION_ERROR :: 12030
@(private)
WH_ERROR_RESEND_REQUEST :: 12032
@(private)
WH_ERROR_HEADER_NOT_FOUND :: 12150
@(private)
WH_ERROR_INVALID_SERVER_RESPONSE :: 12152
@(private)
WH_ERROR_REDIRECT_FAILED :: 12156

@(private)
WH_BUF :: 16 * 1024
@(private)
WH_BUF_POOL :: 4
@(private)
WH_EVENTS :: 8
@(private)
WH_WRITE_MAX :: 1 << 24
@(private)
WH_CHUNK_HEAD :: 10

Winhttp :: struct {
	loop:       ^prim.Loop,
	api:        _Wh_Api,
	ca:         _Ca_Api,
	session:    HINTERNET,
	lock:       win.SRWLOCK,
	ready:      ^Wh_Transfer,
	ready_tail: ^Wh_Transfer,
	signaled:   bool,
	draining:   bool,
	tid:        u32,
	pipe_r:     win.HANDLE,
	pipe_w:     win.HANDLE,
	evt:        win.HANDLE,
	wake:       prim.Watch,
	armed:      bool,
	ca_store:   win.HCERTSTORE,
	ca_engine:  rawptr,
	ca_retired: [dynamic]rawptr,
	ca_stores:  [dynamic]win.HCERTSTORE,
	allocator:  runtime.Allocator,
	live:       map[Id]^Wh_Transfer,
	bufs:       [dynamic][]u8,
	handles:    int,
	next:       u64,
	depth:      int,
}

@(private)
_Wh_Ev :: struct {
	status: u32,
	a:      u32,
	b:      u32,
}

@(private)
Wh_Transfer :: struct {
	owner:      ^Winhttp,
	id:         Id,
	sink:       Sink,
	body:       [][]u8,
	reader:     Body_Reader,
	conn:       HINTERNET,
	req:        HINTERNET,
	host:       win.wstring,
	ca:         rawptr,
	timer:      prim.Timer,
	seg:        int,
	seg_off:    int,
	total:      u32,
	optional:   []u8,
	upbuf:      []u8,
	rbuf:       []u8,
	head_buf:   [dynamic]u8,
	head_idx:   [dynamic][4]u32,
	status:     int,
	length:     i64,
	received:   i64,
	closing:    i32,
	chunked:    bool,
	up_end:     bool,
	trailer:    bool,
	paused:     bool,
	head_ready: bool,
	head_sent:  bool,
	no_body:    bool,
	dead:       bool,
	evs:        [WH_EVENTS]_Wh_Ev,
	ev_n:       int,
	queued:     bool,
	closed:     bool,
	overflow:   bool,
	ca_failed:  bool,
	secure:     u32,
	next:       ^Wh_Transfer,
}

@(private)
_wh_sym :: proc(m: win.HMODULE, name: cstring, out: ^$T) -> bool {
	p := win.GetProcAddress(m, name)
	if p == nil {
		return false
	}
	out^ = (T)(p)
	return true
}

@(private)
_wh_module :: proc(name: string) -> win.HMODULE {
	w := win.utf8_to_wstring(name, context.temp_allocator)
	if m := win.GetModuleHandleW(w); m != nil {
		return m
	}
	return win.LoadLibraryExW(w, nil, {.LOAD_LIBRARY_SEARCH_SYSTEM32})
}

@(private)
_wh_load :: proc(a: ^_Wh_Api) -> bool {
	m := _wh_module("winhttp.dll")
	if m == nil {
		return false
	}
	a.module = m
	ok := _wh_sym(m, "WinHttpOpen", &a.open)
	ok &&= _wh_sym(m, "WinHttpCloseHandle", &a.close)
	ok &&= _wh_sym(m, "WinHttpConnect", &a.connect)
	ok &&= _wh_sym(m, "WinHttpOpenRequest", &a.open_request)
	ok &&= _wh_sym(m, "WinHttpSetStatusCallback", &a.set_callback)
	ok &&= _wh_sym(m, "WinHttpSetOption", &a.set_option)
	ok &&= _wh_sym(m, "WinHttpQueryOption", &a.query_option)
	ok &&= _wh_sym(m, "WinHttpSetTimeouts", &a.set_timeouts)
	ok &&= _wh_sym(m, "WinHttpAddRequestHeaders", &a.add_headers)
	ok &&= _wh_sym(m, "WinHttpSendRequest", &a.send_request)
	ok &&= _wh_sym(m, "WinHttpWriteData", &a.write_data)
	ok &&= _wh_sym(m, "WinHttpReceiveResponse", &a.receive)
	ok &&= _wh_sym(m, "WinHttpQueryHeaders", &a.query_headers)
	ok &&= _wh_sym(m, "WinHttpReadData", &a.read_data)
	ok &&= _wh_sym(m, "WinHttpQueryDataAvailable", &a.query_data)
	_wh_sym(m, "WinHttpReadDataEx", &a.read_data_ex)
	return ok
}

@(private)
_wh_load_ca :: proc(a: ^_Ca_Api) -> bool {
	if a.module != nil {
		return true
	}
	m := _wh_module("crypt32.dll")
	if m == nil {
		return false
	}
	ok := _wh_sym(m, "CertOpenStore", &a.open_store)
	ok &&= _wh_sym(m, "CertCloseStore", &a.close_store)
	ok &&= _wh_sym(m, "CertAddEncodedCertificateToStore", &a.add_encoded)
	ok &&= _wh_sym(m, "CryptStringToBinaryA", &a.string_to_bin)
	ok &&= _wh_sym(m, "CertCreateCertificateChainEngine", &a.create_engine)
	ok &&= _wh_sym(m, "CertFreeCertificateChainEngine", &a.free_engine)
	ok &&= _wh_sym(m, "CertGetCertificateChain", &a.get_chain)
	ok &&= _wh_sym(m, "CertVerifyCertificateChainPolicy", &a.verify_policy)
	ok &&= _wh_sym(m, "CertFreeCertificateChain", &a.free_chain)
	ok &&= _wh_sym(m, "CertFreeCertificateContext", &a.free_cert)
	if ok {
		a.module = m
	}
	return ok
}

winhttp_init :: proc(h: ^Winhttp, l: ^prim.Loop, allocator := context.allocator) -> bool {
	h^ = {}
	h.loop = l
	h.allocator = allocator
	if !_wh_load(&h.api) {
		return false
	}
	agent := win.utf8_to_wstring("0ndb", context.temp_allocator)
	h.session = h.api.open(agent, WH_ACCESS_AUTOMATIC_PROXY, nil, nil, WH_FLAG_ASYNC)
	if h.session == nil {
		h.session = h.api.open(agent, WH_ACCESS_DEFAULT_PROXY, nil, nil, WH_FLAG_ASYNC)
	}
	if h.session == nil {
		return false
	}
	h2 := u32(WH_PROTOCOL_HTTP2)
	h.api.set_option(h.session, WH_OPT_ENABLE_PROTOCOL, &h2, size_of(h2))
	assured := win.BOOL(true)
	h.api.set_option(h.session, WH_OPT_ASSURED_NON_BLOCKING, &assured, size_of(assured))
	keepalive := [3]u32{1, 30_000, 15_000}
	h.api.set_option(h.session, WH_OPT_TCP_KEEPALIVE, &keepalive, size_of(keepalive))
	if !_wh_set_callback(h) {
		h.api.close(h.session)
		h^ = {}
		return false
	}
	h.tid = win.GetCurrentThreadId()
	h.evt = win.CreateEventW(nil, false, false, nil)
	if h.evt == nil || !_wh_pipe_open(h) {
		if h.evt != nil {
			win.CloseHandle(h.evt)
		}
		h.api.close(h.session)
		h^ = {}
		return false
	}
	h.live = make(map[Id]^Wh_Transfer, allocator)
	h.bufs = make([dynamic][]u8, allocator)
	h.ca_retired = make([dynamic]rawptr, allocator)
	h.ca_stores = make([dynamic]win.HCERTSTORE, allocator)
	_wh_arm(h)
	return true
}

@(private)
_wh_set_callback :: proc(h: ^Winhttp) -> bool {
	flags := u32(WH_CALLBACK_FLAGS)
	if h.ca_engine != nil {
		flags |= WH_STATUS_SENDING_REQUEST
	}
	prev := h.api.set_callback(h.session, _wh_on_status, flags, 0)
	return transmute(uintptr)prev != max(uintptr)
}

@(private)
_wh_pipe_open :: proc(h: ^Winhttp) -> bool {
	for attempt in 0 ..< 4 {
		rnd: [8]u8
		runtime.rand_bytes(rnd[:])
		name := strings.concatenate({"\\\\.\\pipe\\0ndb-http-", _wh_hex(u64(win.GetCurrentProcessId())), "-", _wh_hex(transmute(u64)rnd)}, context.temp_allocator)
		wname := win.utf8_to_wstring(name, context.temp_allocator)
		r := win.CreateNamedPipeW(wname, win.PIPE_ACCESS_INBOUND | win.FILE_FLAG_OVERLAPPED | win.FILE_FLAG_FIRST_PIPE_INSTANCE, win.PIPE_TYPE_BYTE | win.PIPE_READMODE_BYTE | win.PIPE_WAIT | win.PIPE_REJECT_REMOTE_CLIENTS, 1, 64, 64, 0, nil)
		if r == win.INVALID_HANDLE_VALUE {
			if attempt < 3 {
				continue
			}
			return false
		}
		w := win.CreateFileW(wname, win.GENERIC_WRITE, 0, nil, win.OPEN_EXISTING, 0, nil)
		if w == win.INVALID_HANDLE_VALUE {
			win.CloseHandle(r)
			return false
		}
		wt, err := prim.watch_overlapped(h.loop, prim.Fd(i32(int(uintptr(r)))), h, _wh_on_wake)
		if err != .None {
			win.CloseHandle(w)
			win.CloseHandle(r)
			return false
		}
		h.pipe_r = r
		h.pipe_w = w
		h.wake = wt
		return true
	}
	return false
}

@(private)
_wh_hex :: proc(v: u64) -> string {
	buf := make([]u8, 16, context.temp_allocator)
	digits := "0123456789abcdef"
	for i in 0 ..< 16 {
		buf[i] = digits[(v >> u64(60 - 4 * i)) & 0xF]
	}
	return string(buf)
}

@(private)
_wh_arm :: proc(h: ^Winhttp) {
	if h.armed || h.wake == 0 {
		return
	}
	op, err := prim.overlapped_begin(h.loop, h.wake, 16)
	if err != .None {
		return
	}
	ok := win.ReadFile(h.pipe_r, raw_data(op.buf), 16, nil, (^win.OVERLAPPED)(prim.overlapped_ptr(op)))
	if prim.overlapped_submit(h.loop, op, bool(ok)) == .None {
		h.armed = true
	}
}

@(private)
_wh_on_wake :: proc(l: ^prim.Loop, w: prim.Watch, op: ^prim.Overlapped_Op, bytes: int, err: prim.Error, data: rawptr) {
	h := (^Winhttp)(data)
	h.armed = false
	if err != .None {
		return
	}
	_wh_pump(h)
	_wh_arm(h)
}

@(private)
_wh_on_status :: proc "system" (hi: HINTERNET, ctx: uintptr, status: u32, info: rawptr, n: u32) {
	if ctx == 0 {
		return
	}
	t := (^Wh_Transfer)(ctx)
	h := t.owner
	ev := _Wh_Ev {
		status = status,
	}
	switch status {
	case WH_STATUS_SENDING_REQUEST:
		if t.ca != nil {
			_wh_ca_check(h, t, hi)
		}
		return
	case WH_STATUS_SECURE_FAILURE, WH_STATUS_WRITE_COMPLETE, WH_STATUS_DATA_AVAILABLE:
		if info != nil {
			ev.a = (^u32)(info)^
		}
	case WH_STATUS_REQUEST_ERROR:
		if info != nil {
			r := (^_Async_Result)(info)
			ev.a = r.error
			ev.b = u32(r.result)
		}
	case WH_STATUS_READ_COMPLETE:
		ev.a = n
	case WH_STATUS_HANDLE_CLOSING, WH_STATUS_SENDREQUEST_COMPLETE, WH_STATUS_HEADERS_AVAILABLE:
	case:
		return
	}
	win.AcquireSRWLockExclusive(&h.lock)
	switch status {
	case WH_STATUS_HANDLE_CLOSING:
		t.closed = true
	case WH_STATUS_SECURE_FAILURE:
		t.secure |= ev.a
	case:
		if t.ev_n < len(t.evs) {
			t.evs[t.ev_n] = ev
			t.ev_n += 1
		} else {
			t.overflow = true
		}
	}
	if !t.queued {
		t.queued = true
		t.next = nil
		if h.ready_tail != nil {
			h.ready_tail.next = t
		} else {
			h.ready = t
		}
		h.ready_tail = t
	}
	if h.draining {
		win.SetEvent(h.evt)
	} else if !h.signaled && win.GetCurrentThreadId() != h.tid {
		h.signaled = true
		one := u8(1)
		wrote: u32
		win.WriteFile(h.pipe_w, &one, 1, &wrote, nil)
	}
	win.ReleaseSRWLockExclusive(&h.lock)
}

@(private)
_wh_ca_check :: proc "system" (h: ^Winhttp, t: ^Wh_Transfer, hi: HINTERNET) {
	ok := false
	cert: ^win.CERT_CONTEXT
	n := u32(size_of(cert))
	if bool(h.api.query_option(hi, WH_OPT_SERVER_CERT_CONTEXT, &cert, &n)) && cert != nil {
		para := _Chain_Para {
			size = size_of(_Chain_Para),
		}
		chain: rawptr
		if bool(h.ca.get_chain(t.ca, cert, nil, cert.hCertStore, &para, 0, nil, &chain)) && chain != nil {
			ssl := _Ssl_Policy_Para {
				size      = size_of(_Ssl_Policy_Para),
				auth_type = 2,
				server    = t.host,
			}
			pp := _Policy_Para {
				size  = size_of(_Policy_Para),
				extra = &ssl,
			}
			st := _Policy_Status {
				size = size_of(_Policy_Status),
			}
			if bool(h.ca.verify_policy(4, chain, &pp, &st)) && st.error == 0 {
				ok = true
			}
			h.ca.free_chain(chain)
		}
		h.ca.free_cert(cert)
	}
	if ok {
		return
	}
	win.AcquireSRWLockExclusive(&h.lock)
	t.ca_failed = true
	win.ReleaseSRWLockExclusive(&h.lock)
	if intrinsics.atomic_compare_exchange_strong(&t.closing, 0, 1) == 0 {
		h.api.close(hi)
	}
}

winhttp_ca_file :: proc(h: ^Winhttp, path: string) {
	if h.session == nil {
		return
	}
	if h.ca_engine != nil {
		append(&h.ca_retired, h.ca_engine)
		h.ca_engine = nil
	}
	if h.ca_store != nil {
		append(&h.ca_stores, h.ca_store)
		h.ca_store = nil
	}
	if path == "" {
		_wh_set_callback(h)
		return
	}
	if !_wh_load_ca(&h.ca) {
		return
	}
	data, err := prim.read_file(prim.os_vfs(), path, context.temp_allocator)
	if err != .None {
		return
	}
	h.ca_store = h.ca.open_store(2, 0, nil, 0, nil)
	if h.ca_store == nil {
		_wh_set_callback(h)
		return
	}
	begin := "-----BEGIN CERTIFICATE-----"
	end := "-----END CERTIFICATE-----"
	rest := string(data)
	added := 0
	for {
		i := strings.index(rest, begin)
		if i < 0 {
			break
		}
		j := strings.index(rest[i:], end)
		if j < 0 {
			break
		}
		block := rest[i:i + j + len(end)]
		rest = rest[i + j + len(end):]
		need: u32
		if !bool(h.ca.string_to_bin(raw_data(block), u32(len(block)), 0, nil, &need, nil, nil)) || need == 0 {
			continue
		}
		der := make([]u8, int(need), context.temp_allocator)
		if !h.ca.string_to_bin(raw_data(block), u32(len(block)), 0, raw_data(der), &need, nil, nil) {
			continue
		}
		if h.ca.add_encoded(h.ca_store, 0x10001, raw_data(der), need, 4, nil) {
			added += 1
		}
	}
	if added == 0 {
		_wh_set_callback(h)
		return
	}
	cfg := _Chain_Engine_Config {
		size           = size_of(_Chain_Engine_Config),
		exclusive_root = h.ca_store,
	}
	engine: rawptr
	if !h.ca.create_engine(&cfg, &engine) {
		_wh_set_callback(h)
		return
	}
	h.ca_engine = engine
	_wh_set_callback(h)
}

winhttp_destroy :: proc(h: ^Winhttp) {
	if h.session == nil {
		h^ = {}
		return
	}
	ids := make([dynamic]Id, context.temp_allocator)
	for id in h.live {
		append(&ids, id)
	}
	slice.sort(ids[:])
	for id in ids {
		winhttp_cancel(h, id)
	}
	win.AcquireSRWLockExclusive(&h.lock)
	h.draining = true
	win.ReleaseSRWLockExclusive(&h.lock)
	deadline := prim.mono_ns() + 5_000_000_000
	for {
		_wh_pump(h)
		if h.handles == 0 || prim.mono_ns() > deadline {
			break
		}
		win.WaitForSingleObject(h.evt, 50)
	}
	if h.wake != 0 {
		prim.unwatch(h.loop, h.wake)
	}
	win.CloseHandle(h.pipe_w)
	win.CloseHandle(h.pipe_r)
	h.api.set_callback(h.session, nil, 0, 0)
	h.api.close(h.session)
	win.CloseHandle(h.evt)
	if h.ca_engine != nil {
		append(&h.ca_retired, h.ca_engine)
	}
	for e in h.ca_retired {
		h.ca.free_engine(e)
	}
	if h.ca_store != nil {
		append(&h.ca_stores, h.ca_store)
	}
	for st in h.ca_stores {
		h.ca.close_store(st, 0)
	}
	for b in h.bufs {
		delete(b, h.allocator)
	}
	delete(h.bufs)
	delete(h.live)
	delete(h.ca_retired)
	delete(h.ca_stores)
	h^ = {}
}

winhttp_client :: proc(h: ^Winhttp) -> Client {
	return Client{data = h, start = _wh_start_proc, cancel = _wh_cancel_proc, resume = _wh_resume_proc}
}

winhttp_active :: proc(h: ^Winhttp) -> int {
	return len(h.live)
}

winhttp_sockets :: proc(h: ^Winhttp) -> int {
	return len(h.live)
}

winhttp_version :: proc(h: ^Winhttp, id: Id) -> Version {
	t, ok := h.live[id]
	if !ok || t.req == nil {
		return .Auto
	}
	flags: u32
	n := u32(size_of(flags))
	if !h.api.query_option(t.req, WH_OPT_PROTOCOL_USED, &flags, &n) {
		return .Auto
	}
	return .Http2 if flags & WH_PROTOCOL_HTTP2 != 0 else .Http1
}

@(private)
_wh_start_proc :: proc(data: rawptr, req: ^Request, sink: Sink) -> (Id, Error) {
	return winhttp_start((^Winhttp)(data), req, sink)
}

@(private)
_wh_cancel_proc :: proc(data: rawptr, id: Id) {
	winhttp_cancel((^Winhttp)(data), id)
}

@(private)
_wh_resume_proc :: proc(data: rawptr, id: Id) {
	winhttp_resume((^Winhttp)(data), id)
}

@(private)
_Wh_Url :: struct {
	secure: bool,
	host:   string,
	port:   u16,
	object: string,
}

@(private)
_wh_parse_url :: proc(url: string) -> (u: _Wh_Url, ok: bool) {
	rest: string
	switch {
	case len(url) >= 8 && strings.equal_fold(url[:8], "https://"):
		u.secure = true
		u.port = 443
		rest = url[8:]
	case len(url) >= 7 && strings.equal_fold(url[:7], "http://"):
		u.port = 80
		rest = url[7:]
	case:
		return
	}
	end := len(rest)
	for c, i in transmute([]u8)rest {
		if c == '/' || c == '?' || c == '#' {
			end = i
			break
		}
	}
	auth := rest[:end]
	path := rest[end:]
	if hash := strings.index_byte(path, '#'); hash >= 0 {
		path = path[:hash]
	}
	if len(auth) == 0 || strings.index_byte(auth, '@') >= 0 {
		return
	}
	port_s := ""
	if auth[0] == '[' {
		close := strings.index_byte(auth, ']')
		if close < 0 {
			return
		}
		u.host = auth[1:close]
		tail := auth[close + 1:]
		if len(tail) > 0 {
			if tail[0] != ':' {
				return
			}
			port_s = tail[1:]
		}
	} else if colon := strings.last_index_byte(auth, ':'); colon >= 0 {
		u.host = auth[:colon]
		port_s = auth[colon + 1:]
	} else {
		u.host = auth
	}
	if len(u.host) == 0 {
		return
	}
	if len(port_s) > 0 {
		p, pok := strconv.parse_u64_of_base(port_s, 10)
		if !pok || p == 0 || p > 65535 {
			return
		}
		u.port = u16(p)
	}
	u.object = path
	if len(path) == 0 || path[0] != '/' {
		u.object = strings.concatenate({"/", path}, context.temp_allocator)
	}
	return u, true
}

winhttp_start :: proc(h: ^Winhttp, req: ^Request, sink: Sink) -> (Id, Error) {
	u, uok := _wh_parse_url(req.url)
	if !uok {
		return 0, .Unsupported
	}
	t := new(Wh_Transfer, h.allocator)
	if t == nil {
		return 0, .No_Memory
	}
	h.next += 1
	t.owner = h
	t.id = Id(h.next)
	t.sink = sink
	t.body = req.body
	t.reader = req.reader
	t.length = -1
	t.head_buf = make([dynamic]u8, h.allocator)
	t.head_idx = make([dynamic][4]u32, h.allocator)
	t.ca = h.ca_engine
	h.handles += 1
	has_body := len(req.body) > 0 || req.reader.read != nil || req.method == "POST" || req.method == "PUT" || req.method == "PATCH"
	verb := req.method
	if verb == "" {
		verb = has_body ? "POST" : "GET"
	}
	t.no_body = verb == "HEAD"
	ta := context.temp_allocator
	host := win.utf8_to_wstring(u.host, h.allocator)
	if host == nil {
		_wh_release(h, t)
		return 0, .Unsupported
	}
	t.host = host
	t.conn = h.api.connect(h.session, host, u.port, 0)
	if t.conn == nil {
		err := _wh_map(win.GetLastError(), false)
		_wh_release(h, t)
		return 0, err
	}
	flags := u32(WH_FLAG_ESCAPE_DISABLE | WH_FLAG_ESCAPE_DISABLE_QUERY)
	if u.secure {
		flags |= WH_FLAG_SECURE
	}
	t.req = h.api.open_request(t.conn, win.utf8_to_wstring(verb, ta), win.utf8_to_wstring(u.object, ta), nil, nil, nil, flags)
	if t.req == nil {
		err := _wh_map(win.GetLastError(), false)
		_wh_release(h, t)
		return 0, err
	}
	ctx := uintptr(rawptr(t))
	if !h.api.set_option(t.req, WH_OPT_CONTEXT_VALUE, &ctx, size_of(ctx)) {
		_wh_release(h, t)
		return 0, .Other
	}
	t.chunked = req.reader.read != nil && req.body_len <= 0
	policy := u32(2 if req.follow else 0)
	h.api.set_option(t.req, WH_OPT_REDIRECT_POLICY, &policy, size_of(policy))
	if req.follow {
		maxr := u32(10)
		h.api.set_option(t.req, WH_OPT_MAX_REDIRECTS, &maxr, size_of(maxr))
	}
	feature := u32(WH_DISABLE_COOKIES)
	h.api.set_option(t.req, WH_OPT_DISABLE_FEATURE, &feature, size_of(feature))
	if req.version == .Http1 || t.chunked || (!u.secure && req.version == .Http2_Prior_Knowledge) {
		none := u32(0)
		h.api.set_option(t.req, WH_OPT_ENABLE_PROTOCOL, &none, size_of(none))
	}
	if t.ca != nil {
		sec := u32(WH_SECURITY_IGNORE_UNKNOWN_CA)
		h.api.set_option(t.req, WH_OPT_SECURITY_FLAGS, &sec, size_of(sec))
	}
	connect := i32(min(req.connect_ms, i64(max(i32)))) if req.connect_ms > 0 else 300_000
	stall := i32(min(req.stall_ms, i64(max(i32)))) if req.stall_ms > 0 else 0
	h.api.set_timeouts(t.req, 0, connect, stall, stall)
	resp := u32(stall)
	h.api.set_option(t.req, WH_OPT_RECEIVE_RESPONSE_TIMEOUT, &resp, size_of(resp))
	for hd in req.headers {
		line := win.utf8_to_wstring(strings.concatenate({hd.name, ": ", hd.value}, ta), ta)
		if line == nil || !bool(h.api.add_headers(t.req, line, max(u32), WH_ADDREQ_ADD | WH_ADDREQ_REPLACE)) {
			if hd.value != "" {
				_wh_release(h, t)
				return 0, .Unsupported
			}
		}
	}
	if t.chunked {
		h.api.add_headers(t.req, win.utf8_to_wstring("Transfer-Encoding: chunked", ta), max(u32), WH_ADDREQ_ADD | WH_ADDREQ_REPLACE)
	}
	total: i64
	if req.reader.read != nil {
		total = req.body_len if req.body_len > 0 else 0
	} else {
		total = i64(body_len(req.body))
		if len(req.body) == 1 && total > 0 && total < i64(max(u32)) {
			t.optional = req.body[0]
			t.seg = 1
		}
	}
	if total >= i64(max(u32)) {
		h.api.add_headers(t.req, win.utf8_to_wstring(strings.concatenate({"Content-Length: ", _wh_dec(total)}, ta), ta), max(u32), WH_ADDREQ_ADD | WH_ADDREQ_REPLACE)
		total = 0
	}
	t.total = u32(total)
	if req.timeout_ms > 0 {
		t.timer = prim.timer(h.loop, req.timeout_ms, t, _wh_on_deadline)
	}
	h.live[t.id] = t
	if !_wh_send(h, t) {
		code := win.GetLastError()
		delete_key(&h.live, t.id)
		t.dead = true
		_wh_stop_timer(h, t)
		_wh_close(h, t)
		_wh_pump(h)
		return 0, _wh_map(code, false)
	}
	_wh_pump(h)
	return t.id, .None
}

@(private)
_wh_dec :: proc(v: i64) -> string {
	buf := make([]u8, 24, context.temp_allocator)
	return strconv.write_int(buf, v, 10)
}

@(private)
_wh_send :: proc(h: ^Winhttp, t: ^Wh_Transfer) -> bool {
	return bool(h.api.send_request(t.req, nil, 0, raw_data(t.optional), u32(len(t.optional)), t.total, uintptr(rawptr(t))))
}

winhttp_cancel :: proc(h: ^Winhttp, id: Id) {
	t, ok := h.live[id]
	if !ok {
		return
	}
	delete_key(&h.live, id)
	t.dead = true
	_wh_stop_timer(h, t)
	_wh_close(h, t)
	_wh_pump(h)
}

winhttp_resume :: proc(h: ^Winhttp, id: Id) {
	t, ok := h.live[id]
	if !ok || !t.paused {
		return
	}
	t.paused = false
	_wh_upload(h, t)
	_wh_pump(h)
}

@(private)
_wh_stop_timer :: proc(h: ^Winhttp, t: ^Wh_Transfer) {
	if t.timer != 0 {
		prim.timer_cancel(h.loop, t.timer)
		t.timer = 0
	}
}

@(private)
_wh_close :: proc(h: ^Winhttp, t: ^Wh_Transfer) {
	if t.req != nil && intrinsics.atomic_compare_exchange_strong(&t.closing, 0, 1) == 0 {
		h.api.close(t.req)
	}
}

@(private)
_wh_release :: proc(h: ^Winhttp, t: ^Wh_Transfer) {
	if t.req != nil && intrinsics.atomic_load(&t.closing) == 0 {
		t.closing = 1
		zero: uintptr
		h.api.set_option(t.req, WH_OPT_CONTEXT_VALUE, &zero, size_of(zero))
		h.api.close(t.req)
	}
	if t.conn != nil {
		h.api.close(t.conn)
	}
	_wh_buf_put(h, t.rbuf)
	_wh_buf_put(h, t.upbuf)
	delete(t.head_buf)
	delete(t.head_idx)
	if t.host != nil {
		free(rawptr(t.host), h.allocator)
	}
	free(t, h.allocator)
	h.handles -= 1
}

@(private)
_wh_buf_get :: proc(h: ^Winhttp) -> []u8 {
	if len(h.bufs) > 0 {
		return pop(&h.bufs)
	}
	b, _ := make([]u8, WH_BUF, h.allocator)
	return b
}

@(private)
_wh_buf_put :: proc(h: ^Winhttp, b: []u8) {
	if b == nil {
		return
	}
	if len(h.bufs) < WH_BUF_POOL {
		append(&h.bufs, b)
		return
	}
	delete(b, h.allocator)
}

@(private)
_wh_on_deadline :: proc(l: ^prim.Loop, data: rawptr) {
	t := (^Wh_Transfer)(data)
	h := t.owner
	t.timer = 0
	_wh_finish(h, t, .Stalled if t.head_sent else .Timeout, "the operation timed out")
	_wh_pump(h)
}

@(private)
_wh_pump :: proc(h: ^Winhttp) {
	if h.depth > 0 {
		return
	}
	h.depth += 1
	defer h.depth -= 1
	for {
		win.AcquireSRWLockExclusive(&h.lock)
		t := h.ready
		h.ready = nil
		h.ready_tail = nil
		h.signaled = false
		win.ReleaseSRWLockExclusive(&h.lock)
		if t == nil {
			break
		}
		for t != nil {
			evs: [WH_EVENTS]_Wh_Ev
			win.AcquireSRWLockExclusive(&h.lock)
			next := t.next
			t.next = nil
			t.queued = false
			n := t.ev_n
			copy(evs[:n], t.evs[:n])
			t.ev_n = 0
			closed := t.closed
			overflow := t.overflow
			secure := t.secure
			ca_failed := t.ca_failed
			win.ReleaseSRWLockExclusive(&h.lock)
			for ev in evs[:n] {
				if t.dead {
					break
				}
				_wh_event(h, t, ev, secure, ca_failed)
			}
			if overflow && !t.dead {
				_wh_finish(h, t, .Other, "too many pending WinHTTP notifications")
			}
			if closed {
				_wh_release(h, t)
			}
			t = next
		}
	}
}

@(private)
_wh_event :: proc(h: ^Winhttp, t: ^Wh_Transfer, ev: _Wh_Ev, secure: u32, ca_failed: bool) {
	switch ev.status {
	case WH_STATUS_SENDREQUEST_COMPLETE, WH_STATUS_WRITE_COMPLETE:
		_wh_upload(h, t)
	case WH_STATUS_HEADERS_AVAILABLE:
		_wh_headers(h, t)
		if !t.dead {
			_wh_read(h, t)
		}
	case WH_STATUS_READ_COMPLETE:
		_wh_on_read(h, t, int(ev.a))
	case WH_STATUS_DATA_AVAILABLE:
		if ev.a == 0 {
			_wh_on_read(h, t, 0)
		} else if !h.api.read_data(t.req, raw_data(t.rbuf), min(ev.a, u32(len(t.rbuf))), nil) {
			code := win.GetLastError()
			_wh_finish(h, t, _wh_map(code, t.head_sent), _wh_detail(h, code, 0))
		}
	case WH_STATUS_REQUEST_ERROR:
		if ev.a == WH_ERROR_RESEND_REQUEST && t.reader.read == nil {
			t.seg = 1 if t.optional != nil else 0
			t.seg_off = 0
			if _wh_send(h, t) {
				return
			}
			_wh_finish(h, t, _wh_map(win.GetLastError(), t.head_sent), _wh_detail(h, win.GetLastError(), 0))
			return
		}
		if ca_failed {
			_wh_finish(h, t, .Tls, "the server certificate is not trusted by the configured CA file")
			return
		}
		err := _wh_map(ev.a, t.head_sent)
		if ev.a == WH_ERROR_RESEND_REQUEST {
			err = .Body
		}
		_wh_finish(h, t, err, _wh_detail(h, ev.a, secure))
	}
}

@(private)
_wh_upload :: proc(h: ^Winhttp, t: ^Wh_Transfer) {
	if t.dead {
		return
	}
	if t.reader.read == nil {
		for t.seg < len(t.body) && t.seg_off >= len(t.body[t.seg]) {
			t.seg += 1
			t.seg_off = 0
		}
		if t.seg < len(t.body) {
			src := t.body[t.seg][t.seg_off:]
			k := min(len(src), WH_WRITE_MAX)
			t.seg_off += k
			_wh_write(h, t, raw_data(src), k)
			return
		}
		_wh_receive(h, t)
		return
	}
	if t.up_end {
		if t.chunked && !t.trailer {
			t.trailer = true
			if t.upbuf == nil {
				t.upbuf = _wh_buf_get(h)
			}
			n := copy(t.upbuf, "0\r\n\r\n")
			_wh_write(h, t, raw_data(t.upbuf), n)
			return
		}
		_wh_receive(h, t)
		return
	}
	if t.upbuf == nil {
		t.upbuf = _wh_buf_get(h)
		if t.upbuf == nil {
			_wh_finish(h, t, .No_Memory, "")
			return
		}
	}
	off := WH_CHUNK_HEAD if t.chunked else 0
	room := len(t.upbuf) - off - (2 if t.chunked else 0)
	n, st := t.reader.read(t.reader.data, t.id, t.upbuf[off:off + room])
	if t.dead {
		return
	}
	switch st {
	case .Data, .Wait:
		if n <= 0 {
			t.paused = true
			return
		}
	case .End:
		t.up_end = true
		if n <= 0 {
			_wh_upload(h, t)
			return
		}
	case .Fail:
		_wh_finish(h, t, .Body, "the request body reader failed")
		return
	}
	n = min(n, room)
	if !t.chunked {
		_wh_write(h, t, raw_data(t.upbuf), n)
		return
	}
	hex: [8]u8
	digits := "0123456789abcdef"
	k := 0
	for v := n; ; v >>= 4 {
		hex[k] = digits[v & 0xF]
		k += 1
		if v < 16 {
			break
		}
	}
	start := off - k - 2
	for i in 0 ..< k {
		t.upbuf[start + i] = hex[k - 1 - i]
	}
	t.upbuf[off - 2] = '\r'
	t.upbuf[off - 1] = '\n'
	t.upbuf[off + n] = '\r'
	t.upbuf[off + n + 1] = '\n'
	_wh_write(h, t, &t.upbuf[start], off + n + 2 - start)
}

@(private)
_wh_write :: proc(h: ^Winhttp, t: ^Wh_Transfer, p: rawptr, n: int) {
	if !h.api.write_data(t.req, p, u32(n), nil) {
		code := win.GetLastError()
		_wh_finish(h, t, _wh_map(code, t.head_sent), _wh_detail(h, code, 0))
	}
}

@(private)
_wh_receive :: proc(h: ^Winhttp, t: ^Wh_Transfer) {
	if !h.api.receive(t.req, nil) {
		code := win.GetLastError()
		_wh_finish(h, t, _wh_map(code, t.head_sent), _wh_detail(h, code, 0))
	}
}

@(private)
_wh_read :: proc(h: ^Winhttp, t: ^Wh_Transfer) {
	if t.rbuf == nil {
		t.rbuf = _wh_buf_get(h)
		if t.rbuf == nil {
			_wh_finish(h, t, .No_Memory, "")
			return
		}
	}
	if h.api.read_data_ex != nil {
		code := h.api.read_data_ex(t.req, raw_data(t.rbuf), u32(len(t.rbuf)), nil, 0, 0, nil)
		if code != 0 && code != u32(win.ERROR_IO_PENDING) {
			_wh_finish(h, t, _wh_map(code, t.head_sent), _wh_detail(h, code, 0))
		}
		return
	}
	if !h.api.query_data(t.req, nil) {
		code := win.GetLastError()
		_wh_finish(h, t, _wh_map(code, t.head_sent), _wh_detail(h, code, 0))
	}
}

@(private)
_wh_headers :: proc(h: ^Winhttp, t: ^Wh_Transfer) {
	code: u32
	n := u32(size_of(code))
	if h.api.query_headers(t.req, WH_QUERY_STATUS_CODE | WH_QUERY_FLAG_NUMBER, nil, &code, &n, nil) {
		t.status = int(code)
	}
	clear(&t.head_buf)
	clear(&t.head_idx)
	size: u32
	h.api.query_headers(t.req, WH_QUERY_RAW_HEADERS_CRLF, nil, nil, &size, nil)
	if size > 0 && size < 4 << 20 {
		wbuf := make([]u16, int(size / 2) + 1, context.temp_allocator)
		if h.api.query_headers(t.req, WH_QUERY_RAW_HEADERS_CRLF, nil, raw_data(wbuf), &size, nil) {
			raw, _ := win.wstring_to_utf8(win.wstring(raw_data(wbuf)), int(size / 2), context.temp_allocator)
			_wh_parse_headers(t, raw)
		}
	}
	t.head_ready = true
	if t.no_body || t.status == 204 || t.status == 304 || t.status < 200 {
		t.length = -1
	}
}

@(private)
_wh_parse_headers :: proc(t: ^Wh_Transfer, raw: string) {
	rest := raw
	first := true
	for len(rest) > 0 {
		nl := strings.index_byte(rest, '\n')
		line := rest
		if nl >= 0 {
			line = rest[:nl]
			rest = rest[nl + 1:]
		} else {
			rest = ""
		}
		for len(line) > 0 && (line[len(line) - 1] == '\r' || line[len(line) - 1] == '\n') {
			line = line[:len(line) - 1]
		}
		if first {
			first = false
			continue
		}
		colon := strings.index_byte(line, ':')
		if len(line) == 0 || colon <= 0 || len(t.head_buf) + len(line) > 1 << 20 {
			continue
		}
		value := line[colon + 1:]
		for len(value) > 0 && (value[0] == ' ' || value[0] == '\t') {
			value = value[1:]
		}
		name := line[:colon]
		if ascii_ieq(name, "content-length") {
			if v, ok := strconv.parse_i64_of_base(value, 10); ok && v >= 0 {
				t.length = v
			}
		}
		base := u32(len(t.head_buf))
		append(&t.head_buf, name)
		vstart := u32(len(t.head_buf))
		append(&t.head_buf, value)
		append(&t.head_idx, [4]u32{base, base + u32(len(name)), vstart, u32(len(t.head_buf))})
	}
}

@(private)
_wh_send_head :: proc(t: ^Wh_Transfer) {
	t.head_sent = true
	if t.sink.head == nil {
		return
	}
	hs := make([]Header, len(t.head_idx), context.temp_allocator)
	for x, i in t.head_idx {
		hs[i] = Header {
			name  = string(t.head_buf[x[0]:x[1]]),
			value = string(t.head_buf[x[2]:x[3]]),
		}
	}
	t.sink.head(t.sink.data, t.id, t.status, hs)
}

@(private)
_wh_on_read :: proc(h: ^Winhttp, t: ^Wh_Transfer, n: int) {
	if n == 0 {
		if t.length >= 0 && t.received != t.length {
			_wh_finish(h, t, .Reset, "the connection closed before the whole response body arrived")
			return
		}
		_wh_finish(h, t, .None, "")
		return
	}
	t.received += i64(n)
	if !t.head_sent {
		_wh_send_head(t)
		if t.dead {
			return
		}
	}
	if t.sink.body != nil {
		if !t.sink.body(t.sink.data, t.id, t.rbuf[:min(n, len(t.rbuf))]) {
			if !t.dead {
				delete_key(&h.live, t.id)
				t.dead = true
				_wh_stop_timer(h, t)
				_wh_close(h, t)
			}
			return
		}
		if t.dead {
			return
		}
	}
	_wh_read(h, t)
}

@(private)
_wh_finish :: proc(h: ^Winhttp, t: ^Wh_Transfer, err: Error, detail: string) {
	if t.dead {
		return
	}
	if err == .None && !t.head_sent {
		_wh_send_head(t)
		if t.dead {
			return
		}
	}
	t.dead = true
	delete_key(&h.live, t.id)
	_wh_stop_timer(h, t)
	_wh_close(h, t)
	if t.sink.done != nil {
		t.sink.done(t.sink.data, t.id, err, detail)
	}
}

@(private)
_wh_map :: proc "contextless" (code: u32, head_sent: bool) -> Error {
	switch code {
	case 0:
		return .Other
	case WH_ERROR_NAME_NOT_RESOLVED:
		return .Dns
	case WH_ERROR_CANNOT_CONNECT, 12166, 12167, 12178, 12180:
		return .Connect
	case WH_ERROR_TIMEOUT:
		return .Stalled if head_sent else .Timeout
	case 12037, 12038, 12044, 12045, 12057, 12157, 12169, 12170, 12175, 12179, 12185, 12186:
		return .Tls
	case WH_ERROR_CONNECTION_ERROR:
		return .Reset
	case WH_ERROR_INVALID_SERVER_RESPONSE, WH_ERROR_HEADER_NOT_FOUND, WH_ERROR_REDIRECT_FAILED:
		return .Protocol
	case 12181, 12182, 12183, 12184:
		return .Too_Large
	case WH_ERROR_INVALID_URL, WH_ERROR_UNRECOGNIZED_SCHEME:
		return .Unsupported
	case WH_ERROR_OPERATION_CANCELLED:
		return .Cancelled
	case WH_ERROR_OUT_OF_HANDLES, 8, 14:
		return .No_Memory
	}
	return .Other
}

@(private)
_wh_detail :: proc(h: ^Winhttp, code: u32, secure: u32) -> string {
	buf: [512]u16
	n := win.FormatMessageW(win.FORMAT_MESSAGE_FROM_HMODULE | win.FORMAT_MESSAGE_FROM_SYSTEM | win.FORMAT_MESSAGE_IGNORE_INSERTS, rawptr(h.api.module), code, 0, &buf[0], len(buf), nil)
	msg := ""
	if n > 0 {
		msg, _ = win.wstring_to_utf8(win.wstring(&buf[0]), int(n), context.temp_allocator)
		msg = strings.trim_right_space(msg)
	}
	if msg == "" {
		msg = strings.concatenate({"WinHTTP error ", _wh_dec(i64(code))}, context.temp_allocator)
	}
	if secure != 0 {
		msg = strings.concatenate({msg, " (certificate flags 0x", _wh_hex(u64(secure))[8:], ")"}, context.temp_allocator)
	}
	return msg
}
