#+build linux
package observe

AUDIT_ARCH_X86_64 :: u32(0xC000003E)
AUDIT_ARCH_I386 :: u32(0x40000003)
AUDIT_ARCH_AARCH64 :: u32(0xC00000B7)
AUDIT_ARCH_ARM :: u32(0x40000028)

X32_BIT :: u32(0x40000000)

@(private)
RET_KILL_PROCESS :: u32(0x80000000)
@(private)
RET_ERRNO :: u32(0x00050000)
@(private)
RET_USER_NOTIF :: u32(0x7fc00000)
@(private)
RET_ALLOW :: u32(0x7fff0000)

@(private)
EPERM :: u32(1)
@(private)
ENOSYS :: u32(38)

@(private)
O_WRONLY :: u64(0o1)
@(private)
O_RDWR :: u64(0o2)
@(private)
O_CREAT :: u64(0o100)
@(private)
O_EXCL :: u64(0o200)
@(private)
O_TRUNC :: u64(0o1000)
@(private)
O_PATH :: u64(0o10000000)
@(private)
CLONE_FS :: u32(0x200)
@(private)
CLONE_NEWNS :: u32(0x20000)
@(private)
CLONE_THREAD :: u32(0x10000)
@(private)
O_TMPFILE_BIT :: u64(0o20000000)
@(private)
WRITE_MASK :: O_WRONLY | O_RDWR | O_CREAT | O_TRUNC

Call :: enum u8 {
	None,
	Open,
	Openat,
	Openat2,
	Creat,
	Rename,
	Renameat,
	Renameat2,
	Unlink,
	Unlinkat,
	Link,
	Linkat,
	Symlink,
	Symlinkat,
	Mkdir,
	Mkdirat,
	Rmdir,
	Truncate,
	Mknod,
	Mknodat,
	Chmod,
	Fchmod,
	Fchmodat,
	Fchmodat2,
	Open_By_Handle,
	Io_Uring_Setup,
	Chdir,
	Fchdir,
	Chroot,
	Pivot_Root,
	Setns,
	Unshare,
	Clone,
	Clone3,
}

Sys :: struct {
	nr:   u32,
	call: Call,
}

X86_64_CALLS :: [?]Sys {
	{2, .Open},
	{76, .Truncate},
	{82, .Rename},
	{83, .Mkdir},
	{84, .Rmdir},
	{85, .Creat},
	{86, .Link},
	{87, .Unlink},
	{88, .Symlink},
	{90, .Chmod},
	{91, .Fchmod},
	{133, .Mknod},
	{257, .Openat},
	{258, .Mkdirat},
	{259, .Mknodat},
	{263, .Unlinkat},
	{264, .Renameat},
	{265, .Linkat},
	{266, .Symlinkat},
	{268, .Fchmodat},
	{304, .Open_By_Handle},
	{316, .Renameat2},
	{425, .Io_Uring_Setup},
	{437, .Openat2},
	{452, .Fchmodat2},
	{56, .Clone},
	{80, .Chdir},
	{81, .Fchdir},
	{155, .Pivot_Root},
	{161, .Chroot},
	{272, .Unshare},
	{308, .Setns},
	{435, .Clone3},
}

I386_CALLS :: [?]Sys {
	{5, .Open},
	{8, .Creat},
	{9, .Link},
	{10, .Unlink},
	{14, .Mknod},
	{15, .Chmod},
	{38, .Rename},
	{39, .Mkdir},
	{40, .Rmdir},
	{83, .Symlink},
	{92, .Truncate},
	{94, .Fchmod},
	{193, .Truncate},
	{295, .Openat},
	{296, .Mkdirat},
	{297, .Mknodat},
	{301, .Unlinkat},
	{302, .Renameat},
	{303, .Linkat},
	{304, .Symlinkat},
	{306, .Fchmodat},
	{342, .Open_By_Handle},
	{353, .Renameat2},
	{425, .Io_Uring_Setup},
	{437, .Openat2},
	{452, .Fchmodat2},
	{12, .Chdir},
	{61, .Chroot},
	{120, .Clone},
	{133, .Fchdir},
	{217, .Pivot_Root},
	{310, .Unshare},
	{346, .Setns},
	{435, .Clone3},
}

AARCH64_CALLS :: [?]Sys {
	{33, .Mknodat},
	{34, .Mkdirat},
	{35, .Unlinkat},
	{36, .Symlinkat},
	{37, .Linkat},
	{38, .Renameat},
	{45, .Truncate},
	{52, .Fchmod},
	{53, .Fchmodat},
	{56, .Openat},
	{265, .Open_By_Handle},
	{276, .Renameat2},
	{425, .Io_Uring_Setup},
	{437, .Openat2},
	{452, .Fchmodat2},
	{41, .Pivot_Root},
	{49, .Chdir},
	{50, .Fchdir},
	{51, .Chroot},
	{97, .Unshare},
	{220, .Clone},
	{268, .Setns},
	{435, .Clone3},
}

ARM_CALLS :: [?]Sys {
	{5, .Open},
	{8, .Creat},
	{9, .Link},
	{10, .Unlink},
	{14, .Mknod},
	{15, .Chmod},
	{38, .Rename},
	{39, .Mkdir},
	{40, .Rmdir},
	{83, .Symlink},
	{92, .Truncate},
	{94, .Fchmod},
	{193, .Truncate},
	{322, .Openat},
	{323, .Mkdirat},
	{324, .Mknodat},
	{328, .Unlinkat},
	{329, .Renameat},
	{330, .Linkat},
	{331, .Symlinkat},
	{333, .Fchmodat},
	{371, .Open_By_Handle},
	{382, .Renameat2},
	{425, .Io_Uring_Setup},
	{437, .Openat2},
	{452, .Fchmodat2},
	{12, .Chdir},
	{61, .Chroot},
	{120, .Clone},
	{133, .Fchdir},
	{218, .Pivot_Root},
	{337, .Unshare},
	{375, .Setns},
	{435, .Clone3},
}

when ODIN_ARCH == .amd64 {
	NATIVE_ARCH :: AUDIT_ARCH_X86_64
	COMPAT_ARCH :: AUDIT_ARCH_I386
	@(private, rodata)
	_native_calls := X86_64_CALLS
	@(private, rodata)
	_compat_calls := I386_CALLS
	NATIVE_SUPPORTED :: true
} else when ODIN_ARCH == .arm64 {
	NATIVE_ARCH :: AUDIT_ARCH_AARCH64
	COMPAT_ARCH :: AUDIT_ARCH_ARM
	@(private, rodata)
	_native_calls := AARCH64_CALLS
	@(private, rodata)
	_compat_calls := ARM_CALLS
	NATIVE_SUPPORTED :: true
} else {
	NATIVE_ARCH :: u32(0)
	COMPAT_ARCH :: u32(0)
	@(private, rodata)
	_native_calls: [0]Sys
	@(private, rodata)
	_compat_calls: [0]Sys
	NATIVE_SUPPORTED :: false
}

decode_call :: proc "contextless" (arch: u32, nr: i32) -> Call {
	n := u32(nr)
	table: []Sys
	switch arch {
	case NATIVE_ARCH:
		if arch == AUDIT_ARCH_X86_64 {
			n &~= X32_BIT
		}
		table = _native_calls[:]
	case COMPAT_ARCH:
		table = _compat_calls[:]
	case:
		return .None
	}
	for s in table {
		if s.nr == n {
			return s.call
		}
	}
	return .None
}

nofollow_flag :: proc "contextless" (arch: u32) -> u64 {
	if arch == AUDIT_ARCH_X86_64 || arch == AUDIT_ARCH_I386 {
		return 0o400000
	}
	return 0o100000
}

Insn :: struct {
	code: u16,
	jt:   u8,
	jf:   u8,
	k:    u32,
}

Fprog :: struct {
	len:    u16,
	filter: [^]Insn,
}

@(private)
BPF_LD_W_ABS :: u16(0x20)
@(private)
BPF_JEQ_K :: u16(0x15)
@(private)
BPF_JSET_K :: u16(0x45)
@(private)
BPF_RET_K :: u16(0x06)
@(private)
BPF_AND_K :: u16(0x54)

@(private)
OFF_NR :: u32(0)
@(private)
OFF_ARCH :: u32(4)

@(private)
_arg_lo :: proc "contextless" (i: u32) -> u32 {
	return 16 + 8 * i
}

@(private)
Label :: enum u8 {
	Next,
	Native,
	Compat,
	Chk1,
	Chk2,
	Chk_Handle,
	Chk_Unshare,
	Chk_Clone,
	Notify,
	Allow,
	Enosys,
	Eperm,
	Kill,
}

@(private)
Fixup :: struct {
	at:    int,
	jt:    Label,
	jf:    Label,
}

@(private)
Asm :: struct {
	code:   [dynamic]Insn,
	fixups: [dynamic]Fixup,
	labels: [Label]int,
}

@(private)
_emit :: proc(a: ^Asm, code: u16, k: u32, jt := Label.Next, jf := Label.Next) {
	if jt != .Next || jf != .Next {
		append(&a.fixups, Fixup{len(a.code), jt, jf})
	}
	append(&a.code, Insn{code = code, k = k})
}

@(private)
_mark :: proc(a: ^Asm, l: Label) {
	a.labels[l] = len(a.code)
}

@(private)
_emit_table :: proc(a: ^Asm, table: []Sys, x32: bool) {
	_emit(a, BPF_LD_W_ABS, OFF_NR)
	if x32 {
		_emit(a, BPF_AND_K, ~X32_BIT)
	}
	for s in table {
		target: Label
		#partial switch s.call {
		case .Open:
			target = .Chk1
		case .Openat:
			target = .Chk2
		case .Open_By_Handle:
			target = .Chk_Handle
		case .Io_Uring_Setup:
			target = .Enosys
		case .Unshare:
			target = .Chk_Unshare
		case .Clone:
			target = .Chk_Clone
		case:
			target = .Notify
		}
		_emit(a, BPF_JEQ_K, s.nr, target, .Next)
	}
	_emit(a, BPF_RET_K, RET_ALLOW)
}

build_filter :: proc(allocator := context.allocator) -> (prog: []Insn, ok: bool) {
	when !NATIVE_SUPPORTED {
		return nil, false
	}
	a: Asm
	a.code = make([dynamic]Insn, context.temp_allocator)
	a.fixups = make([dynamic]Fixup, context.temp_allocator)
	_emit(&a, BPF_LD_W_ABS, OFF_ARCH)
	_emit(&a, BPF_JEQ_K, NATIVE_ARCH, .Native, .Next)
	_emit(&a, BPF_JEQ_K, COMPAT_ARCH, .Compat, .Kill)
	_mark(&a, .Native)
	_emit_table(&a, _native_calls[:], NATIVE_ARCH == AUDIT_ARCH_X86_64)
	_mark(&a, .Compat)
	_emit_table(&a, _compat_calls[:], false)
	_mark(&a, .Chk1)
	_emit(&a, BPF_LD_W_ABS, _arg_lo(1))
	_emit(&a, BPF_JSET_K, u32(WRITE_MASK), .Notify, .Allow)
	_mark(&a, .Chk2)
	_emit(&a, BPF_LD_W_ABS, _arg_lo(2))
	_emit(&a, BPF_JSET_K, u32(WRITE_MASK), .Notify, .Allow)
	_mark(&a, .Chk_Handle)
	_emit(&a, BPF_LD_W_ABS, _arg_lo(2))
	_emit(&a, BPF_JSET_K, u32(WRITE_MASK), .Eperm, .Allow)
	_mark(&a, .Chk_Unshare)
	_emit(&a, BPF_LD_W_ABS, _arg_lo(0))
	_emit(&a, BPF_JSET_K, CLONE_NEWNS | CLONE_FS, .Notify, .Allow)
	_mark(&a, .Chk_Clone)
	_emit(&a, BPF_LD_W_ABS, _arg_lo(0))
	_emit(&a, BPF_JSET_K, CLONE_NEWNS, .Notify, .Next)
	_emit(&a, BPF_AND_K, CLONE_THREAD | CLONE_FS)
	_emit(&a, BPF_JEQ_K, CLONE_THREAD, .Notify, .Allow)
	_mark(&a, .Notify)
	_emit(&a, BPF_RET_K, RET_USER_NOTIF)
	_mark(&a, .Allow)
	_emit(&a, BPF_RET_K, RET_ALLOW)
	_mark(&a, .Enosys)
	_emit(&a, BPF_RET_K, RET_ERRNO | ENOSYS)
	_mark(&a, .Eperm)
	_emit(&a, BPF_RET_K, RET_ERRNO | EPERM)
	_mark(&a, .Kill)
	_emit(&a, BPF_RET_K, RET_KILL_PROCESS)
	for f in a.fixups {
		for which in 0 ..< 2 {
			l := f.jt if which == 0 else f.jf
			if l == .Next {
				continue
			}
			off := a.labels[l] - (f.at + 1)
			if off < 0 || off > 255 {
				return nil, false
			}
			if which == 0 {
				a.code[f.at].jt = u8(off)
			} else {
				a.code[f.at].jf = u8(off)
			}
		}
	}
	if len(a.code) > 4096 {
		return nil, false
	}
	out, err := make([]Insn, len(a.code), allocator)
	if err != nil {
		return nil, false
	}
	copy(out, a.code[:])
	return out, true
}
