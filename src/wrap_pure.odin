package main


// 64 字符地址编码器 —— family 0：纯 Odin 线性求解
//
// family 0 只允许 ADD（mode=0），每个 entry 给出方程：
//
//     Σ_j count(entry, j) * p[j] ≡ head - X0   (mod 2^32)
//
// 先在 mod 2 上解出特解，再逐位提升到 mod 2^32；每提升一位都重新用
// GF(2) 高斯消元求新位。多解时自由变量取 0（最简解）。
// 求解结果最终还要经过 verify 重放，失败时会继续尝试 Z3 的 family 1..3。
//
// 对应 prompt.md 第 5、7 节。

/*
尝试用 family 0（纯 ADD）求解。

成功时返回全部 64 个字符的 mode/param（未出现的字符 param=0, mode=0），
不修改 Encoder；失败时返回 ok=false。
*/
pure_solve :: proc(e: ^Encoder) -> (ok: bool, modes: [CHAR_COUNT]u32, params: [CHAR_COUNT]u32) {
	n := len(e.entries)
	if n == 0 {
		return false, modes, params
	}

	used: [CHAR_COUNT]bool
	for entry in e.entries {
		for ch in entry.key {
			idx, valid := char_index(ch)
			if !valid {
				return false, modes, params
			}
			used[idx] = true
		}
	}

	col_of: [CHAR_COUNT]int
	for i in 0 ..< CHAR_COUNT {
		col_of[i] = -1
	}
	m := 0
	for i in 0 ..< CHAR_COUNT {
		if used[i] {
			col_of[i] = m
			m += 1
		}
	}
	if m == 0 {
		return false, modes, params
	}

	counts := make([]u64, n * m)
	b := make([]u32, n)
	x := make([]u32, m)
	parity := make([]u64, n)
	rows := make([]u64, n)
	c := make([]u8, n)
	y := make([]u32, m)
	defer {
		delete(counts)
		delete(b)
		delete(x)
		delete(parity)
		delete(rows)
		delete(c)
		delete(y)
	}

	for entry, i in e.entries {
		b[i] = entry.head - u32(X0)
		for ch in entry.key {
			idx, _ := char_index(ch)
			col := col_of[idx]
			counts[i * m + col] += 1
		}
		for j in 0 ..< m {
			if counts[i * m + j] & 1 != 0 {
				parity[i] |= u64(1) << u32(j)
			}
		}
	}

	if !solve_full_rank(counts, b, parity, x, n, m) {
		if !solve_kernel_lift(counts, parity, b, x, n, m) {
			if !solve_mod_2_32(counts, b, parity, x, rows, c, y, n, m) {
				return false, modes, params
			}
		}
	}

	for i in 0 ..< CHAR_COUNT {
		modes[i] = 0
		params[i] = 0
	}
	for i in 0 ..< CHAR_COUNT {
		if col_of[i] >= 0 {
			params[i] = x[col_of[i]]
		}
	}
	return true, modes, params
}

@(private)
solve_full_rank :: proc(counts: []u64, b: []u32, parity: []u64, x: []u32, n, m: int) -> bool {
	if n < m {
		return false
	}

	// 在 GF(2) 上选出 m 个线性无关的原始行（只记录原始行号，不做行变换）。
	basis_mask: [64]u64
	basis_idx: [64]int
	for i in 0 ..< 64 {
		basis_idx[i] = -1
	}
	rank := 0
	for r in 0 ..< n {
		v := parity[r]
		for col in 0 ..< m {
			if v & (u64(1) << u32(col)) == 0 {
				continue
			}
			if basis_mask[col] != 0 {
				v ~= basis_mask[col]
				continue
			}
			basis_mask[col] = v
			basis_idx[col] = r
			rank += 1
			break
		}
	}
	if rank < m {
		return false
	}

	// 用这 m 行构造方阵，在 Z/2^32 上做带奇数主元的高斯消元。
	stride := m + 1
	S := make([]u32, m * stride)
	defer delete(S)
	pos := 0
	for col in 0 ..< m {
		r := basis_idx[col]
		for j in 0 ..< m {
			S[pos * stride + j] = u32(counts[r * m + j])
		}
		S[pos * stride + m] = b[r]
		pos += 1
	}

	for col in 0 ..< m {
		sel := -1
		for r in col ..< m {
			if S[r * stride + col] & 1 != 0 {
				sel = r
				break
			}
		}
		if sel < 0 {
			return false
		}
		if sel != col {
			for j in col ..< stride {
				S[col * stride + j], S[sel * stride + j] = S[sel * stride + j], S[col * stride + j]
			}
		}
		inv := inv_odd(S[col * stride + col])
		for j in col ..< stride {
			S[col * stride + j] = u32(u64(S[col * stride + j]) * u64(inv))
		}
		for r in 0 ..< m {
			if r == col {
				continue
			}
			f := S[r * stride + col]
			if f == 0 {
				continue
			}
			for j in col ..< stride {
				S[r * stride + j] = u32(u64(S[r * stride + j]) - u64(f) * u64(S[col * stride + j]))
			}
		}
	}

	for i in 0 ..< m {
		x[i] = S[i * stride + m]
	}
	return true
}

// 奇数 a 在模 2^32 下的乘法逆元（牛顿迭代，位数翻倍）。
@(private)
inv_odd :: proc(a: u32) -> u32 {
	inv: u32 = 1
	for _ in 0 ..< 6 {
		inv = inv * (2 - a * inv)
	}
	return inv
}



/*
在 Z/2^32 上逐位求解 A x = b。

rows/c/y 为调用方提供的临时缓冲区。
*/
@(private)
solve_mod_2_32 :: proc(
	counts: []u64,
	b: []u32,
	parity: []u64,
	x: []u32,
	rows: []u64,
	c: []u8,
	y: []u32,
	n, m: int,
) -> bool {
	for i in 0 ..< n {
		c[i] = u8(b[i] & 1)
	}
	free_cols: [64]int
	free_count := 0
	if !solve_gf2(parity, c, x, rows, n, m, free_cols[:], &free_count) {
		return false
	}

	// mod 2 的解可能不唯一；只有部分解能提升到 mod 4。
	// 若自由变量不多，枚举 mod 2 解空间，找到可提升的那一支。
	if free_count > 0 && free_count <= 10 {
		branches := 1 << u32(free_count)
		base: [64]u32
		copy(base[:], x[:m])
		for mask in 0 ..< branches {
			for j in 0 ..< m {
				x[j] = base[j]
			}
			for b_idx in 0 ..< free_count {
				if (mask >> u32(b_idx)) & 1 != 0 {
					x[free_cols[b_idx]] = 1
				}
			}
			if lift_solution(counts, b, parity, x, rows, c, y, n, m) {
				return true
			}
		}
		return false
	}

	return lift_solution(counts, b, parity, x, rows, c, y, n, m)
}

/*
给定一个 mod 2 的解，逐位提升到 mod 2^32。
*/
@(private)
lift_solution :: proc(
	counts: []u64,
	b: []u32,
	parity: []u64,
	x: []u32,
	rows: []u64,
	c: []u8,
	y: []u32,
	n, m: int,
) -> bool {
	for k in 1 ..< 32 {
		mask := (u64(1) << u32(k + 1)) - 1
		low_mask := (u64(1) << u32(k)) - 1

		for i in 0 ..< n {
			sum: u64 = 0
			base := i * m
			for j in 0 ..< m {
				sum += counts[base + j] * u64(x[j])
			}
			r := (u64(b[i]) - sum) & mask
			if r & low_mask != 0 {
				return false
			}
			c[i] = u8((r >> u32(k)) & 1)
		}

		fc: [64]int
		fcount := 0
		if !solve_gf2(parity, c, y, rows, n, m, fc[:], &fcount) {
			return false
		}
		for j in 0 ..< m {
			if y[j] != 0 {
				x[j] |= u32(1) << u32(k)
			}
		}
	}

	return true
}

/*
求解 GF(2) 上的线性系统 A sol = c（A 由 parity 给出），自由变量取 0。
*/
@(private)
solve_gf2 :: proc(
	parity: []u64,
	c: []u8,
	sol: []u32,
	rows: []u64,
	n, m: int,
	free_cols: []int,
	free_count: ^int,
) -> bool {
	AUG_BIT :: 63
	assert(m <= AUG_BIT)

	for i in 0 ..< n {
		rows[i] = parity[i]
		if c[i] != 0 {
			rows[i] |= u64(1) << u64(AUG_BIT)
		}
	}

	coeff_mask := (u64(1) << u32(m)) - 1
	pivot_row: [64]int
	for i in 0 ..< 64 {
		pivot_row[i] = -1
	}

	row := 0
	for col in 0 ..< m {
		sel := -1
		for r in row ..< n {
			if rows[r] & (u64(1) << u32(col)) != 0 {
				sel = r
				break
			}
		}
		if sel < 0 {
			continue
		}
		if sel != row {
			rows[row], rows[sel] = rows[sel], rows[row]
		}
		for r in 0 ..< n {
			if r != row && rows[r] & (u64(1) << u32(col)) != 0 {
				rows[r] ~= rows[row]
			}
		}
		pivot_row[col] = row
		row += 1
		if row == n {
			break
		}
	}

	for r in 0 ..< n {
		if rows[r] & coeff_mask == 0 && rows[r] & (u64(1) << u64(AUG_BIT)) != 0 {
			return false
		}
	}

	for j in 0 ..< m {
		sol[j] = 0
	}
	free_count^ = 0
	for col in 0 ..< m {
		pr := pivot_row[col]
		if pr >= 0 {
			sol[col] = u32((rows[pr] >> u64(AUG_BIT)) & 1)
		} else {
			free_cols[free_count^] = col
			free_count^ += 1
		}
	}
	return true
}



