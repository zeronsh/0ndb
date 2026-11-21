package prim

import win "core:sys/windows"

foreign import kernel32_env "system:Kernel32.lib"

@(private)
@(default_calling_convention = "system")
foreign kernel32_env {
	GetEnvironmentStringsW :: proc() -> [^]u16 ---
	FreeEnvironmentStringsW :: proc(block: [^]u16) -> win.BOOL ---
}

environ :: proc(allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	block := GetEnvironmentStringsW()
	if block == nil {
		return out[:]
	}
	defer FreeEnvironmentStringsW(block)
	i := 0
	for block[i] != 0 {
		n := 0
		for block[i + n] != 0 {
			n += 1
		}
		w := block[i:i + n]
		buf, err := make([]u8, n * 3, allocator)
		if err == nil {
			m, _ := _wide_to_wtf8(w, buf)
			if m > 0 && buf[0] != '=' {
				append(&out, string(buf[:m]))
			}
		}
		i += n + 1
	}
	return out[:]
}

real_path :: proc(path: string, allocator := context.allocator) -> (string, Error) {
	buf: WPath_Buf = ---
	p, perr := _wpath(path, &buf)
	if perr != .None {
		return "", perr
	}
	h := win.CreateFileW(_ws(p), FILE_READ_ATTRIBUTES, FILE_SHARE_ALL, nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nil)
	if h == INVALID_HANDLE {
		return "", _last()
	}
	defer win.CloseHandle(h)
	out: WPath_Buf = ---
	n := int(win.GetFinalPathNameByHandleW(h, _ws(&out[0]), u32(len(out)), 0))
	if n == 0 {
		return "", _last()
	}
	if n >= len(out) {
		return "", .Name_Too_Long
	}
	w := out[:n]
	unc := false
	if len(w) >= 4 && w[0] == '\\' && w[1] == '\\' && w[2] == '?' && w[3] == '\\' {
		w = w[4:]
		if len(w) >= 4 && w[0] == 'U' && w[1] == 'N' && w[2] == 'C' && w[3] == '\\' {
			w = w[3:]
			unc = true
		}
	}
	res, err := make([]u8, len(w) * 3 + 1, allocator)
	if err != nil {
		return "", .No_Memory
	}
	k := 0
	if unc {
		res[0] = '/'
		k = 1
	}
	m, _ := _wide_to_wtf8(w, res[k:])
	m += k
	for i in 0 ..< m {
		if res[i] == '\\' {
			res[i] = '/'
		}
	}
	return string(res[:m]), .None
}
