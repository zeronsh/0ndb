package main

import "core:fmt"
import "core:os"
import "core:strings"
import "../../../src/pack"
import "../../../src/prim"

walk :: proc(v: prim.Vfs, path: string) {
	d: prim.Dir
	if prim.dir_open(v, &d, path) != .None {
		return
	}
	defer prim.dir_close(v, &d)
	for {
		e, ok, err := prim.dir_next(v, &d)
		if !ok || err != .None {
			break
		}
		if e.name == "." || e.name == ".." {
			continue
		}
		child := strings.concatenate({path, "/", e.name}) if len(path) > 0 else strings.clone(e.name)
		st, serr := prim.lstat(v, child)
		if serr == .None && st.kind == .Dir {
			walk(v, child)
		} else {
			fmt.printfln("F %d %s", st.size, child)
		}
	}
}

main :: proc() {
	p: pack.Pack
	if err := pack.open(&p, prim.os_vfs(), os.args[1]); err != .None {
		fmt.eprintln("open", err)
		os.exit(1)
	}
	total, live: i64
	for c in p.conts {
		fmt.printfln("c%08x size %d live %d", c.id, c.size, c.live)
		total += c.size
		live += max(c.live, 0)
	}
	fmt.printfln("containers %d bytes, %d live", total, live)
	if len(os.args) > 3 {
		data, err := prim.read_file(pack.vfs(&p), os.args[3])
		if err == .None {
			prim.replace_atomic(prim.os_vfs(), os.args[2], data)
		}
	} else if len(os.args) > 2 {
		walk(pack.vfs(&p), os.args[2])
	}
	pack.close(&p)
}
