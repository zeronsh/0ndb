#+build linux, darwin, windows
package osync

replicator_presence_settled :: proc "contextless" (r: ^Replicator) -> bool {
	return r.present_ok && r.phase == .Ready
}

replicator_keys_refresh :: proc(r: ^Replicator, scope: ^Scope, device: Device_Id, name: string, epoch: u64) {
	_enter(r)
	defer _leave(r)
	kn, err := keys_stream_name(name)
	if err != .None {
		return
	}
	_keys_head_start(r, scope, device, kn, epoch + 1)
	_repl_flush(r)
}
