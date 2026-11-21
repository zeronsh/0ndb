#+build !amd64
#+build !arm64
package odb

@(private)
sha1_hw_supported :: proc "contextless" () -> bool {
	return false
}

@(private)
sha1_hw_blocks :: proc "contextless" (state: ^[5]u32, data: []u8) {
}
