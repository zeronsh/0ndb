#+build !linux
package odb

import "../prim"

@(private)
HAS_SYNCFS :: false

@(private)
os_syncfs :: proc(fd: prim.Fd) -> bool {
	return false
}
