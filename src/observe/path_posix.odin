#+build linux, darwin
package observe

path_is_abs :: proc "contextless" (p: string) -> bool {
	return len(p) > 0 && p[0] == '/'
}

@(private)
_abs_root_len :: proc "contextless" (p: string) -> int {
	return 0 if path_is_abs(p) else -1
}

@(private)
_path_native :: proc(p: string) -> string {
	return p
}
