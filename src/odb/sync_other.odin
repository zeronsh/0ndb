#+build !linux
#+build !darwin
package odb

import "core:os"

@(private)
sync_paths :: proc(files, dirs: []string, roots: []string) -> Error {
	for list in ([][]string{files, dirs}) {
		for p in list {
			f, err := open_for_sync(p)
			if err == .Not_Found {
				continue
			}
			err or_return
			serr := os.sync(f)
			os.close(f)
			if serr != nil {
				return .Io
			}
		}
	}
	return .None
}
