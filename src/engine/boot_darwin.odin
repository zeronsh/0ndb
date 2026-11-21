package engine

foreign import libc "system:System.framework"

@(private)
@(default_calling_convention = "c")
foreign libc {
	sysctlbyname :: proc(name: cstring, oldp: rawptr, oldlenp: ^uint, newp: rawptr, newlen: uint) -> i32 ---
}

@(private)
_os_boot_raw :: proc() -> []u8 {
	buf := make([]u8, 64, context.temp_allocator)
	n := uint(len(buf))
	if sysctlbyname("kern.bootsessionuuid", raw_data(buf), &n, nil, 0) != 0 || n == 0 {
		return nil
	}
	return buf[:n]
}
