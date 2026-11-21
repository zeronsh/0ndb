package prim

Error :: enum u8 {
	None,
	Not_Found,
	Exists,
	Permission,
	Would_Block,
	Interrupted,
	Broken_Pipe,
	Busy,
	Invalid,
	Not_Dir,
	Is_Dir,
	Not_Empty,
	No_Space,
	Too_Many_Files,
	Name_Too_Long,
	Too_Large,
	Unsupported,
	No_Memory,
	No_Child,
	Io,
}

Fd :: distinct i32
Pid :: distinct i32

INVALID_FD :: Fd(-1)

PATH_MAX :: 4096
