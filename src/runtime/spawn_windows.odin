package rt

import "core:strings"
import "../fs"
import "../observe"
import "../prim"

@(private)
Window_Spawn :: struct {
	r:        ^Runtime,
	w:        ^observe.Window,
	fallback: Spawner,
}

window_spawner :: proc(r: ^Runtime, w: ^observe.Window) -> Spawner {
	s := new(Window_Spawn, r.allocator)
	s.r = r
	s.w = w
	s.fallback = engine_spawner(r.e)
	observe.window_set_decider(w, window_decider(r))
	return Spawner{data = s, spawn = _window_spawn}
}

window_spawner_free :: proc(r: ^Runtime, sp: Spawner) {
	if sp.spawn == _window_spawn && sp.data != nil {
		s := (^Window_Spawn)(sp.data)
		if s.w.decider.data == r {
			observe.window_set_decider(s.w, {})
		}
		free(s, r.allocator)
	}
}

window_decider :: proc(r: ^Runtime) -> observe.Decider {
	return observe.Decider{data = r, decide = _window_decide}
}

@(private)
_window_spawn :: proc(data: rawptr, req: ^Spawn_Request) -> (prim.Child, prim.Error) {
	s := (^Window_Spawn)(data)
	child, err := s.fallback.spawn(s.fallback.data, req)
	if err == .None && req.observe {
		observe.window_add_root(s.w, child.pid)
	}
	return child, err
}

@(private)
_window_decide :: proc(data: rawptr, m: ^fs.Mount, w: ^observe.Write) -> (^fs.Scope, bool) {
	return nil, false
}

shell_argv :: proc(cmd: string, allocator := context.temp_allocator) -> []string {
	if git, batch, err := prim.resolve_executable("git", nil, context.temp_allocator); err == .None && !batch {
		root := prim.dir_name(prim.dir_name(git))
		for rel in ([]string{"bin/bash.exe", "usr/bin/bash.exe"}) {
			if p, perr := prim.path_join(context.temp_allocator, root, rel); perr == .None && _file_exists(p) {
				out := make([]string, 3, allocator)
				out[0] = strings.clone(p, allocator)
				out[1] = "-c"
				out[2] = cmd
				return out
			}
		}
	}
	out := make([]string, 5, allocator)
	out[0] = "powershell.exe"
	out[1] = "-NoProfile"
	out[2] = "-NonInteractive"
	out[3] = "-Command"
	out[4] = cmd
	return out
}

@(private)
_file_exists :: proc(p: string) -> bool {
	st, err := prim.stat(prim.os_vfs(), p)
	return err == .None && st.kind == .File
}
