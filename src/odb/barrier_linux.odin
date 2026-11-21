#+build linux
package odb

import "base:intrinsics"
import "core:sys/linux"
import "../prim"

@(private)
HAS_SYNCFS :: true

@(private)
os_syncfs :: proc(fd: prim.Fd) -> bool {
	return int(intrinsics.syscall(linux.SYS_syncfs, uintptr(fd))) >= 0
}
