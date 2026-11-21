package fs

import "core:c"
import "../prim"

foreign import libc "system:System"

@(private)
foreign libc {
	clonefile :: proc(src: cstring, dst: cstring, flags: c.uint32_t) -> c.int ---
}

clone_file :: proc(vfs: prim.Vfs, src, dst: string, mode: u32) -> Error {
	if vfs.procs == prim.os_vfs().procs {
		sbuf, dbuf: prim.Path_Buf
		sp, e1 := prim.cpath(src, &sbuf)
		dp, e2 := prim.cpath(dst, &dbuf)
		if e1 == .None && e2 == .None {
			prim.remove(vfs, dst)
			if clonefile(sp, dp, 1) == 0 {
				return .None
			}
		}
	}
	return copy_file_vfs(vfs, src, dst, mode)
}

@(private)
HAS_SYNCFS :: false

@(private)
os_syncfs :: proc(fd: prim.Fd) -> bool {
	return false
}
