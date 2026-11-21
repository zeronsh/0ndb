package search

import "core:bytes"
import "core:unicode"
import "core:unicode/utf8"

NS_TRI :: u8(1)
NS_WORD :: u8(2)
NS_FTRI :: u8(3)
NS_OBJECT :: u8(4)
NS_FROM :: u8(5)
NS_FIELD :: u8(6)
NS_TITLE :: u8(7)
NS_KIND :: u8(8)
NS_SLOT :: u8(9)
NS_VTRI :: u8(11)
VOCAB_CAP :: 512
VOCAB_SCAN :: 2048

MAX_KEY :: 255
MAX_WORD :: 64

fold :: #force_inline proc "contextless" (c: u8) -> u8 {
	return c | (u8(c - 'A' < 26) << 5)
}

is_word :: #force_inline proc "contextless" (c: u8) -> bool {
	l := c | 0x20
	return (l >= 'a' && l <= 'z') || (c >= '0' && c <= '9') || c == '_' || c >= 0x80
}

fold_into :: proc(dst: []u8, src: []u8) #no_bounds_check {
	n := min(len(dst), len(src))
	i := 0
	for i < n {
		c := src[i]
		if c < 0x80 {
			dst[i] = fold(c)
			i += 1
			continue
		}
		r, size := utf8.decode_rune(src[i:n])
		if r == utf8.RUNE_ERROR || size <= 1 {
			dst[i] = c
			i += 1
			continue
		}
		l := unicode.to_lower(r)
		if l != r {
			enc, ln := utf8.encode_rune(l)
			if ln == size {
				for k in 0 ..< size {
					dst[i + k] = enc[k]
				}
				i += size
				continue
			}
		}
		for k in 0 ..< size {
			dst[i + k] = src[i + k]
		}
		i += size
	}
}

key64 :: #force_inline proc "contextless" (ns: u8, payload: u64) -> u64 {
	return u64(ns) << 56 | payload
}

tri_key :: #force_inline proc "contextless" (a, b, c: u8) -> u64 {
	return u64(NS_TRI) << 56 | u64(a) << 16 | u64(b) << 8 | u64(c)
}

key64_bytes :: proc "contextless" (k: u64, out: ^[8]u8) -> int {
	ns := u8(k >> 56)
	n := 4
	switch ns {
	case NS_KIND, NS_TITLE:
		n = 2
	}
	out[0] = ns
	for i in 1 ..< n {
		out[i] = u8(k >> u64(8 * (n - 1 - i)))
	}
	return n
}

word_key :: proc(w: []u8, out: ^[MAX_KEY]u8) -> int {
	out[0] = NS_WORD
	return 1 + copy(out[1:], w)
}

VAL_NONE :: u8(0)
VAL_IMPACT :: u8(1)

val_kind :: #force_inline proc "contextless" (ns: u8) -> u8 {
	switch ns {
	case NS_WORD:
		return VAL_IMPACT
	}
	return VAL_NONE
}

Word_Iter :: struct {
	t: []u8,
	i: int,
}

word_next :: proc "contextless" (w: ^Word_Iter) -> (start, end: int, ok: bool) {
	n := len(w.t)
	for w.i < n {
		for w.i < n && !is_word(w.t[w.i]) {
			w.i += 1
		}
		s := w.i
		for w.i < n && is_word(w.t[w.i]) {
			w.i += 1
		}
		if w.i > s {
			return s, w.i, true
		}
	}
	return 0, 0, false
}

Occurrences :: struct {
	count:  int,
	words:  int,
	first:  int,
	weight: f64,
}

find_all :: proc(hay: []u8, needle: []u8, word_only: bool) -> (o: Occurrences) {
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
	if len(needle) == 0 {
		return true
	}
	if len(needle) > len(hay) {
		return false
	}
	buf: [MAX_PATH]u8
	h := hay
	if len(h) > len(buf) {
		h = h[:len(buf)]
	}
	fold_into(buf[:len(h)], h)
	return bytes.index(buf[:len(h)], needle) >= 0
}
