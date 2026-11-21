#+build windows
package engine

import "base:runtime"

Page_Heap :: struct {
	on: bool,
}

@(private)
PAGES_DEFAULT :: false

@(private)
_pages_init :: proc(h: ^Page_Heap) {
}

@(private)
_pages_allocator :: proc(h: ^Page_Heap) -> runtime.Allocator {
	return {}
}

@(private)
_pages_release :: proc(h: ^Page_Heap) {
}

@(private)
_pages_destroy :: proc(h: ^Page_Heap) {
}
