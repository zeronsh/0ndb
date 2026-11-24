package stepsize

import "core:fmt"
import "core:os"
import "core:strings"
import "core:strconv"
import "core:time"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/pack"
import "../../src/prim"

write_file :: proc(path, data: string) {
	fd, err := os.open(path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, os.Permissions_Read_Write_All)
	if err != nil {
		fmt.eprintln("open", path, err)
		os.exit(1)
	}
	os.write_string(fd, data)
	os.sync(fd)
	os.close(fd)
}

file_size :: proc(path: string) -> i64 {
	info, err := os.stat(path, context.temp_allocator)
	if err != nil {
		return 0
	}
	return info.size
}

dir_bytes :: proc(path: string) -> (total: i64) {
	fd, err := os.open(path)
	if err != nil {
		return
	}
	defer os.close(fd)
	infos, rerr := os.read_dir(fd, -1, context.temp_allocator)
	if rerr != nil {
		return
	}
	for info in infos {
		p := strings.concatenate({path, "/", info.name}, context.temp_allocator)
		if info.type == .Directory {
			total += dir_bytes(p)
		} else {
			total += info.size
		}
	}
	return
}

pump :: proc(e: ^eng.Engine, ms: int) {
	end := time.time_to_unix_nano(time.now()) + i64(ms) * 1_000_000
	for time.time_to_unix_nano(time.now()) < end {
		eng.step(e, false)
		time.sleep(2 * time.Millisecond)
	}
}

main :: proc() {
	edits := 1000
	if len(os.args) > 3 {
		edits, _ = strconv.parse_int(os.args[3])
	}
	dir := os.args[1]
	repo := os.args[2]
	variant := os.args[5] if len(os.args) > 5 else ""
	fixed_who: prim.Id
	fixed_sid: prim.Id
	e: eng.Engine
	if err := eng.open(&e, eng.default_config(dir)); err != .None {
		fmt.eprintln("open", err)
		os.exit(1)
	}
	space, _ := eng.space_create(&e, "size")
	eng.space_open(&e, space)
	tree, terr := eng.tree_create(&e, space, "work")
	fmt.eprintln("tree", terr)
	reg, rerr := eng.registry(&e)
	fmt.eprintln("registry", rerr)
	write_file(strings.concatenate({repo, "/a.txt"}), "line 0\nline 1\n")
	m, merr := eng.tree_mount(&e, tree, repo, fs.DEFAULT_MOUNT)
	fmt.eprintln("mount", merr)
	pump(&e, 1500)
	before := dir_bytes(dir)
	cur := strings.builder_make()
	strings.write_string(&cur, "line 0\nline 1\n")
	maxlog := i64(0)
	t0 := time.now()
	prim.random_fill(reg.random, fixed_who[:])
	prim.random_fill(reg.random, fixed_sid[:])
	has :: proc(v: string, c: rune) -> bool {
		return strings.contains_rune(v, c)
	}
	for i in 0 ..< edits {
		who: prim.Id
		prim.random_fill(reg.random, who[:])
		sid: prim.Id
		prim.random_fill(reg.random, sid[:])
		if has(variant, 'a') {
			who = fixed_who
		}
		if has(variant, 'i') {
			sid = fixed_sid
		}
		if has(variant, 's') {
			text := strings.to_string(cur)
			_ = text
			strings.write_string(&cur, fmt.tprintf("edit %d added by the agent\n", i))
			write_file(strings.concatenate({repo, "/a.txt"}, context.temp_allocator), strings.to_string(cur))
		} else {
			s := fs.scope_open(reg, m, sid, who)
			text := strings.to_string(cur)
			if !has(variant, 'b') {
				fs.scope_read_base(s, "a.txt", transmute([]u8)text)
			}
			if !has(variant, 'o') {
				fs.mount_observe_begin(m, "a.txt", s)
			}
			strings.write_string(&cur, fmt.tprintf("edit %d added by the agent\n", i))
			write_file(strings.concatenate({repo, "/a.txt"}, context.temp_allocator), strings.to_string(cur))
			fs.scope_close(reg, s)
		}
		pump(&e, 60 if has(variant, 'p') else 3)
		maxlog = max(maxlog, m.log_len)
		free_all(context.temp_allocator)
	}
	pump(&e, 2500)
	fs.mount_sync(m)
	pump(&e, 1500)
	if len(os.args) > 4 {
		extra, _ := strconv.parse_int(os.args[4])
		pump(&e, extra * 1000)
	}
	after := dir_bytes(dir)
	{
		Ent :: struct {
			bytes: i64,
			path:  string,
		}
		list := make([dynamic]Ent)
		for inum, b in pack.DBG_LOGGED {
			path := "?"
			ext := inum & (1 << 60) != 0
			if pp, ok := pack.DBG_PATH[inum &~ (1 << 60)]; ok {
				path = pp
			}
			append(&list, Ent{b, fmt.tprintf("%s inum=%x %s", "EXT" if ext else "LOG", inum &~ (1 << 60), path)})
		}
		for _ in 0 ..< 12 {
			best := -1
			for e, i in list {
				if best < 0 || e.bytes > list[best].bytes {
					best = i
				}
			}
			if best < 0 {
				break
			}
			fmt.eprintln("TOP", list[best].bytes, list[best].path)
			ordered_remove(&list, best)
		}
	}
	fmt.eprintf("stepsize: edits=%d disk_delta=%d per_edit=%.1f max_attrib_log=%d elapsed=%v\n", edits, after - before, f64(after - before) / f64(edits), maxlog, time.since(t0))
}
