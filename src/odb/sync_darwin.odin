#+build darwin
package odb

import "core:os"
import "core:sys/posix"

@(private)
F_FULLFSYNC :: 51

@(private)
sync_paths :: proc(files, dirs: []string, roots: []string) -> Error {
	last: ^os.File
	defer if last != nil {
		os.close(last)
	}
	for list in ([][]string{files, dirs}) {
		for p in list {
			f, err := open_for_sync(p)
			if err == .Not_Found {
				continue
			}
			err or_return
			if posix.fsync(posix.FD(os.fd(f))) != .OK {
				os.close(f)
				return .Io
			}
			if last != nil {
				os.close(last)
			}
			last = f
		}
	}
	if last == nil {
		for r in roots {
			if r != "" {
				last = open_for_sync(r) or_continue
				break
			}
		}
	}
	if last != nil {
		fd := posix.FD(os.fd(last))
		if posix.fcntl(fd, posix.FCNTL_Cmd(F_FULLFSYNC)) == -1 && posix.fsync(fd) != .OK {
			return .Io
		}
	}
	return .None
}
