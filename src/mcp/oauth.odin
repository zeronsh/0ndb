package mcp

import "base:runtime"
import "core:crypto"
import "core:crypto/sha2"
import "core:encoding/base64"
import "core:strings"
import "../http"
import "../prim"

Oauth_Store :: struct {
	data: rawptr,
	load: proc(data: rawptr, key: string, allocator: runtime.Allocator) -> (string, bool),
	save: proc(data: rawptr, key: string, value: string),
}

Oauth_Config :: struct {
	redirect_uri:        string,
	client_name:         string,
	client_uri:          string,
	scope:               string,
	client_id:           string,
	client_secret:       string,
	client_issuer:       string,
	client_metadata_url: string,
	application_type:    string,
	store:               Oauth_Store,
	max_step_up:         int,
}

Oauth_Phase :: enum u8 {
	Idle,
	Resource_Metadata,
	Server_Metadata,
	Register,
	Await_User,
	Token,
	Refresh,
	Failed,
}

@(private)
Oauth :: struct {
	cfg:              Oauth_Config,
	phase:            Oauth_Phase,
	handle:           http.Id,
	req_body:         []u8,
	parts:            [1][]u8,
	fail_err:         http.Error,
	status:           int,
	body:             Buf,
	candidates:       [dynamic]string,
	cand:             int,
	challenge_scope:  string,
	resource:         string,
	prm_scopes:       string,
	issuer:           string,
	authorization_ep: string,
	token_ep:         string,
	registration_ep:  string,
	iss_supported:    bool,
	cimd_supported:   bool,
	auth_methods:     string,
	as_scopes:        string,
	client_id:        string,
	client_secret:    string,
	client_auth:      string,
	verifier:         string,
	state:            string,
	requested_scope:  string,
	access_token:     string,
	refresh_token:    string,
	expires_at:       i64,
	granted_scope:    string,
	refreshed:        bool,
	step_ups:         int,
	authorize_url:    string,
	refresh_t:        prim.Timer,
	proactive:        bool,
}

@(private)
_oa_set :: proc(hc: ^Http_Client, dst: ^string, v: string) {
	delete(dst^, hc.allocator)
	dst^ = strings.clone(v, hc.allocator) if len(v) > 0 else ""
}

@(private)
_oa_init :: proc(hc: ^Http_Client, cfg: Oauth_Config) {
	o := new(Oauth, hc.allocator)
	hc.oauth = o
	o.cfg = cfg
	o.cfg.redirect_uri = strings.clone(cfg.redirect_uri, hc.allocator)
	o.cfg.client_name = strings.clone(cfg.client_name if cfg.client_name != "" else "0ndb", hc.allocator)
	o.cfg.client_uri = strings.clone(cfg.client_uri, hc.allocator)
	o.cfg.scope = strings.clone(cfg.scope, hc.allocator)
	o.cfg.client_id = strings.clone(cfg.client_id, hc.allocator)
	o.cfg.client_secret = strings.clone(cfg.client_secret, hc.allocator)
	o.cfg.client_issuer = strings.clone(cfg.client_issuer, hc.allocator)
	o.cfg.client_metadata_url = strings.clone(cfg.client_metadata_url, hc.allocator)
	o.cfg.application_type = strings.clone(cfg.application_type if cfg.application_type != "" else "native", hc.allocator)
	if o.cfg.max_step_up <= 0 {
		o.cfg.max_step_up = 3
	}
	o.body = make(Buf, hc.allocator)
	o.candidates = make([dynamic]string, hc.allocator)
	_oa_load_tokens(hc)
}

@(private)
_oa_destroy :: proc(hc: ^Http_Client) {
	o := hc.oauth
	if o == nil {
		return
	}
	if o.handle != 0 {
		http.cancel(&hc.http, o.handle)
	}
	if o.refresh_t != 0 {
		prim.timer_cancel(hc.loop, o.refresh_t)
	}
	delete(o.req_body, hc.allocator)
	for s in ([]string{o.cfg.redirect_uri, o.cfg.client_name, o.cfg.client_uri, o.cfg.scope, o.cfg.client_id, o.cfg.client_secret, o.cfg.client_issuer, o.cfg.client_metadata_url, o.cfg.application_type, o.challenge_scope, o.resource, o.prm_scopes, o.issuer, o.authorization_ep, o.token_ep, o.registration_ep, o.auth_methods, o.as_scopes, o.client_id, o.client_secret, o.client_auth, o.verifier, o.state, o.requested_scope, o.access_token, o.refresh_token, o.granted_scope, o.authorize_url}) {
		delete(s, hc.allocator)
	}
	_oa_clear_candidates(hc)
	delete(o.candidates)
	delete(o.body)
	free(o, hc.allocator)
	hc.oauth = nil
}

@(private)
_oa_clear_candidates :: proc(hc: ^Http_Client) {
	o := hc.oauth
	for c in o.candidates {
		delete(c, hc.allocator)
	}
	clear(&o.candidates)
	o.cand = 0
}

oauth_phase :: proc "contextless" (hc: ^Http_Client) -> Oauth_Phase {
	if hc.oauth == nil {
		return .Idle
	}
	return hc.oauth.phase
}

@(private)
_oa_rand :: proc(n: int) -> string {
	raw := make([]u8, n, context.temp_allocator)
	crypto.rand_bytes(raw)
	out, _ := base64.encode(raw, base64.ENC_URL_TABLE, context.temp_allocator, {.No_Padding})
	return out
}

@(private)
_oa_challenge :: proc(verifier: string) -> string {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]u8)verifier)
	digest: [sha2.DIGEST_SIZE_256]u8
	sha2.final(&ctx, digest[:])
	out, _ := base64.encode(digest[:], base64.ENC_URL_TABLE, context.temp_allocator, {.No_Padding})
	return out
}

url_encode :: proc(b: ^Buf, s: string) {
	hex := "0123456789ABCDEF"
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '.', '_', '~':
			append(b, c)
		case:
			append(b, '%', hex[c >> 4], hex[c & 15])
		}
	}
}

url_decode :: proc(s: string, allocator := context.temp_allocator) -> (string, bool) {
	out := make(Buf, 0, len(s), allocator)
	i := 0
	for i < len(s) {
		c := s[i]
		switch c {
		case '+':
			append(&out, ' ')
			i += 1
		case '%':
			if i + 2 >= len(s) {
				return "", false
			}
			h, l := _hexval(s[i + 1]), _hexval(s[i + 2])
			if h < 0 || l < 0 {
				return "", false
			}
			append(&out, u8(h << 4 | l))
			i += 3
		case:
			append(&out, c)
			i += 1
		}
	}
	return string(out[:]), true
}

@(private)
_form :: proc(b: ^Buf, k: string, v: string) {
	if len(b) > 0 {
		append(b, '&')
	}
	url_encode(b, k)
	append(b, '=')
	url_encode(b, v)
}

query_param :: proc(query: string, name: string) -> (string, bool) {
	q := query
	if i := strings.index_byte(q, '?'); i >= 0 {
		q = q[i + 1:]
	}
	if i := strings.index_byte(q, '#'); i >= 0 {
		q = q[:i]
	}
	rest := q
	for part in strings.split_iterator(&rest, "&") {
		eq := strings.index_byte(part, '=')
		k := part if eq < 0 else part[:eq]
		v := "" if eq < 0 else part[eq + 1:]
		dk, ok := url_decode(k)
		if ok && dk == name {
			return url_decode(v)
		}
	}
	return "", false
}

Www_Auth :: struct {
	bearer:            bool,
	error:             string,
	error_description: string,
	scope:             string,
	resource_metadata: string,
}

www_authenticate_parse :: proc(v: string) -> (w: Www_Auth) {
	i := 0
	skip_ws :: proc(v: string, i: int) -> int {
		j := i
		for j < len(v) && (v[j] == ' ' || v[j] == '\t' || v[j] == ',') {
			j += 1
		}
		return j
	}
	in_bearer := false
	for i < len(v) {
		i = skip_ws(v, i)
		start := i
		for i < len(v) && _tchar(v[i]) {
			i += 1
		}
		tok := v[start:i]
		if len(tok) == 0 {
			i += 1
			continue
		}
		j := i
		for j < len(v) && (v[j] == ' ' || v[j] == '\t') {
			j += 1
		}
		if j < len(v) && v[j] == '=' {
			k := j + 1
			for k < len(v) && (v[k] == ' ' || v[k] == '\t') {
				k += 1
			}
			val := make(Buf, context.temp_allocator)
			if k < len(v) && v[k] == '"' {
				k += 1
				for k < len(v) && v[k] != '"' {
					if v[k] == '\\' && k + 1 < len(v) {
						k += 1
					}
					append(&val, v[k])
					k += 1
				}
				k += 1
			} else {
				for k < len(v) && v[k] != ',' && v[k] != ' ' {
					append(&val, v[k])
					k += 1
				}
			}
			i = k
			if !in_bearer {
				continue
			}
			s := string(val[:])
			switch {
			case _ascii_equal_fold(tok, "error"):
				w.error = s
			case _ascii_equal_fold(tok, "error_description"):
				w.error_description = s
			case _ascii_equal_fold(tok, "scope"):
				w.scope = s
			case _ascii_equal_fold(tok, "resource_metadata"):
				w.resource_metadata = s
			}
			continue
		}
		in_bearer = _ascii_equal_fold(tok, "bearer")
		if in_bearer {
			w.bearer = true
		}
	}
	return
}

@(private)
_oa_secure :: proc(url: string) -> bool {
	u, ok := url_parse(url)
	if !ok {
		return false
	}
	if _ascii_equal_fold(u.scheme, "https") {
		return true
	}
	h := u.host
	return _ascii_equal_fold(u.scheme, "http") && (h == "localhost" || h == "127.0.0.1" || h == "[::1]")
}

@(private)
_oa_canonical :: proc(url: string) -> string {
	u, ok := url_parse(url)
	if !ok {
		return url
	}
	b := make(Buf, context.temp_allocator)
	append(&b, strings.to_lower(u.scheme, context.temp_allocator))
	append(&b, "://")
	append(&b, strings.to_lower(u.host, context.temp_allocator))
	default_port := 443 if _ascii_equal_fold(u.scheme, "https") else 80
	if u.port != default_port {
		append(&b, ':')
		w_int(&b, i64(u.port))
	}
	t := u.target
	if t != "/" {
		append(&b, t)
	}
	return string(b[:])
}

@(private)
_oa_fail :: proc(hc: ^Http_Client, why: string) {
	o := hc.oauth
	o.phase = .Failed
	ids := make([dynamic]i64, context.temp_allocator)
	append(&ids, ..hc.auth_wait[:])
	clear(&hc.auth_wait)
	e := Event{kind = .Auth_Required, message = why}
	_hc_event(hc, &hc.client, &e)
	for id in ids {
		client_fail_request(&hc.client, id, JSONRPC_INTERNAL_ERROR, strings.concatenate({"authorization failed: ", why}, context.temp_allocator))
	}
	o.phase = .Idle
}

@(private)
_oa_request :: proc(hc: ^Http_Client, method: string, url: string, content_type: string, body: []u8, basic: string = "") {
	o := hc.oauth
	clear(&o.body)
	o.status = 0
	headers := make([dynamic]Header, context.temp_allocator)
	append(&headers, Header{"Accept", "application/json"})
	if content_type != "" {
		append(&headers, Header{"Content-Type", content_type})
	}
	if basic != "" {
		append(&headers, Header{"Authorization", basic})
	}
	delete(o.req_body, hc.allocator)
	o.req_body = nil
	req := http.Request {
		method     = method,
		url        = url,
		headers    = headers[:],
		connect_ms = hc.head_timeout,
		timeout_ms = hc.head_timeout,
	}
	if len(body) > 0 {
		o.req_body = make([]u8, len(body), hc.allocator)
		copy(o.req_body, body)
		o.parts[0] = o.req_body
		req.body = o.parts[:]
	}
	id, err := http.start(&hc.http, &req, http.Sink{data = hc, head = _oa_on_head, body = _oa_on_body, done = _oa_on_done})
	if err == .None {
		o.handle = id
		return
	}
	o.handle = 0
	o.fail_err = err
	prim.timer(hc.loop, 0, hc, proc(l: ^prim.Loop, data: rawptr) {
		hc := (^Http_Client)(data)
		if hc.oauth != nil && hc.oauth.handle == 0 && !hc.closing {
			_oa_on_done(hc, 0, hc.oauth.fail_err, "")
		}
	})
}

@(private)
_oa_on_head :: proc(data: rawptr, id: http.Id, status: int, headers: []Header) {
	hc := (^Http_Client)(data)
	hc.oauth.status = status
}

@(private)
_oa_on_body :: proc(data: rawptr, id: http.Id, chunk: []u8) -> bool {
	hc := (^Http_Client)(data)
	o := hc.oauth
	if len(o.body) + len(chunk) > 1 << 20 {
		return false
	}
	append(&o.body, ..chunk)
	return true
}

@(private)
_oa_on_done :: proc(data: rawptr, id: http.Id, err: http.Error, detail: string) {
	hc := (^Http_Client)(data)
	o := hc.oauth
	o.handle = 0
	if hc.closing {
		return
	}
	body := strings.clone(string(o.body[:]), context.temp_allocator)
	ok := err == .None && o.status >= 200 && o.status < 300 && json_kind(body) == .Object && json_valid(body)
	switch o.phase {
	case .Resource_Metadata:
		if ok && _oa_take_prm(hc, body) {
			return
		}
		_oa_next_candidate(hc, "no usable protected resource metadata")
	case .Server_Metadata:
		if ok && _oa_take_asm(hc, body) {
			return
		}
		if o.phase == .Server_Metadata {
			_oa_next_candidate(hc, "no usable authorization server metadata")
		}
	case .Register:
		if !ok {
			_oa_fail(hc, strings.concatenate({"dynamic client registration failed: ", body}, context.temp_allocator))
			return
		}
		_oa_take_registration(hc, body)
	case .Token, .Refresh:
		was_refresh := o.phase == .Refresh
		if !ok {
			if was_refresh {
				_oa_set(hc, &o.refresh_token, "")
				_oa_save_tokens(hc)
				if o.proactive && len(hc.auth_wait) == 0 {
					o.proactive = false
					o.phase = .Idle
					return
				}
				o.proactive = false
				_oa_discover(hc)
				return
			}
			_oa_fail(hc, strings.concatenate({"token request failed: ", body}, context.temp_allocator))
			return
		}
		_oa_take_tokens(hc, body)
	case .Idle, .Await_User, .Failed:
	}
}

@(private)
_oa_next_candidate :: proc(hc: ^Http_Client, why: string) {
	o := hc.oauth
	o.cand += 1
	if o.cand < len(o.candidates) {
		_oa_request(hc, "GET", o.candidates[o.cand], "", nil)
		return
	}
	_oa_fail(hc, why)
}

http_client_oauth_challenge :: proc(hc: ^Http_Client, status: int, www_authenticate: string) -> bool {
	o := hc.oauth
	if o == nil {
		return false
	}
	w := www_authenticate_parse(www_authenticate)
	if o.phase != .Idle {
		return true
	}
	if w.scope != "" {
		_oa_set(hc, &o.challenge_scope, w.scope)
	}
	if status == 403 {
		if w.error != "insufficient_scope" {
			return false
		}
		o.step_ups += 1
		if o.step_ups > o.cfg.max_step_up {
			_oa_fail(hc, "insufficient scope after repeated step-up authorization")
			o.step_ups = 0
			return true
		}
		_oa_start(hc, w.resource_metadata)
		return true
	}
	if o.refresh_token != "" && o.token_ep != "" && !o.refreshed {
		_oa_refresh(hc)
		return true
	}
	_oa_start(hc, w.resource_metadata)
	return true
}

@(private)
_oa_start :: proc(hc: ^Http_Client, resource_metadata: string) {
	o := hc.oauth
	o.refreshed = false
	_oa_clear_candidates(hc)
	if resource_metadata != "" {
		append(&o.candidates, strings.clone(resource_metadata, hc.allocator))
	}
	u, ok := url_parse(hc.url)
	if !ok {
		_oa_fail(hc, "invalid server URL")
		return
	}
	path := u.target
	if q := strings.index_byte(path, '?'); q >= 0 {
		path = path[:q]
	}
	if path != "/" && path != "" {
		append(&o.candidates, strings.concatenate({u.origin, "/.well-known/oauth-protected-resource", path}, hc.allocator))
	}
	append(&o.candidates, strings.concatenate({u.origin, "/.well-known/oauth-protected-resource"}, hc.allocator))
	o.phase = .Resource_Metadata
	_oa_request(hc, "GET", o.candidates[0], "", nil)
}

@(private)
_oa_discover :: proc(hc: ^Http_Client) {
	_oa_start(hc, "")
}

@(private)
_oa_take_prm :: proc(hc: ^Http_Client, body: string) -> bool {
	o := hc.oauth
	servers, ok := json_get_array(body, "authorization_servers")
	if !ok {
		return false
	}
	it, _ := json_array(servers)
	first, fok := json_next_item(&it)
	if !fok {
		return false
	}
	as_url, sok := json_string(first)
	if !sok || as_url == "" {
		return false
	}
	resource := _oa_canonical(hc.url)
	if r, rok := json_get_string(body, "resource"); rok && r != "" {
		pr, pok := url_parse(r)
		mu, mok := url_parse(hc.url)
		if !pok || !mok || !_ascii_equal_fold(pr.origin, mu.origin) || !strings.has_prefix(mu.target, strings.trim_right(pr.target, "/")) {
			_oa_fail(hc, "protected resource metadata names a different resource")
			return true
		}
		resource = _oa_canonical(r)
	}
	_oa_set(hc, &o.resource, resource)
	scopes := make(Buf, context.temp_allocator)
	if arr, aok := json_get_array(body, "scopes_supported"); aok {
		sit, _ := json_array(arr)
		for v in json_next_item(&sit) {
			if s, s_ok := json_string(v); s_ok {
				if len(scopes) > 0 {
					append(&scopes, ' ')
				}
				append(&scopes, s)
			}
		}
	}
	_oa_set(hc, &o.prm_scopes, string(scopes[:]))
	if !_oa_secure(as_url) {
		_oa_fail(hc, "authorization server is not served over HTTPS")
		return true
	}
	_oa_set(hc, &o.issuer, as_url)
	_oa_clear_candidates(hc)
	u, _ := url_parse(as_url)
	path := strings.trim_right(u.target, "/")
	if path != "" {
		append(&o.candidates, strings.concatenate({u.origin, "/.well-known/oauth-authorization-server", path}, hc.allocator))
		append(&o.candidates, strings.concatenate({u.origin, "/.well-known/openid-configuration", path}, hc.allocator))
		append(&o.candidates, strings.concatenate({u.origin, path, "/.well-known/openid-configuration"}, hc.allocator))
	} else {
		append(&o.candidates, strings.concatenate({u.origin, "/.well-known/oauth-authorization-server"}, hc.allocator))
		append(&o.candidates, strings.concatenate({u.origin, "/.well-known/openid-configuration"}, hc.allocator))
	}
	o.phase = .Server_Metadata
	_oa_request(hc, "GET", o.candidates[0], "", nil)
	return true
}

@(private)
_oa_join :: proc(arr: string) -> string {
	b := make(Buf, context.temp_allocator)
	it, _ := json_array(arr)
	for v in json_next_item(&it) {
		if s, ok := json_string(v); ok {
			if len(b) > 0 {
				append(&b, ' ')
			}
			append(&b, s)
		}
	}
	return string(b[:])
}

@(private)
_oa_has_word :: proc(words: string, w: string) -> bool {
	rest := words
	for part in strings.split_iterator(&rest, " ") {
		if part == w {
			return true
		}
	}
	return false
}

@(private)
_oa_take_asm :: proc(hc: ^Http_Client, body: string) -> bool {
	o := hc.oauth
	issuer, _ := json_get_string(body, "issuer")
	if issuer != o.issuer && strings.trim_right(issuer, "/") != strings.trim_right(o.issuer, "/") {
		return false
	}
	if issuer != o.issuer {
		_oa_set(hc, &o.issuer, issuer)
	}
	methods, mok := json_get_array(body, "code_challenge_methods_supported")
	if !mok || !_oa_has_word(_oa_join(methods), "S256") {
		_oa_fail(hc, "authorization server does not support PKCE with S256")
		return true
	}
	ae, _ := json_get_string(body, "authorization_endpoint")
	te, _ := json_get_string(body, "token_endpoint")
	re, _ := json_get_string(body, "registration_endpoint")
	if ae == "" || te == "" || !_oa_secure(ae) || !_oa_secure(te) || (re != "" && !_oa_secure(re)) {
		_oa_fail(hc, "authorization server metadata lacks secure endpoints")
		return true
	}
	_oa_set(hc, &o.authorization_ep, ae)
	_oa_set(hc, &o.token_ep, te)
	_oa_set(hc, &o.registration_ep, re)
	o.iss_supported = json_get_bool(body, "authorization_response_iss_parameter_supported")
	o.cimd_supported = json_get_bool(body, "client_id_metadata_document_supported")
	if a, ok := json_get_array(body, "token_endpoint_auth_methods_supported"); ok {
		_oa_set(hc, &o.auth_methods, _oa_join(a))
	} else {
		_oa_set(hc, &o.auth_methods, "client_secret_basic")
	}
	if a, ok := json_get_array(body, "scopes_supported"); ok {
		_oa_set(hc, &o.as_scopes, _oa_join(a))
	}
	_oa_register(hc)
	return true
}

@(private)
_oa_store_key :: proc(kind: string, k: string) -> string {
	return strings.concatenate({"mcp-oauth:", kind, ":", k}, context.temp_allocator)
}

@(private)
_oa_register :: proc(hc: ^Http_Client) {
	o := hc.oauth
	if o.client_id != "" && o.client_auth != "" {
		_oa_authorize(hc)
		return
	}
	st := o.cfg.store
	if st.load != nil {
		if saved, ok := st.load(st.data, _oa_store_key("client", o.issuer), context.temp_allocator); ok && json_kind(saved) == .Object {
			id, _ := json_get_string(saved, "client_id")
			if id != "" {
				sec, _ := json_get_string(saved, "client_secret")
				method, _ := json_get_string(saved, "token_endpoint_auth_method")
				_oa_set(hc, &o.client_id, id)
				_oa_set(hc, &o.client_secret, sec)
				_oa_set(hc, &o.client_auth, method if method != "" else "none")
				_oa_authorize(hc)
				return
			}
		}
	}
	if o.cfg.client_id != "" {
		if o.cfg.client_issuer != "" && o.cfg.client_issuer != o.issuer {
			_oa_fail(hc, "pre-registered client belongs to a different authorization server")
			return
		}
		_oa_set(hc, &o.client_id, o.cfg.client_id)
		_oa_set(hc, &o.client_secret, o.cfg.client_secret)
		method := "none"
		if o.cfg.client_secret != "" {
			method = "client_secret_post" if _oa_has_word(o.auth_methods, "client_secret_post") && !_oa_has_word(o.auth_methods, "client_secret_basic") else "client_secret_basic"
		}
		_oa_set(hc, &o.client_auth, method)
		_oa_authorize(hc)
		return
	}
	if o.cfg.client_metadata_url != "" && o.cimd_supported && _oa_secure(o.cfg.client_metadata_url) {
		_oa_set(hc, &o.client_id, o.cfg.client_metadata_url)
		_oa_set(hc, &o.client_secret, "")
		_oa_set(hc, &o.client_auth, "none")
		_oa_authorize(hc)
		return
	}
	if o.registration_ep == "" {
		_oa_fail(hc, "no client registration is possible: configure a client id")
		return
	}
	b := make(Buf, context.temp_allocator)
	append(&b, '{')
	f_str(&b, "client_name", o.cfg.client_name)
	if o.cfg.client_uri != "" {
		f_str(&b, "client_uri", o.cfg.client_uri)
	}
	f_arr(&b, "redirect_uris")
	w_item_str(&b, o.cfg.redirect_uri)
	w_close_arr(&b)
	f_raw(&b, "grant_types", `["authorization_code","refresh_token"]`)
	f_raw(&b, "response_types", `["code"]`)
	f_str(&b, "token_endpoint_auth_method", "none")
	f_str(&b, "application_type", o.cfg.application_type)
	append(&b, '}')
	o.phase = .Register
	_oa_request(hc, "POST", o.registration_ep, "application/json", b[:])
}

@(private)
_oa_take_registration :: proc(hc: ^Http_Client, body: string) {
	o := hc.oauth
	id, _ := json_get_string(body, "client_id")
	if id == "" {
		_oa_fail(hc, "registration response lacks client_id")
		return
	}
	sec, _ := json_get_string(body, "client_secret")
	method, _ := json_get_string(body, "token_endpoint_auth_method")
	if method == "" {
		method = "client_secret_basic" if sec != "" else "none"
	}
	_oa_set(hc, &o.client_id, id)
	_oa_set(hc, &o.client_secret, sec)
	_oa_set(hc, &o.client_auth, method)
	st := o.cfg.store
	if st.save != nil {
		b := make(Buf, context.temp_allocator)
		append(&b, '{')
		f_str(&b, "client_id", id)
		if sec != "" {
			f_str(&b, "client_secret", sec)
		}
		f_str(&b, "token_endpoint_auth_method", method)
		f_str(&b, "issuer", o.issuer)
		append(&b, '}')
		st.save(st.data, _oa_store_key("client", o.issuer), string(b[:]))
	}
	_oa_authorize(hc)
}

@(private)
_oa_scope :: proc(hc: ^Http_Client) -> string {
	o := hc.oauth
	words := make([dynamic]string, context.temp_allocator)
	add :: proc(words: ^[dynamic]string, list: string) {
		rest := list
		for w in strings.split_iterator(&rest, " ") {
			if w == "" {
				continue
			}
			found := false
			for x in words {
				if x == w {
					found = true
					break
				}
			}
			if !found {
				append(words, w)
			}
		}
	}
	add(&words, o.requested_scope)
	if o.challenge_scope != "" {
		add(&words, o.challenge_scope)
	} else if len(words) == 0 {
		add(&words, o.prm_scopes)
	}
	add(&words, o.cfg.scope)
	if len(words) > 0 && _oa_has_word(o.as_scopes, "offline_access") {
		add(&words, "offline_access")
	}
	return strings.join(words[:], " ", context.temp_allocator)
}

@(private)
_oa_authorize :: proc(hc: ^Http_Client) {
	o := hc.oauth
	if o.cfg.redirect_uri == "" || !_oa_secure(o.cfg.redirect_uri) {
		_oa_fail(hc, "redirect URI must be localhost or HTTPS")
		return
	}
	_oa_set(hc, &o.verifier, _oa_rand(32))
	_oa_set(hc, &o.state, _oa_rand(16))
	scope := _oa_scope(hc)
	_oa_set(hc, &o.requested_scope, scope)
	b := make(Buf, context.temp_allocator)
	_form(&b, "response_type", "code")
	_form(&b, "client_id", o.client_id)
	_form(&b, "redirect_uri", o.cfg.redirect_uri)
	_form(&b, "code_challenge", _oa_challenge(o.verifier))
	_form(&b, "code_challenge_method", "S256")
	_form(&b, "state", o.state)
	_form(&b, "resource", o.resource)
	if scope != "" {
		_form(&b, "scope", scope)
	}
	sep := "&" if strings.contains_rune(o.authorization_ep, '?') else "?"
	_oa_set(hc, &o.authorize_url, strings.concatenate({o.authorization_ep, sep, string(b[:])}, context.temp_allocator))
	o.phase = .Await_User
	e := Event{kind = .Authorize, message = o.authorize_url, data = o.cfg.redirect_uri}
	_hc_event(hc, &hc.client, &e)
}

http_client_oauth_callback :: proc(hc: ^Http_Client, redirect: string) -> bool {
	o := hc.oauth
	if o == nil || o.phase != .Await_User {
		return false
	}
	state, _ := query_param(redirect, "state")
	if state != o.state {
		return false
	}
	iss, has_iss := query_param(redirect, "iss")
	if has_iss && iss != o.issuer {
		_oa_fail(hc, "authorization response issuer mismatch")
		return false
	}
	if !has_iss && o.iss_supported {
		_oa_fail(hc, "authorization response lacks the iss parameter")
		return false
	}
	if errc, has_err := query_param(redirect, "error"); has_err {
		desc, _ := query_param(redirect, "error_description")
		_oa_fail(hc, strings.concatenate({errc, ": ", desc}, context.temp_allocator))
		return false
	}
	code, has_code := query_param(redirect, "code")
	if !has_code || code == "" {
		_oa_fail(hc, "authorization response lacks a code")
		return false
	}
	b := make(Buf, context.temp_allocator)
	_form(&b, "grant_type", "authorization_code")
	_form(&b, "code", code)
	_form(&b, "redirect_uri", o.cfg.redirect_uri)
	_form(&b, "code_verifier", o.verifier)
	_form(&b, "resource", o.resource)
	basic := _oa_client_auth(hc, &b)
	o.phase = .Token
	_oa_request(hc, "POST", o.token_ep, "application/x-www-form-urlencoded", b[:], basic)
	return true
}

@(private)
_oa_client_auth :: proc(hc: ^Http_Client, b: ^Buf) -> string {
	o := hc.oauth
	if o.client_secret != "" && o.client_auth == "client_secret_basic" {
		cred := make(Buf, context.temp_allocator)
		url_encode(&cred, o.client_id)
		append(&cred, ':')
		url_encode(&cred, o.client_secret)
		enc, _ := base64.encode(cred[:], allocator = context.temp_allocator)
		return strings.concatenate({"Basic ", enc}, context.temp_allocator)
	}
	_form(b, "client_id", o.client_id)
	if o.client_secret != "" {
		_form(b, "client_secret", o.client_secret)
	}
	return ""
}

@(private)
_oa_refresh :: proc(hc: ^Http_Client) {
	o := hc.oauth
	o.refreshed = true
	b := make(Buf, context.temp_allocator)
	_form(&b, "grant_type", "refresh_token")
	_form(&b, "refresh_token", o.refresh_token)
	_form(&b, "resource", o.resource)
	basic := _oa_client_auth(hc, &b)
	o.phase = .Refresh
	_oa_request(hc, "POST", o.token_ep, "application/x-www-form-urlencoded", b[:], basic)
}

@(private)
_oa_take_tokens :: proc(hc: ^Http_Client, body: string) {
	o := hc.oauth
	at, _ := json_get_string(body, "access_token")
	tt, _ := json_get_string(body, "token_type")
	if at == "" || !_ascii_equal_fold(tt, "bearer") {
		_oa_fail(hc, "token response is not a bearer token")
		return
	}
	_oa_set(hc, &o.access_token, at)
	if rt, ok := json_get_string(body, "refresh_token"); ok && rt != "" {
		_oa_set(hc, &o.refresh_token, rt)
	}
	o.expires_at = 0
	if ei, ok := json_get_int(body, "expires_in"); ok && ei > 0 {
		o.expires_at = prim.now_ms() + ei * 1000
	}
	if sc, ok := json_get_string(body, "scope"); ok {
		_oa_set(hc, &o.granted_scope, sc)
	} else {
		_oa_set(hc, &o.granted_scope, o.requested_scope)
	}
	o.refreshed = false
	o.proactive = false
	o.step_ups = 0
	o.phase = .Idle
	_oa_apply(hc)
	_oa_save_tokens(hc)
	_oa_arm_refresh(hc)
	e := Event{kind = .Authorized, message = o.granted_scope}
	_hc_event(hc, &hc.client, &e)
	http_client_retry_auth(hc)
}

@(private)
_oa_apply :: proc(hc: ^Http_Client) {
	o := hc.oauth
	if o.access_token == "" {
		return
	}
	http_client_set_header(hc, "Authorization", strings.concatenate({"Bearer ", o.access_token}, context.temp_allocator))
}

@(private)
_oa_save_tokens :: proc(hc: ^Http_Client) {
	o := hc.oauth
	st := o.cfg.store
	if st.save == nil {
		return
	}
	b := make(Buf, context.temp_allocator)
	append(&b, '{')
	f_str(&b, "access_token", o.access_token)
	if o.refresh_token != "" {
		f_str(&b, "refresh_token", o.refresh_token)
	}
	f_int(&b, "expires_at", o.expires_at)
	f_str(&b, "scope", o.granted_scope)
	f_str(&b, "issuer", o.issuer)
	f_str(&b, "resource", o.resource)
	f_str(&b, "token_endpoint", o.token_ep)
	f_str(&b, "client_id", o.client_id)
	if o.client_secret != "" {
		f_str(&b, "client_secret", o.client_secret)
	}
	f_str(&b, "client_auth", o.client_auth)
	append(&b, '}')
	st.save(st.data, _oa_store_key("tokens", _oa_canonical(hc.url)), string(b[:]))
}

@(private)
_oa_load_tokens :: proc(hc: ^Http_Client) {
	o := hc.oauth
	st := o.cfg.store
	if st.load == nil {
		return
	}
	saved, ok := st.load(st.data, _oa_store_key("tokens", _oa_canonical(hc.url)), context.temp_allocator)
	if !ok || json_kind(saved) != .Object {
		return
	}
	get :: proc(hc: ^Http_Client, saved: string, k: string, dst: ^string) {
		if v, ok := json_get_string(saved, k); ok {
			_oa_set(hc, dst, v)
		}
	}
	get(hc, saved, "access_token", &o.access_token)
	get(hc, saved, "refresh_token", &o.refresh_token)
	get(hc, saved, "scope", &o.granted_scope)
	get(hc, saved, "issuer", &o.issuer)
	get(hc, saved, "resource", &o.resource)
	get(hc, saved, "token_endpoint", &o.token_ep)
	get(hc, saved, "client_id", &o.client_id)
	get(hc, saved, "client_secret", &o.client_secret)
	get(hc, saved, "client_auth", &o.client_auth)
	o.expires_at, _ = json_get_int(saved, "expires_at")
	_oa_set(hc, &o.requested_scope, o.granted_scope)
	_oa_apply(hc)
	_oa_arm_refresh(hc)
}

@(private)
_oa_arm_refresh :: proc(hc: ^Http_Client) {
	o := hc.oauth
	if o.refresh_t != 0 {
		prim.timer_cancel(hc.loop, o.refresh_t)
		o.refresh_t = 0
	}
	if o.refresh_token == "" || o.token_ep == "" || o.expires_at <= 0 || hc.closing {
		return
	}
	remaining := o.expires_at - prim.now_ms()
	margin := min(i64(30_000), max(remaining / 5, 0))
	o.refresh_t = prim.timer(hc.loop, max(remaining - margin, 0), hc, proc(l: ^prim.Loop, data: rawptr) {
		hc := (^Http_Client)(data)
		o := hc.oauth
		o.refresh_t = 0
		if o.phase != .Idle || o.refresh_token == "" || hc.closing {
			return
		}
		o.proactive = true
		_oa_refresh(hc)
	})
}
