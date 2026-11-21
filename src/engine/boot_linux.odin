package engine

import "../prim"

@(private)
_os_boot_raw :: proc() -> []u8 {
	data, err := prim.read_file(prim.os_vfs(), "/proc/sys/kernel/random/boot_id", context.temp_allocator)
	if err != .None {
		return nil
	}
	return data
}
