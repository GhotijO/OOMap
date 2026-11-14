package main

// 64 字符地址编码器 —— 字符集、求值与校验
//
// 对应原始任务规格第 1、5、8 节。

CHAR_COUNT :: 64
X0 :: 31

// Σ = "." + "0".."9" + "A".."Z" + "_" + "a".."z"，按 ASCII 顺序排列。
SIGMA :: ".0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz"

/*
把字符映射到 Σ 中的下标。

返回 ok=false 表示字符不在 Σ 内。
*/
char_index :: proc(ch: rune) -> (idx: u8, ok: bool) {
	switch {
	case ch == '.':
		return 0, true
	case ch >= '0' && ch <= '9':
		return u8(int(ch - '0') + 1), true
	case ch >= 'A' && ch <= 'Z':
		return u8(int(ch - 'A') + 11), true
	case ch == '_':
		return 37, true
	case ch >= 'a' && ch <= 'z':
		return u8(int(ch - 'a') + 38), true
	}
	return 0, false
}

/*
单个字符上的操作，p 为参数、x 为当前值，全部按 u32 回绕语义。

mode: 0=ADD, 1=SUB, 2=XOR, 3=MOD（p=0 时不取模）
*/
apply :: proc(mode: u32, p: u32, x: u32) -> u32 {
	switch mode {
	case 0:
		return x + p
	case 1:
		return x - p
	case 2:
		return x ~ p
	case 3:
		return p == 0 ? x : x % p
	}
	return x
}

/*
按 cache 中的 mode/param 对一个 key 从左到右求值。

要求 cache 至少包含前 128 个 u32；字符不在 Σ 内或 mode 非法时返回 ok=false。
*/
eval :: proc(cache: []u32, key: string) -> (value: u32, ok: bool) {
	if len(cache) < MODE_PARAM_END {
		return 0, false
	}

	x := u32(X0)
	for ch in key {
		i, valid := char_index(ch)
		if !valid {
			return 0, false
		}
		mode := cache[int(i)]
		if mode > 3 {
			return 0, false
		}
		x = apply(mode, cache[int(i) + PARAM_OFFSET], x)
	}
	return x, true
}

VerifyBad :: struct {
	key:  string,
	want: u32,
	got:  u32,
}

/*
纯 Odin 重放校验：不调用 Z3、不查表。

返回首个不匹配的样本；全部通过时 bad 为 nil。
*/
verify :: proc(e: ^Encoder) -> (ok: bool, bad: Maybe(VerifyBad)) {
	return verify_with(e, e.cache[:])
}

/*
使用指定的 cache 切片重放校验（wrap 在提交前对工作缓冲区调用）。
*/
verify_with :: proc(e: ^Encoder, cache: []u32) -> (ok: bool, bad: Maybe(VerifyBad)) {
	if len(cache) < MODE_PARAM_END {
		return false, VerifyBad{"<cache>", MODE_PARAM_END, u32(len(cache))}
	}

	for entry in e.entries {
		got, valid := eval(cache, entry.key)
		if !valid {
			return false, VerifyBad{entry.key, entry.head, got}
		}
		if got != entry.head {
			return false, VerifyBad{entry.key, entry.head, got}
		}
	}
	return true, nil
}

/*
用 wrap 的结果把字符串解码回原始数据。

流程：
  1. 按当前 cache 的 mode/param 对 key 求值得到 head（即该段的起始下标）；
  2. 检查 head 处的段标记，并校验段内记录的长度和字符串内容都与输入 key 一致；
     不一致（或越界、标记非法）时放弃，返回 ok=false；
  3. 读取段内的 u32 字数，展开为小端字节返回（长度按 4 字节对齐，末位补 0）。

支持 add 的 0x0000/0xFFFF 格式与 add_framed 的 0xFF00FFxx 格式。
返回的 data 由调用方 delete。
*/
read_data :: proc(e: ^Encoder, key: string) -> (data: []u8, ok: bool) {
	head, valid := eval(e.cache[:], key)
	if !valid {
		return nil, false
	}
	return read_segment_at(e.cache[:], key, int(head))
}

@(private)
read_segment_at :: proc(cache: []u32, key: string, head: int) -> (data: []u8, ok: bool) {
	if head < 0 || head + 1 >= len(cache) {
		return nil, false
	}

	switch cache[head] {
	case 0:
		return read_segment_legacy(cache, key, head)
	case FRAME_START:
		return read_segment_framed(cache, key, head)
	}
	return nil, false
}

@(private)
read_segment_legacy :: proc(cache: []u32, key: string, head: int) -> (data: []u8, ok: bool) {
	key_len := int(cache[head + 1])
	if key_len != len(key) {
		return nil, false
	}
	key_words := (key_len + 3) / 4
	pos := head + 2
	if pos + key_words >= len(cache) || !packed_key_matches(cache, pos, key) {
		return nil, false
	}
	pos += key_words

	if cache[pos] != SEGMENT_SEPARATOR {
		return nil, false
	}
	pos += 1
	if pos >= len(cache) {
		return nil, false
	}
	data_words := int(cache[pos])
	pos += 1
	if data_words < 0 || pos + data_words > len(cache) {
		return nil, false
	}
	return unpack_words(cache, pos, data_words), true
}

@(private)
read_segment_framed :: proc(cache: []u32, key: string, head: int) -> (data: []u8, ok: bool) {
	if head + 2 >= len(cache) || cache[head + 2] != FRAME_KEY {
		return nil, false
	}
	key_len := int(cache[head + 1])
	if key_len != len(key) {
		return nil, false
	}
	key_words := (key_len + 3) / 4
	pos := head + 3
	if pos + key_words + 3 > len(cache) || !packed_key_matches(cache, pos, key) {
		return nil, false
	}
	pos += key_words

	if cache[pos] != FRAME_DATA_LEN {
		return nil, false
	}
	data_words := int(cache[pos + 1])
	pos += 2
	if cache[pos] != FRAME_DATA {
		return nil, false
	}
	pos += 1
	if data_words < 0 || pos + data_words > len(cache) {
		return nil, false
	}
	return unpack_words(cache, pos, data_words), true
}

/*
校验 cache[start..] 处的打包字符串是否与 key 完全一致。
*/
@(private)
packed_key_matches :: proc(cache: []u32, start: int, key: string) -> bool {
	words := (len(key) + 3) / 4
	if start + words > len(cache) {
		return false
	}
	for b in 0 ..< len(key) {
		word := cache[start + b / 4]
		byte := u8((word >> u32((b % 4) * 8)) & 0xFF)
		if byte != key[b] {
			return false
		}
	}
	return true
}

@(private)
unpack_words :: proc(cache: []u32, start: int, words: int) -> []u8 {
	out := make([]u8, words * 4)
	for w in 0 ..< words {
		for b in 0 ..< 4 {
			out[w * 4 + b] = u8((cache[start + w] >> u32(b * 8)) & 0xFF)
		}
	}
	return out
}

/*
把 wrap 结果（前 128 个 u32）复制到一个由 make 分配的固定大小数组。

这只是只读快照：Encoder.cache 仍然需要保持动态数组以承载 add 追加的段，
wrap 的写入位置也仍是 cache[0..107]，这样不会破坏 prompt.md 的 cache 布局。
*/
solution_snapshot :: proc(e: ^Encoder) -> []u32 {
	if len(e.cache) < MODE_PARAM_END {
		return make([]u32, MODE_PARAM_END)
	}
	out := make([]u32, MODE_PARAM_END)
	copy(out, e.cache[:MODE_PARAM_END])
	return out
}


