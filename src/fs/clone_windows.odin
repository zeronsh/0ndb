package fs

import "../prim"

clone_file :: proc(vfs: prim.Vfs, src, dst: string, mode: u32) -> Error {
	return copy_file_vfs(vfs, src, dst, mode)
}

@(private)
HAS_SYNCFS :: false

@(private)
os_syncfs :: proc(fd: prim.Fd) -> bool {
	return false
}
