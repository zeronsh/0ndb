package engine

import "base:runtime"
import "core:strconv"
import "core:strings"
import "core:sys/linux"

foreign import libc "system:c"

@(private)
@(default_calling_convention = "c")
foreign libc {
	malloc_trim :: proc(pad: uint) -> i32 ---
}

@(private)
_heap_release :: proc(e: ^Engine) {
	if e.allocator.procedure == runtime.heap_allocator_proc {
		malloc_trim(0)
	}
}

@(private)
_pageout :: proc(e: ^Engine) {
	fd, oerr := linux.open("/proc/self/maps", {})
	if oerr != .NONE {
		return
	}
	defer linux.close(fd)
	buf := make([dynamic]u8, context.temp_allocator)
	chunk: [16384]u8
	for {
		n, rerr := linux.read(fd, chunk[:])
		if rerr == .EINTR {
			continue
		}
		if rerr != .NONE || n <= 0 {
			break
		}
		append(&buf, ..chunk[:n])
	}
	advice := linux.MAdvice.PAGEOUT
	text := string(buf[:])
	for len(text) > 0 {
		nl := strings.index_byte(text, '\n')
		line := text
		if nl >= 0 {
			line = text[:nl]
			text = text[nl + 1:]
		} else {
			text = ""
		}
		lo, hi, perms, path, ok := _maps_line(line)
		if !ok || len(path) == 0 || path[0] != '/' || perms[1] == 'w' {
			continue
		}
		if perms[2] != 'x' && perms[0] != 'r' {
			continue
		}
		err := linux.madvise(rawptr(lo), uint(hi - lo), advice)
		if err == .EINVAL && advice == .PAGEOUT {
			advice = .COLD
			linux.madvise(rawptr(lo), uint(hi - lo), advice)
		}
	}
}

@(private)
_maps_line :: proc(line: string) -> (lo, hi: uintptr, perms: string, path: string, ok: bool) {
	dash := strings.index_byte(line, '-')
	sp := strings.index_byte(line, ' ')
	if dash <= 0 || sp <= dash || len(line) < sp + 5 {
		return
	}
	l, lok := strconv.parse_u64_of_base(line[:dash], 16)
	h, hok := strconv.parse_u64_of_base(line[dash + 1:sp], 16)
	if !lok || !hok || h <= l {
		return
	}
	perms = line[sp + 1:sp + 5]
	fields := 0
	i := sp
	for i < len(line) && fields < 4 {
		for i < len(line) && line[i] == ' ' {
			i += 1
		}
		for i < len(line) && line[i] != ' ' {
			i += 1
		}
		fields += 1
	}
	for i < len(line) && line[i] == ' ' {
		i += 1
	}
	return uintptr(l), uintptr(h), perms, line[i:], true
}
