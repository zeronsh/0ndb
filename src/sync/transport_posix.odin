#+build linux, darwin
package osync

import "../prim"

@(private)
_Transport_Os :: struct {}

@(private)
_t_attach :: proc "contextless" (t: ^Transport, l: ^prim.Loop, w: prim.Watch) {
}

@(private)
_t_sendfile :: proc(t: ^Transport, src: prim.Fd, off: i64, n: int) -> (int, Error) {
	return _sendfile(t.fd, src, off, n)
}

@(private)
_t_os_close :: proc "contextless" (t: ^Transport) {
}
