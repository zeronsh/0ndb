package sim

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"

IMAGE_BLOCK :: 64
IMAGE_REPORT_MAX :: 12

Image_File :: struct {
	disk:    string,
	path:    string,
	data:    []u64,
	durable: []u64,
	size:    int,
	dsize:   int,
}

Disk_Images :: struct {
	files: [dynamic]Image_File,
}

@(private = "file")
_blocks :: proc(b: []u8, allocator: runtime.Allocator) -> []u64 {
	n := (len(b) + IMAGE_BLOCK - 1) / IMAGE_BLOCK
	out := make([]u64, n, allocator)
	for i in 0 ..< n {
		lo := i * IMAGE_BLOCK
		out[i] = mix_bytes(u64(i), b[lo:min(lo + IMAGE_BLOCK, len(b))])
	}
	return out
}

world_disks :: proc(w: ^World) -> []^Disk {
	disks := make([dynamic]^Disk, context.temp_allocator)
	for n in w.nodes {
		append(&disks, &n.disk)
	}
	append(&disks, &w.relay.disk)
	return disks[:]
}

disk_images_take :: proc(w: ^World, out: ^Disk_Images, label: string) {
	h := runtime.heap_allocator()
	out.files = make([dynamic]Image_File, h)
	dump, dumping := os.lookup_env("SIM_DISK_DUMP", context.temp_allocator)
	for d in world_disks(w) {
		files := make([dynamic]Disk_File, context.temp_allocator)
		disk_walk(d, &files)
		for f in files {
			im := Image_File {
				disk    = strings.clone(d.name, h),
				path    = strings.clone(f.path, h),
				data    = _blocks(f.data, h),
				durable = _blocks(f.durable, h),
				size    = len(f.data),
				dsize   = len(f.durable),
			}
			append(&out.files, im)
			if dumping && len(dump) > 0 {
				for kind in ([]string{"cache", "durable"}) {
					p := strings.concatenate({dump, "/", label, "/", kind, "/", d.name, f.path}, context.temp_allocator)
					dir := p[:strings.last_index_byte(p, '/')]
					_ = os.make_directory_all(dir)
					_ = os.write_entire_file(p, f.data if kind == "cache" else f.durable)
				}
			}
		}
	}
}

disk_images_free :: proc(im: ^Disk_Images) {
	h := runtime.heap_allocator()
	for f in im.files {
		delete(f.disk, h)
		delete(f.path, h)
		delete(f.data, h)
		delete(f.durable, h)
	}
	delete(im.files)
}

@(private = "file")
_first_diff :: proc(a, b: []u64) -> (first: int, last: int, count: int) {
	first, last = -1, -1
	for i in 0 ..< max(len(a), len(b)) {
		if i < len(a) && i < len(b) && a[i] == b[i] {
			continue
		}
		if first < 0 {
			first = i
		}
		last = i
		count += 1
	}
	return
}

@(private = "file")
_key_less :: proc(a, b: Image_File) -> bool {
	if a.disk != b.disk {
		return a.disk < b.disk
	}
	return a.path < b.path
}

disk_images_compare :: proc(a, b: ^Disk_Images, out: ^[dynamic]string) -> (same: bool) {
	h := runtime.heap_allocator()
	same = true
	reported := 0
	note :: proc(out: ^[dynamic]string, reported: ^int, msg: string) {
		if reported^ < IMAGE_REPORT_MAX {
			append(out, msg)
		} else {
			delete(msg, runtime.heap_allocator())
		}
		reported^ += 1
	}
	i, j := 0, 0
	for i < len(a.files) || j < len(b.files) {
		switch {
		case j >= len(b.files) || (i < len(a.files) && _key_less(a.files[i], b.files[j])):
			same = false
			note(out, &reported, fmt.aprintf("determinism: disk %s file %s exists only in the first run (%d bytes)", a.files[i].disk, a.files[i].path, a.files[i].size, allocator = h))
			i += 1
		case i >= len(a.files) || _key_less(b.files[j], a.files[i]):
			same = false
			note(out, &reported, fmt.aprintf("determinism: disk %s file %s exists only in the second run (%d bytes)", b.files[j].disk, b.files[j].path, b.files[j].size, allocator = h))
			j += 1
		case:
			x, y := a.files[i], b.files[j]
			for kind in 0 ..< 2 {
				xa, ya, xs, ys := x.data, y.data, x.size, y.size
				if kind == 1 {
					xa, ya, xs, ys = x.durable, y.durable, x.dsize, y.dsize
				}
				first, last, count := _first_diff(xa, ya)
				if first < 0 && xs == ys {
					continue
				}
				same = false
				note(out, &reported, fmt.aprintf("determinism: disk %s file %s %s bytes differ between two runs of the same seed: sizes %d vs %d, %d of %d %d-byte blocks differ, first at offset %d, last at offset %d", x.disk, x.path, "page-cache" if kind == 0 else "durable", xs, ys, count, max(len(xa), len(ya)), IMAGE_BLOCK, first * IMAGE_BLOCK, last * IMAGE_BLOCK, allocator = h))
			}
			i += 1
			j += 1
		}
	}
	if reported > IMAGE_REPORT_MAX {
		append(out, fmt.aprintf("determinism: %d more differing files not listed", reported - IMAGE_REPORT_MAX, allocator = h))
	}
	return
}
