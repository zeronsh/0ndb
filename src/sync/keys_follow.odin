#+build linux, darwin, windows
package osync

import "../journal"
import "../prim"

@(private)
KWAIT_PASSES :: 4

@(private)
_following :: proc "contextless" (rm: ^Remote) -> bool {
	return rm.follow || rm.kfollow
}

@(private)
_kwait_hold :: proc(r: ^Replicator, rm: ^Remote) {
	if rm.is_head || _is_keys_name(rm.name) {
		return
	}
	head := _kwait_head_get(r, rm)
	if head == nil {
		return
	}
	rm.kwait_head = head.id
	r.kwait_dirty = true
}

@(private)
_kwait_release :: proc(r: ^Replicator, rm: ^Remote) {
	if rm.kwait_head == {} {
		return
	}
	rm.kwait_head = {}
	r.kwait_dirty = true
}

@(private)
_kwait_head_get :: proc(r: ^Replicator, rm: ^Remote) -> ^Remote {
	kn, kerr := keys_stream_name(rm.name)
	if kerr != .None {
		return nil
	}
	hname, herr := keys_head_name(kn)
	if herr != .None {
		return nil
	}
	head, gerr := _remote_get(r, &rm.scope, rm.device, hname, 0)
	if gerr != .None {
		return nil
	}
	head.is_head = true
	if len(head.head_keys) == 0 {
		head.head_keys, _ = _clone_string(kn, r.allocator)
	}
	return head
}

@(private)
_kwait_head_landed :: proc(r: ^Replicator, head: ^Remote) {
	if !head.kfollow || len(head.head_keys) == 0 {
		return
	}
	epoch, ok := _keys_head_epoch(r, head)
	if !ok {
		return
	}
	_keys_head_seen(r, head)
	id := stream_id(&head.scope, head.device, head.head_keys, epoch)
	if head.kstream == id {
		return
	}
	if _, err := _remote_get(r, &head.scope, head.device, head.head_keys, epoch); err != .None {
		return
	}
	head.kstream = id
	r.kwait_dirty = true
}

@(private)
_kwait_keys_landed :: proc(r: ^Replicator, ks: ^Remote) {
	if !ks.kfollow || ks.is_head || journal.replica_length(&ks.rep) <= 0 {
		return
	}
	for id in _sorted_ids(r.remotes) {
		rm, ok := r.remotes[id]
		if !ok || !rm.keys_wait || rm.kwait_head == {} {
			continue
		}
		if head, hok := r.remotes[rm.kwait_head]; hok && head.kstream == ks.id {
			_emit(r, Repl_Event{kind = .Keys_Needed, device = rm.device, name = rm.name, epoch = rm.epoch, stream = rm.id})
		}
	}
}

@(private)
_kwait_head_want :: proc(r: ^Replicator, head: ^Remote) {
	n := head.relay_len
	if !head.kfollow || n <= 0 {
		return
	}
	from := max(n - 64, 0)
	if _, missing := journal.replica_missing(&head.rep, from, n); !missing {
		return
	}
	_want_add(head, journal.Range{from, n})
}

@(private)
_kwait_sync :: proc(r: ^Replicator) {
	r.hold += 1
	defer r.hold -= 1
	for pass := 0; pass < KWAIT_PASSES && r.kwait_dirty; pass += 1 {
		r.kwait_dirty = false
		need := make(map[Stream_Id]bool, context.temp_allocator)
		for id in _sorted_ids(r.remotes) {
			rm, ok := r.remotes[id]
			if !ok || rm.kwait_head == {} {
				continue
			}
			if !rm.keys_wait || rm.quarantined {
				rm.kwait_head = {}
				continue
			}
			head, hok := r.remotes[rm.kwait_head]
			if !hok {
				head = _kwait_head_get(r, rm)
				if head == nil {
					continue
				}
				rm.kwait_head = head.id
			}
			need[head.id] = true
			if head.kstream != {} {
				need[head.kstream] = true
			}
		}
		for id in _sorted_ids(r.remotes) {
			rm, ok := r.remotes[id]
			if !ok {
				continue
			}
			want := id in need
			if want && !rm.kfollow {
				_kfollow_on(r, rm)
			} else if !want && rm.kfollow {
				_kfollow_off(r, rm)
			}
		}
	}
	was := r.pumping
	r.pumping = true
	_repl_flush(r)
	r.pumping = was
}

@(private)
_kfollow_on :: proc(r: ^Replicator, rm: ^Remote) {
	was := _following(rm)
	rm.kfollow = true
	if rm.is_head {
		_kwait_head_landed(r, rm)
	} else {
		_kwait_keys_landed(r, rm)
	}
	if was {
		return
	}
	rm.want_gen += 1
	if rm.is_head {
		_kwait_head_want(r, rm)
	}
	if r.phase != .Ready {
		return
	}
	if r.cfg.filtered && !was && !rm.grouped {
		pat := [1]Feed_Pattern{{kind = .Exact, bytes = cast([32]u8)rm.id}}
		from := u64(r.feed_cursor) if r.feed_cursor >= 0 else 0
		client_feed_follow(&r.client, from, pat[:], true, true)
	}
	_remote_follow_send(r, rm)
	_remote_settle(r, rm)
}

@(private)
_kfollow_off :: proc(r: ^Replicator, rm: ^Remote) {
	rm.kfollow = false
	if rm.is_head {
		rm.kstream = {}
	}
	if _following(rm) {
		return
	}
	if r.phase == .Ready {
		if r.cfg.filtered {
			_feed_subscribe(r, false)
		} else {
			ids := [1]Stream_Id{rm.id}
			client_unfollow(&r.client, ids[:])
		}
	}
	_remote_maybe_free(r, rm)
}

@(private)
_keys_head_epoch :: proc(r: ^Replicator, head: ^Remote) -> (epoch: u64, ok: bool) {
	end := journal.replica_length(&head.rep)
	if end <= 0 {
		return 0, false
	}
	rd: journal.Reader
	journal.replica_reader(&head.rep, &rd, context.temp_allocator)
	defer journal.reader_close(&rd)
	if !head.plain {
		journal.reader_set_keys(&rd, static_provider(&head.skey))
	}
	body, _, err := journal.record_before(&rd, end)
	if err != .None || len(body) != 9 || body[0] != KEYS_HEAD_RECORD {
		return 0, false
	}
	return prim.get_u64le(body[1:]), true
}

@(private)
_is_keys_name :: proc(name: string) -> bool {
	return (len(name) >= len(KEYS_STREAM) && name[:len(KEYS_STREAM)] == KEYS_STREAM) || (len(name) >= len(KEYS_HEAD_STREAM) && name[:len(KEYS_HEAD_STREAM)] == KEYS_HEAD_STREAM)
}

@(private)
_remote_hold_retry :: proc(r: ^Replicator, rm: ^Remote) {
	rm.retry_hold = true
	if r.retry == 0 && r.loop != nil {
		r.retry = prim.timer(r.loop, RETRY_MS, r, _on_retry)
	}
}

@(private)
_remote_deny :: proc(r: ^Replicator, rm: ^Remote) {
	rm.denied = true
	rm.tail = 0
	if rm.is_head {
		_key_probe_answered(r, rm, 0, false)
	}
	for w in rm.wants {
		if !rm.is_head {
			_emit(r, Repl_Event{kind = .Present, device = rm.device, name = rm.name, epoch = rm.epoch, stream = rm.id, from = w.from, to = w.from, length = max(rm.relay_len, 0)})
		}
	}
	clear(&rm.wants)
}

replicator_catching_up :: proc(r: ^Replicator, scope: ^Scope, device: Device_Id, name: string, epoch: u64) -> bool {
	rm, ok := r.remotes[stream_id(scope, device, name, epoch)]
	if !ok || rm.relay_len <= 0 || rm.quarantined || rm.denied || (rm.tamper_hold && r.tamper_run >= TAMPER_REPORT) || r.phase != .Ready {
		return false
	}
	at: i64
	for h in journal.replica_have(&rm.rep) {
		if h.from > at {
			return true
		}
		at = max(at, h.to)
	}
	return at < rm.relay_len
}
