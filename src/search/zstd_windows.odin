package search

import "../prim"

@(private)
_zstd_git_library :: proc() -> (string, bool) {
	path, ok := prim.getenv("PATH")
	if !ok {
		return "", false
	}
	vfs := prim.os_vfs()
	rest := path
	for len(rest) > 0 {
		i := 0
		for i < len(rest) && rest[i] != ';' {
			i += 1
		}
		dir := rest[:i]
		rest = rest[i + 1:] if i < len(rest) else ""
		for len(dir) > 0 && (dir[len(dir) - 1] == '\\' || dir[len(dir) - 1] == '/') {
			dir = dir[:len(dir) - 1]
		}
		if len(dir) == 0 {
			continue
		}
		exe, jerr := prim.path_join(context.temp_allocator, dir, "git.exe")
		if jerr != .None || !prim.exists(vfs, exe) {
			continue
		}
		prefix := prim.dir_name(dir)
		for sub in ([]string{"mingw64/bin/libzstd.dll", "mingw64/libexec/git-core/libzstd.dll"}) {
			dll, derr := prim.path_join(context.temp_allocator, prefix, sub)
			if derr == .None && prim.exists(vfs, dll) {
				return dll, true
			}
		}
	}
	return "", false
}
