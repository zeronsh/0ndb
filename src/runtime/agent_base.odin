package rt

import "core:strings"
import "../agent"
import "../fs"

@(private)
File_Hold :: struct {
	tool:  string,
	scope: ^fs.Scope,
	rel:   string,
}

@(private)
_run_file :: proc(run: ^Run, path: string) -> (m: ^fs.Mount, rel: string, ok: bool) {
	if run.ws == nil || len(path) == 0 {
		return
	}
	for mb in run.ws.members {
		if mb.m == nil {
			continue
		}
		root := mb.m.root
		if len(path) > len(root) + 1 && strings.has_prefix(path, root) && (path[len(root)] == '/' || path[len(root)] == '\\') {
			r, _ := strings.replace_all(path[len(root) + 1:], "\\", "/", context.temp_allocator)
			return mb.m, r, true
		}
	}
	return
}

@(private)
_run_tool_index :: proc(run: ^Run, id: string) -> int {
	for t, i in run.tools {
		if t.id == id {
			return i
		}
	}
	return -1
}

run_file_write_begin :: proc(run: ^Run, tool, path: string) {
	m, rel, ok := _run_file(run, path)
	if !ok {
		return
	}
	s := _run_scope(run, m, _run_tool_index(run, tool))
	if s == nil {
		return
	}
	fs.scope_write_begin(s, rel)
	if run.file_holds == nil {
		run.file_holds = make([dynamic]File_Hold, run.alloc)
	}
	append(&run.file_holds, File_Hold{tool = clone(tool, run.alloc), scope = s, rel = clone(rel, run.alloc)})
}

run_file_base :: proc(run: ^Run, tool, path, base: string, kind: agent.File_Base_Kind) {
	m, rel, ok := _run_file(run, path)
	if !ok {
		return
	}
	switch kind {
	case .Write:
		for h in run.file_holds {
			if h.tool == tool && h.rel == rel {
				fs.scope_write_base(h.scope, rel, transmute([]u8)base)
				return
			}
		}
	case .Read:
		if s := _run_scope(run, m, _run_tool_index(run, tool)); s != nil {
			fs.scope_read_base(s, rel, transmute([]u8)base)
		}
	}
}

run_file_tool_end :: proc(run: ^Run, tool: string) {
	i := 0
	for i < len(run.file_holds) {
		h := run.file_holds[i]
		if h.tool == tool {
			fs.scope_write_end(h.scope, h.rel)
			ordered_remove(&run.file_holds, i)
			continue
		}
		i += 1
	}
}
