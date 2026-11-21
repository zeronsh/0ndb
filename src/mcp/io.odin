package mcp

import "../prim"

Out_Queue :: struct {
	buf:     Buf,
	pos:     int,
	waiting: bool,
	base:    prim.Events,
}

out_pending :: proc "contextless" (q: ^Out_Queue) -> int {
	return len(q.buf) - q.pos
}

out_destroy :: proc(q: ^Out_Queue) {
	delete(q.buf)
	base := q.base
	q^ = {}
	q.base = base
}

out_write :: proc(q: ^Out_Queue, l: ^prim.Loop, w: prim.Watch, fd: prim.Fd, parts: ..[]u8) -> prim.Error {
	if fd == prim.INVALID_FD {
		return .Broken_Pipe
	}
	if out_pending(q) == 0 {
		q.pos = 0
		clear(&q.buf)
		for part, i in parts {
			data := part
			for len(data) > 0 {
				n, err := prim.write(fd, data)
				if err == .Interrupted {
					continue
				}
				if err == .Would_Block {
					break
				}
				if err != .None {
					return err
				}
				data = data[n:]
			}
			if len(data) > 0 {
				append(&q.buf, ..data)
				for rest in parts[i + 1:] {
					append(&q.buf, ..rest)
				}
				break
			}
		}
	} else {
		for part in parts {
			append(&q.buf, ..part)
		}
	}
	if out_pending(q) > 0 && !q.waiting {
		q.waiting = true
		prim.watch_modify(l, w, q.base + {.Write})
	}
	return .None
}

out_flush :: proc(q: ^Out_Queue, l: ^prim.Loop, w: prim.Watch, fd: prim.Fd) -> prim.Error {
	for out_pending(q) > 0 {
		n, err := prim.write(fd, q.buf[q.pos:])
		if err == .Interrupted {
			continue
		}
		if err == .Would_Block {
			return .None
		}
		if err != .None {
			return err
		}
		q.pos += n
	}
	q.pos = 0
	clear(&q.buf)
	if cap(q.buf) > 1 << 20 {
		delete(q.buf)
		q.buf = nil
	}
	if q.waiting {
		q.waiting = false
		prim.watch_modify(l, w, q.base)
	}
	return .None
}
