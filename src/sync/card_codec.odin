package osync

CARD_RECORD :: u8(1)

card_record :: proc "contextless" (card: []u8) -> (out: [1 + CARD_LEN]u8) {
	out[0] = CARD_RECORD
	copy(out[1:], card)
	return
}

card_record_body :: proc "contextless" (body: []u8) -> []u8 {
	if len(body) == 1 + CARD_LEN && body[0] == CARD_RECORD {
		return body[1:]
	}
	return body
}
