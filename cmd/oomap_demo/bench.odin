package main

// 性能基准（仅在 demo 进程中运行，不属于库 API）。
//
// 运行：bin\OOMap.exe --bench
//
// 所有计时都只包含被测量函数本身：生成 key、构造 Entry 等准备工作放在计时之外。

import "core:fmt"
import "core:time"

@(private)
bench_ms :: proc(start: time.Tick) -> f64 {
	return time.duration_milliseconds(time.tick_since(start))
}

@(private)
bench_free_keys :: proc(keys: ^[dynamic]string) {
	for key in keys^ {
		delete(key)
	}
	delete(keys^)
}

@(private)
bench_unique_keys :: proc(n: int, seed: u64) -> [dynamic]string {
	keys := make([dynamic]string, 0, n)
	seen := make(map[string]bool)
	state := seed
	for len(keys) < n {
		key := random_key(&state, 4, 10)
		if key in seen {
			delete(key)
			continue
		}
		seen[key] = true
		append(&keys, key)
	}
	delete(seen)
	return keys
}

/*
add 的吞吐：重复 key 检查是 O(n) 线性扫描，整体 O(n^2)，是批量导入的主要瓶颈。
*/
@(private)
bench_add :: proc() {
	data := []u8{0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04}
	for n in ([]int{1000, 5000, 10_000}) {
		keys := bench_unique_keys(n, 0x1000 + u64(n))
		e := encoder_init()

		start := time.tick_now()
		added := 0
		for key in keys {
			_, err := add(&e, key, data)
			if err != .None {
				break
			}
			added += 1
		}
		elapsed := bench_ms(start)

		fmt.printf(
			"BENCH add: n=%d %.2fms (%.3f us/entry) cache=%d words\n",
			added, elapsed, elapsed * 1000.0 / f64(added), len(e.cache),
		)

		encoder_destroy(&e)
		bench_free_keys(&keys)
	}
}

/*
family 0 求解 + verify：n 条样本、64 个未知数。
*/
@(private)
bench_wrap :: proc() {
	for n in ([]int{100, 1000, 5000}) {
		e := encoder_init()
		hidden: [CHAR_COUNT]u32
		modes: [CHAR_COUNT]u32
		for i in 0 ..< CHAR_COUNT {
			hidden[i] = 200 + u32(i) * 7
		}

		keys := bench_unique_keys(n, 0x2000 + u64(n))
		for key in keys {
			head, ok := head_for(key, modes, hidden)
			if !ok {
				continue
			}
			append(&e.entries, Entry{key = key, head = head})
		}
		// keys 的所有权已交给 entries。
		delete(keys)

		info: WrapInfo
		start := time.tick_now()
		err := wrap_ex(&e, 30_000, &info)
		wrap_elapsed := bench_ms(start)

		verify_ok := false
		verify_ms := 0.0
		if err == .None {
			verify_ok, _ = verify(&e)
			VERIFY_ITERS :: 100
			verify_start := time.tick_now()
			for _ in 0 ..< VERIFY_ITERS {
				verify(&e)
			}
			verify_ms = bench_ms(verify_start) / f64(VERIFY_ITERS)
		}

		fmt.printf(
			"BENCH wrap: n=%d %.2fms (%.3f us/entry) family=%d verify=%.3fms ok=%v\n",
			n, wrap_elapsed, wrap_elapsed * 1000.0 / f64(n),
			info.solved_family, verify_ms, verify_ok && err == .None,
		)

		wrap_info_destroy(&info)
		encoder_destroy(&e)
	}
}

/*
read_data / read_data_exact 微基准：单段、13 字节（会触发 3 字节填充）。
*/
@(private)
bench_read :: proc() {
	e := encoder_init()
	defer encoder_destroy(&e)

	TARGET :: 300
	for len(e.cache) < TARGET {
		append(&e.cache, 0)
	}
	data := []u8{0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D}
	_, add_err := add(&e, "A", data)
	if add_err != .None {
		fmt.println("BENCH read: add failed:", add_err)
		return
	}
	info: WrapInfo
	defer wrap_info_destroy(&info)
	if err := wrap_ex(&e, 5_000, &info); err != .None {
		fmt.println("BENCH read: wrap failed:", err)
		return
	}

	ITERS :: 100_000
	start := time.tick_now()
	for _ in 0 ..< ITERS {
		d, ok := read_data(&e, "A")
		if !ok {
			fmt.println("BENCH read: read_data failed")
			return
		}
		delete(d)
	}
	padded_ms := bench_ms(start)

	start = time.tick_now()
	for _ in 0 ..< ITERS {
		d, n, ok := read_data_exact(&e, "A")
		if !ok || n != len(data) {
			fmt.println("BENCH read: read_data_exact failed")
			return
		}
		delete(d)
	}
	exact_ms := bench_ms(start)

	fmt.printf(
		"BENCH read: iters=%d read_data=%.1fns/op read_data_exact=%.1fns/op\n",
		ITERS,
		padded_ms * 1_000_000.0 / f64(ITERS),
		exact_ms * 1_000_000.0 / f64(ITERS),
	)
}

/*
entries_from_cache：按段顺序解析整份 cache（含 key 的分配与克隆）。
*/
@(private)
bench_entries :: proc() {
	data := []u8{0x11, 0x22, 0x33, 0x44, 0x55}
	for n in ([]int{1000, 5000}) {
		e := encoder_init()
		keys := bench_unique_keys(n, 0x3000 + u64(n))
		for key in keys {
			add(&e, key, data)
		}
		bench_free_keys(&keys)

		start := time.tick_now()
		entries, err := entries_from_cache(e.cache[:])
		elapsed := bench_ms(start)

		parsed := len(entries)
		for entry in entries {
			delete(entry.key)
		}
		delete(entries)
		encoder_destroy(&e)

		fmt.printf(
			"BENCH entries_from_cache: n=%d parsed=%d %.2fms (%.3f us/entry) err=%v\n",
			n, parsed, elapsed, elapsed * 1000.0 / f64(n), err,
		)
	}
}

@(private)
bench_z3 :: proc() {
	if !z3_available() {
		fmt.println("BENCH z3: 跳过（libz3 不可用）")
		return
	}

	// 最小 family 3 场景：A / AA 共享 head=3，ADD 下 2p 与 p 矛盾，必须用 MOD。
	e := make_minimal_encoder()
	defer encoder_destroy(&e)

	info: WrapInfo
	start := time.tick_now()
	err := wrap_ex(&e, 10_000, &info)
	elapsed := bench_ms(start)
	verify_ok := false
	if err == .None {
		verify_ok, _ = verify(&e)
	}
	fmt.printf(
		"BENCH z3: n=%d %.2fms family=%d verify=%v err=%v\n",
		len(e.entries), elapsed, info.solved_family, verify_ok, err,
	)
	wrap_info_destroy(&info)
}

/*
压力场景：64 个字符 × 2 条样本（共 128 条）只有 MOD 能解。
Optimize 的耗时可能远超 timeout_ms，用于观察最坏情况；单独用 --bench-z3-stress 触发。
*/
@(private)
bench_z3_stress :: proc() {
	if !z3_available() {
		fmt.println("BENCH z3-stress: 跳过（libz3 不可用）")
		return
	}
	e := make_mod_only_encoder()
	defer encoder_destroy(&e)

	info: WrapInfo
	start := time.tick_now()
	err := wrap_ex(&e, 10_000, &info)
	elapsed := bench_ms(start)
	fmt.printf(
		"BENCH z3-stress: n=%d %.2fms (timeout_ms=10000) family=%d err=%v\n",
		len(e.entries), elapsed, info.solved_family, err,
	)
	wrap_info_destroy(&info)
}

@(private)
bench :: proc() {
	fmt.println("== benchmark ==")
	fmt.println("注意：计时只包含被测函数；add 的 key 生成在计时之外。")
	bench_add()
	bench_wrap()
	bench_read()
	bench_entries()
	bench_z3()
}
