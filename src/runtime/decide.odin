package rt

import "../fs"
import "../observe"
import "../prim"

window_decide :: proc(r: ^Runtime, m: ^fs.Mount, w: ^observe.Write) -> (^fs.Scope, bool) {
	for run in r.runs {
		if !_run_has_mount(run, m) {
			continue
		}
		calls, idx := _open_calls(run)
		if w.exact {
			pid := prim.Pid(0)
			if run.proc_ != nil && run.proc_.child.pid > 0 {
				pid = run.proc_.child.pid
			}
			inside := pid > 0 && w.pid == pid
			for p in w.lineage {
				inside ||= pid > 0 && p == pid
			}
			if !inside {
				continue
			}
			k, ambiguous := observe.attribute(calls, w, pid)
			if s := _run_scope(run, m, idx[k] if k >= 0 && !ambiguous else -1); s != nil {
				return s, true
			}
			continue
		}
		if !w.window || len(calls) == 0 {
			continue
		}
		k, ambiguous := observe.attribute_window(calls, w)
		if k >= 0 && !ambiguous {
			if s := _run_scope(run, m, idx[k]); s != nil {
				r.stats.inexact += 1
				return s, true
			}
			continue
		}
		if ambiguous {
			if s := _run_scope(run, m, -1); s != nil {
				r.stats.inexact += 1
				return s, true
			}
		}
	}
	if w.exact {
		if s := observe.scope_of(m.reg if m != nil else nil, w.lineage); s != nil && s.mount == m {
			return s, true
		}
	}
	return nil, false
}
