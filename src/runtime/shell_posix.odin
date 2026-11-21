#+build linux, darwin
package rt

shell_argv :: proc(cmd: string, allocator := context.temp_allocator) -> []string {
	out := make([]string, 3, allocator)
	out[0] = "/bin/sh"
	out[1] = "-c"
	out[2] = cmd
	return out
}
