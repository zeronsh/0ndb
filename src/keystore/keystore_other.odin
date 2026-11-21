#+build !linux
#+build !darwin
#+build !windows
package keystore

@(private)
_PREFERENCE :: [?]Kind{.File}

@(private)
_available :: proc(kind: Kind, opts: Options, probe: bool) -> Error {
	return .Unavailable
}

@(private)
_bind :: proc(ks: ^Keystore) {
}
