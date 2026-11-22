package engine

import "base:runtime"
import "core:crypto/blake2b"
import "core:strings"
import "../fs"
import omap "../map"
import "../odb"
import "../prim"

CATALOG_REMOTE :: u32(33)

@(private)
GIT_JOBS_MAX :: 4
@(private)
GIT_OIDS_MAX :: 65536
@(private)
GIT_ERR_KEEP :: 4096

Git_Fetch :: struct {
	url:     string,
	git_dir: string,
	format:  odb.Hash_Format,
	oids:    []odb.Oid,
	env:     []string,
	impl:    rawptr,
}

Git_Remote :: struct {
	data:   rawptr,
	fetch:  proc(data: rawptr, e: ^Engine, req: ^Git_Fetch) -> Error,
	cancel: proc(data: rawptr, e: ^Engine, req: ^Git_Fetch),
}

Git_Credentials :: struct {
	data:   rawptr,
	env:    proc(data: rawptr, url: string, allocator: runtime.Allocator) -> []string,
	begin:  proc(data: rawptr, url: string, done: Git_Cred_Done) -> Error,
	cancel: proc(data: rawptr, done: Git_Cred_Done),
}

Git_Cred_Done :: struct {
	data: rawptr,
	call: proc(data: rawptr, err: Error, env: []string),
}

@(private)
Git_State :: struct {
	pending: [dynamic]odb.Oid,
	reqs:    [dynamic]^Git_Req,
	splits:  [dynamic]Git_Split,
}

@(private)
Git_Split :: struct {
	space:  prim.Id,
	object: prim.Id,
	url:    int,
	oids:   [dynamic]odb.Oid,
}

@(private)
Git_Req :: struct {
	fetch:  Git_Fetch,
	space:  prim.Id,
	object: prim.Id,
	url:    int,
	oids:   [dynamic]odb.Oid,
	env:    [dynamic]string,
	done:   bool,
	e:      ^Engine,
	creds:  bool,
}

@(private)
_git_init :: proc(e: ^Engine) {
	e.git.pending = make([dynamic]odb.Oid, e.allocator)
	e.git.reqs = make([dynamic]^Git_Req, e.allocator)
	e.git.splits = make([dynamic]Git_Split, e.allocator)
}

@(private)
_git_destroy :: proc(e: ^Engine) {
	for q in e.git.reqs {
		if q.creds {
			if e.cfg.git_credentials.cancel != nil {
				context = _outer(e)
				e.cfg.git_credentials.cancel(e.cfg.git_credentials.data, Git_Cred_Done{q, _git_cred_done})
			}
		} else if !q.done && e.cfg.git_remote.cancel != nil {
			context = _outer(e)
			e.cfg.git_remote.cancel(e.cfg.git_remote.data, e, &q.fetch)
		}
		_git_req_free(e, q)
	}
	delete(e.git.reqs)
	delete(e.git.pending)
	for s in e.git.splits {
		delete(s.oids)
	}
	delete(e.git.splits)
}

@(private)
_git_req_free :: proc(e: ^Engine, q: ^Git_Req) {
	delete(q.fetch.url, e.allocator)
	delete(q.fetch.git_dir, e.allocator)
	delete(q.oids)
	for s in q.env {
		delete(s, e.allocator)
	}
	delete(q.env)
	free(q, e.allocator)
}

@(private)
_tree_remote_urls :: proc(e: ^Engine, space: prim.Id, object: prim.Id, allocator := context.temp_allocator) -> []string {
	sp, ok := e.spaces[space]
	if !ok {
		return nil
	}
	h, herr := _catalog_handle(e, sp)
	if herr != .None {
		return nil
	}
	_map_sync(e, h)
	kb: [16]u8
	en, found, gerr := omap.table_get(&h.table, omap.catalog_key(object, &kb), context.temp_allocator)
	if gerr != .None || !found {
		return nil
	}
	v, has := omap.entry_register(&en, CATALOG_REMOTE)
	if !has || len(v) == 0 {
		return nil
	}
	out := make([dynamic]string, allocator)
	s := string(v)
	for line in strings.split_lines_iterator(&s) {
		if len(line) > 0 {
			x, _ := strings.clone(line, allocator)
			append(&out, x)
		}
	}
	return out[:]
}

@(private)
_tree_remote_note :: proc(e: ^Engine, sp: ^Space, object: prim.Id, urls: string) {
	cur := _tree_remote_urls(e, sp.id, object)
	joined := strings.join(cur, "\n", context.temp_allocator)
	if joined == urls {
		return
	}
	u := _catalog_q(e, sp.id, object, .File_Tree)
	if u == nil {
		return
	}
	delete(u.remote, e.allocator)
	u.remote, _ = _clone(urls, e.allocator)
	u.set_remote = true
}

@(private)
Tree_Reach :: struct {
	reach: fs.Remote_Reach,
	urls:  string,
	ok:    bool,
}

@(private)
_tree_git_mount :: proc(e: ^Engine, h: ^Handle) -> ^fs.Mount {
	if !e.plug.reg_on || h.hist == nil {
		return nil
	}
	for m in e.plug.reg.mounts {
		if m != nil && m.history == h.hist && m.has_git && m.git_refs && m.db != nil {
			return m
		}
	}
	return nil
}

@(private)
_tree_reach :: proc(e: ^Engine, h: ^Handle) -> (t: Tree_Reach) {
	m := _tree_git_mount(e, h)
	if m == nil {
		return
	}
	sum: [16]u8
	ctx: blake2b.Context
	blake2b.init(&ctx, 16)
	blake2b.update(&ctx, transmute([]u8)string("0ndb remote reach v1"))
	blake2b.update(&ctx, transmute([]u8)m.git.common)
	blake2b.final(&ctx, sum[:])
	hx := prim.id_hex(prim.Id(sum))
	dir, jerr := _join(context.temp_allocator, e.dir, "remotes", string(hx[:]))
	if jerr != .None {
		return
	}
	u, uerr := fs.remote_update(m.vfs, m.db, m.git, dir)
	if uerr != .None {
		return
	}
	if u.rewritten {
		e.stats.remote_rewrites += 1
	}
	reach, ok := fs.remote_reach_load(m.vfs, dir, u.format, context.temp_allocator)
	if !ok {
		return
	}
	names := make(map[string]bool, context.temp_allocator)
	for tip in fs.git_remote_tips(m.vfs, m.git, context.temp_allocator) {
		rest := tip.ref[len("refs/remotes/"):]
		if i := strings.index_byte(rest, '/'); i > 0 {
			names[rest[:i]] = true
		}
	}
	urls := make([dynamic]string, context.temp_allocator)
	for r in fs.git_remote_urls(m.vfs, m.git, context.temp_allocator) {
		if names[r.name] && strings.index_byte(r.url, '\n') < 0 {
			append(&urls, fs.remote_url_public(r.url, context.temp_allocator))
		}
	}
	if len(urls) == 0 {
		return
	}
	t.reach = reach
	t.urls = strings.join(urls[:], "\n", context.temp_allocator)
	t.ok = true
	return
}

@(private)
_git_wanted :: proc(e: ^Engine, w: ^Content_Wait) -> bool {
	if e.cfg.git_remote.fetch == nil {
		return false
	}
	db, derr := device_odb(e)
	if derr != .None || w.n != odb.oid_size(db.format) {
		return false
	}
	urls := _tree_remote_urls(e, w.space, w.object)
	if w.url >= len(urls) {
		return false
	}
	for x in e.git.pending {
		if x == w.oid {
			return true
		}
	}
	append(&e.git.pending, w.oid)
	_touch(e)
	return true
}

@(private)
_git_flush :: proc(e: ^Engine) {
	if len(e.git.pending) == 0 && len(e.git.splits) == 0 || e.cfg.git_remote.fetch == nil {
		return
	}
	busy := 0
	for q in e.git.reqs {
		if !q.done {
			busy += 1
		}
	}
	if busy >= GIT_JOBS_MAX {
		return
	}
	db, derr := device_odb(e)
	if derr != .None {
		return
	}
	for busy < GIT_JOBS_MAX && len(e.git.splits) > 0 {
		sp := pop(&e.git.splits)
		urls := _tree_remote_urls(e, sp.space, sp.object)
		if sp.url < len(urls) {
			q := _git_req_new(e, sp.space, sp.object, sp.url, urls[sp.url])
			append(&q.oids, ..sp.oids[:])
			_git_start(e, q, db)
			busy += 1
		}
		delete(sp.oids)
	}
	pending := e.git.pending
	e.git.pending = make([dynamic]odb.Oid, e.allocator)
	defer delete(pending)
	Group :: struct {
		space:  prim.Id,
		object: prim.Id,
		url:    int,
	}
	groups := make(map[Group]^Git_Req, context.temp_allocator)
	order := make([dynamic]^Git_Req, context.temp_allocator)
	for oid in pending {
		w, ok := e.content.waits[oid]
		if !ok {
			continue
		}
		g := Group{w.space, w.object, w.url}
		q, has := groups[g]
		if !has {
			if busy >= GIT_JOBS_MAX {
				append(&e.git.pending, oid)
				continue
			}
			urls := _tree_remote_urls(e, w.space, w.object)
			if w.url >= len(urls) {
				w.inflight = false
				_content_request(e, w)
				continue
			}
			q = _git_req_new(e, w.space, w.object, w.url, urls[w.url])
			groups[g] = q
			append(&order, q)
			busy += 1
		}
		if len(q.oids) >= GIT_OIDS_MAX {
			append(&e.git.pending, oid)
			continue
		}
		append(&q.oids, oid)
		w.inflight = true
	}
	for q in order {
		_git_start(e, q, db)
	}
	if len(e.git.pending) > 0 || len(e.git.splits) > 0 {
		_touch(e)
	}
}

@(private)
_git_req_new :: proc(e: ^Engine, space, object: prim.Id, url: int, link: string) -> ^Git_Req {
	q := new(Git_Req, e.allocator)
	q.e = e
	q.space = space
	q.object = object
	q.url = url
	q.oids = make([dynamic]odb.Oid, e.allocator)
	q.env = make([dynamic]string, e.allocator)
	q.fetch.url, _ = _clone(link, e.allocator)
	return q
}

@(private)
_git_start :: proc(e: ^Engine, q: ^Git_Req, db: ^odb.Odb) {
	gd, _ := _join(e.allocator, e.dir, "objects")
	q.fetch.git_dir = gd
	q.fetch.format = db.format
	q.fetch.oids = q.oids[:]
	append(&e.git.reqs, q)
	e.stats.git_fetches += 1
	if e.cfg.git_credentials.begin != nil {
		q.creds = true
		berr: Error
		{
			context = _outer(e)
			berr = e.cfg.git_credentials.begin(e.cfg.git_credentials.data, q.fetch.url, Git_Cred_Done{q, _git_cred_done})
		}
		if berr == .None || !q.creds {
			return
		}
		q.creds = false
	} else if e.cfg.git_credentials.env != nil {
		extra: []string
		{
			context = _outer(e)
			extra = e.cfg.git_credentials.env(e.cfg.git_credentials.data, q.fetch.url, context.temp_allocator)
		}
		_git_env_add(e, q, extra)
	}
	_git_launch(e, q)
}

@(private)
_git_env_add :: proc(e: ^Engine, q: ^Git_Req, extra: []string) {
	for s in extra {
		c, _ := _clone(s, e.allocator)
		append(&q.env, c)
	}
}

@(private)
_git_cred_done :: proc(data: rawptr, err: Error, env: []string) {
	q := (^Git_Req)(data)
	e := q.e
	context = context_for(e)
	if !q.creds {
		return
	}
	q.creds = false
	if err == .None {
		_git_env_add(e, q, env)
	}
	_git_launch(e, q)
	_touch(e)
}

@(private)
_git_launch :: proc(e: ^Engine, q: ^Git_Req) {
	q.fetch.env = q.env[:]
	ferr: Error
	{
		context = _outer(e)
		ferr = e.cfg.git_remote.fetch(e.cfg.git_remote.data, e, &q.fetch)
	}
	if ferr != .None {
		_git_complete(e, q, ferr)
	}
}

git_fetch_done :: proc(e: ^Engine, req: ^Git_Fetch, err: Error) {
	context = context_for(e)
	for q in e.git.reqs {
		if &q.fetch == req {
			_git_complete(e, q, err)
			_touch(e)
			return
		}
	}
}

@(private)
_git_complete :: proc(e: ^Engine, q: ^Git_Req, err: Error) {
	if q.done {
		return
	}
	q.done = true
	db, derr := device_odb(e)
	got := 0
	left := make([dynamic]odb.Oid, context.temp_allocator)
	for oid in q.oids {
		w, ok := e.content.waits[oid]
		if !ok {
			continue
		}
		if derr == .None && odb.exists(db, oid) {
			got += 1
			_content_forget(e, w)
			continue
		}
		append(&left, oid)
	}
	if err != .None && len(left) > 1 {
		half := len(left) / 2
		for part in ([2][]odb.Oid{left[:half], left[half:]}) {
			s := Git_Split{space = q.space, object = q.object, url = q.url, oids = make([dynamic]odb.Oid, e.allocator)}
			append(&s.oids, ..part)
			append(&e.git.splits, s)
		}
		_touch(e)
	} else {
		for oid in left {
			w := e.content.waits[oid]
			w.inflight = false
			w.url = q.url + 1
			_content_request(e, w)
		}
	}
	e.stats.git_objects += u64(got)
	if err != .None {
		_log(e, .Info, "git fetch from remote failed; falling back to relay")
	}
	if got > 0 {
		_ckpt_content(e, q.space, q.object)
		_object_changed(e, q.space, q.object, .Data)
	}
	for x, i in e.git.reqs {
		if x == q {
			ordered_remove(&e.git.reqs, i)
			break
		}
	}
	_git_req_free(e, q)
}

@(private)
Git_Job :: struct {
	e:       ^Engine,
	req:     ^Git_Fetch,
	child:   prim.Child,
	w_in:    prim.Watch,
	w_out:   prim.Watch,
	w_err:   prim.Watch,
	cw:      prim.Child_Watch,
	stdin:   [dynamic]u8,
	in_pos:  int,
	errs:    [dynamic]u8,
	exited:  bool,
	out_eof: bool,
	err_eof: bool,
	status:  prim.Exit_Status,
}

default_git_remote :: proc "contextless" () -> Git_Remote {
	return Git_Remote{fetch = _git_spawn_fetch, cancel = _git_spawn_cancel}
}

@(private)
_git_spawn_fetch :: proc(data: rawptr, e: ^Engine, req: ^Git_Fetch) -> Error {
	argv := []string {
		"git",
		strings.concatenate({"--git-dir=", req.git_dir}, context.temp_allocator),
		"-c", "protocol.version=2",
		"-c", "fetch.negotiationAlgorithm=noop",
		"-c", "gc.auto=0",
		"-c", "maintenance.auto=false",
		"-c", "fetch.writeCommitGraph=false",
		"-c", "core.fsync=objects,derived-metadata",
		"-c", "core.fsyncMethod=fsync",
		"-c", "http.lowSpeedLimit=1000",
		"-c", "http.lowSpeedTime=60",
		"fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--recurse-submodules=no", "--stdin",
		req.url,
	}
	env := make([dynamic]string, context.temp_allocator)
	keys := []string{"GIT_OBJECT_DIRECTORY=", "GIT_TERMINAL_PROMPT=", "GIT_DIR=", "GIT_ALTERNATE_OBJECT_DIRECTORIES=", "GIT_WORK_TREE=", "GIT_INDEX_FILE=", "GIT_COMMON_DIR="}
	outer: for s in prim.environ(context.temp_allocator) {
		for k in keys {
			if strings.has_prefix(s, k) {
				continue outer
			}
		}
		for x in req.env {
			if i := strings.index_byte(x, '='); i > 0 && strings.has_prefix(s, x[:i + 1]) {
				continue outer
			}
		}
		append(&env, s)
	}
	append(&env, "GIT_TERMINAL_PROMPT=0")
	append(&env, ..req.env)
	sp := spawner(e)
	child, serr := sp.spawn(sp.data, argv, req.git_dir, env[:], true)
	if serr != .None {
		return .Unsupported
	}
	j := new(Git_Job, e.allocator)
	j.e = e
	j.req = req
	j.child = child
	j.stdin = make([dynamic]u8, e.allocator)
	j.errs = make([dynamic]u8, e.allocator)
	hb: [odb.MAX_HEX]u8
	for oid in req.oids {
		append(&j.stdin, ..transmute([]u8)odb.oid_to_string(oid, req.format, &hb))
		append(&j.stdin, '\n')
	}
	req.impl = j
	l := e.loop
	if child.stdout >= 0 {
		prim.set_nonblocking(child.stdout)
		j.w_out, _ = prim.watch(l, child.stdout, {.Read}, j, _git_job_on_out)
	} else {
		j.out_eof = true
	}
	if child.stderr >= 0 {
		prim.set_nonblocking(child.stderr)
		j.w_err, _ = prim.watch(l, child.stderr, {.Read}, j, _git_job_on_err)
	} else {
		j.err_eof = true
	}
	if child.stdin >= 0 {
		prim.set_nonblocking(child.stdin)
		j.w_in, _ = prim.watch(l, child.stdin, {.Write}, j, _git_job_on_in)
	}
	j.cw, _ = prim.child_watch(l, child.pid, j, _git_job_on_exit)
	return .None
}

@(private)
_git_spawn_cancel :: proc(data: rawptr, e: ^Engine, req: ^Git_Fetch) {
	j := (^Git_Job)(req.impl)
	if j == nil {
		return
	}
	req.impl = nil
	_git_job_free(j, true)
}

@(private)
_git_job_drain :: proc(fd: prim.Fd, keep: ^[dynamic]u8) -> bool {
	buf: [8192]u8
	for {
		n, err := prim.read(fd, buf[:])
		if err == .Would_Block || err == .Interrupted {
			return false
		}
		if err != .None || n == 0 {
			return true
		}
		if keep != nil {
			room := GIT_ERR_KEEP - len(keep)
			if room > 0 {
				append(keep, ..buf[:min(n, room)])
			}
		}
	}
}

@(private)
_git_job_on_out :: proc(l: ^prim.Loop, fd: prim.Fd, ev: prim.Events, data: rawptr) {
	j := (^Git_Job)(data)
	context = context_for(j.e)
	if _git_job_drain(fd, nil) {
		prim.unwatch(l, j.w_out)
		j.w_out = 0
		j.out_eof = true
		_git_job_check(j)
	}
}

@(private)
_git_job_on_err :: proc(l: ^prim.Loop, fd: prim.Fd, ev: prim.Events, data: rawptr) {
	j := (^Git_Job)(data)
	context = context_for(j.e)
	if _git_job_drain(fd, &j.errs) {
		prim.unwatch(l, j.w_err)
		j.w_err = 0
		j.err_eof = true
		_git_job_check(j)
	}
}

@(private)
_git_job_on_in :: proc(l: ^prim.Loop, fd: prim.Fd, ev: prim.Events, data: rawptr) {
	j := (^Git_Job)(data)
	context = context_for(j.e)
	for j.in_pos < len(j.stdin) {
		n, err := prim.write(fd, j.stdin[j.in_pos:])
		if err == .Would_Block || err == .Interrupted {
			return
		}
		if err != .None || n <= 0 {
			break
		}
		j.in_pos += n
	}
	prim.unwatch(l, j.w_in)
	j.w_in = 0
	prim.child_close_stdin(&j.child)
}

@(private)
_git_job_on_exit :: proc(l: ^prim.Loop, pid: prim.Pid, status: prim.Exit_Status, data: rawptr) {
	j := (^Git_Job)(data)
	context = context_for(j.e)
	j.exited = true
	j.cw = 0
	j.status = status
	if !j.out_eof && j.child.stdout >= 0 {
		_git_job_drain(j.child.stdout, nil)
	}
	if !j.err_eof && j.child.stderr >= 0 {
		_git_job_drain(j.child.stderr, &j.errs)
	}
	j.out_eof = true
	j.err_eof = true
	_git_job_check(j)
}

@(private)
_git_job_check :: proc(j: ^Git_Job) {
	if !j.exited || !j.out_eof || !j.err_eof {
		return
	}
	e := j.e
	req := j.req
	ok := j.status.code == 0 && j.status.signal == 0
	if !ok && len(j.errs) > 0 {
		_log(e, .Info, string(j.errs[:]))
	}
	req.impl = nil
	_git_job_free(j, false)
	git_fetch_done(e, req, .None if ok else .Io)
}

@(private)
_git_job_free :: proc(j: ^Git_Job, kill: bool) {
	e := j.e
	l := e.loop
	if kill && !j.exited {
		prim.child_kill(&j.child, .Kill)
	}
	if j.w_out != 0 {
		prim.unwatch(l, j.w_out)
	}
	if j.w_err != 0 {
		prim.unwatch(l, j.w_err)
	}
	if j.w_in != 0 {
		prim.unwatch(l, j.w_in)
	}
	if j.cw != 0 {
		prim.child_unwatch(l, j.cw)
	}
	prim.child_close(&j.child)
	delete(j.stdin)
	delete(j.errs)
	free(j, e.allocator)
}
