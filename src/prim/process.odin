#+build linux, darwin, windows
package prim

import "base:runtime"
import "core:bytes"

Pipe :: enum u8 {
	Stdin,
	Stdout,
	Stderr,
}

Pipes :: bit_set[Pipe;u8]

ALL_PIPES :: Pipes{.Stdin, .Stdout, .Stderr}

Signal :: enum i32 {
	Hangup    = 1,
	Interrupt = 2,
	Kill      = 9,
	Terminate = 15,
}

Pre_Exec :: struct {
	data: rawptr,
	run:  proc "contextless" (data: rawptr) -> i32,
}

Child :: struct {
	pid:    Pid,
	stdin:  Fd,
	stdout: Fd,
	stderr: Fd,
	group:  bool,
	os:     _Child_Os,
}

child_close :: proc "contextless" (c: ^Child) {
	close(c.stdin)
	close(c.stdout)
	close(c.stderr)
	c.stdin = INVALID_FD
	c.stdout = INVALID_FD
	c.stderr = INVALID_FD
	_child_os_close(c)
}

child_close_stdin :: proc "contextless" (c: ^Child) {
	close(c.stdin)
	c.stdin = INVALID_FD
}

child_kill :: proc "contextless" (c: ^Child, sig := Signal.Terminate) -> Error {
	return _child_kill(c, sig)
}

Line_Buffer :: struct {
	data:      []u8,
	start:     int,
	scan:      int,
	end:       int,
	keep:      int,
	limit:     int,
	eof:       bool,
	allocator: runtime.Allocator,
}

LINE_BUFFER_DEFAULT :: 16 * 1024

line_buffer_init :: proc(lb: ^Line_Buffer, keep := LINE_BUFFER_DEFAULT, limit := 0, allocator := context.allocator) {
	lb^ = {}
	lb.keep = max(keep, 64)
	lb.limit = limit
	lb.allocator = allocator
}

line_buffer_destroy :: proc(lb: ^Line_Buffer) {
	if lb.data != nil {
		delete(lb.data, lb.allocator)
	}
	lb.data = nil
	lb.start = 0
	lb.scan = 0
	lb.end = 0
}

line_buffer_reset :: proc(lb: ^Line_Buffer) {
	lb.start = 0
	lb.scan = 0
	lb.end = 0
	lb.eof = false
	if len(lb.data) > lb.keep {
		delete(lb.data, lb.allocator)
		lb.data = nil
	}
}

line_buffered :: proc "contextless" (lb: ^Line_Buffer) -> []u8 {
	return lb.data[lb.start:lb.end]
}

line_fill :: proc(lb: ^Line_Buffer, fd: Fd) -> (int, Error) {
	if lb.eof {
		return 0, .None
	}
	_line_compact(lb)
	if lb.end == len(lb.data) {
		if err := _line_grow(lb); err != .None {
			return 0, err
		}
	}
	n, err := read(fd, lb.data[lb.end:])
	if err != .None {
		return 0, err
	}
	if n == 0 {
		lb.eof = true
		return 0, .None
	}
	lb.end += n
	return n, .None
}

line_feed :: proc(lb: ^Line_Buffer, data: []u8) -> Error {
	_line_compact(lb)
	for len(lb.data) - lb.end < len(data) {
		if err := _line_grow(lb); err != .None {
			return err
		}
	}
	copy(lb.data[lb.end:], data)
	lb.end += len(data)
	return .None
}

line_finish :: proc "contextless" (lb: ^Line_Buffer) {
	lb.eof = true
}

line_next :: proc(lb: ^Line_Buffer) -> ([]u8, bool) {
	if lb.scan < lb.end {
		if i := bytes.index_byte(lb.data[lb.scan:lb.end], '\n'); i >= 0 {
			nl := lb.scan + i
			line := lb.data[lb.start:nl]
			lb.start = nl + 1
			lb.scan = lb.start
			return line, true
		}
		lb.scan = lb.end
	}
	if lb.eof && lb.start < lb.end {
		line := lb.data[lb.start:lb.end]
		lb.start = lb.end
		lb.scan = lb.end
		return line, true
	}
	return nil, false
}

@(private)
_line_compact :: proc(lb: ^Line_Buffer) {
	if lb.start == 0 {
		return
	}
	if lb.start == lb.end {
		lb.start = 0
		lb.scan = 0
		lb.end = 0
		if len(lb.data) > lb.keep {
			delete(lb.data, lb.allocator)
			lb.data = nil
		}
		return
	}
	n := lb.end - lb.start
	copy(lb.data[:n], lb.data[lb.start:lb.end])
	lb.scan -= lb.start
	lb.start = 0
	lb.end = n
}

@(private)
_line_grow :: proc(lb: ^Line_Buffer) -> Error {
	if lb.allocator.procedure == nil {
		lb.allocator = context.allocator
	}
	size := len(lb.data) * 2
	if size == 0 {
		size = lb.keep if lb.keep > 0 else LINE_BUFFER_DEFAULT
	}
	if lb.limit > 0 {
		if len(lb.data) >= lb.limit {
			return .Too_Large
		}
		size = min(size, lb.limit)
	}
	next, err := make([]u8, size, lb.allocator)
	if err != nil {
		return .No_Memory
	}
	if lb.data != nil {
		copy(next, lb.data[:lb.end])
		delete(lb.data, lb.allocator)
	}
	lb.data = next
	return .None
}
