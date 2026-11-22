package prim

@(private = "file")
RESYNC_CHUNK :: 64 << 10

resync_file :: proc(vfs: Vfs, path: string, full := false) -> Error {
	fd, oerr := open_file(vfs, path, {.Write})
	if oerr != .None {
		return oerr
	}
	defer close_file(vfs, fd)
	return resync_fd(vfs, fd, full)
}

resync_fd :: proc(vfs: Vfs, fd: Fd, full := false) -> Error {
	size := file_size(vfs, fd) or_return
	return resync_range(vfs, fd, 0, size, full)
}

resync_range :: proc(vfs: Vfs, fd: Fd, from, to: i64, full := false) -> Error {
	buf: [RESYNC_CHUNK]u8
	for off := from; off < to; {
		want := min(i64(len(buf)), to - off)
		n := read_at(vfs, fd, buf[:want], off) or_return
		if n <= 0 {
			return .Io
		}
		write_at(vfs, fd, buf[:n], off) or_return
		off += i64(n)
	}
	return fullsync(vfs, fd) if full else datasync(vfs, fd)
}
