package main

// Demo 是 OOMap 的外部调用方：这里只导入库包，并把公开 API 绑定到本包名字，
// 让 demo 代码保持可读。真正的第三方库用法见 docs/LIBRARY.md（使用 `oomap.add`
// 这类限定名调用，不需要这份兼容层）。

import "core:strings"
import oomap "../../src/oomap"

Encoder :: oomap.Encoder
Entry :: oomap.Entry
WrapInfo :: oomap.WrapInfo
ErrorCode :: oomap.ErrorCode

CHAR_COUNT :: oomap.CHAR_COUNT
X0 :: oomap.X0
SIGMA :: oomap.SIGMA
PARAM_OFFSET :: oomap.PARAM_OFFSET
RESERVED_LEN :: oomap.RESERVED_LEN

encoder_init :: oomap.encoder_init
encoder_destroy :: oomap.encoder_destroy
add :: oomap.add
add_u32 :: oomap.add_u32
add_framed :: oomap.add_framed
wrap_ex :: oomap.wrap_ex
wrap_info_destroy :: oomap.wrap_info_destroy
verify :: oomap.verify
read_data :: oomap.read_data
read_data_exact :: oomap.read_data_exact
read_data_exact_len :: oomap.read_data_exact_len
data_length :: oomap.data_length
entries_from_cache :: oomap.entries_from_cache
solution_snapshot :: oomap.solution_snapshot
eval :: oomap.eval
char_index :: oomap.char_index
z3_available :: oomap.z3_available
z3_version_string :: oomap.z3_version_string

// ---- demo 自己的测试辅助（不属于库 API） ----

@(private)
rng_next :: proc(state: ^u64) -> u64 {
	state^ += 0x9E37_79B9_7F4A_7C15
	z := state^
	z = (z ~ (z >> 30)) * 0xBF58_476D_1CE4_E5B9
	z = (z ~ (z >> 27)) * 0x94D0_49BB_1331_11EB
	return z ~ (z >> 31)
}

@(private)
random_key :: proc(state: ^u64, min_len: int = 1, max_len: int = 12) -> string {
	sigma := SIGMA
	buf: [32]u8
	span := max_len - min_len + 1
	length := min_len + int(rng_next(state) % u64(span))
	for i in 0 ..< length {
		buf[i] = sigma[int(rng_next(state) % u64(CHAR_COUNT))]
	}
	return strings.clone(string(buf[:length]))
}

@(private)
head_for :: proc(key: string, modes, params: [CHAR_COUNT]u32) -> (u32, bool) {
	cache: [RESERVED_LEN]u32
	for i in 0 ..< CHAR_COUNT {
		cache[i] = modes[i]
		cache[PARAM_OFFSET + i] = params[i]
	}
	return eval(cache[:], key)
}
