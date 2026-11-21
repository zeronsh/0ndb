#+build arm64
package odb

import "base:intrinsics"
import "core:simd"
import "core:simd/arm"
import "core:sys/info"

@(private)
sha1_hw_supported :: proc "contextless" () -> bool {
	required :: info.CPU_Features{.asimd, .sha1}
	return info.cpu_features() >= required
}

@(private, enable_target_feature = "neon,sha2")
sha1_hw_blocks :: proc "contextless" (state: ^[5]u32, data: []u8) #no_bounds_check {
	K0 :: simd.u32x4{0x5a827999, 0x5a827999, 0x5a827999, 0x5a827999}
	K1 :: simd.u32x4{0x6ed9eba1, 0x6ed9eba1, 0x6ed9eba1, 0x6ed9eba1}
	K2 :: simd.u32x4{0x8f1bbcdc, 0x8f1bbcdc, 0x8f1bbcdc, 0x8f1bbcdc}
	K3 :: simd.u32x4{0xca62c1d6, 0xca62c1d6, 0xca62c1d6, 0xca62c1d6}

	abcd := intrinsics.unaligned_load((^simd.u32x4)(&state[0]))
	e0 := state[4]
	e1: u32
	tmp: simd.u32x4

	data := data
	for len(data) >= 64 {
		abcd_save := abcd
		e_save := e0

		m0 := sha1_load_be(raw_data(data))
		m1 := sha1_load_be(raw_data(data[16:]))
		m2 := sha1_load_be(raw_data(data[32:]))
		m3 := sha1_load_be(raw_data(data[48:]))

		tmp = simd.add(m0, K0)
		e1 = arm.vsha1h_u32(arm.vgetq_lane_u32(abcd, 0))
		abcd = arm.vsha1cq_u32(abcd, e0, tmp)
		m0 = arm.vsha1su1q_u32(arm.vsha1su0q_u32(m0, m1, m2), m3)
		tmp = simd.add(m1, K0)
		e0 = arm.vsha1h_u32(arm.vgetq_lane_u32(abcd, 0))
		abcd = arm.vsha1cq_u32(abcd, e1, tmp)
		m1 = arm.vsha1su1q_u32(arm.vsha1su0q_u32(m1, m2, m3), m0)
		tmp = simd.add(m2, K0)
		e1 = arm.vsha1h_u32(arm.vgetq_lane_u32(abcd, 0))
		abcd = arm.vsha1cq_u32(abcd, e0, tmp)
		m2 = arm.vsha1su1q_u32(arm.vsha1su0q_u32(m2, m3, m0), m1)
		tmp = simd.add(m3, K0)
		e0 = arm.vsha1h_u32(arm.vgetq_lane_u32(abcd, 0))
		abcd = arm.vsha1cq_u32(abcd, e1, tmp)
		m3 = arm.vsha1su1q_u32(arm.vsha1su0q_u32(m3, m0, m1), m2)
		tmp = simd.add(m0, K0)
		e1 = arm.vsha1h_u32(arm.vgetq_lane_u32(abcd, 0))
		abcd = arm.vsha1cq_u32(abcd, e0, tmp)
		m0 = arm.vsha1su1q_u32(arm.vsha1su0q_u32(m0, m1, m2), m3)
		tmp = simd.add(m1, K1)
		e0 = arm.vsha1h_u32(arm.vgetq_lane_u32(abcd, 0))
		abcd = arm.vsha1pq_u32(abcd, e1, tmp)
		m1 = arm.vsha1su1q_u32(arm.vsha1su0q_u32(m1, m2, m3), m0)
		tmp = simd.add(m2, K1)
		e1 = arm.vsha1h_u32(arm.vgetq_lane_u32(abcd, 0))
		abcd = arm.vsha1pq_u32(abcd, e0, tmp)
		m2 = arm.vsha1su1q_u32(arm.vsha1su0q_u32(m2, m3, m0), m1)
		tmp = simd.add(m3, K1)
		e0 = arm.vsha1h_u32(arm.vgetq_lane_u32(abcd, 0))
		abcd = arm.vsha1pq_u32(abcd, e1, tmp)
		m3 = arm.vsha1su1q_u32(arm.vsha1su0q_u32(m3, m0, m1), m2)
		tmp = simd.add(m0, K1)
		e1 = arm.vsha1h_u32(arm.vgetq_lane_u32(abcd, 0))
		abcd = arm.vsha1pq_u32(abcd, e0, tmp)
		m0 = arm.vsha1su1q_u32(arm.vsha1su0q_u32(m0, m1, m2), m3)
		tmp = simd.add(m1, K1)
		e0 = arm.vsha1h_u32(arm.vgetq_lane_u32(abcd, 0))
		abcd = arm.vsha1pq_u32(abcd, e1, tmp)
		m1 = arm.vsha1su1q_u32(arm.vsha1su0q_u32(m1, m2, m3), m0)
		tmp = simd.add(m2, K2)
		e1 = arm.vsha1h_u32(arm.vgetq_lane_u32(abcd, 0))
		abcd = arm.vsha1mq_u32(abcd, e0, tmp)
		m2 = arm.vsha1su1q_u32(arm.vsha1su0q_u32(m2, m3, m0), m1)
		tmp = simd.add(m3, K2)
		e0 = arm.vsha1h_u32(arm.vgetq_lane_u32(abcd, 0))
		abcd = arm.vsha1mq_u32(abcd, e1, tmp)
		m3 = arm.vsha1su1q_u32(arm.vsha1su0q_u32(m3, m0, m1), m2)
		tmp = simd.add(m0, K2)
		e1 = arm.vsha1h_u32(arm.vgetq_lane_u32(abcd, 0))
		abcd = arm.vsha1mq_u32(abcd, e0, tmp)
		m0 = arm.vsha1su1q_u32(arm.vsha1su0q_u32(m0, m1, m2), m3)
		tmp = simd.add(m1, K2)
		e0 = arm.vsha1h_u32(arm.vgetq_lane_u32(abcd, 0))
		abcd = arm.vsha1mq_u32(abcd, e1, tmp)
		m1 = arm.vsha1su1q_u32(arm.vsha1su0q_u32(m1, m2, m3), m0)
		tmp = simd.add(m2, K2)
		e1 = arm.vsha1h_u32(arm.vgetq_lane_u32(abcd, 0))
		abcd = arm.vsha1mq_u32(abcd, e0, tmp)
		m2 = arm.vsha1su1q_u32(arm.vsha1su0q_u32(m2, m3, m0), m1)
		tmp = simd.add(m3, K3)
		e0 = arm.vsha1h_u32(arm.vgetq_lane_u32(abcd, 0))
		abcd = arm.vsha1pq_u32(abcd, e1, tmp)
		m3 = arm.vsha1su1q_u32(arm.vsha1su0q_u32(m3, m0, m1), m2)
		tmp = simd.add(m0, K3)
		e1 = arm.vsha1h_u32(arm.vgetq_lane_u32(abcd, 0))
		abcd = arm.vsha1pq_u32(abcd, e0, tmp)
		tmp = simd.add(m1, K3)
		e0 = arm.vsha1h_u32(arm.vgetq_lane_u32(abcd, 0))
		abcd = arm.vsha1pq_u32(abcd, e1, tmp)
		tmp = simd.add(m2, K3)
		e1 = arm.vsha1h_u32(arm.vgetq_lane_u32(abcd, 0))
		abcd = arm.vsha1pq_u32(abcd, e0, tmp)
		tmp = simd.add(m3, K3)
		e0 = arm.vsha1h_u32(arm.vgetq_lane_u32(abcd, 0))
		abcd = arm.vsha1pq_u32(abcd, e1, tmp)

		abcd = simd.add(abcd, abcd_save)
		e0 += e_save
		data = data[64:]
	}

	intrinsics.unaligned_store((^simd.u32x4)(&state[0]), abcd)
	state[4] = e0
}

@(private = "file", enable_target_feature = "neon")
sha1_load_be :: #force_inline proc "contextless" (p: [^]u8) -> simd.u32x4 {
	v := intrinsics.unaligned_load((^simd.u8x16)(p))
	return transmute(simd.u32x4)simd.shuffle(v, v, 3, 2, 1, 0, 7, 6, 5, 4, 11, 10, 9, 8, 15, 14, 13, 12)
}
