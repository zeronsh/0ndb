package fs

import "core:strings"
import "../crdt"
import "../prim"

SWITCH_INGEST :: u8(1)
SWITCH_TARGET :: u8(2)
SWITCH_GIT :: u8(3)

Switch_Done :: #type proc(m: ^Mount, err: Error, data: rawptr)

registry_set_spawner :: proc(reg: ^Registry, spawner: Spawner) {
	reg.spawner = spawner
}

mount_line_switch :: proc(m: ^Mount, to_key: string, done: Switch_Done = nil, data: rawptr = nil) -> Error {
	to := line_name_of(m, to_key)
	if !m.has_git || !m.opts.follow_branch || m.reg == nil || m.reg.spawner.run == nil {
		return .Unsupported
	}
	if len(m.switch_to) > 0 {
		return .Busy
	}
	if to == m.line {
		if done != nil {
			done(m, .None, data)
		}
		return .None
	}
	if _, ok := line_commit(m, to); !ok {
		return .Not_Found
	}
	mount_sync(m) or_return
	m.switch_from, _ = clone_string(m.line, m.allocator)
	m.switch_to, _ = clone_string(to, m.allocator)
	m.switch_phase = SWITCH_INGEST
	m.switch_done = done
	m.switch_data = data
	if err := save_mount_state(m); err != .None {
		switch_clear(m)
		return err
	}
	mount_switch_step(m)
	return .None
}

mount_switch_pending :: proc(m: ^Mount) -> (to: string, pending: bool) {
	return m.switch_to, len(m.switch_to) > 0
}

mount_switch_step :: proc(m: ^Mount) {
	if len(m.switch_to) == 0 {
		return
	}
	if _, err := switch_advance(m); err == .Deferred {
		return
	} else if err == .Reloading {
		mount_reload_retry(m)
	} else if err != .None {
		switch_report(m, err)
	}
}

@(private)
switch_advance :: proc(m: ^Mount) -> (finished: bool, err: Error) {
	if m.pass != nil {
		return false, .None
	}
	to, _ := clone_string(m.switch_to, context.temp_allocator)
	from, _ := clone_string(m.switch_from, context.temp_allocator)
	if m.switch_phase <= SWITCH_INGEST {
		if len(m.dirty) > 0 || m.rescan {
			mount_pass(m, false) or_return
		}
		if !mount_durable_now(m) {
			return false, .None
		}
		switch_line_ensure(m, to) or_return
		delete(m.line, m.allocator)
		m.line, _ = clone_string(to, m.allocator)
		mount_line_actor(m) or_return
		m.switch_phase = SWITCH_TARGET
		save_mount_state(m) or_return
	}
	if m.switch_phase == SWITCH_TARGET {
		if m.line != to {
			return false, .Conflicts
		}
		switch_line_ensure(m, to) or_return
		mount_materialize(m) or_return
		target, found := history_line(m.history, to, context.temp_allocator) or_return
		if !found || !version_same(m, target) {
			return false, .None
		}
		m.switch_phase = SWITCH_GIT
		save_mount_state(m) or_return
	}
	spawner := m.reg.spawner if m.reg != nil else Spawner{}
	if spawner.run == nil {
		return false, .None
	}
	commit, ok := line_commit(m, to)
	if !ok {
		return false, .Not_Found
	}
	lock, _ := path_join(m.git.dir, "index.lock", context.temp_allocator)
	if prim.exists(m.vfs, lock) {
		mount_git_lock(m, true)
		if !mount_lock_stale(m) {
			return false, .None
		}
		prim.remove(m.vfs, lock)
	}
	spawner.run(spawner.data, []string{"git", "read-tree", commit}, m.root) or_return
	spawner.run(spawner.data, []string{"git", "update-index", "-q", "--refresh"}, m.root)
	msg := strings.concatenate({"0ndb: switch from ", line_ref_name(m, from), " to ", line_ref_name(m, to)}, context.temp_allocator)
	if ref, is_ref := line_ref(m, to); is_ref {
		spawner.run(spawner.data, []string{"git", "symbolic-ref", "-m", msg, "HEAD", ref}, m.root) or_return
	} else {
		spawner.run(spawner.data, []string{"git", "update-ref", "--no-deref", "-m", msg, "HEAD", commit}, m.root) or_return
	}
	git_head_destroy(&m.head, m.allocator)
	m.head, _ = git_head(m.vfs, m.git, m.allocator)
	m.reflog_pos = git_reflog_len(m.vfs, m.git)
	m.stamp = git_index_stamp(m.vfs, m.git)
	delete(m.branch, m.allocator)
	m.branch, _ = clone_string(to, m.allocator)
	done, data := m.switch_done, m.switch_data
	switch_clear(m)
	save_mount_state(m) or_return
	if m.reg != nil && m.reg.on_line != nil {
		m.reg.on_line(m, line_key_of(m, from, context.temp_allocator), line_key_of(m, to, context.temp_allocator), m.reg.hook_data)
	}
	if done != nil {
		done(m, .None, data)
	}
	return true, .None
}

@(private)
switch_report :: proc(m: ^Mount, err: Error) {
	done, data := m.switch_done, m.switch_data
	m.switch_done = nil
	m.switch_data = nil
	if done != nil {
		done(m, err, data)
	}
}

@(private)
switch_clear :: proc(m: ^Mount) {
	delete(m.switch_to, m.allocator)
	m.switch_to = ""
	delete(m.switch_from, m.allocator)
	m.switch_from = ""
	m.switch_phase = 0
	m.switch_done = nil
	m.switch_data = nil
}

@(private)
version_same :: proc(m: ^Mount, v: Version) -> bool {
	h := m.history
	a := make([dynamic]crdt.Lv, context.temp_allocator)
	b := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, v, &a) != .None || crdt.graph_version_lvs(&h.g, m.synced[:], &b) != .None {
		return false
	}
	return crdt.frontier_eq(a[:], b[:])
}

@(private)
line_ref :: proc(m: ^Mount, line: string) -> (ref: string, is_ref: bool) {
	if line == m.home_line {
		return m.home, len(m.home) > 0
	}
	if strings.has_prefix(line, "git:detached:") {
		return "", false
	}
	if strings.has_prefix(line, "git:") {
		return line[len("git:"):], true
	}
	return "", false
}

@(private)
line_ref_name :: proc(m: ^Mount, line: string) -> string {
	if ref, is_ref := line_ref(m, line); is_ref {
		return strings.trim_prefix(ref, "refs/heads/")
	}
	if strings.has_prefix(line, "git:detached:") {
		return line[len("git:detached:"):]
	}
	return line
}

@(private)
line_commit :: proc(m: ^Mount, line: string) -> (commit: string, ok: bool) {
	if strings.has_prefix(line, "git:detached:") {
		return line[len("git:detached:"):], true
	}
	ref, is_ref := line_ref(m, line)
	if !is_ref {
		return "", false
	}
	return git_resolve_ref(m.vfs, m.git, ref, context.temp_allocator)
}

@(private)
switch_line_ensure :: proc(m: ^Mount, to: string) -> Error {
	if _, found := history_line(m.history, to, context.temp_allocator) or_return; found {
		return .None
	}
	commit, ok := line_commit(m, to)
	if !ok {
		return .Not_Found
	}
	ref, is_ref := line_ref(m, to)
	_, err := line_from_commit(m, to, m.synced[:], commit, ref if is_ref else "")
	return err
}
