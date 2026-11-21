package crdt

import "../prim"

Lv :: int

Op_Id :: struct {
	actor: prim.Id,
	seq:   u64,
}

Error :: enum u8 {
	None,
	Missing,
	Mismatch,
	Invalid,
	Missing_Ops,
	Unknown,
	Not_Ancestor,
	Corrupt,
	Too_Large,
	Missing_Content,
}

Op_Kind :: enum u8 {
	Insert,
	Delete,
	Delete_Back,
	Opaque,
	Insert_Ref,
}

Oid :: [20]u8

Content_Ref :: struct {
	oid:    Oid,
	offset: int,
}

Content_Source :: struct {
	data: rawptr,
	read: proc(data: rawptr, oid: Oid, offset: int, dst: []u8) -> bool,
}

Op_Run :: struct {
	target:  Op_Id,
	kind:    Op_Kind,
	pos:     int,
	len:     int,
	content: []u8,
	ref:     Content_Ref,
}

Batch :: struct {
	actor:   prim.Id,
	seq:     u64,
	lamport: u64,
	parents: []Op_Id,
	ops:     []Op_Run,
}

Lv_Span :: struct {
	lv:  Lv,
	len: int,
}

Op_Span :: struct {
	id:  Op_Id,
	len: int,
}

Author_Span :: struct {
	id:       Op_Id,
	len:      int,
	redacted: bool,
}

Seq_Range :: struct {
	seq: u64,
	len: int,
}

Bias :: enum u8 {
	Before,
	After,
}

Anchor :: struct {
	id:     Op_Id,
	offset: int,
	bias:   Bias,
}

Conflict :: struct {
	start:  int,
	end:    int,
	ours:   []Op_Span,
	theirs: []Op_Span,
}

MAX_COUNTER :: u64(1) << 62
MAX_LV :: 1 << 52
MAX_RUN :: 1 << 40

is_insert :: #force_inline proc "contextless" (k: Op_Kind) -> bool {
	return k == .Insert || k == .Insert_Ref
}

batch_len :: proc "contextless" (b: ^Batch) -> int {
	n := 0
	for &op in b.ops {
		n += op.len
	}
	return n
}

batch_destroy :: proc(b: ^Batch, allocator := context.allocator) {
	delete(b.parents, allocator)
	delete(b.ops, allocator)
	b^ = {}
}

op_id_less :: proc(a, b: Op_Id) -> bool {
	for i in 0 ..< 16 {
		if a.actor[i] != b.actor[i] {
			return a.actor[i] < b.actor[i]
		}
	}
	return a.seq < b.seq
}

id_less :: proc "contextless" (a, b: prim.Id) -> bool {
	for i in 0 ..< 16 {
		if a[i] != b[i] {
			return a[i] < b[i]
		}
	}
	return false
}
