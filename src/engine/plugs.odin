package engine

import "core:crypto/blake2b"
import "core:fmt"
import "core:strings"
import "core:thread"
import "../fs"
import "../http"
import "../prim"

Refused :: struct {
	object: Object,
	root:   string,
}

@(private)
Plug_State :: struct {
	curl:      http.Curl,
	curl_on:   bool,
	reg:       fs.Registry,
	reg_on:    bool,
	mounts:    [dynamic]^Mounted,
	refused:   [dynamic]Refused,
	jobs:      [dynamic]^Fs_Job,
}

@(private)
Fs_Job :: struct {
	e:    ^Engine,
	job:  proc(arg: rawptr),
	done: proc(arg: rawptr),
	arg:  rawptr,
	th:   ^thread.Thread,
	ran:  bool,
}

@(private)
_fs_exec :: proc(data: rawptr, job: proc(arg: rawptr), done: proc(arg: rawptr), arg: rawptr) {
	e := (^Engine)(data)
	fj := new(Fs_Job, e.allocator)
	fj^ = {e = e, job = job, done = done, arg = arg}
	fj.th = thread.create_and_start_with_data(fj, _fs_job_main, init_context = context)
	if fj.th == nil {
		job(arg)
		done(arg)
		free(fj, e.allocator)
		return
	}
	append(&e.plug.jobs, fj)
}

@(private)
_fs_job_main :: proc(data: rawptr) {
	fj := (^Fs_Job)(data)
	fj.job(fj.arg)
	post(fj.e, _fs_job_done, fj)
}

@(private)
_fs_job_done :: proc(e: ^Engine, data: rawptr) {
	fj := (^Fs_Job)(data)
	if !fj.ran {
		_fs_job_finish(e, fj)
	}
	free(fj, e.allocator)
}

@(private)
_fs_job_finish :: proc(e: ^Engine, fj: ^Fs_Job) {
	thread.join(fj.th)
	thread.destroy(fj.th)
	fj.th = nil
	fj.ran = true
	for x, i in e.plug.jobs {
		if x == fj {
			unordered_remove(&e.plug.jobs, i)
			break
		}
	}
	fj.done(fj.arg)
}

@(private)
Mounted :: struct {
	object:  Object,
	mount:   fs.Mount,
	pending: bool,
	durable: Mount_Done,
}

Boot_Source :: struct {
	data:    rawptr,
	boot_id: proc(data: rawptr) -> prim.Id,
}

boot_id :: proc(e: ^Engine) -> prim.Id {
	context = context_for(e)
	if e.cfg.boot_id.boot_id != nil {
		return e.cfg.boot_id.boot_id(e.cfg.boot_id.data)
	}
	return os_boot_id()
}

os_boot_id :: proc() -> (id: prim.Id) {
	raw := _os_boot_raw()
	if len(raw) == 0 {
		return
	}
	ctx: blake2b.Context
	blake2b.init(&ctx, 16)
	blake2b.update(&ctx, raw)
	blake2b.final(&ctx, id[:])
	return
}

default_spawner :: proc "contextless" () -> Spawner {
	return Spawner{spawn = _default_spawn}
}

@(private)
_default_spawn :: proc(data: rawptr, argv: []string, cwd: string, env: []string, new_group: bool) -> (prim.Child, prim.Error) {
	return prim.spawn(argv, cwd, env, new_group)
}

spawner :: proc(e: ^Engine) -> Spawner {
	context = context_for(e)
	if e.cfg.spawner.spawn != nil {
		return e.cfg.spawner
	}
	return default_spawner()
}

http_client :: proc(e: ^Engine) -> (c: ^http.Client, err: Error) {
	context = context_for(e)
	if e.cfg.http.start == nil {
		e.cfg.http = http.Client{data = e, start = _curl_start, cancel = _curl_cancel, resume = _curl_resume}
	}
	return &e.cfg.http, .None
}

@(private)
_curl_start :: proc(data: rawptr, req: ^http.Request, sink: http.Sink) -> (http.Id, http.Error) {
	e := (^Engine)(data)
	if !e.plug.curl_on {
		if !http.curl_init(&e.plug.curl, e.loop, e.allocator) {
			return {}, .Unsupported
		}
		e.plug.curl_on = true
	}
	return http.curl_start(&e.plug.curl, req, sink)
}

@(private)
_curl_cancel :: proc(data: rawptr, id: http.Id) {
	e := (^Engine)(data)
	if e.plug.curl_on {
		http.curl_cancel(&e.plug.curl, id)
	}
}

@(private)
_curl_resume :: proc(data: rawptr, id: http.Id) {
	e := (^Engine)(data)
	if e.plug.curl_on {
		http.curl_resume(&e.plug.curl, id)
	}
}

@(private)
_curl_settle :: proc(e: ^Engine) {
	if e.plug.curl_on && http.curl_active(&e.plug.curl) == 0 {
		http.curl_destroy(&e.plug.curl)
		e.plug.curl_on = false
	}
}

registry :: proc(e: ^Engine) -> (reg: ^fs.Registry, err: Error) {
	context = context_for(e)
	if !e.plug.reg_on {
		run := _join(context.temp_allocator, e.dir, "run") or_return
		_ferr(fs.registry_init(&e.plug.reg, e.base, run, e.allocator, e.cfg.random)) or_return
		e.plug.reg_on = true
		e.plug.jobs = make([dynamic]^Fs_Job, e.allocator)
		fs.registry_set_exec(&e.plug.reg, e.cfg.fs_exec if e.cfg.fs_exec.run != nil else fs.Sync_Exec{data = e, run = _fs_exec})
		fs.registry_set_base_note(&e.plug.reg, _on_base_note, e)
		fs.registry_set_boot(&e.plug.reg, boot_id(e))
		if e.cfg.watcher.start != nil {
			_ferr(fs.registry_set_watcher(&e.plug.reg, e.cfg.watcher)) or_return
		}
		if e.cfg.write_observer.start != nil {
			if oerr := fs.registry_set_observer(&e.plug.reg, e.cfg.write_observer); oerr != .None {
				_log(e, .Warn, "write observer unavailable")
			}
		}
		fs.registry_set_line_hooks(&e.plug.reg, _on_mount_line, nil, e)
		if aerr := fs.registry_attach(&e.plug.reg, e.loop, _on_mount_ready, e); aerr != .None {
			return nil, _ferr(aerr)
		}
		e.plug.mounts = make([dynamic]^Mounted, e.allocator)
		e.plug.refused = make([dynamic]Refused, e.allocator)
	}
	return &e.plug.reg, .None
}

tree_mount :: proc(e: ^Engine, o: Object, root: string, opts := fs.DEFAULT_MOUNT, durable: Mount_Done = {}) -> (m: ^fs.Mount, err: Error) {
	context = context_for(e)
	reg := registry(e) or_return
	for r in e.plug.refused {
		if r.object != o && fs.path_same(r.root, root) {
			return nil, .Newer
		}
	}
	hist, herr := tree_history(e, o)
	if herr == .Newer {
		_refuse(e, o, root) or_return
	}
	if herr != .None {
		return nil, herr
	}
	defer if m == nil {
		tree_release(e, o)
	}
	tree_refused_clear(e, root)
	db := device_odb(e) or_return
	mid := _mount_id(o.id, root)
	hx := prim.id_hex(mid)
	trees := _join(context.temp_allocator, e.dir, "worktrees") or_return
	state := _join(context.temp_allocator, trees, string(hx[:])) or_return
	if !prim.is_dir(e.base, state) {
		new_trees := !prim.is_dir(e.base, trees)
		_perr(prim.mkdir_all(e.base, state, 0o700)) or_return
		if new_trees {
			_perr(prim.sync_dir(e.base, e.dir)) or_return
		}
		_perr(prim.sync_dir(e.base, trees)) or_return
	}
	mt := new(Mounted, e.allocator)
	mt.object = o
	mo := opts
	mo.idle_ms = 0
	if merr := fs.mount_open(&mt.mount, reg, hist, db, mid, root, state, e.self, mo, e.allocator); merr != .None {
		free(mt, e.allocator)
		return nil, _ferr(merr)
	}
	append(&e.plug.mounts, mt)
	if o.id in e.reg.staged {
		mt.pending = true
		mt.durable = durable
		return &mt.mount, .Pending
	}
	return &mt.mount, .None
}

@(private)
_refuse :: proc(e: ^Engine, o: Object, root: string) -> Error {
	for r in e.plug.refused {
		if fs.path_same(r.root, root) {
			return .None
		}
	}
	c, aerr := strings.clone(root, e.allocator)
	if aerr != nil {
		return .No_Memory
	}
	if _, perr := append(&e.plug.refused, Refused{o, c}); perr != nil {
		delete(c, e.allocator)
		return .No_Memory
	}
	return .None
}

tree_refused :: proc(e: ^Engine) -> []Refused {
	return e.plug.refused[:]
}

tree_refused_clear :: proc(e: ^Engine, root: string) -> bool {
	for r, i in e.plug.refused {
		if fs.path_same(r.root, root) {
			delete(r.root, e.allocator)
			ordered_remove(&e.plug.refused, i)
			return true
		}
	}
	return false
}

@(private)
_mounts_durable :: proc(e: ^Engine) {
	for mt in e.plug.mounts {
		if mt.pending && mt.object.id not_in e.reg.staged {
			_mount_settled(e, mt, .None)
		}
	}
}

@(private)
_mount_settled :: proc(e: ^Engine, mt: ^Mounted, err: Error) {
	mt.pending = false
	d := mt.durable
	mt.durable = {}
	if d.call != nil {
		d.call(d.data, e, &mt.mount, err)
	}
}

tree_unmount :: proc(e: ^Engine, m: ^fs.Mount) {
	context = context_for(e)
	for mt, i in e.plug.mounts {
		if &mt.mount == m {
			if mt.pending {
				_mount_settled(e, mt, .Closed)
			}
			fs.mount_close(&mt.mount)
			tree_release(e, mt.object)
			ordered_remove(&e.plug.mounts, i)
			free(mt, e.allocator)
			return
		}
	}
}

@(private)
_mount_id :: proc(tree: prim.Id, root: string) -> (id: prim.Id) {
	ctx: blake2b.Context
	blake2b.init(&ctx, 16)
	t := tree
	blake2b.update(&ctx, t[:])
	blake2b.update(&ctx, transmute([]u8)root)
	blake2b.final(&ctx, id[:])
	return
}

@(private)
_on_mount_ready :: proc(m: ^fs.Mount, data: rawptr) {
	e := (^Engine)(data)
	context = context_for(e)
	if err := fs.mount_run(m, true); err != .None {
		_log(e, .Warn, "mount pass failed")
	}
	for mt in e.plug.mounts {
		if &mt.mount == m {
			_mount_touched(e, mt)
			return
		}
	}
}

@(private)
_mount_touched :: proc(e: ^Engine, mt: ^Mounted) {
	h, err := _handle_get(e, mt.object, .File_Tree)
	if err != .None {
		return
	}
	if h.w_open && _own_len(h) > h.published {
		_handle_mark(h)
	}
	if h.hist != nil && fs.history_durable_mark(h.hist) > h.hist.durable || len(e.move_waits) > 0 {
		_touch(e)
	}
}

Mount_Done :: struct {
	data: rawptr,
	call: proc(data: rawptr, e: ^Engine, m: ^fs.Mount, err: Error),
}

@(private)
Fence_Ctx :: struct {
	e:    ^Engine,
	done: Mount_Done,
}

tree_mount_fence :: proc(e: ^Engine, m: ^fs.Mount, done: Mount_Done = {}) -> Error {
	context = context_for(e)
	ctx := new(Fence_Ctx, e.allocator)
	ctx.e = e
	ctx.done = done
	if err := fs.mount_fence(m, _mount_fenced, ctx); err != .None {
		free(ctx, e.allocator)
		return _ferr(err)
	}
	return .None
}

@(private)
_mount_fenced :: proc(m: ^fs.Mount, data: rawptr, err: fs.Error) {
	ctx := (^Fence_Ctx)(data)
	e := ctx.e
	context = context_for(e)
	for mt in e.plug.mounts {
		if &mt.mount == m {
			_mount_touched(e, mt)
		}
	}
	if ctx.done.call != nil {
		{
			context = _outer(e)
			ctx.done.call(ctx.done.data, e, m, _ferr(err))
		}
	}
	free(ctx, e.allocator)
}

@(private)
_mounts_settle :: proc(e: ^Engine) {
	if !e.plug.reg_on {
		return
	}
	for mt in e.plug.mounts {
		if len(mt.mount.dirty) == 0 && !mt.mount.rescan || fs.mount_lock_held(&mt.mount) {
			continue
		}
		if err := fs.mount_run(&mt.mount, true); err != .None {
			_log(e, .Warn, "mount pass failed")
		}
		_mount_touched(e, mt)
	}
	for m in e.plug.reg.mounts {
		if m != nil && m.awake {
			fs.mount_hibernate(m)
		}
	}
}

@(private)
_mounts_wake :: proc(e: ^Engine, object: prim.Id) {
	if !e.plug.reg_on {
		return
	}
	for mt in e.plug.mounts {
		if mt.object.id == object {
			fs.mount_schedule(&mt.mount, fs.mount_coalesce_ms(&mt.mount))
		}
	}
}

@(private)
_mounts_wake_now :: proc(e: ^Engine, object: prim.Id) {
	if !e.plug.reg_on {
		return
	}
	for mt in e.plug.mounts {
		if mt.object.id == object {
			fs.mount_materialize_soon(&mt.mount)
		}
	}
}

@(private)
_mounts_changed :: proc(e: ^Engine) {
	if !e.plug.reg_on || len(e.changed) == 0 {
		return
	}
	for mt in e.plug.mounts {
		c, ok := e.changed[mt.object.id]
		if !ok || c.kinds & {.Data, .Keys, .Members} == {} {
			continue
		}
		h, err := _handle_get(e, mt.object, .File_Tree)
		if err != .None {
			continue
		}
		_hist_catch_up(e, h)
		fs.mount_schedule(&mt.mount, 0)
	}
}

@(private)
_mounts_commit :: proc(e: ^Engine) {
	if !e.plug.reg_on {
		return
	}
	for mt in e.plug.mounts {
		if h, ok := e.handles[mt.object.id]; ok && h.w_open && _own_len(h) > h.published {
			h.local = true
		}
	}
}

@(private)
_plugs_close :: proc(e: ^Engine) {
	if e.plug.reg_on {
		for len(e.plug.jobs) > 0 {
			_fs_job_finish(e, e.plug.jobs[len(e.plug.jobs) - 1])
		}
		delete(e.plug.jobs)
		for mt in e.plug.mounts {
			if mt.pending {
				_mount_settled(e, mt, .Closed)
			}
			fs.mount_close(&mt.mount)
			free(mt, e.allocator)
		}
		delete(e.plug.mounts)
		for r in e.plug.refused {
			delete(r.root, e.allocator)
		}
		delete(e.plug.refused)
		fs.registry_destroy(&e.plug.reg)
		e.plug.reg_on = false
	}
	if e.plug.curl_on {
		http.curl_destroy(&e.plug.curl)
		e.plug.curl_on = false
	}
}

@(private)
_on_base_note :: proc(m: ^fs.Mount, rel: string, note: fs.Base_Note, data: rawptr) {
	e := (^Engine)(data)
	switch note {
	case .Merged:
		e.stats.base_merged += 1
	case .Current:
		e.stats.base_current += 1
	case .Mismatch:
		e.stats.base_mismatch += 1
	case .Not_Text:
		e.stats.base_not_text += 1
	}
	_log(e, .Debug, fmt.tprintf("agent write base for %s: %v", rel, note))
}

@(private)
_on_mount_line :: proc(m: ^fs.Mount, from, to: string, data: rawptr) {
	e := (^Engine)(data)
	context = context_for(e)
	for mt in e.plug.mounts {
		if &mt.mount == m {
			detail := strings.concatenate({from, "\n", to}, context.temp_allocator)
			_emit(e, Event{kind = .Line_Switched, space = mt.object.space, object = mt.object.id, detail = detail})
			return
		}
	}
}

line_switch_parts :: proc(ev: ^Event) -> (from, to: string) {
	i := strings.index_byte(ev.detail, '\n')
	if i < 0 {
		return "", ev.detail
	}
	return ev.detail[:i], ev.detail[i + 1:]
}
