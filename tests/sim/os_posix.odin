#+build linux, darwin
package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:sys/posix"
import "../../src/prim"

os_region_map :: proc(base: uintptr, size: uint) -> (ok: bool, why: string) {
	ptr := posix.mmap(rawptr(base), size, {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS})
	if ptr == posix.MAP_FAILED {
		return false, fmt.tprintf("mmap failed: %v", posix.errno())
	}
	if uintptr(ptr) != base {
		posix.munmap(ptr, size)
		return false, fmt.tprintf("the range is in use; the kernel placed it at %p", ptr)
	}
	return true, ""
}

os_region_unmap :: proc(base: uintptr, size: uint) {
	posix.munmap(rawptr(base), size)
}

os_region_discard :: proc(base: uintptr, used: uint) {
	posix.posix_madvise(rawptr(base), used, .DONTNEED)
}

loop_ready :: proc(l: ^prim.Loop) -> bool {
	when ODIN_OS == .Linux {
		fd := posix.FD(l.os.epfd)
	} else {
		fd := posix.FD(l.os.kq)
	}
	fds := [1]posix.pollfd{{fd = fd, events = {.IN}}}
	return posix.poll(&fds[0], 1, 0) > 0
}

os_stats_write :: proc(fd: u64, data: []u8) {
	posix.write(posix.FD(fd), raw_data(data), len(data))
}

os_child_run :: proc(env_in: []string, buf: []u8) -> (got: int, sig: i32, code: i32, err: string) {
	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK {
		return 0, 0, 0, "pipe failed"
	}
	env := make([dynamic]cstring, context.temp_allocator)
	for kv in env_in {
		append(&env, strings.clone_to_cstring(kv, context.temp_allocator))
	}
	append(&env, strings.clone_to_cstring(fmt.tprintf("SIM_STATS_FD=%d", fds[1]), context.temp_allocator))
	append(&env, nil)
	exe_path, perr := os.get_executable_path(context.temp_allocator)
	if perr != nil {
		exe_path = os.args[0]
	}
	exe := strings.clone_to_cstring(exe_path, context.temp_allocator)
	argv := [2]cstring{exe, nil}
	pid := posix.fork()
	if pid == 0 {
		posix.close(fds[0])
		posix.execve(exe, raw_data(argv[:]), raw_data(env[:]))
		posix._exit(127)
	}
	posix.close(fds[1])
	if pid < 0 {
		posix.close(fds[0])
		return 0, 0, 0, "fork failed"
	}
	limit := i64(env_u64("SIM_CHILD_TIMEOUT", 300)) * 1000
	started := time.tick_now()
	hung := false
	for got < len(buf) {
		left := limit - i64(time.duration_milliseconds(time.tick_since(started)))
		if left <= 0 {
			hung = true
			posix.kill(pid, .SIGKILL)
			break
		}
		pfd := [1]posix.pollfd{{fd = fds[0], events = {.IN}}}
		if posix.poll(&pfd[0], 1, i32(min(left, 1000))) <= 0 {
			continue
		}
		n := posix.read(fds[0], &buf[got], uint(len(buf)) - uint(got))
		if n <= 0 {
			break
		}
		got += int(n)
	}
	posix.close(fds[0])
	status: i32
	for {
		r := posix.waitpid(pid, &status, {})
		if r == pid {
			break
		}
		if r < 0 && posix.errno() != .EINTR {
			return got, 0, 0, "waitpid failed"
		}
	}
	if hung {
		return got, 0, 0, fmt.tprintf("HUNG: no result after %d s (killed)", limit / 1000)
	}
	return got, status & 0x7f, (status >> 8) & 0xff, ""
}
