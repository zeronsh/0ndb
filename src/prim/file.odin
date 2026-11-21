package prim

import "base:runtime"
import "core:strings"

Open_Flag :: enum u8 {
	Write,
	Create,
	Truncate,
	Exclusive,
	Append,
	Nonblock,
	Directory,
}

Open_Flags :: bit_set[Open_Flag;u8]

Path_Buf :: [PATH_MAX]u8

cpath :: proc "contextless" (path: string, buf: ^Path_Buf) -> (cstring, Error) {
	if len(path) == 0 {
		return nil, .Not_Found
	}
	if len(path) >= PATH_MAX {
		return nil, .Name_Too_Long
	}
	for i in 0 ..< len(path) {
		if path[i] == 0 {
			return nil, .Invalid
		}
		buf[i] = path[i]
	}
	buf[len(path)] = 0
	return cstring(&buf[0]), .None
}

dir_name :: proc "contextless" (path: string) -> string {
	end := len(path)
	for end > 1 && path[end - 1] == '/' {
		end -= 1
	}
	for i := end - 1; i >= 0; i -= 1 {
		if path[i] == '/' {
			if i == 0 {
				return "/"
			}
			return path[:i]
		}
	}
	return "."
}

read_file :: proc(vfs: Vfs, path: string, allocator := context.allocator) -> (data: []u8, err: Error) {
	fd := open_file(vfs, path) or_return
	defer close_file(vfs, fd)
	size := file_size(vfs, fd) or_return
	if size > i64(max(int)) {
		return nil, .Too_Large
	}
	buf, alloc_err := make([]u8, int(size), allocator)
	if alloc_err != nil {
		return nil, .No_Memory
	}
	n: int
	n, err = read_at(vfs, fd, buf, 0)
	if err != .None {
		delete(buf, allocator)
		return nil, err
	}
	return buf[:n], .None
}

replace_atomic :: proc(vfs: Vfs, path: string, data: []u8) -> Error {
	if len(path) + 4 >= PATH_MAX {
		return .Name_Too_Long
	}
	tmp_buf: Path_Buf
	copy(tmp_buf[:], path)
	copy(tmp_buf[len(path):], ".tmp")
	tmp := string(tmp_buf[:len(path) + 4])
	fd := open_file(vfs, tmp, {.Write, .Create, .Truncate}) or_return
	err := write_at(vfs, fd, data, 0)
	if err == .None {
		err = datasync(vfs, fd)
	}
	close_err := close_file(vfs, fd)
	if err == .None {
		err = close_err
	}
	if err == .None {
		err = rename(vfs, tmp, path)
	}
	if err != .None {
		_ = remove(vfs, tmp)
		return err
	}
	return sync_dir(vfs, dir_name(path))
}

mkdir_all :: proc(vfs: Vfs, path: string, mode: u32 = 0o755) -> Error {
	if len(path) == 0 {
		return .Not_Found
	}
	if len(path) >= PATH_MAX {
		return .Name_Too_Long
	}
	if is_dir(vfs, path) {
		return .None
	}
	i := 0
	for i < len(path) {
		j := i
		for j < len(path) && path[j] == '/' {
			j += 1
		}
		for j < len(path) && path[j] != '/' {
			j += 1
		}
		if j > 0 && path[j - 1] != '/' {
			err := mkdir(vfs, path[:j], mode)
			if err != .None && err != .Exists {
				return err
			}
		}
		i = j
	}
	if !is_dir(vfs, path) {
		return .Not_Dir
	}
	return .None
}

@(private)
_clone :: proc(s: string, allocator: runtime.Allocator) -> (string, Error) {
	out, err := strings.clone(s, allocator)
	if err != nil {
		return "", .No_Memory
	}
	return out, .None
}

path_join :: proc(allocator: runtime.Allocator, parts: ..string) -> (string, Error) {
	n := 0
	for p, k in parts {
		if k > 0 && !strings.has_suffix(parts[k - 1], "/") {
			n += 1
		}
		n += len(p)
	}
	buf, err := make([]u8, n, allocator)
	if err != nil {
		return "", .No_Memory
	}
	i := 0
	for p, k in parts {
		if k > 0 && !strings.has_suffix(parts[k - 1], "/") {
			buf[i] = '/'
			i += 1
		}
		i += copy(buf[i:], p)
	}
	return string(buf), .None
}
