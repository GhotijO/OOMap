package main

// 64 字符地址编码器 —— demo 与独立进程验收入口
//
// 默认运行 demo：add 若干样本 → wrap → verify。
// 由于 Odin 测试运行器在 Windows 上会拦截 Z3 内部的异常（Vectored Exception
// Handler），涉及 Z3 的验收项改用独立进程：
//
//   OOMap.exe --check-z3            验证 family 3 / 超时
//   OOMap.exe --check-missing-z3    验证缺 Z3 降级（需先隐藏 libz3.dll）
//
// 运行前请确保 libz3.dll 可被找到（bin/libz3.dll 或 lib/libz3.dll）。

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

main :: proc() {
	if len(os.args) > 1 {
		switch os.args[1] {
		case "--check-z3":
			ok := check_z3()
			fmt.println(ok ? "Z3 CHECKS: PASS" : "Z3 CHECKS: FAIL")
			os.exit(0 if ok else 1)
		case "--check-missing-z3":
			ok := check_missing_z3()
			fmt.println(ok ? "MISSING-Z3 CHECK: PASS" : "MISSING-Z3 CHECK: FAIL")
			os.exit(0 if ok else 1)
		case "--check-pure":
			ok := check_pure()
			fmt.println(ok ? "PURE CHECK: PASS" : "PURE CHECK: FAIL")
			os.exit(0 if ok else 1)
		case "--test-csv":
			ok := run_csv_test()
			fmt.println(ok ? "CSV TEST: PASS" : "CSV TEST: FAIL")
			os.exit(0 if ok else 1)
		}
	}
	demo()
}

@(private)
make_minimal_encoder :: proc() -> Encoder {
	e := encoder_init()
	k1, _ := strings.clone("A")
	k2, _ := strings.clone("AA")
	append(&e.entries, Entry{key = k1, head = 3})
	append(&e.entries, Entry{key = k2, head = 3})
	return e
}

// 只有 family 3（MOD）才能求解的样本：
// 对 Σ 的每个字符 c，head 都是 h，key 为 "c" 与 "cc"。
@(private)
make_mod_only_encoder :: proc() -> Encoder {
	e := encoder_init()
	sigma := SIGMA
	for i in 0 ..< CHAR_COUNT {
		ch := rune(sigma[i])
		h: u32 = u32(1 + i % 15)
		key1 := fmt.aprintf("%c", ch)
		key2 := fmt.aprintf("%c%c", ch, ch)
		k1, _ := strings.clone(key1)
		k2, _ := strings.clone(key2)
		append(&e.entries, Entry{key = k1, head = h})
		append(&e.entries, Entry{key = k2, head = h})
	}
	return e
}

/*
独立进程验收：family 3 最小 |p| + 超时。
*/
@(private)
check_z3 :: proc() -> bool {
	ok := true

	// 1) 多解最小 |p|：MOD 的 p=4 是 31%p=3 且 3%p=3 的最小解。
	{
		e := make_minimal_encoder()
		defer encoder_destroy(&e)
		info: WrapInfo
		err := wrap_ex(&e, 10_000, &info)
		defer wrap_info_destroy(&info)

		verify_ok, _ := verify(&e)
		a_idx, _ := char_index('A')
		pass := err == .None &&
			info.solved_family == 3 &&
			e.cache[int(a_idx)] == 3 &&
			e.cache[PARAM_OFFSET + int(a_idx)] == 4 &&
			verify_ok
		fmt.printf("CHECK minimal: %s (err=%v family=%d mode[A]=%d param[A]=%d verify=%v)\n",
			pass ? "PASS" : "FAIL", err, info.solved_family, e.cache[int(a_idx)], e.cache[PARAM_OFFSET + int(a_idx)], verify_ok)
		ok = ok && pass
	}

	// 2) 超时：family 0 无解、只剩 family 3，100ms 预算内无法完成。
	{
		e := make_mod_only_encoder()
		defer encoder_destroy(&e)
		info: WrapInfo
		start := time.tick_now()
		err := wrap_ex(&e, 100, &info)
		elapsed := time.duration_milliseconds(time.tick_since(start))
		defer wrap_info_destroy(&info)

		pass := err == .Timeout && elapsed >= 90
		fmt.printf("CHECK timeout: %s (err=%v elapsed=%.1fms)\n", pass ? "PASS" : "FAIL", err, elapsed)
		ok = ok && pass
	}

	return ok
}

/*
独立进程验收：隐藏 libz3.dll 后，family 0 仍工作，family 1..3 返回 MissingZ3。
*/
@(private)
check_pure :: proc() -> bool {
	// 往返测试与性能：用隐藏参数生成一致的 (key, head)，再 wrap + verify。
	all_ok := true
	for n in ([]int{5, 20, 64, 65, 1000}) {
		hidden: [CHAR_COUNT]u32
		modes: [CHAR_COUNT]u32
		for i in 0 ..< CHAR_COUNT {
			hidden[i] = u32(0x9E37_79B9) * u32(i + 1) + u32(n)
		}

		e := encoder_init()
		state: u64 = 0x1234_5678_9ABC_DEF0 + u64(n)
		seen := make(map[string]bool)
		for len(e.entries) < n {
			key := random_key(&state)
			if key in seen {
				delete(key)
				continue
			}
			seen[key] = true
			head, _ := head_for(key, modes, hidden)
			append(&e.entries, Entry{key = key, head = head})
		}
		delete(seen)

		info: WrapInfo
		start := time.tick_now()
		err := wrap_ex(&e, 30_000, &info)
		elapsed := time.duration_milliseconds(time.tick_since(start))
		verify_ok, _ := verify(&e)

		pass := err == .None && verify_ok
		if n == 1000 {
			pass = pass && elapsed < 1000.0
		}
		fmt.printf("CHECK roundtrip n=%d: %s (err=%v family=%d verify=%v %.1fms)\n",
			n, pass ? "PASS" : "FAIL", err, info.solved_family, verify_ok, elapsed)
		all_ok = all_ok && pass

		wrap_info_destroy(&info)
		encoder_destroy(&e)
	}
	return all_ok
}

@(private)
check_missing_z3 :: proc() -> bool {
	ok := true
	if z3_available() {
		fmt.println("CHECK missing-z3: FAIL（libz3.dll 仍可加载，请先隐藏它）")
		return false
	}

	// family 3 才能解 -> MissingZ3
	{
		e := make_minimal_encoder()
		defer encoder_destroy(&e)
		info: WrapInfo
		err := wrap_ex(&e, 5_000, &info)
		defer wrap_info_destroy(&info)
		pass := err == .MissingZ3
		fmt.printf("CHECK missing-z3(family3): %s (err=%v)\n", pass ? "PASS" : "FAIL", err)
		ok = ok && pass
	}

	// family 0 仍可工作
	{
		e := encoder_init()
		defer encoder_destroy(&e)
		k, _ := strings.clone("A")
		append(&e.entries, Entry{key = k, head = u32(X0) + 9})
		info: WrapInfo
		err := wrap_ex(&e, 5_000, &info)
		defer wrap_info_destroy(&info)
		verify_ok, _ := verify(&e)
		pass := err == .None && info.solved_family == 0 && verify_ok
		fmt.printf("CHECK missing-z3(family0): %s (err=%v family=%d verify=%v)\n",
			pass ? "PASS" : "FAIL", err, info.solved_family, verify_ok)
		ok = ok && pass
	}

	return ok
}

@(private)
demo :: proc() {
	fmt.println("== 64 字符地址编码器 demo ==")
	fmt.println("Z3 状态:", z3_available() ? z3_version_string() : "不可用（family 1..3 将返回 MissingZ3）")
	fmt.println()

	e := encoder_init()
	defer encoder_destroy(&e)

	// 隐藏参数：仅用于生成目标 head。add 会把段放在 cache 的当前末尾，
	// 因此先把 cache 填充到目标 head，使 add 返回的段起点恰好等于目标值。
	hidden: [CHAR_COUNT]u32
	for i in 0 ..< CHAR_COUNT {
		hidden[i] = 200 + u32(i) * 7
	}
	base: [RESERVED_LEN]u32
	for i in 0 ..< CHAR_COUNT {
		base[i] = 0 // 全部 ADD
		base[PARAM_OFFSET + i] = hidden[i]
	}

	keys := []string{"A", "B", "Z", "AB", "AAB", "BA", "ZZ", "OOMap", "_z"}
	data := []u8{0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01}

	fmt.println("[add]")
	for key in keys {
		target, ok := eval(base[:], key)
		if !ok {
			fmt.println("  key 非法:", key)
			continue
		}
		if int(target) < len(e.cache) {
			fmt.printf("  跳过 %s：目标 head=%d 已被更早的段占用\n", key, target)
			continue
		}
		for len(e.cache) < int(target) {
			append(&e.cache, 0)
		}
		head, err := add(&e, key, data)
		if err != .None {
			fmt.println("  add 失败:", key, err)
			continue
		}
		fmt.printf("  key=%-6s head=%d\n", key, head)
	}

	info: WrapInfo
	defer wrap_info_destroy(&info)

	err := wrap_ex(&e, 30_000, &info)
	fmt.println()
	fmt.println("[wrap]")
	#partial switch err {
	case .None:
		fmt.println("  结果: 成功，命中 family", info.solved_family)
	case .MissingZ3:
		fmt.println("  结果: .MissingZ3 — 安装/放置 Z3 后重试")
	case .Timeout:
		fmt.println("  结果: .Timeout — 可增大 timeout_ms")
	case .Infeasible:
		fmt.println("  结果: .Infeasible")
	case:
		fmt.println("  结果:", err)
	}
	if len(info.message) > 0 {
		fmt.println("  说明:", info.message)
	}

	if err == .None {
		ok, bad := verify(&e)
		fmt.println()
		fmt.println("[verify]")
		fmt.println("  纯 Odin 重放:", ok ? "全部通过" : "失败")
		if b, has := bad.?; has {
			fmt.printf("  首个不匹配: key=%s want=%d got=%d\n", b.key, b.want, b.got)
		}

		_, add_err := add(&e, "Q", data)
		fmt.println("  frozen 后 add:", add_err)
	}

	// 第二个场景：只有 family 3（MOD）能解，用来演示 Z3 路径与缺 Z3 降级。
	fmt.println()
	fmt.println("== family 3 场景（MOD，需要 Z3） ==")
	e2 := make_minimal_encoder()
	defer encoder_destroy(&e2)
	info2: WrapInfo
	defer wrap_info_destroy(&info2)
	err2 := wrap_ex(&e2, 5_000, &info2)
	#partial switch err2 {
	case .None:
		fmt.println("  结果: 成功，命中 family", info2.solved_family)
		ok2, _ := verify(&e2)
		a_idx, _ := char_index('A')
		fmt.printf("  verify: %v；param[A]=%d mode[A]=%d\n", ok2, e2.cache[PARAM_OFFSET + int(a_idx)], e2.cache[int(a_idx)])
	case .MissingZ3:
		fmt.println("  结果: .MissingZ3 — 缺 Z3 时 family 0 仍可用，family 1..3 未尝试")
	case .Timeout:
		fmt.println("  结果: .Timeout")
	case .Infeasible:
		fmt.println("  结果: .Infeasible")
	case:
		fmt.println("  结果:", err2)
	}
}



