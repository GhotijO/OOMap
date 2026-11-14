package main

// 64 字符地址编码器 —— 数据结构与 add 接口
//
// 对应原始任务规格第 3、4、6 节。

import "core:strings"

ErrorCode :: enum u8 {
	None,
	EmptyKey,
	InvalidCharacter,
	DuplicateKey,
	Frozen,
	Infeasible,
	Timeout,
	MissingZ3,
	InternalError,
}

Entry :: struct {
	key:  string, // 非空、不含 0、只含 Σ 字符
	head: u32, // 该段在 cache 中第一个 u32 的索引
}

Encoder :: struct {
	cache:   [dynamic]u32, // 初始长度 256，全 0
	entries: [dynamic]Entry,
	frozen:  bool,
}

// 保留区布局（cache[0..255]）
MODE_OFFSET :: 0 // 0..63    mode[i]
PARAM_OFFSET :: 64 // 64..127  param[i]
MODE_PARAM_END :: 128 // 128..255 保留
RESERVED_LEN :: 256

// add 段内使用的辅助 marker
SEGMENT_SEPARATOR :: 0x0000FFFF

// add_framed 段内使用的帧标记
FRAME_START :: 0xFF00FF00
FRAME_KEY :: 0xFF00FF02
FRAME_DATA_LEN :: 0xFF00FF04
FRAME_DATA :: 0xFF00FF08
FRAME_END :: 0xFF00FF0F

/*
创建空编码器：cache 长度为 256 且全 0，entries 为空。
*/
encoder_init :: proc() -> Encoder {
	e: Encoder
	resize(&e.cache, RESERVED_LEN)
	for i in 0 ..< RESERVED_LEN {
		e.cache[i] = 0
	}
	e.entries = make([dynamic]Entry)
	return e
}

/*
释放编码器持有的内存（包括 add 时克隆的 key）。
*/
encoder_destroy :: proc(e: ^Encoder) {
	for entry in e.entries {
		delete(entry.key)
	}
	delete(e.entries)
	delete(e.cache)
	e^ = Encoder{}
}

/*
向编码器追加一个样本段。

成功时返回段起点 head 与 .None；失败时不修改任何状态。
*/
add :: proc(e: ^Encoder, key: string, data: []u8) -> (head: u32, err: ErrorCode) {
	if err2 := check_addable(e, key); err2 != .None {
		return 0, err2
	}

	head = u32(len(e.cache))

	// [0x00000000] 段起始 marker
	append(&e.cache, 0)

	// [u32(key_len)]
	append(&e.cache, u32(len(key)))

	// [packed_key; (key_len + 3) / 4 个 u32]，小端打包，末位补 0
	key_words := (len(key) + 3) / 4
	for w in 0 ..< key_words {
		word: u32 = 0
		for b in 0 ..< 4 {
			pos := w * 4 + b
			if pos < len(key) {
				word |= u32(key[pos]) << u32(b * 8)
			}
		}
		append(&e.cache, word)
	}

	// [0x0000FFFF] 分隔符
	append(&e.cache, SEGMENT_SEPARATOR)

	// [u32((data_len + 3) / 4)]
	data_words := (len(data) + 3) / 4
	append(&e.cache, u32(data_words))

	// [packed_data; ...] 小端打包，末位补 0
	for w in 0 ..< data_words {
		word: u32 = 0
		for b in 0 ..< 4 {
			pos := w * 4 + b
			if pos < len(data) {
				word |= u32(data[pos]) << u32(b * 8)
			}
		}
		append(&e.cache, word)
	}

	// [0x0000FFFF] 段结束 marker
	append(&e.cache, SEGMENT_SEPARATOR)

	key_copy, _ := strings.clone(key)
	append(&e.entries, Entry{key = key_copy, head = head})
	return head, .None
}

/*
与 add 相同的校验与 Entry 语义，但使用 0xFF00FFxx 帧格式把数据追加到 cache 尾部：

	[0xFF00FF00][u32 key_len][0xFF00FF02]
	[packed_key; (key_len + 3) / 4 个 u32，小端，末位补 0]
	[0xFF00FF04][u32((data_len + 3) / 4)][0xFF00FF08]
	[packed_data; 每 4 个 u8 占一个 u32，小端，末位补 0]
	[0xFF00FF0F]

返回段起点 head，并把它与字符串 key 组装成 Entry 追加到 e.entries。
失败时返回 .Frozen / .EmptyKey / .InvalidCharacter / .DuplicateKey，且不修改状态。
*/
add_framed :: proc(e: ^Encoder, key: string, data: []u8) -> (head: u32, err: ErrorCode) {
	if err2 := check_addable(e, key); err2 != .None {
		return 0, err2
	}

	head = u32(len(e.cache))

	// [0xFF00FF00][u32 key_len][0xFF00FF02]
	append(&e.cache, FRAME_START)
	append(&e.cache, u32(len(key)))
	append(&e.cache, FRAME_KEY)

	// [packed_key; (key_len + 3) / 4 个 u32]
	key_words := (len(key) + 3) / 4
	for w in 0 ..< key_words {
		word: u32 = 0
		for b in 0 ..< 4 {
			pos := w * 4 + b
			if pos < len(key) {
				word |= u32(key[pos]) << u32(b * 8)
			}
		}
		append(&e.cache, word)
	}

	// [0xFF00FF04][u32((data_len + 3) / 4)][0xFF00FF08]
	data_words := (len(data) + 3) / 4
	append(&e.cache, FRAME_DATA_LEN)
	append(&e.cache, u32(data_words))
	append(&e.cache, FRAME_DATA)

	// [packed_data; ...]
	for w in 0 ..< data_words {
		word: u32 = 0
		for b in 0 ..< 4 {
			pos := w * 4 + b
			if pos < len(data) {
				word |= u32(data[pos]) << u32(b * 8)
			}
		}
		append(&e.cache, word)
	}

	// [0xFF00FF0F]
	append(&e.cache, FRAME_END)

	key_copy, _ := strings.clone(key)
	append(&e.entries, Entry{key = key_copy, head = head})
	return head, .None
}

/*
add 与 add_framed 共用的入参校验：frozen / 空 key / 字符集 / 重复 key。
*/
@(private)
check_addable :: proc(e: ^Encoder, key: string) -> ErrorCode {
	if e.frozen {
		return .Frozen
	}
	if len(key) == 0 {
		return .EmptyKey
	}
	for ch in key {
		if _, ok := char_index(ch); !ok {
			return .InvalidCharacter
		}
	}
	for entry in e.entries {
		if entry.key == key {
			return .DuplicateKey
		}
	}
	return .None
}

/*
从 cache（[]u32）中还原出 Entry 列表。

从 cache[RESERVED_LEN] 开始顺序解析；支持 add 的 0x0000/0xFFFF 段与
add_framed 的 0xFF00FFxx 段，遇到 0 填充会跳过。返回的 Entry.key 是新分配的，
调用方需要逐个 delete(entry.key) 后再 delete(entries)。
*/
entries_from_cache :: proc(cache: []u32) -> (entries: [dynamic]Entry, err: ErrorCode) {
	entries = make([dynamic]Entry)
	if len(cache) < RESERVED_LEN {
		return entries, .InternalError
	}

	pos := RESERVED_LEN
	for pos < len(cache) {
		switch cache[pos] {
		case 0:
			if key, next, ok := parse_legacy_entry(cache, pos); ok {
				append(&entries, Entry{key = key, head = u32(pos)})
				pos = next
			} else if cache[pos] == 0 {
				// 段间 0 填充
				pos += 1
			} else {
				return entries, .InternalError
			}
		case FRAME_START:
			key, next, ok := parse_framed_entry(cache, pos)
			if !ok {
				free_entry_list(&entries)
				return entries, .InternalError
			}
			append(&entries, Entry{key = key, head = u32(pos)})
			pos = next
		case:
			free_entry_list(&entries)
			return entries, .InternalError
		}
	}
	return entries, .None
}

@(private)
free_entry_list :: proc(entries: ^[dynamic]Entry) {
	for entry in entries^ {
		delete(entry.key)
	}
	delete(entries^)
	entries^ = nil
}

@(private)
parse_legacy_entry :: proc(cache: []u32, head: int) -> (key: string, next: int, ok: bool) {
	if head + 1 >= len(cache) {
		return "", 0, false
	}
	key_len := int(cache[head + 1])
	key_words := (key_len + 3) / 4
	key_start := head + 2
	sep := key_start + key_words
	if sep >= len(cache) || cache[sep] != SEGMENT_SEPARATOR {
		return "", 0, false
	}
	data_words_pos := sep + 1
	if data_words_pos >= len(cache) {
		return "", 0, false
	}
	data_words := int(cache[data_words_pos])
	end := data_words_pos + 1 + data_words
	if end >= len(cache) || cache[end] != SEGMENT_SEPARATOR {
		return "", 0, false
	}
	key, ok = unpack_key(cache, key_start, key_len)
	return key, end + 1, ok
}

@(private)
parse_framed_entry :: proc(cache: []u32, head: int) -> (key: string, next: int, ok: bool) {
	if head + 2 >= len(cache) || cache[head + 2] != FRAME_KEY {
		return "", 0, false
	}
	key_len := int(cache[head + 1])
	key_words := (key_len + 3) / 4
	key_start := head + 3
	pos := key_start + key_words
	if pos + 2 >= len(cache) || cache[pos] != FRAME_DATA_LEN {
		return "", 0, false
	}
	data_words := int(cache[pos + 1])
	pos += 2
	if pos >= len(cache) || cache[pos] != FRAME_DATA {
		return "", 0, false
	}
	pos += 1
	end := pos + data_words
	if end >= len(cache) || cache[end] != FRAME_END {
		return "", 0, false
	}
	key, ok = unpack_key(cache, key_start, key_len)
	return key, end + 1, ok
}

/*
从 cache 的打包区还原字符串并校验字符集。
*/
@(private)
unpack_key :: proc(cache: []u32, start, key_len: int) -> (key: string, ok: bool) {
	if key_len == 0 {
		return "", false
	}
	bytes := make([]u8, key_len)
	defer delete(bytes)
	for b in 0 ..< key_len {
		word := cache[start + b / 4]
		bytes[b] = u8((word >> u32((b % 4) * 8)) & 0xFF)
	}
	for b in bytes {
		if _, valid := char_index(rune(b)); !valid {
			return "", false
		}
	}
	key, _ = strings.clone_from_bytes(bytes)
	return key, true
}

