package zstd

import "core:c"

VERSION :: 10507

when ODIN_OS == .Windows && ODIN_ARCH == .amd64 {
	foreign import lib {
		"lib/zstd_windows_amd64.lib",
		"system:libucrt.lib",
		"system:legacy_stdio_definitions.lib",
	}
} else when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
	foreign import lib "lib/libzstd_darwin_arm64.a"
} else when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
	foreign import lib "lib/libzstd_linux_amd64.a"
} else {
	#assert(false, "zstd: no vendored build for this target; run src/zstd/build.sh or build.bat on it")
}

CCtx :: struct {}
DCtx :: struct {}
CDict :: struct {}
DDict :: struct {}

@(default_calling_convention = "c")
foreign lib {
	ZSTD_versionNumber :: proc() -> c.uint ---
	ZSTD_compressBound :: proc(src_size: c.size_t) -> c.size_t ---
	ZSTD_isError :: proc(code: c.size_t) -> c.uint ---
	ZSTD_createCCtx :: proc() -> ^CCtx ---
	ZSTD_freeCCtx :: proc(cctx: ^CCtx) -> c.size_t ---
	ZSTD_createDCtx :: proc() -> ^DCtx ---
	ZSTD_freeDCtx :: proc(dctx: ^DCtx) -> c.size_t ---
	ZSTD_createCDict :: proc(dict: rawptr, size: c.size_t, level: c.int) -> ^CDict ---
	ZSTD_freeCDict :: proc(cdict: ^CDict) -> c.size_t ---
	ZSTD_createDDict :: proc(dict: rawptr, size: c.size_t) -> ^DDict ---
	ZSTD_freeDDict :: proc(ddict: ^DDict) -> c.size_t ---
	ZSTD_compressCCtx :: proc(cctx: ^CCtx, dst: rawptr, cap: c.size_t, src: rawptr, size: c.size_t, level: c.int) -> c.size_t ---
	ZSTD_decompressDCtx :: proc(dctx: ^DCtx, dst: rawptr, cap: c.size_t, src: rawptr, size: c.size_t) -> c.size_t ---
	ZSTD_compress_usingCDict :: proc(cctx: ^CCtx, dst: rawptr, cap: c.size_t, src: rawptr, size: c.size_t, cdict: ^CDict) -> c.size_t ---
	ZSTD_decompress_usingDDict :: proc(dctx: ^DCtx, dst: rawptr, cap: c.size_t, src: rawptr, size: c.size_t, ddict: ^DDict) -> c.size_t ---
	ZDICT_trainFromBuffer :: proc(dict: rawptr, cap: c.size_t, samples: rawptr, sizes: [^]c.size_t, n: c.uint) -> c.size_t ---
	ZDICT_isError :: proc(code: c.size_t) -> c.uint ---
}
