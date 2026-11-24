package sim

import "base:runtime"
import "core:os"
import "core:testing"
import "../../src/fs"
import "../../src/prim"

@(test)
link_probe :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	d: Disk
	disk_init(&d, "probe", runtime.heap_allocator())
	defer disk_destroy(&d)
	v := disk_vfs(&d)
	if prim.mkdir_all(v, "/work/m", 0o700) != .None {
		testing.expect(t, false, "link probe: setup mkdir")
		return
	}
	m: fs.Mount
	m.vfs = v
	m.root = "/work/m"
	before := d.stats.ops
	links := fs.mount_symlinks(&m)
	testing.expectf(t, d.stats.ops == before && m.fence_seq == 0, "link probe: asking a mount on the sim disk whether it has symlinks issued %d disk ops and took %d temp names; the probe is for the OS file system, and on the sim disk it shifts every later crash point and temp name, so a seed no longer reproduces across platforms", d.stats.ops - before, m.fence_seq)
	testing.expect(t, links, "link probe: a mount on the sim disk reports no symlinks")
}
