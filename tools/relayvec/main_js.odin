package relayvec

import "core:strings"

@(export)
relayvec_failed: i32 = -1

main :: proc() {
	all := #load_directory("../../docs/relay-vectors")
	files := make([dynamic]Embedded)
	for f in all {
		if strings.has_suffix(f.name, ".json") && f.name != "index.json" {
			append(&files, Embedded{name = f.name, data = f.data})
		}
	}
	total, bad := check_embedded(files[:])
	relayvec_failed = i32(bad) if total > 0 else -1
}
