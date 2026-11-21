package fs

import "base:intrinsics"
import "core:sys/linux"
import "../prim"

@(private)
FICLONE :: 0x40049409

clone_file :: proc(vfs: prim.Vfs, src, dst: string, mode: u32) -> Error {
	if vfs.procs != prim.os_vfs().procs {
		return copy_file_vfs(vfs, src, dst, mode)
	}
	sbuf, dbuf: prim.Path_Buf
	sp, e1 := prim.cpath(src, &sbuf)
	dp, e2 := prim.cpath(dst, &dbuf)
	if e1 != .None || e2 != .None {
		return .Name_Too_Long
	}
	in_fd, ierr := linux.open(sp, {.CLOEXEC, .NOFOLLOW})
	if ierr != .NONE {
		return from_errno(ierr)
	}
	defer linux.close(in_fd)
	out_fd, oerr := linux.open(dp, {.WRONLY, .CREAT, .TRUNC, .CLOEXEC}, transmute(linux.Mode)(mode & 0o7777))
	if oerr != .NONE {
		return from_errno(oerr)
	}
	defer linux.close(out_fd)
	if linux.ioctl(out_fd, FICLONE, uintptr(in_fd)) == 0 {
		return .None
	}
	for {
		n := linux.syscall(linux.SYS_copy_file_range, in_fd, 0, out_fd, 0, 1 << 30, 0)
		if n == 0 {
			return .None
		}
		if int(n) < 0 {
			if linux.Errno(-int(n)) == .EINTR {
				continue
			}
			break
		}
	}
	linux.ftruncate(out_fd, 0)
	return copy_file_vfs(vfs, src, dst, mode)
}

@(private)
HAS_SYNCFS :: true

@(private)
os_syncfs :: proc(fd: prim.Fd) -> bool {
	return int(intrinsics.syscall(linux.SYS_syncfs, uintptr(fd))) >= 0
}
