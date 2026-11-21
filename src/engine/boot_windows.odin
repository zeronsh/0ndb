package engine

foreign import ntdll "system:ntdll.lib"

@(private)
@(default_calling_convention = "system")
foreign ntdll {
	NtQuerySystemInformation :: proc(class: i32, info: rawptr, size: u32, ret: ^u32) -> i32 ---
}

@(private)
SYSTEM_TIME_OF_DAY_INFORMATION :: 3

@(private)
_os_boot_raw :: proc() -> []u8 {
	info := make([]u8, 48, context.temp_allocator)
	ret: u32
	if NtQuerySystemInformation(SYSTEM_TIME_OF_DAY_INFORMATION, raw_data(info), u32(len(info)), &ret) < 0 || ret < 40 {
		return nil
	}
	boot := (^i64)(&info[0])^ - (^i64)(&info[32])^
	(^i64)(&info[0])^ = boot
	return info[:8]
}
