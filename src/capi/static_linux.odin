package capi

import "base:runtime"

when ODIN_BUILD_MODE == .Static {
	@(private, link_section = ".init_array", require)
	_static_ctor := _static_init
}

@(private)
_static_init :: proc "c" () {
	context = runtime.default_context()
	runtime._startup_runtime()
}
