#+build windows
package observe

import "base:runtime"
import "core:strings"
import "core:unicode/utf16"
import win "core:sys/windows"
import "../fs"
import "../prim"

foreign import rstrtmgr "system:Rstrtmgr.lib"

@(private)
RM_UNIQUE_PROCESS :: struct {
	dwProcessId:      u32,
	ProcessStartTime: win.FILETIME,
}

@(private)
RM_PROCESS_INFO :: struct {
	Process:             RM_UNIQUE_PROCESS,
	strAppName:          [256]u16,
	strServiceShortName: [64]u16,
	ApplicationType:     u32,
	AppStatus:           u32,
	TSSessionId:         u32,
	bRestartable:        i32,
}

@(private)
@(default_calling_convention = "system")
foreign rstrtmgr {
	RmStartSession :: proc(session: ^u32, flags: u32, key: [^]u16) -> u32 ---
	RmRegisterResources :: proc(session: u32, nfiles: u32, files: [^][^]u16, napps: u32, apps: rawptr, nservices: u32, services: rawptr) -> u32 ---
	RmGetList :: proc(session: u32, needed: ^u32, count: ^u32, infos: [^]RM_PROCESS_INFO, reasons: ^u32) -> u32 ---
	RmEndSession :: proc(session: u32) -> u32 ---
}

@(private)
_snapshot :: proc(allocator: runtime.Allocator) -> []win.PROCESSENTRY32W {
	out := make([dynamic]win.PROCESSENTRY32W, allocator)
	snap := win.CreateToolhelp32Snapshot(win.TH32CS_SNAPPROCESS, 0)
	if snap == win.INVALID_HANDLE_VALUE {
		return out[:]
	}
	defer win.CloseHandle(snap)
	e: win.PROCESSENTRY32W
	e.dwSize = size_of(win.PROCESSENTRY32W)
	ok := win.Process32FirstW(snap, &e)
	for ok {
		append(&out, e)
		ok = win.Process32NextW(snap, &e)
	}
	return out[:]
}

@(private)
_exe_name :: proc(e: ^win.PROCESSENTRY32W) -> string {
	n := 0
	for n < len(e.szExeFile) && e.szExeFile[n] != 0 {
		n += 1
	}
	buf := make([]u8, n * 4, context.temp_allocator)
	k := utf16.decode_to_utf8(buf, e.szExeFile[:n])
	return strings.to_lower(string(buf[:k]), context.temp_allocator)
}

@(private)
_rm_holders :: proc(lock: string) -> []prim.Pid {
	out := make([dynamic]prim.Pid, context.temp_allocator)
	native, _ := strings.replace_all(lock, "/", "\\", context.temp_allocator)
	wpath := win.utf8_to_wstring(native, context.temp_allocator)
	key: [33]u16
	session: u32
	if RmStartSession(&session, 0, &key[0]) != 0 {
		return out[:]
	}
	defer RmEndSession(session)
	files := [1][^]u16{([^]u16)(rawptr(wpath))}
	if RmRegisterResources(session, 1, &files[0], 0, nil, 0, nil) != 0 {
		return out[:]
	}
	infos: [64]RM_PROCESS_INFO
	needed, count, reasons: u32
	count = len(infos)
	if RmGetList(session, &needed, &count, &infos[0], &reasons) != 0 {
		return out[:]
	}
	for i in 0 ..< min(int(count), len(infos)) {
		append(&out, prim.Pid(infos[i].Process.dwProcessId))
	}
	return out[:]
}

@(private)
_win_lock_procs :: proc(lock: string, roots: []string, allocator: runtime.Allocator) -> []fs.Git_Proc {
	out := make([dynamic]fs.Git_Proc, allocator)
	holders := _rm_holders(lock)
	for &e in _snapshot(context.temp_allocator) {
		if _exe_name(&e) != "git.exe" {
			continue
		}
		pid := prim.Pid(e.th32ProcessID)
		holder := false
		for h in holders {
			holder ||= h == pid
		}
		if len(holders) > 0 && !holder {
			continue
		}
		append(&out, fs.Git_Proc{pid = pid, holder = holder})
	}
	return out[:]
}
