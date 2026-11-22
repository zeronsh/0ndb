#+build darwin
package observe

import "base:runtime"
import "core:c"
import "core:sys/posix"
import "../prim"

@(private)
Susp_Gate :: struct {
	id:   u32,
	pids: [dynamic]prim.Pid,
}

@(private)
Susp_Gates :: struct {
	gates: [dynamic]Susp_Gate,
	next:  u32,
}

@(private)
_susp_gate :: proc(g: ^Susp_Gates, roots: []prim.Pid, root: string, exempt: []prim.Pid, allocator: runtime.Allocator) -> (id: u32, ok: bool) {
	self := prim.Pid(getpid())
	sg := Susp_Gate{pids = make([dynamic]prim.Pid, allocator)}
	queue := make([dynamic]prim.Pid, context.temp_allocator)
	kids: [512]c.int
	cb: [MAXPATHLEN]u8
	for r in roots {
		if !_path_under(_cwd_of(r, cb[:]), root) {
			continue
		}
		clear(&queue)
		append(&queue, r)
		walk: for len(queue) > 0 {
			p := pop(&queue)
			if p <= 1 || p == self {
				continue
			}
			for e in exempt {
				if e == p {
					continue walk
				}
			}
			if posix.kill(posix.pid_t(p), .SIGSTOP) == .OK {
				append(&sg.pids, p)
			}
			n := proc_listchildpids(c.int(p), &kids[0], c.int(size_of(kids)))
			for i in 0 ..< max(int(n), 0) {
				if i < len(kids) && kids[i] > 1 {
					append(&queue, prim.Pid(kids[i]))
				}
			}
		}
	}
	g.next += 1
	if g.next == 0 {
		g.next = 1
	}
	sg.id = g.next
	if g.gates == nil {
		g.gates = make([dynamic]Susp_Gate, allocator)
	}
	append(&g.gates, sg)
	return sg.id, true
}

@(private)
_susp_ungate :: proc(g: ^Susp_Gates, id: u32) {
	for &sg, i in g.gates {
		if sg.id != id {
			continue
		}
		for p in sg.pids {
			posix.kill(posix.pid_t(p), .SIGCONT)
		}
		delete(sg.pids)
		unordered_remove(&g.gates, i)
		return
	}
}
