package fs

import "../prim"

git_pid_alive :: proc(pid: prim.Pid) -> bool {
	return pid > 0
}

git_proc_argv :: proc(pid: prim.Pid, allocator := context.temp_allocator) -> []string {
	return nil
}

git_lock_procs :: proc(lock: string, roots: []string, allocator := context.temp_allocator) -> []Git_Proc {
	return nil
}
