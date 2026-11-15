package main

// test.csv 端到端测试：
//   - 读取程序同目录（也兼容当前目录 / bin 目录）下的 test.csv；
//   - 第一列为字符串 key，第二列为十六进制数据（可带空格，可为空）；
//   - 对每一行执行 add -> wrap -> verify -> read_data -> 与原始数据比对；
//   - 记录并打印总耗时与平均每行耗时。
//
// 可用 scripts/gen_test_csv.py 生成样本文件。

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

/*
查找 test.csv：优先 exe 同目录，其次当前目录、bin 目录。
*/
@(private)
find_test_csv :: proc() -> (path: string, ok: bool) {
	if dir, err := os.get_executable_directory(context.temp_allocator); err == nil {
		candidate := fmt.aprintf("%s\\test.csv", dir, allocator = context.temp_allocator)
		if os.exists(candidate) {
			return candidate, true
		}
	}
	for candidate in ([]string{"test.csv", "bin\\test.csv", "bin/test.csv"}) {
		if os.exists(candidate) {
			return candidate, true
		}
	}
	return "", false
}

@(private)
hex_nibble :: proc(c: rune) -> (u8, bool) {
	switch {
	case c >= '0' && c <= '9':
		return u8(c - '0'), true
	case c >= 'a' && c <= 'f':
		return u8(c - 'a' + 10), true
	case c >= 'A' && c <= 'F':
		return u8(c - 'A' + 10), true
	}
	return 0, false
}

/*
解析十六进制字符串（允许空格/制表符/下划线分隔）。空串表示空数据。
*/
@(private)
hex_to_bytes :: proc(hex: string) -> (data: []u8, ok: bool) {
	digits := make([dynamic]u8, 0, len(hex))
	defer delete(digits)

	for c in hex {
		switch c {
		case ' ', '\t', '\r', '_':
			continue
		}
		v, valid := hex_nibble(c)
		if !valid {
			return nil, false
		}
		append(&digits, v)
	}
	if len(digits) % 2 != 0 {
		return nil, false
	}

	out := make([]u8, len(digits) / 2)
	for i in 0 ..< len(out) {
		out[i] = (digits[i * 2] << 4) | digits[i * 2 + 1]
	}
	return out, true
}

/*
对一行数据跑完整链路，返回是否通过。
*/
@(private)
test_csv_row :: proc(key: string, data: []u8) -> bool {
	// 用一组隐藏参数决定目标 head；add 前把 cache 填充到该位置，
	// 这样 add 返回的段起点恰好等于目标，wrap 需要求出能映射到它的参数。
	hidden: [CHAR_COUNT]u32
	modes: [CHAR_COUNT]u32
	for i in 0 ..< CHAR_COUNT {
		hidden[i] = 200 + u32(i) * 7
	}
	target, ok := head_for(key, modes, hidden)
	if !ok {
		return false
	}

	e := encoder_init()
	defer encoder_destroy(&e)

	for len(e.cache) < int(target) {
		append(&e.cache, 0)
	}
	head, add_err := add(&e, key, data)
	if add_err != .None || head != target {
		return false
	}

	info: WrapInfo
	wrap_err := wrap_ex(&e, 5_000, &info)
	wrap_info_destroy(&info)
	if wrap_err != .None {
		return false
	}

	ok_verify, _ := verify(&e)
	if !ok_verify {
		return false
	}

	got, length, read_ok := read_data_exact(&e, key)
	defer delete(got)
	if !read_ok || length != len(data) || len(got) != len(data) {
		return false
	}
	for i in 0 ..< len(data) {
		if got[i] != data[i] {
			return false
		}
	}
	return true
}

/*
运行 test.csv 端到端测试。返回是否全部通过。
*/
run_csv_test :: proc() -> bool {
	path, found := find_test_csv()
	if !found {
		fmt.println("CSV: 未找到 test.csv（应位于 exe 同目录、当前目录或 bin 目录）")
		return false
	}
	fmt.println("CSV: file =", path)

	content, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.println("CSV: 读取失败:", err)
		return false
	}
	defer delete(content)

	lines, split_err := strings.split(string(content), "\n")
	if split_err != nil {
		fmt.println("CSV: 解析失败:", split_err)
		return false
	}
	defer delete(lines)

	start := time.tick_now()
	rows := 0
	passed := 0
	failed := 0
	line_no := 0

	for raw_line in lines {
		line_no += 1
		line := strings.trim_space(raw_line)
		if len(line) == 0 || line[0] == '#' {
			continue
		}
		// 只接受精确的表头文本，避免把以 "key..." 开头的真实 key 误判为表头。
		if rows == 0 && (line == "key,hex" || line == "字符串,十六进制数据") {
			continue
		}

		parts, part_err := strings.split(line, ",")
		if part_err != nil || len(parts) < 2 {
			failed += 1
			fmt.printf("CSV: 第 %d 行格式错误，已跳过\n", line_no)
			if len(parts) > 0 {
				delete(parts)
			}
			continue
		}

		key := strings.trim_space(parts[0])
		hex := strings.trim_space(parts[1])
		data, data_ok := hex_to_bytes(hex)

		ok := false
		if data_ok && len(key) > 0 {
			ok = test_csv_row(key, data)
		}
		if ok {
			passed += 1
		} else {
			failed += 1
			fmt.printf("CSV: 第 %d 行失败 key=%q\n", line_no, key)
		}
		rows += 1

		if data_ok {
			delete(data)
		}
		delete(parts)
	}

	elapsed := time.duration_milliseconds(time.tick_since(start))
	fmt.printf(
		"CSV: rows=%d passed=%d failed=%d elapsed=%.1fms avg=%.2fms\n",
		rows, passed, failed, elapsed,
		0.0 if rows == 0 else elapsed / f64(rows),
	)
	return failed == 0 && rows > 0
}

