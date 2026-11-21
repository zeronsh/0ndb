package index

import "base:runtime"
import "core:slice"
import "../prim"
import "../thread"

MERGED_VERSION :: 1

Merged_Field :: struct {
	tag:    u8,
	hlc:    prim.Hlc,
	device: prim.Id,
	value:  []u8,
}

Session :: struct {
	id:       prim.Id,
	title:    string,
	worktree: prim.Id,
	provider: string,
	model:    string,
	host:     prim.Id,
	created:  u64,
	activity: u64,
	archived: bool,
	pinned:   bool,
	leaf:     i64,
	length:   i64,
	status:   thread.Status,
	queued:   u32,
	pending:  u32,
	usage:    thread.Usage,
}

Worktree :: struct {
	id:           prim.Id,
	path:         string,
	host:         prim.Id,
	repository:   string,
	branch:       string,
	source:       prim.Id,
	fork_version: []u8,
	archived:     bool,
}

field_wins :: proc "contextless" (a_hlc: prim.Hlc, a_dev: prim.Id, a_val: []u8, b_hlc: prim.Hlc, b_dev: prim.Id, b_val: []u8) -> bool {
	if a_hlc != b_hlc {
		return a_hlc > b_hlc
	}
	ad, bd := a_dev, b_dev
	for i in 0 ..< 16 {
		if ad[i] != bd[i] {
			return ad[i] > bd[i]
		}
	}
	n := min(len(a_val), len(b_val))
	for i in 0 ..< n {
		if a_val[i] != b_val[i] {
			return a_val[i] > b_val[i]
		}
	}
	return len(a_val) > len(b_val)
}

decode_merged :: proc(data: []u8, allocator := context.temp_allocator) -> (out: []Merged_Field, err: Error) {
	if len(data) == 0 {
		return nil, .None
	}
	r := prim.reader(data)
	if prim.read_u8(&r) != MERGED_VERSION {
		return nil, .Corrupt
	}
	nd := prim.read_uvarint(&r)
	if r.err != .None || nd > MAX_FIELDS || nd * 16 > u64(prim.reader_remaining(&r)) {
		return nil, .Corrupt
	}
	devs: [MAX_FIELDS]prim.Id
	for i in 0 ..< int(nd) {
		devs[i] = prim.read_id(&r)
	}
	nf := prim.read_uvarint(&r)
	if r.err != .None || nf > 256 || nf > u64(prim.reader_remaining(&r) / 11) {
		return nil, .Corrupt
	}
	fields, aerr := make([]Merged_Field, int(nf), allocator)
	if aerr != nil {
		return nil, .No_Memory
	}
	for &f in fields {
		f.tag = prim.read_u8(&r)
		f.hlc = prim.Hlc(prim.read_u64le(&r))
		d := prim.read_uvarint(&r)
		f.value = prim.read_bytes(&r)
		if d >= nd {
			return nil, .Corrupt
		}
		f.device = devs[d]
	}
	if r.err != .None {
		return nil, .Corrupt
	}
	return fields, .None
}

encode_merged :: proc(buf: ^[dynamic]u8, fields: []Merged_Field) -> Error {
	devs: [256]prim.Id
	nd := 0
	idx := make([]u8, len(fields), context.temp_allocator)
	for f, i in fields {
		k := -1
		for d in 0 ..< nd {
			if devs[d] == f.device {
				k = d
				break
			}
		}
		if k < 0 {
			if nd == len(devs) {
				return .Limit
			}
			devs[nd] = f.device
			k = nd
			nd += 1
		}
		idx[i] = u8(k)
	}
	w := prim.writer(buf)
	prim.write_u8(&w, MERGED_VERSION)
	prim.write_uvarint(&w, u64(nd))
	for d in 0 ..< nd {
		prim.write_id(&w, devs[d])
	}
	prim.write_uvarint(&w, u64(len(fields)))
	for f, i in fields {
		prim.write_u8(&w, f.tag)
		prim.write_u64le(&w, u64(f.hlc))
		prim.write_uvarint(&w, u64(idx[i]))
		prim.write_bytes(&w, f.value)
	}
	if w.err != .None {
		return .No_Memory
	}
	return .None
}

merge :: proc(old: []u8, device: prim.Id, incoming: []Field, allocator := context.temp_allocator) -> (out: []u8, changed: bool, err: Error) {
	cur := decode_merged(old, context.temp_allocator) or_return
	list := make([dynamic]Merged_Field, 0, len(cur) + len(incoming), context.temp_allocator)
	append(&list, ..cur)
	for f in incoming {
		k := -1
		for e, i in list {
			if e.tag == f.tag {
				k = i
				break
			}
		}
		if k < 0 {
			append(&list, Merged_Field{f.tag, f.hlc, device, f.value})
			changed = true
			continue
		}
		e := list[k]
		if field_wins(f.hlc, device, f.value, e.hlc, e.device, e.value) {
			list[k] = Merged_Field{f.tag, f.hlc, device, f.value}
			changed = true
		}
	}
	if !changed {
		return old, false, .None
	}
	if len(list) > MAX_FIELDS {
		return nil, false, .Limit
	}
	slice.sort_by(list[:], proc(a, b: Merged_Field) -> bool {
		return a.tag < b.tag
	})
	buf := make([dynamic]u8, allocator)
	encode_merged(&buf, list[:]) or_return
	return buf[:], true, .None
}

merged_get :: proc(fields: []Merged_Field, tag: u8) -> ([]u8, bool) {
	for f in fields {
		if f.tag == tag {
			return f.value, true
		}
	}
	return nil, false
}

session_from :: proc(id: prim.Id, data: []u8, allocator := context.allocator) -> (s: Session, err: Error) {
	fields := decode_merged(data, context.temp_allocator) or_return
	s.id = id
	for f in fields {
		v := f.value
		#partial switch Thread_Tag(f.tag) {
		case .Title:
			s.title = _clone_str(string(v), allocator) or_return
		case .Worktree:
			s.worktree, _ = value_id(v)
		case .Provider:
			s.provider = _clone_str(string(v), allocator) or_return
		case .Model:
			s.model = _clone_str(string(v), allocator) or_return
		case .Host:
			s.host, _ = value_id(v)
		case .Created:
			s.created, _ = value_u64(v)
		case .Activity:
			s.activity, _ = value_u64(v)
		case .Archived:
			s.archived, _ = value_bool(v)
		case .Pinned:
			s.pinned, _ = value_bool(v)
		case .Leaf:
			x, _ := value_u64(v)
			s.leaf = i64(min(x, u64(max(i64))))
		case .Length:
			x, _ := value_u64(v)
			s.length = i64(min(x, u64(max(i64))))
		case .Status:
			if st, ok := value_status(v); ok {
				s.status = st.status
				s.queued = st.queued
			}
		case .Pending:
			x, _ := value_u64(v)
			s.pending = u32(min(x, u64(max(u32))))
		case .Usage:
			s.usage, _ = value_usage(v)
		}
	}
	return s, .None
}

worktree_from :: proc(id: prim.Id, data: []u8, allocator := context.allocator) -> (w: Worktree, err: Error) {
	fields := decode_merged(data, context.temp_allocator) or_return
	w.id = id
	for f in fields {
		v := f.value
		#partial switch Worktree_Tag(f.tag) {
		case .Path:
			w.path = _clone_str(string(v), allocator) or_return
		case .Host:
			w.host, _ = value_id(v)
		case .Repository:
			w.repository = _clone_str(string(v), allocator) or_return
		case .Branch:
			w.branch = _clone_str(string(v), allocator) or_return
		case .Source:
			w.source, _ = value_id(v)
		case .Fork_Version:
			b := _clone_str(string(v), allocator) or_return
			w.fork_version = transmute([]u8)b
		case .Archived:
			w.archived, _ = value_bool(v)
		}
	}
	return w, .None
}

@(private)
_clone_str :: proc(s: string, allocator: runtime.Allocator) -> (string, Error) {
	if len(s) == 0 {
		return "", .None
	}
	b, err := make([]u8, len(s), allocator)
	if err != nil {
		return "", .No_Memory
	}
	copy(b, s)
	return string(b), .None
}
