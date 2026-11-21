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
	for c.pos < req.to {
		_, _, ok := journal.next(&c)
		if ok {
			continue
		}
		#partial switch c.err {
		case .None:
			return .Accept
		case .Equivocation, .Forged:
			return .Equivocation
		case:
			return .Hold
		}
	}
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
