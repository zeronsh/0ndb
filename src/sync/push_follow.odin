#+build linux, darwin, windows
package osync

import "../journal"

replicator_live_segments :: proc(r: ^Replicator, scope: ^Scope, name: string, epoch: u64, live: bool) {
	_enter(r)
	defer _leave(r)
	g, ok := r.groups[stream_suffix(scope, name, epoch)]
	if !ok || g.live == live {
		return
	}
	g.live = live
	for dev in g.members {
		if rm, rok := r.remotes[stream_id(&g.scope, dev, g.name, g.epoch)]; rok {
			rm.live = live
			_push_follow(r, rm)
		}
	}
	_repl_flush(r)
}

@(private)
_push_follow :: proc(r: ^Replicator, rm: ^Remote) {
	if r.phase != .Ready {
		return
	}
	want := rm.live && rm.follow && !rm.quarantined
	if want && !rm.pushed {
		e := [1]Follow_Entry{{rm.id, FOLLOW_END}}
		if client_follow(&r.client, e[:], false) == .None {
			rm.pushed = true
		}
	} else if !want && rm.pushed {
		ids := [1]Stream_Id{rm.id}
		client_unfollow(&r.client, ids[:])
		rm.pushed = false
	}
}

@(private)
_pushed_landed :: proc(r: ^Replicator, rm: ^Remote, length: i64) {
	s0 := r.stage_at
	_stage_flush(r, false, length)
	s1 := r.stage_at
	if s1 == s0 && len(r.stage) > 0 && (!_is_boundary(rm, s0) || len(r.stage) > STAGE_MAX) {
		r.stage_at += i64(len(r.stage))
		clear(&r.stage)
	}
	if s1 > s0 && _following(rm) && !rm.quarantined && journal.replica_covers(&rm.rep, s0, s1) {
		if !rm.full && rm.pulled >= s0 && rm.pulled < s1 {
			rm.pulled = s1
		}
		if s1 > rm.relay_len {
			r.ahead_n += 1
			r.ahead_id = rm.id
			r.ahead_to = s1
		}
		v, vlo, vhi := _verdict(r, rm, s0, s1)
		switch v {
		case .Accept:
			from := min(s0, vlo) if vhi > vlo else s0
			_emit(r, Repl_Event{kind = .Grew, device = rm.device, name = rm.name, epoch = rm.epoch, stream = rm.id, from = from, to = s1, length = rm.relay_len})
		case .Hold:
			if vhi > vlo {
				_emit(r, Repl_Event{kind = .Grew, device = rm.device, name = rm.name, epoch = rm.epoch, stream = rm.id, from = vlo, to = vhi, length = rm.relay_len})
			}
		case .Equivocation:
			_quarantine(r, rm, s0)
			return
		case .Tampered:
			_tamper_forget(r, rm, vlo, vhi)
		}
	}
	_remote_settle(r, rm)
}
