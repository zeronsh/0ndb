#+build linux
package odb

import "base:intrinsics"
import "core:os"
import "core:sys/linux"

@(private)
SYNCFS_THRESHOLD :: 128

@(private)
sync_paths :: proc(files, dirs: []string, roots: []string) -> Error {
	if len(files) + len(dirs) > SYNCFS_THRESHOLD {
		done := 0
		for r in roots {
			if r == "" {
				continue
			}
			f := open_for_sync(r) or_continue
			ret := intrinsics.syscall(linux.SYS_syncfs, uintptr(os.fd(f)))
			os.close(f)
			if int(ret) < 0 {
				return .Io
			}
			done += 1
		}
		if done > 0 {
			return .None
		}
	}
	for p in files {
		f, err := open_for_sync(p)
		if err == .Not_Found {
			continue
		}
		err or_return
		e := linux.fdatasync(linux.Fd(os.fd(f)))
		os.close(f)
		if e != .NONE {
			return .Io
		}
	}
	for p in dirs {
		f, err := open_for_sync(p)
		if err == .Not_Found {
			continue
		}
		err or_return
		e := linux.fsync(linux.Fd(os.fd(f)))
		os.close(f)
		if e != .NONE && e != .EINVAL {
			return .Io
		}
	}
	return .None
}
