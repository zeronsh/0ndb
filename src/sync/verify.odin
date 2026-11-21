package osync

import "../journal"

Chain_Verifier :: struct {
	data:     rawptr,
	identity: proc(data: rawptr, device: Device_Id) -> (Identity, bool),
	seed:     proc(data: rawptr, stream: Stream_Id) -> journal.Hash,
	keys:     proc(data: rawptr, stream: Stream_Id) -> journal.Key_Provider,
	keyring:  Keyring,
}

@(private)
_Sig_Check :: struct {
	cv:     ^Chain_Verifier,
	signer: Identity,
}

chain_seed :: proc "contextless" (id: Stream_Id) -> (h: journal.Hash) {
	v := id
	copy(h[:], v[:])
	return
}

keyring_signer :: proc(kr: ^Keyring) -> journal.Signer {
	return journal.Signer{data = kr, sign = _keyring_sign}
}

@(private)
_keyring_sign :: proc(data: rawptr, msg: []u8, sig: ^[dynamic]u8) -> bool {
	kr := cast(^Keyring)data
	s: [64]u8
	if kr.sign(kr.data, msg, &s) != .None {
		return false
	}
	_, err := append(sig, ..s[:])
	return err == nil
}

chain_verify :: proc(cv: ^Chain_Verifier, req: ^Verify_Request) -> Verdict {
	signer, known := cv.identity(cv.data, req.device)
	if !known {
		return .Hold
	}
	check := _Sig_Check{cv, signer}
	chain := journal.Chain {
		seed = cv.seed(cv.data, req.stream),
		verifier = journal.Verifier{data = &check, verify = _sig_check},
	}
	if cv.keys != nil {
		chain.keys = cv.keys(cv.data, req.stream)
	}
	rd: journal.Reader
	journal.replica_reader(req.replica, &rd, context.temp_allocator)
	defer journal.reader_close(&rd)
	if chain.keys.key != nil {
		journal.reader_set_keys(&rd, chain.keys)
	}
	journal.reader_set_chain(&rd, &chain)
	c := journal.cursor(&rd, req.from)
	last: journal.Sig_Info
	have_last := false
	for c.pos < req.to {
		_, _, ok := journal.next(&c)
		if span, sok := journal.reader_span(&rd); sok && (!have_last || span.off != last.off) {
			if v := _span_cross(req, span); v != .Accept {
				return v
			}
			last = span
			have_last = true
		}
		if ok {
			continue
		}
		#partial switch c.err {
		case .None:
			return .Accept
		case .Missing:
			if c.pos >= req.to {
				return .Accept
			}
			req.done = c.pos
			return .Hold
		case .Equivocation, .Forged, .Corrupt:
			return .Equivocation
		case:
			req.done = c.pos
			return .Hold
		}
	}
	return .Accept
}

@(private)
_span_cross :: proc(req: ^Verify_Request, span: journal.Sig_Info) -> Verdict {
	if req.span == nil || req.span_ok == nil {
		return .Accept
	}
	if req.span_ok^ {
		prev := req.span^
		if span.off == prev.off && span.head != prev.head {
			return .Equivocation
		}
		if span.off != prev.off && span.range_start < prev.end && span.end > prev.range_start {
			return .Equivocation
		}
		if span.range_start == prev.end && span.prev_head != prev.head {
			return .Equivocation
		}
		if prev.range_start == span.end && prev.prev_head != span.head {
			return .Equivocation
		}
		if span.end <= prev.end {
			return .Accept
		}
	}
	req.span^ = span
	req.span_ok^ = true
	return .Accept
}

@(private)
_sig_check :: proc(data: rawptr, msg: []u8, sig: []u8) -> bool {
	s := cast(^_Sig_Check)data
	kr := s.cv.keyring
	if kr.verify != nil {
		return kr.verify(kr.data, &s.signer, msg, sig)
	}
	return signature_verify(s.signer.sign, msg, sig)
}
