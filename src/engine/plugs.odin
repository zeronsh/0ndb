package engine

import "core:crypto/blake2b"
import "core:fmt"
import "../fs"
import "../http"
import "../prim"

@(private)
Plug_State :: struct {
	curl:      http.Curl,
	curl_on:   bool,
	reg:       fs.Registry,
	reg_on:    bool,
	mounts:    [dynamic]^Mounted,
}

@(private)
Mounted :: struct {
	object: Object,
	mount:  fs.Mount,
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
		if aerr := fs.registry_attach(&e.plug.reg, e.loop, _on_mount_ready, e); aerr != .None {
			return nil, _ferr(aerr)
		}
		e.plug.mounts = make([dynamic]^Mounted, e.allocator)
	}
	return &e.plug.reg, .None
}

tree_mount :: proc(e: ^Engine, o: Object, root: string, opts := fs.DEFAULT_MOUNT) -> (m: ^fs.Mount, err: Error) {
	context = context_for(e)
	reg := registry(e) or_return
	hist := tree_history(e, o) or_return
	defer if err != .None {
		tree_release(e, o)
	}
	db := device_odb(e) or_return
	mid := _mount_id(o.id, root)
	hx := prim.id_hex(mid)
	state := _join(context.temp_allocator, e.dir, "worktrees", string(hx[:])) or_return
	_perr(prim.mkdir_all(e.base, state, 0o700)) or_return
	mt := new(Mounted, e.allocator)
	mt.object = o
	mo := opts
	mo.idle_ms = 0
	if merr := fs.mount_open(&mt.mount, reg, hist, db, mid, root, state, e.self, mo, e.allocator); merr != .None {
		free(mt, e.allocator)
		return nil, _ferr(merr)
	}
	append(&e.plug.mounts, mt)
	return &mt.mount, .None
}

tree_unmount :: proc(e: ^Engine, m: ^fs.Mount) {
	context = context_for(e)
	for mt, i in e.plug.mounts {
		if &mt.mount == m {
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
	if err := fs.mount_run(m); err != .None {
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
	if h.hist != nil && fs.history_durable_mark(h.hist) > h.hist.durable {
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
		if len(mt.mount.dirty) == 0 && !mt.mount.rescan {
			continue
		}
		if err := fs.mount_run(&mt.mount); err != .None {
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
_mounts_changed :: proc(e: ^Engine) {
	if !e.plug.reg_on || len(e.changed) == 0 {
		return
	}
	for mt in e.plug.mounts {
		c, ok := e.changed[mt.object.id]
		if !ok || c.kinds & {.Data, .Keys, .Members, .Redacted} == {} {
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
		for mt in e.plug.mounts {
			fs.mount_close(&mt.mount)
			free(mt, e.allocator)
		}
		delete(e.plug.mounts)
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
