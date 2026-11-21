package observe

import "../prim"

@(private)
_strip_firmlink :: proc "contextless" (p: string) -> string {
	return p
}

process_args :: proc(pid: prim.Pid, buf: []u8) -> ([]u8, bool) {
	return nil, false
}
