package oomap

// 64 字符地址编码器 —— 验收测试
//
// 对应 原始任务规格 第 11 节。运行：odin test src

import "core:fmt"
import "core:strings"
import "core:testing"

// ---------------------------------------------------------------- 帮助函数

@(private)
rng_next :: proc(state: ^u64) -> u64 {
	// splitmix64：高位/低位都充分混合，避免 LCG 低位短周期导致字符矩阵退化。
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

@(private)
make_encoder :: proc(keys: []string, modes, params: [CHAR_COUNT]u32) -> Encoder {
	e := encoder_init()
	for key in keys {
		head, _ := head_for(key, modes, params)
		k, _ := strings.clone(key)
		append(&e.entries, Entry{key = k, head = head})
	}
	return e
}

@(private)
free_keys :: proc(keys: []string) {
	for k in keys {
		delete(k)
	}
}

@(private)
cache_snapshot :: proc(e: ^Encoder) -> []u32 {
	snapshot := make([]u32, len(e.cache))
	copy(snapshot, e.cache[:])
	return snapshot
}

@(private)
parse_segment_data :: proc(cache: []u32, head: u32) -> (data: []u8, ok: bool) {
	h := int(head)
	if h + 2 > len(cache) || cache[h] != 0 {
		return nil, false
	}
	key_len := int(cache[h + 1])
	pos := h + 2 + (key_len + 3) / 4
	if pos >= len(cache) || cache[pos] != SEGMENT_SEPARATOR {
		return nil, false
	}
	pos += 1
	if pos >= len(cache) {
		return nil, false
	}
	data_words := int(cache[pos])
	pos += 1
	out := make([]u8, data_words * 4)
	for w in 0 ..< data_words {
		if pos + w >= len(cache) {
			delete(out)
			return nil, false
		}
		for b in 0 ..< 4 {
			out[w * 4 + b] = u8((cache[pos + w] >> u32(b * 8)) & 0xFF)
		}
	}
	return out, true
}

// ---------------------------------------------------------------- 1. 格式测试

@(test)
test_add_format :: proc(t: ^testing.T) {
	e := encoder_init()
	defer encoder_destroy(&e)

	head, err := add(&e, "A", []u8{1, 2, 3})
	testing.expect_value(t, err, ErrorCode.None)
	testing.expect_value(t, head, u32(256))
	testing.expect_value(t, len(e.cache), 263)

	testing.expect_value(t, e.cache[256], u32(0x00000000))
	testing.expect_value(t, e.cache[257], u32(1))
	testing.expect_value(t, e.cache[258], u32(0x00000041))
	testing.expect_value(t, e.cache[259], u32(SEGMENT_SEPARATOR))
	testing.expect_value(t, e.cache[260], u32(1))
	testing.expect_value(t, e.cache[261], u32(0x00030201))
	testing.expect_value(t, e.cache[262], u32(SEGMENT_SEPARATOR))
}

// ---------------------------------------------------------------- 2. 帧格式 add_framed

@(test)
test_add_framed_format :: proc(t: ^testing.T) {
	e := encoder_init()
	defer encoder_destroy(&e)

	data := []u8{0x01, 0x02, 0x03, 0x04, 0x05}
	head, err := add_framed(&e, "AB", data)
	testing.expect_value(t, err, ErrorCode.None)
	testing.expect_value(t, head, u32(256))
	// [START][len][KEY][1 word][DATA_LEN][2 words][DATA][2 words][END]
	testing.expect_value(t, len(e.cache), 256 + 10)

	testing.expect_value(t, e.cache[256], u32(FRAME_START))
	testing.expect_value(t, e.cache[257], u32(2))
	testing.expect_value(t, e.cache[258], u32(FRAME_KEY))
	testing.expect_value(t, e.cache[259], u32(0x00004241))
	testing.expect_value(t, e.cache[260], u32(FRAME_DATA_LEN))
	testing.expect_value(t, e.cache[261], u32(2))
	testing.expect_value(t, e.cache[262], u32(FRAME_DATA))
	testing.expect_value(t, e.cache[263], u32(0x04030201))
	testing.expect_value(t, e.cache[264], u32(0x00000005))
	testing.expect_value(t, e.cache[265], u32(FRAME_END))

	// 空 data：data_words=0，DATA 标记后直接是 END。
	head2, err2 := add_framed(&e, "C", nil)
	testing.expect_value(t, err2, ErrorCode.None)
	testing.expect_value(t, e.cache[head2 + 3], u32(0x00000043))
	testing.expect_value(t, e.cache[head2 + 4], u32(FRAME_DATA_LEN))
	testing.expect_value(t, e.cache[head2 + 5], u32(0))
	testing.expect_value(t, e.cache[head2 + 6], u32(FRAME_DATA))
	testing.expect_value(t, e.cache[head2 + 7], u32(FRAME_END))

	// 重复 key 仍被拒绝。
	_, err3 := add_framed(&e, "AB", nil)
	testing.expect_value(t, err3, ErrorCode.DuplicateKey)
}

// ---------------------------------------------------------------- 2b. 数据回读

@(test)
test_read_data :: proc(t: ^testing.T) {
	// 旧格式：mode/param 由 wrap 求出，read_data 再用同样的规则定位段。
	e := encoder_init()
	defer encoder_destroy(&e)

	target: u32 = 300
	for len(e.cache) < int(target) {
		append(&e.cache, 0)
	}
	data := []u8{0x11, 0x22, 0x33, 0x44, 0x55}
	head, err := add(&e, "A", data)
	testing.expect_value(t, err, ErrorCode.None)
	testing.expect_value(t, head, target)

	info: WrapInfo
	wrap_err := wrap_ex(&e, 5_000, &info)
	wrap_info_destroy(&info)
	testing.expect_value(t, wrap_err, ErrorCode.None)

	got, ok := read_data(&e, "A")
	defer delete(got)
	testing.expect(t, ok)
	testing.expect_value(t, len(got), 8) // 5 字节向上取整到 2 个 u32
	for i in 0 ..< len(data) {
		testing.expect_value(t, got[i], data[i])
	}

	// 字符串不对：eval 得到的 head 指向保留区，长度/内容校验失败。
	_, bad_ok := read_data(&e, "B")
	testing.expect(t, !bad_ok)

	// 帧格式
	e2 := encoder_init()
	defer encoder_destroy(&e2)
	target2: u32 = 400
	for len(e2.cache) < int(target2) {
		append(&e2.cache, 0)
	}
	data2 := []u8{0xAA, 0xBB, 0xCC}
	head2, err2 := add_framed(&e2, "AB", data2)
	testing.expect_value(t, err2, ErrorCode.None)
	testing.expect_value(t, head2, target2)

	info2: WrapInfo
	wrap_err2 := wrap_ex(&e2, 5_000, &info2)
	wrap_info_destroy(&info2)
	testing.expect_value(t, wrap_err2, ErrorCode.None)

	got2, ok2 := read_data(&e2, "AB")
	defer delete(got2)
	testing.expect(t, ok2)
	testing.expect_value(t, len(got2), 4)
	for i in 0 ..< len(data2) {
		testing.expect_value(t, got2[i], data2[i])
	}
}

@(test)
test_solution_snapshot :: proc(t: ^testing.T) {
	e := encoder_init()
	defer encoder_destroy(&e)

	k, _ := strings.clone("A")
	append(&e.entries, Entry{key = k, head = u32(X0) + 7})

	info: WrapInfo
	err := wrap_ex(&e, 5_000, &info)
	wrap_info_destroy(&info)
	testing.expect_value(t, err, ErrorCode.None)

	snap := solution_snapshot(&e)
	defer delete(snap)
	testing.expect_value(t, len(snap), MODE_PARAM_END)
	for i in 0 ..< MODE_PARAM_END {
		testing.expect_value(t, snap[i], e.cache[i])
	}
}

// ---------------------------------------------------------------- 2c. 从 cache 还原 Entry

@(test)
test_entries_from_cache :: proc(t: ^testing.T) {
	e := encoder_init()
	defer encoder_destroy(&e)

	h1, err1 := add(&e, "A", []u8{0x10, 0x20})
	testing.expect_value(t, err1, ErrorCode.None)
	h2, err2 := add_framed(&e, "B0", []u8{0x30})
	testing.expect_value(t, err2, ErrorCode.None)

	entries, err := entries_from_cache(e.cache[:])
	testing.expect_value(t, err, ErrorCode.None)
	testing.expect_value(t, len(entries), 2)
	if len(entries) == 2 {
		testing.expect_value(t, entries[0].key, "A")
		testing.expect_value(t, entries[0].head, h1)
		testing.expect_value(t, entries[1].key, "B0")
		testing.expect_value(t, entries[1].head, h2)
	}
	for entry in entries {
		delete(entry.key)
	}
	delete(entries)
}

// ---------------------------------------------------------------- 2d. 64 字符全参与

@(test)
test_all_chars_underdetermined :: proc(t: ^testing.T) {
	e := encoder_init()
	defer encoder_destroy(&e)

	// 一个覆盖全部 64 个字符的 key：方程欠定（1 条样本、64 个变量），
	// 用来覆盖 m=64 时的 family 0 回退路径。
	k, _ := strings.clone(SIGMA)
	append(&e.entries, Entry{key = k, head = u32(X0) + 42})

	info: WrapInfo
	err := wrap_ex(&e, 5_000, &info)
	defer wrap_info_destroy(&info)
	testing.expect_value(t, err, ErrorCode.None)
	testing.expect_value(t, info.solved_family, 0)
	ok, _ := verify(&e)
	testing.expect(t, ok)
}

// ---------------------------------------------------------------- 3. 不可行测试

@(test)
test_infeasible_duplicate :: proc(t: ^testing.T) {
	e := encoder_init()
	defer encoder_destroy(&e)

	for entry in ([]Entry{{"X", 100}, {"X", 200}}) {
		k, _ := strings.clone(entry.key)
		append(&e.entries, Entry{key = k, head = entry.head})
	}
	before := cache_snapshot(&e)
	defer delete(before)

	info: WrapInfo
	err := wrap_ex(&e, 5_000, &info)
	defer wrap_info_destroy(&info)

	testing.expect_value(t, err, ErrorCode.Infeasible)
	testing.expect_value(t, len(e.cache), len(before))
	for i in 0 ..< len(before) {
		testing.expect_value(t, e.cache[i], before[i])
	}

	// add 层面对重复 key 的拒绝
	head, add_err := add(&e, "X", nil)
	testing.expect_value(t, add_err, ErrorCode.DuplicateKey)
	testing.expect_value(t, head, u32(0))
}

// ---------------------------------------------------------------- 4. 边界

@(test)
test_boundaries :: proc(t: ^testing.T) {
	e := encoder_init()
	defer encoder_destroy(&e)

	_, err := add(&e, "", nil)
	testing.expect_value(t, err, ErrorCode.EmptyKey)

	_, err = add(&e, ":", nil)
	testing.expect_value(t, err, ErrorCode.InvalidCharacter)

	_, err = add(&e, "a b", nil)
	testing.expect_value(t, err, ErrorCode.InvalidCharacter)

	cases := [][]u8{
		{0xFF},
		{0xFF, 0xFF},
		{0xFF, 0xFF, 0xFF, 0xFF},
		{0x00, 0xFF, 0xFF, 0x00, 0xFF},
	}
	for data, i in cases {
		key := fmt.aprintf("k%c", rune('a' + i), allocator = context.temp_allocator)
		head, e2 := add(&e, key, data)
		testing.expect_value(t, e2, ErrorCode.None)
		got, ok := parse_segment_data(e.cache[:], head)
		testing.expectf(t, ok, "case %d 解析失败", i)
		if ok {
			// 格式只存 u32 数量，末位补 0，因此长度按 4 字节对齐。
			testing.expect_value(t, len(got), ((len(data) + 3) / 4) * 4)
			for b in 0 ..< len(data) {
				testing.expect_value(t, got[b], data[b])
			}
			for b in len(data) ..< len(got) {
				testing.expect_value(t, got[b], u8(0))
			}
			delete(got)
		}
	}
}

// ---------------------------------------------------------------- 5. 回绕

@(test)
test_wrap_around :: proc(t: ^testing.T) {
	e := encoder_init()
	defer encoder_destroy(&e)

	p: u32 = 0xFFFF_FFF0
	head := u32(X0) + p // 31 + 0xFFFFFFF0 = 15
	k, _ := strings.clone("A")
	append(&e.entries, Entry{key = k, head = head})

	info: WrapInfo
	err := wrap_ex(&e, 5_000, &info)
	defer wrap_info_destroy(&info)

	a_idx, _ := char_index('A')
	testing.expect_value(t, err, ErrorCode.None)
	testing.expect_value(t, info.solved_family, 0)
	testing.expect_value(t, e.cache[int(a_idx)], u32(0)) // mode["A"] = ADD
	testing.expect_value(t, e.cache[PARAM_OFFSET + int(a_idx)], p) // param["A"]
	ok, _ := verify(&e)
	testing.expect(t, ok)
}

// ---------------------------------------------------------------- 6. 超时
//
// Z3 的 check 在 Odin 测试运行器（Windows 上启用 Vectored Exception Handler）
// 内可能被其异常拦截器误判为测试信号，因此超时/Z3 相关场景由
// scripts\run_acceptance.ps1 以独立进程运行 bin\OOMap.exe 验证。

// ---------------------------------------------------------------- 7. frozen

@(test)
test_frozen :: proc(t: ^testing.T) {
	e := encoder_init()
	defer encoder_destroy(&e)

	k, _ := strings.clone("A")
	append(&e.entries, Entry{key = k, head = u32(X0) + 7})

	info: WrapInfo
	err := wrap_ex(&e, 5_000, &info)
	wrap_info_destroy(&info)
	testing.expect_value(t, err, ErrorCode.None)

	before := cache_snapshot(&e)
	defer delete(before)

	_, add_err := add(&e, "B", nil)
	testing.expect_value(t, add_err, ErrorCode.Frozen)
	for i in 0 ..< len(before) {
		testing.expect_value(t, e.cache[i], before[i])
	}
}

// ---------------------------------------------------------------- 8. 精确字节回读

@(test)
test_read_data_exact :: proc(t: ^testing.T) {
	cases := [][]u8{
		{},
		{0x00},
		{0x11},
		{0x11, 0x00},
		{0x11, 0x22, 0x33},
		{0x11, 0x22, 0x33, 0x44},
		{0x00, 0x00, 0x00, 0x00, 0x00}, // 原始数据自带尾随 0，不能被当成填充
	}

	for data, i in cases {
		e := encoder_init()
		target := u32(300 + i * 20)
		for len(e.cache) < int(target) {
			append(&e.cache, 0)
		}
		head: u32
		add_err: ErrorCode
		if i % 2 == 1 {
			head, add_err = add_framed(&e, "A", data)
		} else {
			head, add_err = add(&e, "A", data)
		}
		testing.expect_value(t, add_err, ErrorCode.None)
		testing.expect_value(t, head, target)

		info: WrapInfo
		wrap_err := wrap_ex(&e, 5_000, &info)
		wrap_info_destroy(&info)
		testing.expect_value(t, wrap_err, ErrorCode.None)

		got, length, ok := read_data_exact(&e, "A")
		defer delete(got)
		testing.expectf(t, ok, "case %d 精确回读失败", i)
		testing.expect_value(t, length, len(data))
		testing.expect_value(t, len(got), len(data))
		for b in 0 ..< len(data) {
			testing.expect_value(t, got[b], data[b])
		}

		// data_length 与 exact 一致；read_data 仍返回 4 字节对齐的数据。
		known, known_ok := data_length(&e, "A")
		testing.expect_value(t, known_ok, true)
		testing.expect_value(t, known, len(data))

		padded, padded_ok := read_data(&e, "A")
		defer delete(padded)
		testing.expect(t, padded_ok)
		testing.expect_value(t, len(padded), ((len(data) + 3) / 4) * 4)
		for b in 0 ..< len(data) {
			testing.expect_value(t, padded[b], data[b])
		}
		for b in len(data) ..< len(padded) {
			testing.expect_value(t, padded[b], u8(0))
		}

		// 长度超过段内字数 * 4 时必须失败。
		too_long, too_long_ok := read_data_exact_len(&e, "A", len(padded) + 1)
		testing.expect(t, !too_long_ok)
		testing.expect_value(t, len(too_long), 0)
		delete(too_long)

		encoder_destroy(&e)
	}
}

@(test)
test_read_data_exact_without_length_metadata :: proc(t: ^testing.T) {
	// 先用 add + wrap 生成一份完整 cache。
	src := encoder_init()
	defer encoder_destroy(&src)
	data := []u8{0xDE, 0xAD, 0xBE, 0xEF, 0x01}
	for len(src.cache) < 320 {
		append(&src.cache, 0)
	}
	_, add_err := add(&src, "A", data)
	testing.expect_value(t, add_err, ErrorCode.None)

	info: WrapInfo
	wrap_err := wrap_ex(&src, 5_000, &info)
	wrap_info_destroy(&info)
	testing.expect_value(t, wrap_err, ErrorCode.None)

	// 只从 cache 重建 Encoder：entries 可以恢复，但原始长度不可恢复。
	restored := encoder_init()
	defer encoder_destroy(&restored)
	delete(restored.cache)
	restored.cache = make([dynamic]u32, len(src.cache))
	copy(restored.cache[:], src.cache[:])

	entries, entries_err := entries_from_cache(restored.cache[:])
	testing.expect_value(t, entries_err, ErrorCode.None)
	testing.expect_value(t, len(entries), 1)
	for entry in entries {
		append(&restored.entries, entry)
	}
	delete(entries)

	_, _, exact_ok := read_data_exact(&restored, "A")
	testing.expect(t, !exact_ok)

	got, ok := read_data_exact_len(&restored, "A", len(data))
	defer delete(got)
	testing.expect(t, ok)
	testing.expect_value(t, len(got), len(data))
	for b in 0 ..< len(data) {
		testing.expect_value(t, got[b], data[b])
	}
}

// ---------------------------------------------------------------- 9. 缺 Z3
//
// 说明：Z3 的动态库探测是进程级全局状态（z3_reset 会强制重载），
// 与 odin test 默认的多线程测试并发执行会互相干扰，因此“缺 Z3 降级”
// 由 scripts\test_missing_z3.ps1 以独立进程方式验证（隐藏 libz3.dll 后运行 demo）。



// ---------------------------------------------------------------- 10. cache 往返

@(test)
test_encoder_from_cache :: proc(t: ^testing.T) {
	src := encoder_init()
	defer encoder_destroy(&src)

	for len(src.cache) < 300 {
		append(&src.cache, 0)
	}
	_, e1 := add(&src, "A", []u8{0x10, 0x20, 0x30})
	testing.expect_value(t, e1, ErrorCode.None)
	_, e2 := add_framed(&src, "B", []u8{0x40, 0x50})
	testing.expect_value(t, e2, ErrorCode.None)

	info: WrapInfo
	wrap_err := wrap_ex(&src, 5_000, &info)
	wrap_info_destroy(&info)
	testing.expect_value(t, wrap_err, ErrorCode.None)

	snapshot := make([]u32, len(src.cache))
	defer delete(snapshot)
	copy(snapshot, cache_view(&src))

	restored, err := encoder_from_cache(snapshot)
	defer encoder_destroy(&restored)
	testing.expect_value(t, err, ErrorCode.None)
	testing.expect_value(t, len(restored.entries), 2)

	verify_ok, _ := verify(&restored)
	testing.expect(t, verify_ok)

	got, read_ok := read_data(&restored, "A")
	defer delete(got)
	testing.expect(t, read_ok)
	testing.expect_value(t, len(got), 4)
	testing.expect_value(t, got[0], u8(0x10))
	testing.expect_value(t, got[1], u8(0x20))
	testing.expect_value(t, got[2], u8(0x30))

	// 长度元数据没有随 cache 保存。
	_, _, exact_ok := read_data_exact(&restored, "A")
	testing.expect(t, !exact_ok)
	exact, exact_len_ok := read_data_exact_len(&restored, "A", 3)
	defer delete(exact)
	testing.expect(t, exact_len_ok)
	testing.expect_value(t, len(exact), 3)

	// 恢复出来的 Encoder 已 frozen。
	_, add_err := add(&restored, "C", nil)
	testing.expect_value(t, add_err, ErrorCode.Frozen)
}
