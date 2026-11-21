#+build amd64
package odb

import "base:intrinsics"
import "core:simd/x86"
import "core:sys/info"

@(private)
sha1_hw_supported :: proc "contextless" () -> bool {
	required :: info.CPU_Features{.sse2, .ssse3, .sse41, .sha}
	return info.cpu_features() >= required
}

@(private, enable_target_feature = "sse2,ssse3,sse4.1,sha")
sha1_hw_blocks :: proc "contextless" (state: ^[5]u32, data: []u8) #no_bounds_check {
	MASK :: x86.__m128i{0x08090a0b0c0d0e0f, 0x0001020304050607}

	abcd := intrinsics.unaligned_load((^x86.__m128i)(&state[0]))
	abcd = x86._mm_shuffle_epi32(abcd, 0x1b)
	e0 := x86._mm_set_epi32(i32(state[4]), 0, 0, 0)
	e1: x86.__m128i

	data := data
	for len(data) >= 64 {
		abcd_save := abcd
		e0_save := e0

		m0 := x86._mm_shuffle_epi8(intrinsics.unaligned_load((^x86.__m128i)(raw_data(data))), MASK)
		m1 := x86._mm_shuffle_epi8(intrinsics.unaligned_load((^x86.__m128i)(raw_data(data[16:]))), MASK)
		m2 := x86._mm_shuffle_epi8(intrinsics.unaligned_load((^x86.__m128i)(raw_data(data[32:]))), MASK)
		m3 := x86._mm_shuffle_epi8(intrinsics.unaligned_load((^x86.__m128i)(raw_data(data[48:]))), MASK)

		e0 = x86._mm_add_epi32(e0, m0)
		e1 = abcd
		abcd = x86._mm_sha1rnds4_epu32(abcd, e0, 0)
		e1 = x86._mm_sha1nexte_epu32(e1, m1)
		e0 = abcd
		abcd = x86._mm_sha1rnds4_epu32(abcd, e1, 0)
		m0 = x86._mm_sha1msg1_epu32(m0, m1)
		e0 = x86._mm_sha1nexte_epu32(e0, m2)
		e1 = abcd
		abcd = x86._mm_sha1rnds4_epu32(abcd, e0, 0)
		m1 = x86._mm_sha1msg1_epu32(m1, m2)
		m0 = x86._mm_xor_si128(m0, m2)
		e1 = x86._mm_sha1nexte_epu32(e1, m3)
		e0 = abcd
		abcd = x86._mm_sha1rnds4_epu32(abcd, e1, 0)
		m2 = x86._mm_sha1msg1_epu32(m2, m3)
		m1 = x86._mm_xor_si128(m1, m3)
		m0 = x86._mm_sha1msg2_epu32(m0, m3)
		e0 = x86._mm_sha1nexte_epu32(e0, m0)
		e1 = abcd
		abcd = x86._mm_sha1rnds4_epu32(abcd, e0, 0)
		m3 = x86._mm_sha1msg1_epu32(m3, m0)
		m2 = x86._mm_xor_si128(m2, m0)
		m1 = x86._mm_sha1msg2_epu32(m1, m0)
		e1 = x86._mm_sha1nexte_epu32(e1, m1)
		e0 = abcd
		abcd = x86._mm_sha1rnds4_epu32(abcd, e1, 1)
		m0 = x86._mm_sha1msg1_epu32(m0, m1)
		m3 = x86._mm_xor_si128(m3, m1)
		m2 = x86._mm_sha1msg2_epu32(m2, m1)
		e0 = x86._mm_sha1nexte_epu32(e0, m2)
		e1 = abcd
		abcd = x86._mm_sha1rnds4_epu32(abcd, e0, 1)
		m1 = x86._mm_sha1msg1_epu32(m1, m2)
		m0 = x86._mm_xor_si128(m0, m2)
		m3 = x86._mm_sha1msg2_epu32(m3, m2)
		e1 = x86._mm_sha1nexte_epu32(e1, m3)
		e0 = abcd
		abcd = x86._mm_sha1rnds4_epu32(abcd, e1, 1)
		m2 = x86._mm_sha1msg1_epu32(m2, m3)
		m1 = x86._mm_xor_si128(m1, m3)
		m0 = x86._mm_sha1msg2_epu32(m0, m3)
		e0 = x86._mm_sha1nexte_epu32(e0, m0)
		e1 = abcd
		abcd = x86._mm_sha1rnds4_epu32(abcd, e0, 1)
		m3 = x86._mm_sha1msg1_epu32(m3, m0)
		m2 = x86._mm_xor_si128(m2, m0)
		m1 = x86._mm_sha1msg2_epu32(m1, m0)
		e1 = x86._mm_sha1nexte_epu32(e1, m1)
		e0 = abcd
		abcd = x86._mm_sha1rnds4_epu32(abcd, e1, 1)
		m0 = x86._mm_sha1msg1_epu32(m0, m1)
		m3 = x86._mm_xor_si128(m3, m1)
		m2 = x86._mm_sha1msg2_epu32(m2, m1)
		e0 = x86._mm_sha1nexte_epu32(e0, m2)
		e1 = abcd
		abcd = x86._mm_sha1rnds4_epu32(abcd, e0, 2)
		m1 = x86._mm_sha1msg1_epu32(m1, m2)
		m0 = x86._mm_xor_si128(m0, m2)
		m3 = x86._mm_sha1msg2_epu32(m3, m2)
		e1 = x86._mm_sha1nexte_epu32(e1, m3)
		e0 = abcd
		abcd = x86._mm_sha1rnds4_epu32(abcd, e1, 2)
		m2 = x86._mm_sha1msg1_epu32(m2, m3)
		m1 = x86._mm_xor_si128(m1, m3)
		m0 = x86._mm_sha1msg2_epu32(m0, m3)
		e0 = x86._mm_sha1nexte_epu32(e0, m0)
		e1 = abcd
		abcd = x86._mm_sha1rnds4_epu32(abcd, e0, 2)
		m3 = x86._mm_sha1msg1_epu32(m3, m0)
		m2 = x86._mm_xor_si128(m2, m0)
		m1 = x86._mm_sha1msg2_epu32(m1, m0)
		e1 = x86._mm_sha1nexte_epu32(e1, m1)
		e0 = abcd
		abcd = x86._mm_sha1rnds4_epu32(abcd, e1, 2)
		m0 = x86._mm_sha1msg1_epu32(m0, m1)
		m3 = x86._mm_xor_si128(m3, m1)
		m2 = x86._mm_sha1msg2_epu32(m2, m1)
		e0 = x86._mm_sha1nexte_epu32(e0, m2)
		e1 = abcd
		abcd = x86._mm_sha1rnds4_epu32(abcd, e0, 2)
		m1 = x86._mm_sha1msg1_epu32(m1, m2)
		m0 = x86._mm_xor_si128(m0, m2)
		m3 = x86._mm_sha1msg2_epu32(m3, m2)
		e1 = x86._mm_sha1nexte_epu32(e1, m3)
		e0 = abcd
		abcd = x86._mm_sha1rnds4_epu32(abcd, e1, 3)
		m2 = x86._mm_sha1msg1_epu32(m2, m3)
		m1 = x86._mm_xor_si128(m1, m3)
		m0 = x86._mm_sha1msg2_epu32(m0, m3)
		e0 = x86._mm_sha1nexte_epu32(e0, m0)
		e1 = abcd
		abcd = x86._mm_sha1rnds4_epu32(abcd, e0, 3)
		m3 = x86._mm_sha1msg1_epu32(m3, m0)
		m2 = x86._mm_xor_si128(m2, m0)
		m1 = x86._mm_sha1msg2_epu32(m1, m0)
		e1 = x86._mm_sha1nexte_epu32(e1, m1)
		e0 = abcd
		abcd = x86._mm_sha1rnds4_epu32(abcd, e1, 3)
		m3 = x86._mm_xor_si128(m3, m1)
		m2 = x86._mm_sha1msg2_epu32(m2, m1)
		e0 = x86._mm_sha1nexte_epu32(e0, m2)
		e1 = abcd
		abcd = x86._mm_sha1rnds4_epu32(abcd, e0, 3)
		m3 = x86._mm_sha1msg2_epu32(m3, m2)
		e1 = x86._mm_sha1nexte_epu32(e1, m3)
		e0 = abcd
		abcd = x86._mm_sha1rnds4_epu32(abcd, e1, 3)

		e0 = x86._mm_sha1nexte_epu32(e0, e0_save)
		abcd = x86._mm_add_epi32(abcd, abcd_save)
		data = data[64:]
	}

	abcd = x86._mm_shuffle_epi32(abcd, 0x1b)
	intrinsics.unaligned_store((^x86.__m128i)(&state[0]), abcd)
	state[4] = u32(x86._mm_extract_epi32(e0, 3))
}
