package fs

import "../prim"

@(private)
_open_root :: proc(sc: ^Scanner, root: string) -> (prim.Fd, Error) {
	fd, err := prim.open_file(sc.vfs, root, {.Directory})
	return fd, from_prim(err)
}

@(private)
_read_dir :: proc(sc: ^Scanner, t: ^Dir_Task, raw: ^[dynamic]Raw_Dirent, gitignore: ^[]u8) -> Error {
	return read_dir_vfs(sc, t, raw, gitignore)
}
