package oomap

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
@(private)
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
	// wrap 成功后会清理 entries（只读服务模式）；此时按需从 cache 重建，
	// 成功后立即释放，避免长期占用样本内存。
	if e.frozen && len(e.entries) == 0 {
		entries, err := entries_from_cache(e.cache[:])
		if err != .None {
			return false, VerifyBad{"<cache>", 0, 0}
		}
		ok, bad = verify_entries(e.cache[:], entries[:])
		if ok {
			free_entry_list(&entries)
		} else {
			// 保留 entries，使 bad.key 在调用方读取期间仍然有效；
			// encoder_destroy 会统一释放。
			e.entries = entries
		}
		return ok, bad
	}
	return verify_with(e, e.cache[:])
}

/*
使用指定的 cache 切片重放校验（wrap 在提交前对工作缓冲区调用）。
*/
@(private)
verify_with :: proc(e: ^Encoder, cache: []u32) -> (ok: bool, bad: Maybe(VerifyBad)) {
	return verify_entries(cache, e.entries[:])
}

@(private)
verify_entries :: proc(cache: []u32, entries: []Entry) -> (ok: bool, bad: Maybe(VerifyBad)) {
	if len(cache) < MODE_PARAM_END {
		return false, VerifyBad{"<cache>", MODE_PARAM_END, u32(len(cache))}
	}

	for entry in entries {
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
	start, words, found := locate_segment(e.cache[:], key, int(head))
	if !found {
		return nil, false
	}
	return unpack_words(e.cache[:], start, words), true
}

/*
读取 key 对应的**原始字节**，同时返回 add / add_framed 时传入的字节数。

与 read_data 的区别：
  - read_data 返回按 4 字节对齐的数据（末尾补 0），长度是 ceil(n/4)*4；
  - read_data_exact 去掉填充，len(data) 就是原始长度 n。

原始长度没有写进 cache（两种段格式都只存 u32 字数），而是由 Encoder 在
add / add_framed 时记录在内存表里。因此：
  - 同一个 Encoder 上（wrap 前后均可）返回精确长度；
  - 从 cache 重新构造的 Encoder 没有这张表，ok=false；
    此时如果调用方自己保存了原始长度，请用 read_data_exact_len。
*/
read_data_exact :: proc(e: ^Encoder, key: string) -> (data: []u8, length: int, ok: bool) {
	head, valid := eval(e.cache[:], key)
	if !valid {
		return nil, 0, false
	}
	exact, known := e.data_lens[head]
	if !known {
		return nil, 0, false
	}
	data, ok = read_segment_exact(e.cache[:], key, int(head), exact)
	if !ok {
		return nil, 0, false
	}
	return data, exact, true
}

/*
由调用方给出原始字节数的 read_data_exact。

用于只持有 cache（例如从磁盘恢复）的场景。会检查 length 不超过段内
u32 字数 * 4，并要求填充区全为 0，避免长度与段内容不一致时静默返回错误数据。
*/
read_data_exact_len :: proc(e: ^Encoder, key: string, length: int) -> (data: []u8, ok: bool) {
	head, valid := eval(e.cache[:], key)
	if !valid {
		return nil, false
	}
	return read_segment_exact(e.cache[:], key, int(head), length)
}

/*
返回 key 的原始字节数（仅当本 Encoder 记录过 add / add_framed 的长度）。
*/
data_length :: proc(e: ^Encoder, key: string) -> (length: int, ok: bool) {
	head, valid := eval(e.cache[:], key)
	if !valid {
		return 0, false
	}
	length, ok = e.data_lens[head]
	return length, ok
}

@(private)
locate_segment :: proc(cache: []u32, key: string, head: int) -> (start, words: int, ok: bool) {
	if head < 0 || head + 1 >= len(cache) {
		return 0, 0, false
	}

	switch cache[head] {
	case 0:
		return locate_segment_legacy(cache, key, head)
	case FRAME_START:
		return locate_segment_framed(cache, key, head)
	}
	return 0, 0, false
}

@(private)
locate_segment_legacy :: proc(cache: []u32, key: string, head: int) -> (start, words: int, ok: bool) {
	key_len := int(cache[head + 1])
	if key_len != len(key) {
		return 0, 0, false
	}
	key_words := (key_len + 3) / 4
	pos := head + 2
	if pos + key_words >= len(cache) || !packed_key_matches(cache, pos, key) {
		return 0, 0, false
	}
	pos += key_words

	if cache[pos] != SEGMENT_SEPARATOR {
		return 0, 0, false
	}
	pos += 1
	if pos >= len(cache) {
		return 0, 0, false
	}
	data_words := int(cache[pos])
	pos += 1
	if data_words < 0 || pos + data_words > len(cache) {
		return 0, 0, false
	}
	end := pos + data_words
	if end >= len(cache) || cache[end] != SEGMENT_SEPARATOR {
		return 0, 0, false
	}
	return pos, data_words, true
}

@(private)
locate_segment_framed :: proc(cache: []u32, key: string, head: int) -> (start, words: int, ok: bool) {
	if head + 2 >= len(cache) || cache[head + 2] != FRAME_KEY {
		return 0, 0, false
	}
	key_len := int(cache[head + 1])
	if key_len != len(key) {
		return 0, 0, false
	}
	key_words := (key_len + 3) / 4
	pos := head + 3
	if pos + key_words + 3 > len(cache) || !packed_key_matches(cache, pos, key) {
		return 0, 0, false
	}
	pos += key_words

	if cache[pos] != FRAME_DATA_LEN {
		return 0, 0, false
	}
	data_words := int(cache[pos + 1])
	pos += 2
	if cache[pos] != FRAME_DATA {
		return 0, 0, false
	}
	pos += 1
	if data_words < 0 || pos + data_words > len(cache) {
		return 0, 0, false
	}
	end := pos + data_words
	if end >= len(cache) || cache[end] != FRAME_END {
		return 0, 0, false
	}
	return pos, data_words, true
}

/*
按原始长度 exact 读取并去掉填充；填充区必须全为 0。
*/
@(private)
read_segment_exact :: proc(cache: []u32, key: string, head, exact: int) -> (data: []u8, ok: bool) {
	start, words, found := locate_segment(cache, key, head)
	if !found || exact < 0 || exact > words * 4 {
		return nil, false
	}
	for b in exact ..< words * 4 {
		word := cache[start + b / 4]
		if u8((word >> u32((b % 4) * 8)) & 0xFF) != 0 {
			return nil, false
		}
	}
	out := make([]u8, exact)
	for b in 0 ..< exact {
		word := cache[start + b / 4]
		out[b] = u8((word >> u32((b % 4) * 8)) & 0xFF)
	}
	return out, true
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


