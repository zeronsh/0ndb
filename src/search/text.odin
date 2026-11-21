package search

import "core:bytes"

NS_TRI :: u8(1)
NS_WORD :: u8(2)
NS_FTRI :: u8(3)
NS_OBJECT :: u8(4)
NS_FROM :: u8(5)
NS_FIELD :: u8(6)
NS_TITLE :: u8(7)
NS_KIND :: u8(8)
NS_SLOT :: u8(9)

MAX_KEY :: 255

fold :: #force_inline proc "contextless" (c: u8) -> u8 {
	return c | (u8(c - 'A' < 26) << 5)
}

is_word :: #force_inline proc "contextless" (c: u8) -> bool {
	l := c | 0x20
	return (l >= 'a' && l <= 'z') || (c >= '0' && c <= '9') || c == '_' || c >= 0x80
}

fold_into :: proc(dst: []u8, src: []u8) {
	for i in 0 ..< len(src) {
		dst[i] = fold(src[i])
	}
}

key32 :: #force_inline proc "contextless" (ns: u8, a, b, c: u8) -> u32 {
	return u32(ns) << 24 | u32(a) << 16 | u32(b) << 8 | u32(c)
}

key32_bytes :: proc "contextless" (k: u32, out: ^[4]u8) -> int {
	out[0] = u8(k >> 24)
	out[1] = u8(k >> 16)
	out[2] = u8(k >> 8)
	out[3] = u8(k)
	if out[0] == NS_WORD {
		n := 4
		for n > 1 && out[n - 1] == 0 {
			n -= 1
		}
		return n
	}
	if out[0] == NS_KIND || out[0] == NS_TITLE {
		return 2
	}
	return 4
}

word_key :: proc "contextless" (w: []u8) -> u32 {
	a := fold(w[0])
	b := fold(w[1]) if len(w) > 1 else 0
	return key32(NS_WORD, a, b, 0)
}

Occurrences :: struct {
	count:  int,
	words:  int,
	first:  int,
	weight: f64,
}

find_all :: proc(hay: []u8, needle: []u8, word_only: bool, raw: []u8 = nil) -> (o: Occurrences) {
	o.first = -1
	m := len(needle)
	if m == 0 || m > len(hay) {
		return
	}
	pos := 0
	for pos + m <= len(hay) {
		k := bytes.index(hay[pos:], needle)
		if k < 0 {
			break
		}
		at := pos + k
		left := at == 0 || !is_word(hay[at - 1]) || !is_word(needle[0])
		right := at + m == len(hay) || !is_word(hay[at + m]) || !is_word(needle[m - 1])
		whole := left && right
		if whole || !word_only {
			if o.first < 0 {
				o.first = at
			}
			o.count += 1
			if whole {
				o.words += 1
				o.weight += 1
			} else {
				o.weight += 0.5
			}
			pos = at + m
		} else {
			pos = at + 1
		}
	}
	return
}

contains_fold :: proc(hay: []u8, needle: []u8) -> bool {
	m := len(needle)
	if m == 0 {
		return true
	}
	if m > len(hay) {
		return false
	}
	first := needle[0]
	for i in 0 ..= len(hay) - m {
		if fold(hay[i]) != first {
			continue
		}
		ok := true
		for j in 1 ..< m {
			if fold(hay[i + j]) != needle[j] {
				ok = false
				break
			}
		}
		if ok {
			return true
		}
	}
	return false
}
