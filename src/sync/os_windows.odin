package osync

import "../prim"

@(private)
_Notifier :: struct {
	fd: prim.Fd,
}

@(private)
_notifier_open :: proc(n: ^_Notifier) -> Error {
	n.fd = prim.INVALID_FD
	return .Unsupported
}

@(private)
_notifier_close :: proc(n: ^_Notifier) {
}

@(private)
_notifier_fd :: proc "contextless" (n: ^_Notifier) -> prim.Fd {
	return n.fd
}

@(private)
_notifier_signal :: proc "contextless" (n: ^_Notifier) {
}

@(private)
_notifier_drain :: proc "contextless" (n: ^_Notifier) {
}

@(private)
_listen :: proc(ep: ^Endpoint) -> (lfd: prim.Fd, err: Error) {
	return prim.INVALID_FD, .Unsupported
}

@(private)
_unlink_stale :: proc(ep: ^Endpoint) {
}

@(private)
_accept :: proc "contextless" (lfd: prim.Fd) -> (prim.Fd, [16]u8, Error) {
	return prim.INVALID_FD, {}, .Unsupported
}

@(private)
_connect :: proc(ep: ^Endpoint) -> (fd: prim.Fd, pending: bool, err: Error) {
	return prim.INVALID_FD, false, .Unsupported
}

@(private)
_socket_error :: proc "contextless" (fd: prim.Fd) -> Error {
	return .Unsupported
}

@(private)
_tune_tcp :: proc "contextless" (fd: prim.Fd) {
}

@(private)
_send :: proc "contextless" (fd: prim.Fd, data: []u8, more: bool) -> (int, Error) {
	return 0, .Unsupported
}

@(private)
_recv :: proc "contextless" (fd: prim.Fd, buf: []u8) -> (int, Error) {
	return 0, .Unsupported
}

@(private)
_sendfile :: proc "contextless" (out: prim.Fd, src: prim.Fd, off: i64, n: int) -> (int, Error) {
	return 0, .Unsupported
}

@(private)
_ktls_install :: proc "contextless" (fd: prim.Fd, keys: ^Session_Keys) -> (tx, rx: bool) {
	return false, false
}

@(private)
_peer_is_self :: proc "contextless" (fd: prim.Fd) -> bool {
	return false
}

@(private)
_shutdown :: proc "contextless" (fd: prim.Fd) {
}

@(private)
_raise_nofile :: proc "contextless" () -> int {
	return 16 * 1024 * 1024
}
