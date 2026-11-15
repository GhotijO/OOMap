package oomap

// family 0 的补充求解器：Hensel 提升时同时维护核空间基。
//
// 用于满秩快速路径失败、但 mod 2 解空间不大的情形（例如 64 条样本、
// 字符矩阵在 GF(2) 上秩亏 1）。若核空间过大（维度增长超过 MAXV），返回 false，
// 由调用方继续尝试其它 family。

KResult :: struct {
	part: [MAXV]u32,
	null: [MAXV][MAXV]u32,
	d:    int,
}

MAXV :: 128

@(private)
solve_kernel_lift :: proc(counts: []u64, parity: []u64, b: []u32, x: []u32, n, m: int) -> bool {
	rows := make([][2]u64, n)
	augs := make([]u8, n)
	defer {
		delete(rows)
		delete(augs)
	}

	res := new(KResult)
	defer free(res)

	for i in 0 ..< n {
		rows[i] = {parity[i], 0}
		augs[i] = u8(b[i] & 1)
	}
	if !gf2_solve_k(rows, augs, n, m, res) {
		return false
	}
	for j in 0 ..< m {
		x[j] = res.part[j]
	}

	K := make([]u32, MAXV * MAXV)
	Knew := make([]u32, MAXV * MAXV)
	defer {
		delete(K)
		delete(Knew)
	}
	d := res.d
	for j in 0 ..< d {
		for l in 0 ..< m {
			K[j * MAXV + l] = res.null[j][l]
		}
	}

	for k in 1 ..< 32 {
		mask := (u64(1) << u32(k + 1)) - 1
		low := (u64(1) << u32(k)) - 1

		for i in 0 ..< n {
			sum: u64 = 0
			base := i * m
			for l in 0 ..< m {
				sum += counts[base + l] * u64(x[l])
			}
			r := (u64(b[i]) - sum) & mask
			if r & low != 0 {
				return false
			}
			augs[i] = u8((r >> u32(k)) & 1)
		}

		V := d + m
		if V > MAXV {
			return false
		}

		for i in 0 ..< n {
			row: [2]u64
			for j in 0 ..< d {
				sum: u64 = 0
				kb := j * MAXV
				base := i * m
				for l in 0 ..< m {
					sum += counts[base + l] * u64(K[kb + l])
				}
				if (sum >> u32(k)) & 1 != 0 {
					row[j >> 6] |= u64(1) << u64(j & 63)
				}
			}
			for l in 0 ..< m {
				if (parity[i] >> u32(l)) & 1 != 0 {
					col := d + l
					row[col >> 6] |= u64(1) << u64(col & 63)
				}
			}
			rows[i] = row
		}

		if !gf2_solve_k(rows, augs, n, V, res) {
			return false
		}

		for l in 0 ..< m {
			sum := u64(x[l])
			for j in 0 ..< d {
				if res.part[j] != 0 {
					sum += u64(K[j * MAXV + l])
				}
			}
			sum += u64(res.part[d + l]) << u32(k)
			x[l] = u32(sum & mask)
		}

		nd := res.d
		for j in 0 ..< nd {
			for l in 0 ..< m {
				sum: u64 = 0
				for jj in 0 ..< d {
					if res.null[j][jj] != 0 {
						sum += u64(K[jj * MAXV + l])
					}
				}
				sum += u64(res.null[j][d + l]) << u32(k)
				Knew[j * MAXV + l] = u32(sum & mask)
			}
		}
		for idx in 0 ..< MAXV * MAXV {
			K[idx] = Knew[idx]
		}
		d = nd
	}
	return true
}

@(private)
gf2_solve_k :: proc(rows: [][2]u64, augs: []u8, n, V: int, res: ^KResult) -> bool {
	if V > MAXV {
		return false
	}

	pivot_row: [MAXV]int
	for i in 0 ..< MAXV {
		pivot_row[i] = -1
	}

	rank := 0
	for col in 0 ..< V {
		wi := col >> 6
		bit := u64(1) << u64(col & 63)
		sel := -1
		for r in rank ..< n {
			if rows[r][wi] & bit != 0 {
				sel = r
				break
			}
		}
		if sel < 0 {
			continue
		}
		if sel != rank {
			rows[rank], rows[sel] = rows[sel], rows[rank]
			augs[rank], augs[sel] = augs[sel], augs[rank]
		}
		for r in 0 ..< n {
			if r != rank && rows[r][wi] & bit != 0 {
				rows[r][0] ~= rows[rank][0]
				rows[r][1] ~= rows[rank][1]
				augs[r] ~= augs[rank]
			}
		}
		pivot_row[col] = rank
		rank += 1
		if rank == n {
			break
		}
	}

	for r in 0 ..< n {
		if rows[r][0] == 0 && rows[r][1] == 0 && augs[r] != 0 {
			return false
		}
	}

	for i in 0 ..< MAXV {
		res.part[i] = 0
	}
	for col in 0 ..< V {
		pr := pivot_row[col]
		if pr >= 0 {
			res.part[col] = u32(augs[pr])
		}
	}

	d := 0
	for f in 0 ..< V {
		if pivot_row[f] >= 0 {
			continue
		}
		for i in 0 ..< MAXV {
			res.null[d][i] = 0
		}
		res.null[d][f] = 1
		for col in 0 ..< V {
			pr := pivot_row[col]
			if pr >= 0 {
				res.null[d][col] = u32((rows[pr][f >> 6] >> u64(f & 63)) & 1)
			}
		}
		d += 1
	}
	res.d = d
	return true
}

