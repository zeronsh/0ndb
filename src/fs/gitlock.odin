package fs

import "core:os"
import "core:strings"
import "../prim"

GATE_MAX_MS :: 5_000

Git_Proc :: struct {
	pid:    prim.Pid,
	argv:   []string,
	holder: bool,
}

@(private)
Lock_Watch :: struct {
	pid: prim.Pid,
	cw:  prim.Child_Watch,
}

@(private)
GIT_TREE_WRITERS :: [?]string{"checkout", "switch", "reset", "restore", "merge", "rebase", "pull", "stash", "cherry-pick", "revert", "am", "apply", "read-tree", "checkout-index", "clean", "rm", "mv", "sparse-checkout", "worktree", "bisect", "submodule", "filter-branch"}

@(private)
GIT_INDEX_ONLY :: [?]string{"commit", "add", "status", "update-index", "diff", "diff-index", "diff-files", "log", "show", "fetch", "push", "tag", "branch", "notes", "ls-files", "write-tree", "commit-tree", "gc", "repack", "maintenance", "reflog", "update-ref", "symbolic-ref", "describe", "blame", "grep", "config", "rev-parse", "for-each-ref", "cat-file", "hash-object", "fsck", "prune", "count-objects", "ls-tree", "shortlog", "whatchanged", "range-diff", "format-patch"}

@(private)
GIT_VALUED_OPTIONS :: [?]string{"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--super-prefix", "--exec-path", "--list-cmds", "--attr-source"}

git_subcommand :: proc(argv: []string) -> (sub: string, ok: bool) {
	i := 1
	outer: for i < len(argv) {
		a := argv[i]
		for v in GIT_VALUED_OPTIONS {
			if a == v {
				i += 2
				continue outer
			}
		}
		if strings.has_prefix(a, "-") {
			i += 1
			continue
		}
		return a, true
	}
	return "", false
}

git_cmd_gates :: proc(vfs: prim.Vfs, argv: []string, configs: []string) -> bool {
	sub, ok := git_subcommand(argv)
	for depth := 0; ok && depth < 4; depth += 1 {
		for w in GIT_TREE_WRITERS {
			if sub == w {
				return true
			}
		}
		for x in GIT_INDEX_ONLY {
			if sub == x {
				return false
			}
		}
		alias, found := git_alias(vfs, configs, sub)
		if !found {
			return true
		}
		alias = strings.trim_space(alias)
		if strings.has_prefix(alias, "!") {
			return true
		}
		fields := strings.fields(alias, context.temp_allocator)
		if len(fields) == 0 {
			return true
		}
		sub = fields[0]
	}
	return true
}

git_alias :: proc(vfs: prim.Vfs, configs: []string, name: string) -> (value: string, found: bool) {
	for path in configs {
		data, err := prim.read_file(vfs, path, context.temp_allocator)
		if err != .None {
			continue
		}
		in_alias := false
		for raw in strings.split_lines(string(data), context.temp_allocator) {
			line := strings.trim_space(raw)
			if len(line) == 0 || line[0] == '#' || line[0] == ';' {
				continue
			}
			if line[0] == '[' {
				in_alias = strings.equal_fold(strings.trim(line, "[] \t"), "alias")
				continue
			}
			if !in_alias {
				continue
			}
			eq := strings.index_byte(line, '=')
			if eq < 0 {
				continue
			}
			if strings.equal_fold(strings.trim_space(line[:eq]), name) {
				return strings.trim_space(line[eq + 1:]), true
			}
		}
	}
	return "", false
}

@(private)
_lock_configs :: proc(m: ^Mount) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	common := m.git.common if len(m.git.common) > 0 else m.git.dir
	if p, err := path_join(common, "config", context.temp_allocator); err == nil {
		append(&out, p)
	}
	if home, ok := os.lookup_env("HOME", context.temp_allocator); ok {
		if p, err := path_join(home, ".gitconfig", context.temp_allocator); err == nil {
			append(&out, p)
		}
	}
	if xdg, ok := os.lookup_env("XDG_CONFIG_HOME", context.temp_allocator); ok {
		if p, err := path_join(xdg, "git/config", context.temp_allocator); err == nil {
			append(&out, p)
		}
	}
	return out[:]
}

mount_git_lock :: proc(m: ^Mount, held: bool) {
	if !m.has_git || m.reg == nil {
		return
	}
	if !held {
		m.lock_stale = false
		_lock_lift(m)
		return
	}
	if m.git_locked {
		return
	}
	lock, jerr := path_join(m.git.dir, "index.lock", context.temp_allocator)
	if jerr != nil {
		return
	}
	obs := m.reg.observer
	procs := make([dynamic]Git_Proc, context.temp_allocator)
	if obs.lock_creator != nil {
		if pid, ok := obs.lock_creator(obs.data, lock); ok && git_pid_alive(pid) {
			append(&procs, Git_Proc{pid = pid, argv = git_proc_argv(pid), holder = true})
		}
	}
	roots := []string{m.root, m.git.dir, m.git.common}
	if len(procs) == 0 {
		for p in git_lock_procs(lock, roots) {
			append(&procs, p)
		}
	}
	if len(procs) == 0 && obs.lock_procs != nil {
		for p in obs.lock_procs(obs.data, lock, roots, context.temp_allocator) {
			append(&procs, p)
		}
	}
	if len(procs) == 0 {
		m.lock_stale = true
		return
	}
	m.lock_stale = false
	if m.reg.loop == nil {
		return
	}
	writes := false
	configs := _lock_configs(m)
	pids := make([dynamic]prim.Pid, context.temp_allocator)
	for p in procs {
		append(&pids, p.pid)
		writes ||= len(p.argv) == 0 || git_cmd_gates(prim.os_vfs(), p.argv, configs)
	}
	if !writes {
		return
	}
	if m.lock_watches == nil {
		m.lock_watches = make([dynamic]Lock_Watch, m.allocator)
	}
	for pid in pids {
		cw, werr := prim.child_watch(m.reg.loop, pid, m, _lock_creator_exit)
		if werr == .None {
			append(&m.lock_watches, Lock_Watch{pid = pid, cw = cw})
		}
	}
	if len(m.lock_watches) == 0 {
		return
	}
	m.git_locked = true
	m.lock_first = true
	if obs.gate != nil {
		if id, ok := obs.gate(obs.data, m.root, pids[:]); ok {
			m.gate_id = id
			m.gate_timer = prim.timer(m.reg.loop, obs.gate_max_ms if obs.gate_max_ms > 0 else GATE_MAX_MS, m, _gate_overrun)
		}
	}
	mount_schedule(m, 0)
}

mount_lock_held :: proc "contextless" (m: ^Mount) -> bool {
	return m.git_locked && !m.lock_first
}

mount_lock_stale :: proc "contextless" (m: ^Mount) -> bool {
	return m.lock_stale
}

mount_gated :: proc "contextless" (m: ^Mount) -> bool {
	return m.gate_id != 0
}

mount_gate_overruns :: proc "contextless" (m: ^Mount) -> u64 {
	return m.gate_overruns
}

@(private)
_gate_release :: proc(m: ^Mount) {
	if m.gate_id == 0 {
		return
	}
	if prim.timer_pending(m.reg.loop, m.gate_timer) {
		prim.timer_cancel(m.reg.loop, m.gate_timer)
	}
	obs := m.reg.observer
	if obs.ungate != nil {
		obs.ungate(obs.data, m.gate_id)
	}
	m.gate_id = 0
}

@(private)
_gate_overrun :: proc(l: ^prim.Loop, data: rawptr) {
	m := (^Mount)(data)
	if m.gate_id == 0 {
		return
	}
	m.gate_overruns += 1
	_gate_release(m)
}

mount_unlock :: proc(m: ^Mount) {
	_gate_release(m)
	for w in m.lock_watches {
		prim.child_unwatch(m.reg.loop, w.cw)
	}
	clear(&m.lock_watches)
	m.git_locked = false
	m.lock_first = false
}

@(private)
_lock_lift :: proc(m: ^Mount) {
	if !m.git_locked {
		return
	}
	mount_unlock(m)
	mount_schedule(m, m.opts.settle_ms)
}

@(private)
_lock_creator_exit :: proc(l: ^prim.Loop, pid: prim.Pid, status: prim.Exit_Status, data: rawptr) {
	m := (^Mount)(data)
	for w, i in m.lock_watches {
		if w.pid == pid {
			unordered_remove(&m.lock_watches, i)
			break
		}
	}
	if len(m.lock_watches) > 0 {
		return
	}
	_lock_lift(m)
	if lock, jerr := path_join(m.git.dir, "index.lock", context.temp_allocator); jerr == nil && prim.exists(m.vfs, lock) {
		m.lock_stale = true
	}
}
