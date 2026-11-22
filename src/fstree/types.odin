package fstree

import "base:runtime"
import "../prim"

Op_Id :: struct {
	actor: u32,
	seq:   u64,
}

Inode_Id :: Op_Id

ROOT :: Inode_Id {
	actor = max(u32),
	seq   = max(u64),
}

Event :: struct {
	lamport: u64,
	seq:     u64,
	actor:   u32,
}

Kind :: enum u8 {
	File,
	Dir,
	Symlink,
}

Flag :: enum u8 {
	Exec,
	Crlf,
	Opaque,
	Git_Clean,
}

Flags :: bit_set[Flag;u8]

ALL_FLAGS :: Flags{.Exec, .Crlf, .Opaque, .Git_Clean}

Op_Create :: struct {
	parent: Inode_Id,
	name:   string,
	kind:   Kind,
	flags:  Flags,
	target: string,
}

Op_Move :: struct {
	inode:  Inode_Id,
	parent: Inode_Id,
	name:   string,
}

Op_Remove :: struct {
	inode: Inode_Id,
}

Op_Restore :: struct {
	inode: Inode_Id,
}

Op_Set_Flags :: struct {
	inode: Inode_Id,
	mask:  Flags,
	value: Flags,
}

Op_Set_Target :: struct {
	inode:  Inode_Id,
	target: string,
}

Op :: union {
	Op_Create,
	Op_Move,
	Op_Remove,
	Op_Restore,
	Op_Set_Flags,
	Op_Set_Target,
}

Tree_Error :: enum u8 {
	None,
	Unknown_Inode,
	Not_Dir,
	Wrong_Kind,
	Invalid_Name,
	Root,
	Not_Causal,
	Reserved_Actor,
	Corrupt,
	Unavailable,
}

Error :: union #shared_nil {
	Tree_Error,
	runtime.Allocator_Error,
}

Move_Ref :: struct {
	event: Event,
	inode: Inode_Id,
}

Node_Key :: struct {
	dir:  Inode_Id,
	node: u64,
}

Node_State :: struct {
	key:     Node_Key,
	deleted: bool,
}

Source :: struct {
	data:       rawptr,
	actor:      proc(data: rawptr, actor: u32) -> prim.Id,
	load_inode: proc(data: rawptr, id: Inode_Id) -> (record: []u8, found: bool),
	load_node:  proc(data: rawptr, key: Node_Key) -> (record: []u8, found: bool),
	load_moves: proc(data: rawptr, from_lamport: u64, out: ^[dynamic]Move_Ref) -> bool,
}

View :: struct {
	data:    rawptr,
	visible: proc(data: rawptr, id: Op_Id) -> bool,
	floor:   u64,
}

event_id :: proc "contextless" (e: Event) -> Op_Id {
	return Op_Id{actor = e.actor, seq = e.seq}
}

op_inode :: proc "contextless" (id: Op_Id, op: Op) -> Inode_Id {
	switch o in op {
	case Op_Create:
		return id
	case Op_Move:
		return o.inode
	case Op_Remove:
		return o.inode
	case Op_Restore:
		return o.inode
	case Op_Set_Flags:
		return o.inode
	case Op_Set_Target:
		return o.inode
	}
	return ROOT
}

op_is_move :: proc "contextless" (op: Op) -> bool {
	_, ok := op.(Op_Move)
	return ok
}

MAX_NAME :: 4096

valid_name :: proc "contextless" (name: string) -> bool {
	if len(name) == 0 || len(name) > MAX_NAME || name == "." || name == ".." {
		return false
	}
	for i in 0 ..< len(name) {
		if name[i] == '/' || name[i] == 0 {
			return false
		}
	}
	return true
}
