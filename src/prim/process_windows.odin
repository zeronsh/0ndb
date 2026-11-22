package prim

import "base:runtime"
import win "core:sys/windows"

_Child_Os :: struct {
	process: HANDLE,
	job:     HANDLE,
}

@(private)
KILLED_EXIT_CODE :: 128 + 9

@(private)
PIPE_BUFFER :: 64 * 1024

@(private)
CREATE_SUSPENDED :: 0x4
@(private)
CREATE_NEW_PROCESS_GROUP :: 0x200
@(private)
CREATE_UNICODE_ENVIRONMENT :: 0x400
@(private)
EXTENDED_STARTUPINFO_PRESENT :: 0x80000
@(private)
CREATE_NO_WINDOW :: 0x08000000
@(private)
STARTF_USESTDHANDLES :: 0x100
@(private)
PROC_THREAD_ATTRIBUTE_HANDLE_LIST :: 0x20002
@(private)
JOB_OBJECT_TERMINATE :: 0x8
@(private)
PROCESS_TERMINATE :: 0x1
@(private)
CTRL_BREAK_EVENT :: 1
@(private)
CMDLINE_MAX :: 32767

@(private)
Startup_Info_Ex :: struct {
	si:    win.STARTUPINFOW,
	attrs: rawptr,
}

@(private)
_child_os_close :: proc "contextless" (c: ^Child) {
	if c.os.process != nil {
		win.CloseHandle(c.os.process)
	}
	if c.os.job != nil {
		win.CloseHandle(c.os.job)
	}
	c.os = {}
}

@(private)
_child_kill :: proc "contextless" (c: ^Child, sig: Signal) -> Error {
	if sig == .Kill {
		if c.os.job != nil {
			if !TerminateJobObject(c.os.job, KILLED_EXIT_CODE) {
				return _last()
			}
			return .None
		}
		if c.os.process != nil {
			if !win.TerminateProcess(c.os.process, KILLED_EXIT_CODE) {
				if win.WaitForSingleObject(c.os.process, 0) == 0 {
					return .None
				}
				return _last()
			}
			return .None
		}
	}
	if c.group {
		return kill_group(c.pid, sig)
	}
	return kill_process(c.pid, sig)
}

@(private)
_job_name :: proc "contextless" (pid: Pid, out: []u16) -> [^]u16 {
	prefix := "Local\\0ndb-job-"
	n := 0
	for i in 0 ..< len(prefix) {
		out[n] = u16(prefix[i])
		n += 1
	}
	digits: [16]u16
	d := 0
	v := u32(pid)
	for {
		digits[d] = u16('0' + v % 10)
		d += 1
		v /= 10
		if v == 0 {
			break
		}
	}
	for d > 0 {
		d -= 1
		out[n] = digits[d]
		n += 1
	}
	out[n] = 0
	return raw_data(out)
}

kill_process :: proc "contextless" (pid: Pid, sig := Signal.Terminate) -> Error {
	if pid <= 0 {
		return .Invalid
	}
	if sig != .Kill {
		return .Unsupported
	}
	p := win.OpenProcess(PROCESS_TERMINATE | SYNCHRONIZE, false, u32(pid))
	if p == nil {
		code := win.GetLastError()
		if code == ERROR_INVALID_PARAMETER {
			return .Not_Found
		}
		return _werror(code)
	}
	defer win.CloseHandle(p)
	if !win.TerminateProcess(p, KILLED_EXIT_CODE) {
		if win.WaitForSingleObject(p, 0) == 0 {
			return .None
		}
		return _last()
	}
	return .None
}

kill_group :: proc "contextless" (pid: Pid, sig := Signal.Terminate) -> Error {
	if pid <= 0 {
		return .Invalid
	}
	if sig != .Kill {
		if !win.GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT, u32(pid)) {
			return .Unsupported
		}
		return .None
	}
	name: [64]u16
	job := OpenJobObjectW(JOB_OBJECT_TERMINATE, false, _job_name(pid, name[:]))
	if job == nil {
		code := win.GetLastError()
		if code == ERROR_FILE_NOT_FOUND {
			return .Not_Found
		}
		return _werror(code)
	}
	defer win.CloseHandle(job)
	if !TerminateJobObject(job, KILLED_EXIT_CODE) {
		return _last()
	}
	return .None
}

reap :: proc "contextless" (pid: Pid, block := false) -> (status: Exit_Status, done: bool, err: Error) {
	p := win.OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, false, u32(pid))
	if p == nil {
		code := win.GetLastError()
		if code == ERROR_INVALID_PARAMETER {
			return {}, false, .No_Child
		}
		return {}, false, _werror(code)
	}
	defer win.CloseHandle(p)
	if win.WaitForSingleObject(p, INFINITE if block else 0) != 0 {
		return {}, false, .None
	}
	code: u32
	if !win.GetExitCodeProcess(p, &code) {
		return {}, false, _last()
	}
	return {code = i32(code)}, true, .None
}

@(private)
_Cmd :: struct {
	buf: [dynamic]u16,
	err: Error,
}

@(private)
_cmd_str :: proc(c: ^_Cmd, s: string) {
	tmp: [256]u16
	rest := s
	for len(rest) > 0 {
		k := min(len(rest), 80)
		for k < len(rest) && k > 0 && rest[k] & 0xC0 == 0x80 {
			k -= 1
		}
		n, err := _wtf8_to_wide(rest[:k], tmp[:])
		if err != .None {
			c.err = err
			return
		}
		append(&c.buf, ..tmp[:n])
		rest = rest[k:]
	}
}

@(private)
_cmd_char :: proc(c: ^_Cmd, ch: u16, count := 1) {
	for _ in 0 ..< count {
		append(&c.buf, ch)
	}
}

@(private)
_arg_needs_quote :: proc(arg: string) -> bool {
	if len(arg) == 0 {
		return true
	}
	for i in 0 ..< len(arg) {
		switch arg[i] {
		case ' ', '\t', '\n', '\v', '"':
			return true
		}
	}
	return false
}

@(private)
_cmd_arg :: proc(c: ^_Cmd, arg: string) {
	for i in 0 ..< len(arg) {
		if arg[i] == 0 {
			c.err = .Invalid
			return
		}
	}
	if !_arg_needs_quote(arg) {
		_cmd_str(c, arg)
		return
	}
	_cmd_char(c, '"')
	slashes := 0
	for i in 0 ..< len(arg) {
		ch := arg[i]
		if ch == '\\' {
			slashes += 1
			continue
		}
		if ch == '"' {
			_cmd_char(c, '\\', 2 * slashes + 1)
			_cmd_char(c, '"')
		} else {
			_cmd_char(c, '\\', slashes)
			_cmd_str(c, arg[i:i + 1] if ch < 0x80 else _utf8_seq(arg, i))
		}
		slashes = 0
	}
	_cmd_char(c, '\\', 2 * slashes)
	_cmd_char(c, '"')
}

@(private)
_utf8_seq :: proc(s: string, i: int) -> string {
	c := s[i]
	if c & 0xC0 == 0x80 {
		return ""
	}
	n := 1
	switch {
	case c & 0xE0 == 0xC0:
		n = 2
	case c & 0xF0 == 0xE0:
		n = 3
	case c & 0xF8 == 0xF0:
		n = 4
	}
	return s[i:min(i + n, len(s))]
}

@(private)
_bat_arg :: proc(c: ^_Cmd, arg: string) {
	quote := len(arg) == 0 || arg[len(arg) - 1] == '\\'
	for i in 0 ..< len(arg) {
		ch := arg[i]
		if ch == 0 || ch == '\r' || ch == '\n' {
			c.err = .Invalid
			return
		}
		if ch < 0x80 {
			alnum := (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
			ok := false
			switch ch {
			case '#', '$', '*', '+', '-', '.', '/', ':', '?', '@', '\\', '_':
				ok = true
			}
			if !alnum && !ok {
				quote = true
			}
		}
	}
	if quote {
		_cmd_char(c, '"')
	}
	slashes := 0
	for i in 0 ..< len(arg) {
		ch := arg[i]
		if ch == '\\' {
			slashes += 1
		} else {
			if ch == '"' {
				_cmd_char(c, '\\', slashes)
				_cmd_char(c, '"')
			} else if ch == '%' {
				_cmd_str(c, "%%cd:~,")
			}
			slashes = 0
		}
		if ch < 0x80 {
			_cmd_char(c, u16(ch))
		} else if ch & 0xC0 != 0x80 {
			_cmd_str(c, _utf8_seq(arg, i))
		}
	}
	if quote {
		_cmd_char(c, '\\', slashes)
		_cmd_char(c, '"')
	}
}

@(private)
_ascii_lower :: proc "contextless" (c: u8) -> u8 {
	return c + 32 if c >= 'A' && c <= 'Z' else c
}

@(private)
_has_suffix_fold :: proc "contextless" (s, suffix: string) -> bool {
	if len(s) < len(suffix) {
		return false
	}
	t := s[len(s) - len(suffix):]
	for i in 0 ..< len(t) {
		if _ascii_lower(t[i]) != _ascii_lower(suffix[i]) {
			return false
		}
	}
	return true
}

@(private)
_env_lookup :: proc(env: []string, key: string) -> (string, bool) {
	if env != nil {
		for kv in env {
			if len(kv) > len(key) && kv[len(key)] == '=' {
				match := true
				for i in 0 ..< len(key) {
					if _ascii_lower(kv[i]) != _ascii_lower(key[i]) {
						match = false
						break
					}
				}
				if match {
					return kv[len(key) + 1:], true
				}
			}
		}
		return "", false
	}
	return _utf8_env(key, context.temp_allocator)
}

@(private)
_is_file :: proc(path: string) -> bool {
	buf: WPath_Buf = ---
	p, err := _wpath(path, &buf)
	if err != .None {
		return false
	}
	attrs := win.GetFileAttributesW(_ws(p))
	return attrs != win.INVALID_FILE_ATTRIBUTES && attrs & FILE_ATTRIBUTE_DIRECTORY == 0
}

@(private)
_resolve_exec_windows :: proc(name: string, env: []string, allocator: runtime.Allocator) -> (path: string, batch: bool, err: Error) {
	if len(name) == 0 {
		return "", false, .Not_Found
	}
	pathext, ok := _env_lookup(env, "PATHEXT")
	if !ok || len(pathext) == 0 {
		pathext = ".COM;.EXE;.BAT;.CMD"
	}
	known := false
	{
		rest := pathext
		for len(rest) > 0 {
			i := 0
			for i < len(rest) && rest[i] != ';' {
				i += 1
			}
			ext := rest[:i]
			rest = rest[min(i + 1, len(rest)):]
			if len(ext) > 0 && _has_suffix_fold(name, ext) {
				known = true
			}
		}
	}
	has_dir := false
	for i in 0 ..< len(name) {
		if name[i] == '/' || name[i] == '\\' || name[i] == ':' {
			has_dir = true
		}
	}
	search := ""
	if !has_dir {
		search, _ = _env_lookup(env, "PATH")
	}
	dirs_rest := search
	first := true
	for first || len(dirs_rest) > 0 {
		dir := ""
		if has_dir {
			first = false
		} else {
			first = false
			i := 0
			for i < len(dirs_rest) && dirs_rest[i] != ';' {
				i += 1
			}
			dir = dirs_rest[:i]
			dirs_rest = dirs_rest[min(i + 1, len(dirs_rest)):]
			if len(dir) >= 2 && dir[0] == '"' && dir[len(dir) - 1] == '"' {
				dir = dir[1:len(dir) - 1]
			}
			if len(dir) == 0 {
				continue
			}
		}
		base := name if has_dir else path_join(context.temp_allocator, dir, name) or_continue
		if known {
			if _is_file(base) {
				out := _clone(base, allocator) or_return
				return out, _has_suffix_fold(base, ".bat") || _has_suffix_fold(base, ".cmd"), .None
			}
			continue
		}
		rest := pathext
		for len(rest) > 0 {
			i := 0
			for i < len(rest) && rest[i] != ';' {
				i += 1
			}
			ext := rest[:i]
			rest = rest[min(i + 1, len(rest)):]
			if len(ext) == 0 {
				continue
			}
			cand := _concat(context.temp_allocator, base, ext) or_continue
			if _is_file(cand) {
				out := _clone(cand, allocator) or_return
				return out, _has_suffix_fold(cand, ".bat") || _has_suffix_fold(cand, ".cmd"), .None
			}
		}
	}
	return "", false, .Not_Found
}

resolve_executable :: proc(name: string, env: []string = nil, allocator := context.allocator) -> (path: string, batch: bool, err: Error) {
	return _resolve_exec_windows(name, env, allocator)
}

@(private)
_concat :: proc(allocator: runtime.Allocator, a, b: string) -> (string, Error) {
	out, err := make([]u8, len(a) + len(b), allocator)
	if err != nil {
		return "", .No_Memory
	}
	copy(out, a)
	copy(out[len(a):], b)
	return string(out), .None
}

@(private)
_dos_path :: proc(path: string, buf: ^WPath_Buf) -> ([^]u16, int, Error) {
	p, perr := _wpath(path, buf)
	if perr != .None {
		return nil, 0, perr
	}
	n := _wlen(p)
	if n >= 8 && buf[4] == 'U' && buf[5] == 'N' && buf[6] == 'C' && buf[7] == '\\' {
		copy(buf[1:], buf[7:n + 1])
		buf[0] = '\\'
		return raw_data(buf[:]), n - 6, .None
	}
	copy(buf[:], buf[4:n + 1])
	return raw_data(buf[:]), n - 4, .None
}

@(private)
_pipe_pair :: proc(i: int, sa: ^win.SECURITY_ATTRIBUTES) -> (ours: HANDLE, theirs: HANDLE, err: Error) {
	rnd: [8]u8
	runtime.rand_bytes(rnd[:])
	name: [96]u16
	prefix := "\\\\.\\pipe\\0ndb-"
	n := 0
	for ch in transmute([]u8)prefix {
		name[n] = u16(ch)
		n += 1
	}
	hex := "0123456789abcdef"
	pid := win.GetCurrentProcessId()
	for k := 28; k >= 0; k -= 4 {
		name[n] = u16(hex[(pid >> u32(k)) & 0xF])
		n += 1
	}
	name[n] = '-'
	n += 1
	for b in rnd {
		name[n] = u16(hex[b >> 4])
		name[n + 1] = u16(hex[b & 0xF])
		n += 2
	}
	name[n] = 0
	open_mode: u32 = (PIPE_ACCESS_DUPLEX if i == 0 else PIPE_ACCESS_INBOUND) | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE
	ours = win.CreateNamedPipeW(_ws(&name[0]), open_mode, PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, 1, PIPE_BUFFER, PIPE_BUFFER, 0, nil)
	if ours == INVALID_HANDLE {
		return nil, nil, _last()
	}
	access: u32 = GENERIC_READ | FILE_WRITE_ATTRIBUTES if i == 0 else GENERIC_WRITE | FILE_READ_ATTRIBUTES
	theirs = win.CreateFileW(_ws(&name[0]), access, 0, sa, OPEN_EXISTING, 0, nil)
	if theirs == INVALID_HANDLE {
		err = _last()
		win.CloseHandle(ours)
		return nil, nil, err
	}
	if i == 0 {
		mode: u32 = PIPE_READMODE_BYTE | PIPE_NOWAIT
		if !SetNamedPipeHandleState(ours, &mode, nil, nil) {
			err = _last()
			win.CloseHandle(ours)
			win.CloseHandle(theirs)
			return nil, nil, err
		}
	}
	return ours, theirs, .None
}

spawn :: proc(
	argv: []string,
	cwd := "",
	env: []string = nil,
	new_process_group := false,
	pipes := ALL_PIPES,
	pre_exec := Pre_Exec{},
) -> (
	child: Child,
	err: Error,
) {
	child = {
		stdin  = INVALID_FD,
		stdout = INVALID_FD,
		stderr = INVALID_FD,
		group  = new_process_group,
	}
	if len(argv) == 0 {
		return child, .Invalid
	}
	if pre_exec.run != nil {
		return child, .Unsupported
	}
	ta := context.temp_allocator
	exe, batch := _resolve_exec_windows(argv[0], env, ta) or_return
	args := argv
	if batch && _has_suffix_fold(exe, ".cmd") {
		if direct, ok := npm_shim_argv(exe, argv[1:], env, ta); ok {
			args = direct
			exe = direct[0]
			batch = false
		}
	}

	cmd := _Cmd {
		buf = make([dynamic]u16, ta),
	}
	app_buf: WPath_Buf = ---
	app: [^]u16
	if batch {
		sys: [WPATH_MAX]u16
		sn := int(win.GetSystemDirectoryW(&sys[0], u32(len(sys))))
		if sn == 0 || sn + 9 >= len(sys) {
			return child, .Not_Found
		}
		tail := "\\cmd.exe"
		for ch, k in transmute([]u8)tail {
			sys[sn + k] = u16(ch)
		}
		sys[sn + len(tail)] = 0
		copy(app_buf[:], sys[:sn + len(tail) + 1])
		app = raw_data(app_buf[:])
		script_buf: WPath_Buf = ---
		_, sn2 := _dos_path(exe, &script_buf) or_return
		script := script_buf[:sn2]
		for ch in script {
			if ch == '"' {
				return child, .Invalid
			}
		}
		if sn2 > 0 && script[sn2 - 1] == '\\' {
			return child, .Invalid
		}
		_cmd_str(&cmd, "cmd.exe /e:ON /v:OFF /d /c \"\"")
		append(&cmd.buf, ..script)
		_cmd_char(&cmd, '"')
		for a in args[1:] {
			_cmd_char(&cmd, ' ')
			_bat_arg(&cmd, a)
		}
		_cmd_char(&cmd, '"')
	} else {
		app_p, _ := _dos_path(exe, &app_buf) or_return
		app = app_p
		a0 := args[0]
		for i in 0 ..< len(a0) {
			if a0[i] == '"' || a0[i] == 0 {
				return child, .Invalid
			}
		}
		_cmd_char(&cmd, '"')
		_cmd_str(&cmd, a0)
		_cmd_char(&cmd, '"')
		for a in args[1:] {
			_cmd_char(&cmd, ' ')
			_cmd_arg(&cmd, a)
		}
	}
	if cmd.err != .None {
		return child, cmd.err
	}
	if len(cmd.buf) >= CMDLINE_MAX {
		return child, .Too_Large
	}
	append(&cmd.buf, 0)

	envblock: [^]u16
	if env != nil {
		eb := make([dynamic]u16, ta)
		for kv in env {
			for i in 0 ..< len(kv) {
				if kv[i] == 0 {
					return child, .Invalid
				}
			}
			e := _Cmd {
				buf = eb,
			}
			_cmd_str(&e, kv)
			if e.err != .None {
				return child, e.err
			}
			eb = e.buf
			append(&eb, 0)
		}
		if len(env) == 0 {
			append(&eb, 0)
		}
		append(&eb, 0)
		envblock = raw_data(eb)
	}

	cwd_buf: WPath_Buf = ---
	cwd_p: [^]u16
	if len(cwd) > 0 {
		p, n := _dos_path(cwd, &cwd_buf) or_return
		if n >= 258 {
			return child, .Name_Too_Long
		}
		cwd_p = p
	}

	sa := win.SECURITY_ATTRIBUTES {
		nLength        = size_of(win.SECURITY_ATTRIBUTES),
		bInheritHandle = true,
	}
	ours := [3]HANDLE{nil, nil, nil}
	theirs := [3]HANDLE{nil, nil, nil}
	null_h: HANDLE
	job: HANDLE
	pi: win.PROCESS_INFORMATION
	defer {
		for h in theirs {
			if h != nil && h != null_h {
				win.CloseHandle(h)
			}
		}
		if null_h != nil {
			win.CloseHandle(null_h)
		}
		if err != .None {
			for h in ours {
				if h != nil {
					win.CloseHandle(h)
				}
			}
			if job != nil {
				win.CloseHandle(job)
			}
			if pi.hProcess != nil {
				win.TerminateProcess(pi.hProcess, KILLED_EXIT_CODE)
				win.CloseHandle(pi.hProcess)
			}
			if pi.hThread != nil {
				win.CloseHandle(pi.hThread)
			}
		}
	}
	for i in 0 ..< 3 {
		if Pipe(i) in pipes {
			ours[i], theirs[i] = _pipe_pair(i, &sa) or_return
		} else {
			if null_h == nil {
				nul := [?]u16{'N', 'U', 'L', 0}
				null_h = win.CreateFileW(_ws(&nul[0]), GENERIC_READ | GENERIC_WRITE, FILE_SHARE_ALL, &sa, OPEN_EXISTING, 0, nil)
				if null_h == INVALID_HANDLE {
					null_h = nil
					return child, _last()
				}
			}
			theirs[i] = null_h
		}
	}
	inherit: [3]HANDLE
	ninherit := 0
	for h in theirs {
		dup := false
		for k in 0 ..< ninherit {
			if inherit[k] == h {
				dup = true
			}
		}
		if !dup {
			inherit[ninherit] = h
			ninherit += 1
		}
	}
	attr_size: uint
	InitializeProcThreadAttributeList(nil, 1, 0, &attr_size)
	attr_mem, aerr := make([]u8, int(attr_size), ta)
	if aerr != nil {
		return child, .No_Memory
	}
	if !InitializeProcThreadAttributeList(raw_data(attr_mem), 1, 0, &attr_size) {
		return child, _last()
	}
	defer DeleteProcThreadAttributeList(raw_data(attr_mem))
	if !UpdateProcThreadAttribute(raw_data(attr_mem), 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, &inherit[0], uint(ninherit) * size_of(HANDLE), nil, nil) {
		return child, _last()
	}
	six := Startup_Info_Ex {
		si = {
			cb         = size_of(Startup_Info_Ex),
			dwFlags    = STARTF_USESTDHANDLES,
			hStdInput  = theirs[0],
			hStdOutput = theirs[1],
			hStdError  = theirs[2],
		},
		attrs = raw_data(attr_mem),
	}
	flags: u32 = CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED
	if new_process_group {
		flags |= CREATE_NEW_PROCESS_GROUP
	}
	console: [1]u32
	if GetConsoleProcessList(&console[0], 1) == 0 {
		flags |= CREATE_NO_WINDOW
	}
	if !win.CreateProcessW(_ws(app), _ws(raw_data(cmd.buf)), nil, nil, true, flags, envblock, _ws(cwd_p), &six.si, &pi) {
		code := win.GetLastError()
		pi = {}
		return child, _werror(code)
	}
	if new_process_group {
		name: [64]u16
		SetLastError(0)
		job = CreateJobObjectW(nil, _job_name(Pid(pi.dwProcessId), name[:]))
		if job != nil && win.GetLastError() == ERROR_ALREADY_EXISTS {
			win.CloseHandle(job)
			job = CreateJobObjectW(nil, nil)
		}
		if job == nil {
			return child, _last()
		}
		if !AssignProcessToJobObject(job, pi.hProcess) {
			return child, _last()
		}
	}
	if win.ResumeThread(pi.hThread) == max(u32) {
		return child, _last()
	}
	win.CloseHandle(pi.hThread)
	pi.hThread = nil
	child.pid = Pid(pi.dwProcessId)
	child.stdin = _fd(ours[0]) if ours[0] != nil else INVALID_FD
	child.stdout = _fd(ours[1]) if ours[1] != nil else INVALID_FD
	child.stderr = _fd(ours[2]) if ours[2] != nil else INVALID_FD
	child.os = {
		process = pi.hProcess,
		job     = job,
	}
	return child, .None
}

self_pid :: proc "contextless" () -> Pid {
	return Pid(win.GetCurrentProcessId())
}

process_alive :: proc "contextless" (pid: Pid) -> bool {
	if pid <= 0 {
		return false
	}
	p := win.OpenProcess(SYNCHRONIZE, false, u32(pid))
	if p == nil {
		return win.GetLastError() != ERROR_INVALID_PARAMETER
	}
	defer win.CloseHandle(p)
	return win.WaitForSingleObject(p, 0) != 0
}
