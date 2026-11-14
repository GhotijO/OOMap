package main

// 64 字符地址编码器 —— wrap 主流程、family 调度、Z3 建模
//
// 对应 prompt.md 第 5、7、10 节：
//   family 0：纯 Odin 线性求解（ADD）
//   family 1：Z3，mode ∈ {ADD, SUB}
//   family 2：Z3，mode ∈ {ADD, SUB, XOR}
//   family 3：Z3，mode ∈ {ADD, SUB, XOR, MOD}
//
// 求解始终在“工作缓冲区”进行，verify 通过后才一次性写入 e.cache；任何失败都不修改 cache。

import "core:fmt"
import "core:time"

Family :: enum u8 {
	Pure    = 0,
	AddSub  = 1,
	AddXor  = 2,
	Full    = 3,
}

WrapInfo :: struct {
	families_tried: [4]bool,
	solved_family:  int, // -1 表示没有 family 成功
	missing_z3:     bool,
	timed_out:      bool,
	message:        string, // 由 wrap_info_destroy 释放
}

wrap_info_destroy :: proc(info: ^WrapInfo) {
	if len(info.message) > 0 {
		delete(info.message)
	}
	info^ = WrapInfo{solved_family = -1}
}

/*
wrap 的便捷入口（丢弃诊断信息）。
*/
wrap :: proc(e: ^Encoder, timeout_ms: u32 = 30_000) -> ErrorCode {
	info: WrapInfo
	defer wrap_info_destroy(&info)
	return wrap_ex(e, timeout_ms, &info)
}

/*
wrap 主流程。

timeout_ms 是整个 wrap 的总预算（不是每个 family 各一份）。
成功时写入 e.cache 并置 frozen=true；失败时 cache 保持不变。
*/
wrap_ex :: proc(e: ^Encoder, timeout_ms: u32, info: ^WrapInfo) -> ErrorCode {
	info^ = WrapInfo {
		solved_family = -1,
	}

	if e.frozen {
		info.message = fmt.aprintf("wrap: 编码器已 frozen，拒绝修改")
		return .Frozen
	}

	if len(e.entries) == 0 {
		e.frozen = true
		info.message = fmt.aprintf("wrap: entries 为空，保持保留区为 0 并置 frozen")
		return .None
	}

	// 防御性检查：重复 key、非法字符。
	heads := make(map[string]u32)
	defer delete(heads)

	for entry in e.entries {
		for ch in entry.key {
			if _, ok := char_index(ch); !ok {
				info.message = fmt.aprintf("wrap: entry %q 含非法字符，cache 未修改", entry.key)
				return .InternalError
			}
		}
		if prev, exists := heads[entry.key]; exists {
			if prev != entry.head {
				info.message = fmt.aprintf(
					"wrap: 同一 key %q 出现两个不同 head（%d vs %d），约束互相矛盾，判定 Infeasible",
					entry.key, prev, entry.head,
				)
				return .Infeasible
			}
			info.message = fmt.aprintf("wrap: 存在重复 key %q，cache 未修改", entry.key)
			return .DuplicateKey
		}
		heads[entry.key] = entry.head
	}

	if timeout_ms == 0 {
		info.timed_out = true
		info.message = fmt.aprintf("wrap: timeout_ms=0，预算立即耗尽")
		return .Timeout
	}

	start := time.tick_now()
	budget_ms := i64(timeout_ms)

	for family in 0 ..< 4 {
		remaining := budget_ms - elapsed_ms(start)
		if remaining <= 0 {
			info.timed_out = true
			break
		}

		switch family {
		case 0:
			info.families_tried[0] = true
			ok, modes, params := pure_solve(e)
			if ok {
				if commit_solution(e, modes, params, 0) {
					info.solved_family = 0
					info.message = fmt.aprintf("wrap: family 0（纯 Odin 高斯消元）求解成功，verify 通过")
					return .None
				}
			}
		case 1, 2, 3:
			if !z3_available() {
				info.missing_z3 = true
				continue
			}
			info.families_tried[family] = true
			res, modes, params := z3_solve_family(e, family, u32(remaining))
			switch res {
			case .Sat:
				if commit_solution(e, modes, params, family) {
					info.solved_family = int(family)
					info.message = fmt.aprintf("wrap: family %d（Z3）求解成功，verify 通过", family)
					return .None
				}
			case .Unsat:
			// 继续尝试下一档
			case .Timeout:
				info.timed_out = true
			case .Error:
			// 继续尝试下一档
			}
			if info.timed_out {
				break
			}
		}
	}

	switch {
	case info.timed_out:
		info.message = fmt.aprintf(
			"wrap: 超时（总预算 %d ms），已尝试 family %s；未找到可 verify 的解",
			timeout_ms, tried_families_string(info),
		)
		return .Timeout
	case info.missing_z3:
		info.message = fmt.aprintf(
			"wrap: Z3 动态库不可用（libz3.dll 未找到），family 1..3 未尝试；安装 Z3 后重试。已尝试 family %s",
			tried_families_string(info),
		)
		return .MissingZ3
	}

	message := fmt.aprintf(
		"wrap: 所有 family 均无解（Infeasible），已尝试 family %s；样本数 %d，字符数 %d",
		tried_families_string(info), len(e.entries), CHAR_COUNT,
	)
	if len(e.entries) > CHAR_COUNT {
		message = fmt.aprintf(
			"%s；线性独立约束数超过自由参数数，需扩展 family 或引入 padding",
			message,
		)
	}
	if info.families_tried[3] {
		message = fmt.aprintf(
			"%s；若因回绕/非线性导致全族无解，确认输入是否来自单字符固定操作模型",
			message,
		)
	}
	info.message = message
	return .Infeasible
}

@(private)
elapsed_ms :: proc(start: time.Tick) -> i64 {
	return i64(time.duration_milliseconds(time.tick_since(start)))
}

@(private)
tried_families_string :: proc(info: ^WrapInfo) -> string {
	buf: [32]u8
	n := 0
	for i in 0 ..< 4 {
		if info.families_tried[i] {
			if n > 0 {
				buf[n] = ','
				n += 1
			}
			buf[n] = u8('0' + i)
			n += 1
		}
	}
	if n == 0 {
		return "none"
	}
	return fmt.aprintf("%s", string(buf[:n]))
}

/*
把候选解写入工作缓冲区，verify 通过后才提交到 e.cache。
*/
@(private)
commit_solution :: proc(e: ^Encoder, modes, params: [CHAR_COUNT]u32, family: int) -> bool {
	max_mode := u32(family)
	work: [MODE_PARAM_END]u32
	for i in 0 ..< MODE_PARAM_END {
		work[i] = e.cache[i]
	}
	for i in 0 ..< CHAR_COUNT {
		if modes[i] > max_mode || modes[i] > 3 {
			return false
		}
		work[i] = modes[i]
		work[PARAM_OFFSET + i] = params[i]
	}

	ok, _ := verify_with(e, work[:])
	if !ok {
		return false
	}

	for i in 0 ..< MODE_PARAM_END {
		e.cache[i] = work[i]
	}
	e.frozen = true
	return true
}

@(private)
Z3SolveResult :: enum {
	Sat,
	Unsat,
	Timeout,
	Error,
}

/*
用 Z3 尝试某一档 family。

约束：每个出现过的字符对应 (mode[i], param[i])，mode 的取值由 family 决定；
每个 entry 用嵌套 ite 建模从左到右的求值，并要求结果等于 head。
目标：先最小化 Σ|param|（按有符号解释），再最小化 Σmode（多解倾向低 mode）。
*/
@(private)
z3_solve_family :: proc(
	e: ^Encoder,
	family: int,
	timeout_ms: u32,
) -> (
	res: Z3SolveResult,
	modes: [CHAR_COUNT]u32,
	params: [CHAR_COUNT]u32,
) {
	api := z3_api

	cfg := api.Z3_mk_config()
	ctx := api.Z3_mk_context(cfg)
	api.Z3_del_config(cfg)
	defer api.Z3_del_context(ctx)

	bv32 := api.Z3_mk_bv_sort(ctx, 32)
	bv64 := api.Z3_mk_bv_sort(ctx, 64)
	zero32 := api.Z3_mk_unsigned_int(ctx, 0, bv32)
	one32 := api.Z3_mk_unsigned_int(ctx, 1, bv32)
	two32 := api.Z3_mk_unsigned_int(ctx, 2, bv32)
	zero64 := api.Z3_mk_unsigned_int(ctx, 0, bv64)
	limit32 := api.Z3_mk_unsigned_int(ctx, u64(family), bv32)

	used: [CHAR_COUNT]bool
	for entry in e.entries {
		for ch in entry.key {
			idx, ok := char_index(ch)
			if !ok {
				return .Error, modes, params
			}
			used[idx] = true
		}
	}

	p: [CHAR_COUNT]Z3_ast
	m: [CHAR_COUNT]Z3_ast
	name_buf: [32]u8
	for i in 0 ..< CHAR_COUNT {
		if !used[i] {
			continue
		}
		name := fmt.bprintf(name_buf[:], "p_%d", i)
		name_buf[len(name)] = 0
		p[i] = api.Z3_mk_const(ctx, api.Z3_mk_string_symbol(ctx, cstring(raw_data(name_buf[:]))), bv32)

		name = fmt.bprintf(name_buf[:], "m_%d", i)
		name_buf[len(name)] = 0
		m[i] = api.Z3_mk_const(ctx, api.Z3_mk_string_symbol(ctx, cstring(raw_data(name_buf[:]))), bv32)
	}

	// 统一收集约束；family 1/2（线性/XOR）用普通 Solver，family 3 用 Optimize。
	constraints := make([dynamic]Z3_ast)
	defer delete(constraints)

	for i in 0 ..< CHAR_COUNT {
		if used[i] {
			append(&constraints, api.Z3_mk_bvule(ctx, m[i], limit32))
		}
	}

	for entry in e.entries {
		x := api.Z3_mk_unsigned_int(ctx, u64(X0), bv32)
		for ch in entry.key {
			idx, _ := char_index(ch)
			pi := p[idx]
			mi := m[idx]

			add := api.Z3_mk_bvadd(ctx, x, pi)
			sub := api.Z3_mk_bvsub(ctx, x, pi)
			xor := api.Z3_mk_bvxor(ctx, x, pi)

			switch family {
			case 1:
				x = api.Z3_mk_ite(ctx, api.Z3_mk_eq(ctx, mi, zero32), add, sub)
			case 2:
				x = api.Z3_mk_ite(
					ctx,
					api.Z3_mk_eq(ctx, mi, zero32),
					add,
					api.Z3_mk_ite(ctx, api.Z3_mk_eq(ctx, mi, one32), sub, xor),
				)
			case 3:
				rem := api.Z3_mk_ite(
					ctx,
					api.Z3_mk_eq(ctx, pi, zero32),
					x,
					api.Z3_mk_bvurem(ctx, x, pi),
				)
				x = api.Z3_mk_ite(
					ctx,
					api.Z3_mk_eq(ctx, mi, zero32),
					add,
					api.Z3_mk_ite(
						ctx,
						api.Z3_mk_eq(ctx, mi, one32),
						sub,
						api.Z3_mk_ite(ctx, api.Z3_mk_eq(ctx, mi, two32), xor, rem),
					),
				)
			}
		}
		target := api.Z3_mk_unsigned_int(ctx, u64(entry.head), bv32)
		append(&constraints, api.Z3_mk_eq(ctx, x, target))
	}

	check: i32
	solver: Z3_solver
	opt: Z3_optimize
	model: Z3_model

	if family <= 2 {
		solver = api.Z3_mk_solver(ctx)
		api.Z3_solver_inc_ref(ctx, solver)

		prm := api.Z3_mk_params(ctx)
		api.Z3_params_inc_ref(ctx, prm)
		timeout_key := api.Z3_mk_string_symbol(ctx, "timeout")
		api.Z3_params_set_uint(ctx, prm, timeout_key, timeout_ms)
		api.Z3_solver_set_params(ctx, solver, prm)
		api.Z3_params_dec_ref(ctx, prm)

		for c in constraints {
			api.Z3_solver_assert(ctx, solver, c)
		}
		check = api.Z3_solver_check(ctx, solver)
	} else {
		opt = api.Z3_mk_optimize(ctx)
		api.Z3_optimize_inc_ref(ctx, opt)

		prm := api.Z3_mk_params(ctx)
		api.Z3_params_inc_ref(ctx, prm)
		timeout_key := api.Z3_mk_string_symbol(ctx, "timeout")
		api.Z3_params_set_uint(ctx, prm, timeout_key, timeout_ms)
		api.Z3_optimize_set_params(ctx, opt, prm)
		api.Z3_params_dec_ref(ctx, prm)

		for c in constraints {
			api.Z3_optimize_assert(ctx, opt, c)
		}

		// 目标：Σ|param|（64 位，避免 32 位求和溢出），其次 Σmode。
		abs_sum := zero64
		mode_sum := zero64
		for i in 0 ..< CHAR_COUNT {
			if !used[i] {
				continue
			}
			neg := api.Z3_mk_bvslt(ctx, p[i], zero32)
			p_neg := api.Z3_mk_bvsub(ctx, zero32, p[i])
			abs32 := api.Z3_mk_ite(ctx, neg, p_neg, p[i])
			abs64 := api.Z3_mk_zero_ext(ctx, 32, abs32)
			abs_sum = api.Z3_mk_bvadd(ctx, abs_sum, abs64)

			mode64 := api.Z3_mk_zero_ext(ctx, 32, m[i])
			mode_sum = api.Z3_mk_bvadd(ctx, mode_sum, mode64)
		}
		api.Z3_optimize_minimize(ctx, opt, abs_sum)
		api.Z3_optimize_minimize(ctx, opt, mode_sum)

		check = api.Z3_optimize_check(ctx, opt, 0, nil)
	}

	release :: proc(api: Z3_API, ctx: Z3_context, solver: Z3_solver, opt: Z3_optimize) {
		if solver != nil {
			api.Z3_solver_dec_ref(ctx, solver)
		}
		if opt != nil {
			api.Z3_optimize_dec_ref(ctx, opt)
		}
	}

	switch check {
	case 1:
	// SAT
	case -1:
		z3_release(api, ctx, solver, opt)
		return .Unsat, modes, params
	case:
		z3_release(api, ctx, solver, opt)
		return .Timeout, modes, params
	}

	if solver != nil {
		model = api.Z3_solver_get_model(ctx, solver)
	} else {
		model = api.Z3_optimize_get_model(ctx, opt)
	}
	if model == nil {
		z3_release(api, ctx, solver, opt)
		return .Error, modes, params
	}

	for i in 0 ..< CHAR_COUNT {
		if !used[i] {
			continue
		}
		p_val, ok_p := z3_model_uint64(ctx, model, p[i])
		m_val, ok_m := z3_model_uint64(ctx, model, m[i])
		if !ok_p || !ok_m {
			z3_release(api, ctx, solver, opt)
			return .Error, modes, params
		}
		params[i] = u32(p_val & 0xFFFF_FFFF)
		modes[i] = u32(m_val & 0xFFFF_FFFF)
	}
	z3_release(api, ctx, solver, opt)
	return .Sat, modes, params
}

@(private)
z3_model_uint64 :: proc(ctx: Z3_context, model: Z3_model, term: Z3_ast) -> (value: u64, ok: bool) {
	out: Z3_ast
	if !z3_api.Z3_model_eval(ctx, model, term, true, &out) {
		return 0, false
	}
	if out == nil {
		return 0, false
	}
	if !z3_api.Z3_get_numeral_uint64(ctx, out, &value) {
		return 0, false
	}
	return value, true
}


@(private)
z3_release :: proc(api: Z3_API, ctx: Z3_context, solver: Z3_solver, opt: Z3_optimize) {
	if solver != nil {
		api.Z3_solver_dec_ref(ctx, solver)
	}
	if opt != nil {
		api.Z3_optimize_dec_ref(ctx, opt)
	}
}

