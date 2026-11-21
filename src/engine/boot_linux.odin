package engine

import "../prim"

@(private)
_os_boot_raw :: proc() -> []u8 {
	vfs := prim.os_vfs()
	fd, err := prim.open_file(vfs, "/proc/sys/kernel/random/boot_id")
	if err != .None {
		return nil
	}
	defer prim.close_file(vfs, fd)
	buf := make([]u8, 64, context.temp_allocator)
	n, rerr := prim.read_at(vfs, fd, buf, 0)
	if rerr != .None || n <= 0 {
		return nil
	}
	return buf[:n]
}
