package obj

import "base:runtime"

ARENA_FIRST :: 64 * 1024
ARENA_MAX :: 64 * 1024 when ODIN_ARCH == .wasm32 || ODIN_ARCH == .wasm64p32 else 1024 * 1024

Arena :: struct {
	arena: runtime.Arena,
	seen:  uint,
}

Arena_Temp :: runtime.Arena_Temp

arena_init :: proc(a: ^Arena, backing := context.allocator) -> runtime.Allocator_Error {
	a^ = Arena{
		arena = runtime.Arena{
			backing_allocator  = backing,
			minimum_block_size = ARENA_FIRST,
		},
	}
	return nil
}

arena_allocator :: proc(a: ^Arena) -> runtime.Allocator {
	return runtime.Allocator{procedure = _arena_proc, data = a}
}

arena_destroy :: proc(a: ^Arena) {
	runtime.arena_destroy(&a.arena)
	a.seen = 0
}

arena_free_all :: proc(a: ^Arena) {
	runtime.arena_free_all(&a.arena)
	a.seen = a.arena.total_capacity
}

arena_used :: proc "contextless" (a: ^Arena) -> uint {
	return a.arena.total_used
}

arena_temp_begin :: proc(a: ^Arena) -> Arena_Temp {
	return runtime.arena_temp_begin(&a.arena)
}

arena_temp_end :: proc(t: Arena_Temp) {
	runtime.arena_temp_end(t)
}

@(private)
_arena_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	a := (^Arena)(data)
	out, err := runtime.arena_allocator_proc(&a.arena, mode, size, alignment, old_memory, old_size, loc)
	if a.arena.total_capacity > a.seen {
		a.seen = a.arena.total_capacity
		a.arena.minimum_block_size = min(a.arena.minimum_block_size * 2, ARENA_MAX)
	}
	return out, err
}
