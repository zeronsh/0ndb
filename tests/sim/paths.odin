package sim

import "core:testing"
import "../../src/fs"

@(test)
windows_paths :: proc(t: ^testing.T) {
	Case :: struct {
		path:    string,
		root:    string,
		rel:     string,
		ok:      bool,
		windows: bool,
	}
	cases := [?]Case {
		{"C:\\w\\a\\b.txt", "C:/w", "a/b.txt", true, true},
		{"C:/w/a.txt", "C:\\w\\", "a.txt", true, true},
		{"c:\\W\\A.txt", "C:/w", "A.txt", true, true},
		{"C:\\w", "C:/w", "", true, true},
		{"C:\\w\\..\\x.txt", "C:/w", "", false, true},
		{"C:\\work\\x.txt", "C:/w", "", false, true},
		{"D:\\w\\x.txt", "C:/w", "", false, true},
		{"\\\\host\\share\\x.txt", "//host/share", "x.txt", true, true},
		{"/w/a.txt", "/w", "a.txt", true, false},
		{"/W/a.txt", "/w", "", false, false},
		{"/w/a\\b.txt", "/w", "a\\b.txt", true, false},
		{"/w/../x.txt", "/w", "", false, false},
		{"/x.txt", "/", "x.txt", true, false},
	}
	for c in cases {
		rel, ok := fs.path_rel(c.path, c.root, c.windows)
		testing.expectf(t, ok == c.ok && rel == c.rel, "%q under %q (windows %v) is %q %v, not %q %v", c.path, c.root, c.windows, rel, ok, c.rel, c.ok)
	}
	root := fs.clean_root("C:\\", context.temp_allocator, true)
	testing.expectf(t, root == "C:/", "a drive root is kept as C:/, not %q", root)
	free_all(context.temp_allocator)
}
