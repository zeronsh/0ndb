#+build linux
package keystore

import "core:sys/linux"

@(private)
_PREFERENCE :: [?]Kind{.Tpm, .File}

@(private = "file")
TPM_DEVICE :: cstring("/dev/tpmrm0")

@(private)
_available :: proc(kind: Kind, opts: Options, probe: bool) -> Error {
	if kind != .Tpm {
		return .Unavailable
	}
	if opts.user_presence {
		return .Unavailable
	}
	fd := _tpm_open() or_return
	defer linux.close(fd)
	if probe {
		return _tpm_probe(_tpm_call(&fd))
	}
	return .None
}

@(private)
_bind :: proc(ks: ^Keystore) {
	ks.seal = _linux_tpm_seal
	ks.unseal = _linux_tpm_unseal
	ks.forget = _nothing_to_forget
}

@(private = "file")
_tpm_open :: proc() -> (linux.Fd, Error) {
	fd, errno := linux.open(TPM_DEVICE, {.RDWR, .CLOEXEC})
	#partial switch errno {
	case .NONE:
		return fd, .None
	case .ENOENT, .ENXIO, .ENODEV:
		return -1, .Unavailable
	case .EACCES, .EPERM:
		return -1, .Denied
	case .ENOMEM:
		return -1, .No_Memory
	}
	return -1, .Io
}

@(private = "file")
_tpm_call :: proc(fd: ^linux.Fd) -> Tpm_Call {
	return Tpm_Call{data = fd, call = _tpm_transact}
}

@(private = "file")
_tpm_transact :: proc(data: rawptr, cmd: []u8, resp: []u8) -> (int, Error) {
	fd := (^linux.Fd)(data)^
	for {
		n, errno := linux.write(fd, cmd)
		if errno == .EINTR {
			continue
		}
		if errno != .NONE || n != len(cmd) {
			return 0, .Io
		}
		break
	}
	for {
		n, errno := linux.read(fd, resp)
		if errno == .EINTR {
			continue
		}
		if errno != .NONE || n < 10 {
			return 0, .Io
		}
		return n, .None
	}
}

@(private = "file")
_linux_tpm_seal :: proc(data: rawptr, label: string, inner: []u8, out: ^[dynamic]u8) -> Error {
	fd := _tpm_open() or_return
	defer linux.close(fd)
	return _tpm_seal(_tpm_call(&fd), inner, out)
}

@(private = "file")
_linux_tpm_unseal :: proc(data: rawptr, payload: []u8, out: []u8) -> (n: int, err: Error) {
	fd := _tpm_open() or_return
	defer linux.close(fd)
	return _tpm_unseal(_tpm_call(&fd), payload, out)
}
