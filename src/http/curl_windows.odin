package http

import "../prim"

Curl :: struct {
	loop: ^prim.Loop,
}

curl_init :: proc(h: ^Curl, l: ^prim.Loop, allocator := context.allocator) -> bool {
	h^ = {}
	return false
}

curl_ca_file :: proc(h: ^Curl, path: string) {
}

curl_destroy :: proc(h: ^Curl) {
	h^ = {}
}

curl_active :: proc(h: ^Curl) -> int {
	return 0
}

curl_sockets :: proc(h: ^Curl) -> int {
	return 0
}

curl_start :: proc(h: ^Curl, req: ^Request, sink: Sink) -> (Id, Error) {
	return 0, .Unsupported
}

curl_cancel :: proc(h: ^Curl, id: Id) {
}

curl_resume :: proc(h: ^Curl, id: Id) {
}
