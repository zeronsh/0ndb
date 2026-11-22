#+build linux, darwin, windows
package relayvec

import "core:fmt"
import "core:os"
import "core:strings"

main :: proc() {
	args := os.args
	if len(args) < 3 || (args[1] != "write" && args[1] != "check") {
		fmt.eprintln("usage: relayvec write DIR | relayvec check DIR")
		os.exit(2)
	}
	if args[1] == "write" {
		os.exit(write_all(args[2]))
	}
	os.exit(check_dir(args[2]))
}

write_all :: proc(dir: string) -> int {
	bad := 0
	index := strings.builder_make()
	strings.write_string(&index, "[\n")
	for sc, i in scenarios() {
		v: Vector
		vector_begin(&v, sc)
		sc.run(&v)
		text := vector_end(&v)
		if v.failed {
			fmt.eprintfln("relayvec: %s failed while generating", sc.name)
			bad += 1
			continue
		}
		path := fmt.tprintf("%s/%s.json", dir, sc.name)
		if werr := os.write_entire_file(path, transmute([]u8)text); werr != nil {
			fmt.eprintfln("relayvec: cannot write %s", path)
			bad += 1
		}
		fmt.sbprintf(&index, "  {{\"name\": \"%s\", \"steps\": %d, \"summary\": %q}}%s\n", sc.name, v.nsteps, sc.summary, "," if i + 1 < len(scenarios()) else "")
		fmt.printfln("wrote %s (%d steps)", path, v.nsteps)
	}
	strings.write_string(&index, "]\n")
	if werr := os.write_entire_file(fmt.tprintf("%s/index.json", dir), transmute([]u8)strings.to_string(index)); werr != nil {
		bad += 1
	}
	return 1 if bad > 0 else 0
}

check_dir :: proc(dir: string) -> int {
	files, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil {
		fmt.eprintfln("relayvec: cannot read %s", dir)
		return 2
	}
	names := make([dynamic]string)
	for f in files {
		if strings.has_suffix(f.name, ".json") && f.name != "index.json" {
			append(&names, f.fullpath)
		}
	}
	bad, total := 0, 0
	for p in names {
		data, rerr := os.read_entire_file_from_path(p, context.allocator)
		if rerr != nil {
			fmt.eprintfln("relayvec: cannot read %s", p)
			bad += 1
			continue
		}
		total += 1
		if why, ok := check_vector(data); !ok {
			fmt.eprintfln("FAIL %s: %s", p, why)
			bad += 1
		} else {
			fmt.printfln("ok   %s", p)
		}
		free_all(context.temp_allocator)
	}
	fmt.printfln("%d vectors, %d failed", total, bad)
	return 1 if bad > 0 || total == 0 else 0
}
