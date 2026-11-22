package sim

import "core:fmt"
import "core:sync"
import "core:testing"

regions_mapped: int

Sim_Globals :: struct {
	region_main_size: uint,
	region_temp_size: uint,
	trace_events:     bool,
	trace_bytes_at:   u64,
	leak_sites:       bool,
	mw:               ^Mem_World,
	regions_mapped:   int,
}

SIM_GLOBALS_DEFAULT :: Sim_Globals {
	region_main_size = 256 << 20,
	region_temp_size = 96 << 20,
}

sim_globals :: proc() -> Sim_Globals {
	return Sim_Globals {
		region_main_size = region_main_size,
		region_temp_size = region_temp_size,
		trace_events = trace_events,
		trace_bytes_at = trace_bytes_at,
		leak_sites = leak_sites,
		mw = members_world(),
		regions_mapped = regions_mapped,
	}
}

sim_globals_set :: proc(g: Sim_Globals) {
	region_main_size = g.region_main_size
	region_temp_size = g.region_temp_size
	trace_events = g.trace_events
	trace_bytes_at = g.trace_bytes_at
	leak_sites = g.leak_sites
	members_world_set(g.mw)
}

test_begin :: proc(t: ^testing.T, loc := #caller_location) {
	sync.mutex_lock(&serial)
	if g := sim_globals(); g != SIM_GLOBALS_DEFAULT {
		testing.expect(t, false, fmt.tprintf("sim package state is not the default when %s starts: %v", loc.procedure, g))
		sim_globals_set(SIM_GLOBALS_DEFAULT)
	}
}

test_end :: proc(t: ^testing.T, loc := #caller_location) {
	if g := sim_globals(); g != SIM_GLOBALS_DEFAULT {
		testing.expect(t, false, fmt.tprintf("%s left sim package state changed: %v", loc.procedure, g))
		sim_globals_set(SIM_GLOBALS_DEFAULT)
	}
	sync.mutex_unlock(&serial)
}
