package prim

import "base:runtime"

sorted_keys :: proc(m: $M/map[$K]$V, allocator := context.temp_allocator, loc := #caller_location) -> []K {
	keys, err := try_sorted_keys(m, allocator)
	if err != nil {
		panic("sorted_keys: out of memory", loc)
	}
	return keys
}

try_sorted_keys :: proc(m: $M/map[$K]$V, allocator := context.temp_allocator) -> (keys: []K, err: runtime.Allocator_Error) {
	keys = make([]K, len(m), allocator) or_return
	if len(m) > 0 && raw_data(keys) == nil {
		return nil, .Out_Of_Memory
	}
	i := 0
	for k in m {
		keys[i] = k
		i += 1
	}
	_keys_heapsort(keys)
	return keys, nil
}

unordered :: #force_inline proc "contextless" (m: $M/map[$K]$V) -> M {
	return m
}

@(private)
_key_less :: #force_inline proc "contextless" (a, b: $K) -> bool {
	when K == string {
		return a < b
	} else {
		x := transmute([size_of(K)]u8)a
		y := transmute([size_of(K)]u8)b
		for i in 0 ..< size_of(K) {
			if x[i] != y[i] {
				return x[i] < y[i]
			}
		}
		return false
	}
}

@(private)
_keys_heapsort :: proc "contextless" (keys: []$K) {
	n := len(keys)
	sift :: proc "contextless" (keys: []$K, start, end: int) {
		root := start
		for {
			child := 2 * root + 1
			if child >= end {
				return
			}
			if child + 1 < end && _key_less(keys[child], keys[child + 1]) {
				child += 1
			}
			if !_key_less(keys[root], keys[child]) {
				return
			}
			keys[root], keys[child] = keys[child], keys[root]
			root = child
		}
	}
	for start := n / 2 - 1; start >= 0; start -= 1 {
		sift(keys, start, n)
	}
	for end := n - 1; end > 0; end -= 1 {
		keys[0], keys[end] = keys[end], keys[0]
		sift(keys, 0, end)
	}
}
