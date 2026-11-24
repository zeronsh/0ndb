package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "../../src/fs"
import "../../src/prim"

real: prim.Vfs
procs: prim.Vfs_Procs
nth, reads: int
fired: bool
gen_fd: prim.Fd = prim.INVALID_FD
fail_gen: bool

vfs_make :: proc() -> prim.Vfs {
	real = prim.os_vfs()
	procs = real.procs^
	procs.read_at = proc(data: rawptr, fd: prim.Fd, buf: []u8, off: i64) -> (int, prim.Error) {
		if fail_gen && fd == gen_fd {
			fired = true
			return 0, .Io
		}
		if nth > 0 {
			reads += 1
			if reads == nth {
				nth = 0
				fired = true
				return 0, .Io
			}
		}
		return real.procs.read_at(data, fd, buf, off)
	}
	procs.open = proc(data: rawptr, path: string, flags: prim.Open_Flags, mode: u32) -> (prim.Fd, prim.Error) {
		fd, err := real.procs.open(data, path, flags, mode)
		if strings.has_suffix(path, ".gen") {
			gen_fd = fd
		}
		return fd, err
	}
	return prim.Vfs{&procs, real.data}
}

get :: proc(kv: ^fs.Kv, k: string) -> string {
	v, found, err := fs.kv_get(kv, transmute([]u8)k, context.temp_allocator)
	return fmt.tprintf("%q found=%v err=%v", string(v), found, err)
}

main :: proc() {
	mode, dir := os.args[1], os.args[2]
	v := vfs_make()
	kv: fs.Kv
	if mode == "genfault" {
		fail_gen = true
	}
	if err := fs.kv_open(&kv, v, dir, "state", context.allocator); err != .None {
		fmt.printfln("%s: open %v fired=%v", mode, err, fired)
		return
	}
	k := transmute([]u8)string("key")
	switch mode {
	case "make":
		fs.kv_put(&kv, k, transmute([]u8)string("OLD"))
		for i in 0 ..< 200 {
			fs.kv_put(&kv, transmute([]u8)fmt.tprintf("pad%d", i), transmute([]u8)string("pad"))
		}
		fs.kv_commit(&kv)
		for n in 1 ..= 12 {
			fs.kv_put(&kv, k, transmute([]u8)string("NEW"))
			nth, reads, fired = n, 0, false
			err := fs.kv_commit(&kv)
			nth = 0
			got := get(&kv, "key")
			if fired && strings.has_prefix(got, "\"OLD\"") {
				fmt.printfln("make: read %d failed, commit answered %v, get now: %s", n, err, got)
				break
			}
		}
	case "get":
		fmt.printfln("get: %s", get(&kv, "key"))
	case "compact":
		err := fs.kv_compact(&kv)
		fmt.printfln("compact: %v, get: %s, pad7: %s", err, get(&kv, "key"), get(&kv, "pad7"))
	case "fill":
		for c in 0 ..< 20 {
			for i in 0 ..< 10 {
				fs.kv_put(&kv, transmute([]u8)fmt.tprintf("c%02d-%d", c, i), transmute([]u8)fmt.tprintf("value-%02d-%d", c, i))
			}
			fs.kv_commit(&kv)
		}
		fmt.printfln("fill: 20 commits of 10 keys")
	case "count":
		n, first, last := 0, "", ""
		for c in 0 ..< 20 {
			for i in 0 ..< 10 {
				k := fmt.tprintf("c%02d-%d", c, i)
				if _, found, err := fs.kv_get(&kv, transmute([]u8)k, context.temp_allocator); found && err == .None {
					n += 1
					if len(first) == 0 {
						first = k
					}
					last = k
				}
			}
		}
		fmt.printfln("count: %d of 200 keys readable, last %s", n, last)
	case "big":
		for c in 0 ..< 4 {
			v := make([]u8, 2500000)
			for &b, i in v {
				b = u8(i * 7 + c)
			}
			fs.kv_put(&kv, transmute([]u8)fmt.tprintf("big%d", c), v)
			fs.kv_put(&kv, transmute([]u8)fmt.tprintf("c%02d-0", c), transmute([]u8)string("small"))
			fs.kv_commit(&kv)
		}
		fmt.printfln("big: 4 commits of a 2.5 MB value and a small key")
	case "bigcount":
		n := 0
		for c in 0 ..< 4 {
			if v, f, e := fs.kv_get(&kv, transmute([]u8)fmt.tprintf("big%d", c), context.allocator); f && e == .None && len(v) == 2500000 {
				n += 1
			}
			if _, f, e := fs.kv_get(&kv, transmute([]u8)fmt.tprintf("c%02d-0", c), context.allocator); f && e == .None {
				n += 1
			}
		}
		fmt.printfln("bigcount: %d of 8", n)
	case "put":
		fs.kv_put(&kv, k, transmute([]u8)string("NEWER"))
		fmt.printfln("put NEWER: commit %v, get: %s", fs.kv_commit(&kv), get(&kv, "key"))
	case "grow":
		for i in 0 ..< 5000 {
			fs.kv_put(&kv, transmute([]u8)fmt.tprintf("g%d", i), transmute([]u8)string("x"))
		}
		fmt.printfln("grow: commit %v, get: %s", fs.kv_commit(&kv), get(&kv, "key"))
	case "genfault":
		fmt.printfln("genfault: fired=%v, get: %s, pad7: %s", fired, get(&kv, "key"), get(&kv, "pad7"))
	case "kill":
		fs.kv_put(&kv, transmute([]u8)string("other"), transmute([]u8)string("x"))
		fs.kv_commit(&kv)
		fmt.printfln("kill: exit without close")
		os.exit(0)
	}
	fs.kv_close(&kv)
}
