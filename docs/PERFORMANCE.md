# OOMap 性能与瓶颈分析

本文记录可复现的基准、复杂度分析和当前实现的主要瓶颈。数字来自本机一次
实测，绝对值会随 CPU、编译器版本、Z3 版本和系统负载变化；趋势与数量级更有
参考价值。

## 1. 测试环境

| 项 | 值 |
|----|----|
| CPU | 13th Gen Intel Core i5-13500H |
| 内存 | 16 GB |
| OS | Windows x64 |
| Odin | `dev-2026-10-nightly:84bc3fc` |
| Z3 | 5.3.3 x64（运行时 `core:dynlib` 加载） |
| 构建 | `odin build cmd/oomap_demo -out:bin/OOMap.exe` |

复现：

```powershell
build.bat
bin\OOMap.exe --bench
bin\OOMap.exe --bench-z3-stress   # 128 条只有 MOD 可解，耗时较长
python scripts\gen_test_csv.py
bin\OOMap.exe --test-csv
```

`--bench` 的计时只包含被测函数；生成 key、构造 Entry 等准备工作放在计时之外。
`--bench-z3-stress` 单独运行，因为 `Optimize` 路径可能远超 `timeout_ms`。

## 2. 实测结果

### 2.1 `--bench`（代表性一次）

```text
BENCH add: n=1000 1.01ms (1.014 us/entry) cache=9389 words
BENCH add: n=5000 3.80ms (0.760 us/entry) cache=46028 words
BENCH add: n=10000 6.57ms (0.657 us/entry) cache=91640 words
BENCH add vs add_u32: n=5000 bytes=8  add=3.81ms add_u32=3.42ms speedup=1.11x
BENCH add vs add_u32: n=1000 bytes=4096 add=21.80ms add_u32=2.57ms speedup=8.47x
BENCH wrap: n=100 0.52ms (5.150 us/entry) family=0 verify=0.009ms ok=true
BENCH wrap: n=1000 1.84ms (1.836 us/entry) family=0 verify=0.104ms ok=true
BENCH wrap: n=5000 6.51ms (1.303 us/entry) family=0 verify=0.560ms ok=true
BENCH read: iters=100000 read_data=165.2ns/op read_data_exact=156.7ns/op
BENCH entries_from_cache: n=1000 parsed=1000 0.24ms (0.244 us/entry) err=None
BENCH entries_from_cache: n=5000 parsed=5000 1.31ms (0.262 us/entry) err=None
BENCH z3: n=2 592.21ms family=3 verify=true err=None
```

### 2.2 `--bench-z3-stress`

```text
BENCH z3-stress: n=128 57897.31ms (timeout_ms=10000) family=3 err=None
```

即 128 条样本、`timeout_ms = 10_000`，实际约 **57.9 秒**才返回。超时预算不是
硬实时，详见 3.4。

### 2.3 CSV 端到端

```text
CSV: rows=200 passed=200 failed=0 elapsed=772.5ms avg=3.86ms
```

每行都执行 `add -> wrap -> verify -> read_data_exact -> 字节比对`；其中 wrap
是主要成本，单行 4 ms 与 `wrap` 的固定开销（含 Z3 探测/求解失败路径）量级一致。

## 3. 逐项分析

### 3.1 `add` / `add_u32` / `add_framed`

`check_addable` 现在先查 `Encoder.index`（`map[string]u32`，key → head），正常
批量写入的重复 key 检查是期望 O(1)：

- 实测每条约 0.6–1.0 µs；10k 条总计约 **6.6 ms**，已不再是批量导入瓶颈；
- 只有“手工 append `entries` 但没更新 index”的高级用法才会走
  `len(index) != len(entries)` 的线性回退，保证重复检测仍然正确；
- key 克隆、cache 追加、长度表写入是剩余的主要成本。

`add_u32` 是 `add` 的快速路径：调用方直接给出小端 u32 字，函数用
`append(&cache, ..data)` 整段写入，省掉 `add` 的逐字节打包循环。

- 小载荷（2 words）：约 1.1x，固定开销（key 克隆、marker、map 写入）占主导；
- 4 KiB 载荷（1024 words）：`add` 约 21.8 ms，`add_u32` 约 2.6 ms，**约 8.5x**。

`add_framed` 的段比 `add` 多 3 个 marker（`START/KEY/DATA_LEN/DATA/END`），
cache 占用略高，但校验和追加成本同阶；重复 key 检查同样命中 map。

### 3.2 `wrap` family 0：n×64 的计数矩阵与逐位提升

`pure_solve` 的主要成本：

1. 统计每个 entry 的字符计数：`counts` 为 `n × m` 的 `u64`，`m` 是实际出现的
   字符数（≤64）。n=5000 时 `counts` 占 2.56 MB，n=10k 时 5.12 MB。
2. `solve_full_rank`：GF(2) 选主元 + `m × m` 的模 2^32 高斯消元，主项
   `O(n·m + m³)`。
3. `lift_solution`：32 位逐位提升，每位做一次 GF(2) 消元；主项约
   `O(32·(n·m + m³))`。
4. 最后 `commit_solution` 的 `verify_with` 全量重放。

实测 n=5000 时约 6.5 ms（约 1.3 µs/entry），verify 另占约 0.6 ms；n=100 时固定
开销占主导（5.2 µs/entry）。在 64 个未知数的规模下，这是可接受的主路径。

内存是这一路径的主要压力：`counts`、`parity`、`rows` 等数组都随 n 线性增长；
若把 `counts` 从 `u64` 收窄为 `u32`（每个 key 的字符计数远小于 2³²），可省一半
内存。n 继续增大时，优先改成分块/稀疏计数，而不是继续放大稠密矩阵。

### 3.3 `verify`、`read_data` 与 wrap 后清理

- `verify` 是纯重放：`O(Σ key_len)`，n=5000 约 0.56 ms，属于廉价操作；
- `read_data` 对 13 字节数据约 150–170 ns/op，主要由一次 `make([]u8, 8)` 和段
  校验组成；`read_data_exact` 多做一次填充区零值扫描和精确分配，量级相同。
  两者都适合在线路径。

`wrap` 成功后会尽量清理求解期状态：

- 如果每个 entry 都能在 cache 中找到对应数据段，释放 `entries`（样本 key）并
  删除重复检查索引，只保留 cache 与精确长度表；
- 手工构造、没有数据段的 samples 无法从 cache 恢复，会保留 `entries` 供 verify
  使用；
- 清理后 `verify` 会按需从 cache 重建 entries，成功后立即释放，失败时保留以便
  `bad.key` 有效。

因此 add 数据的典型工作流在 wrap 后常驻内存只剩 cache + 长度表；verify 是
“按需重放”，不会长期占用样本内存。

### 3.4 Z3 family 3：真正的最坏情况

- 最小场景（2 条样本，A/AA 共享 head=3）需要 family 3，单次约 **592 ms**；
- 128 条样本、`timeout_ms=10_000` 的 `Optimize` 实测约 **57.9 s** 才返回。

原因：

1. family 3 用 `Z3_optimize_minimize` 先最小化 `Σ|param|`，再最小化 `Σmode`；
   Optimize 会多次调用底层求解器，`timeout` 参数是每次调用的预算，不保证总时长。
2. 每个 entry 的 key 被展开为嵌套 `ite` 表达式，样本越多表达式越大。
3. `wrap_ex` 只在 family 边界检查剩余预算，进入 Z3 后无法抢占。

因此 README 里的“100 ms 超时”测试只覆盖了一个能在预算附近返回的特定实例；
**不要把 `timeout_ms` 当成硬实时保证**。对延迟敏感的服务应把 `wrap` 放到独立
进程/任务中，超时后直接丢弃，而不是依赖 Z3 内部的中断。

另一个结构性观察：family 1（ADD/SUB）在可满足性上与 family 0 等价。因为每个
字符的符号可以吸收到变量里（`q_i = ±p_i` 仍是任意 u32），ADD 与 SUB 只是对
同一个线性系统做变量替换；family 1 的价值主要是换一条 Z3 搜索路径，用来弥补
family 0 求解器的完备性边界，而不是扩大可解集合。真正扩大表达力的是 family 2
（XOR）与 family 3（MOD）。如果 family 0 已经覆盖了绝大多数样本，family 1 的
Z3 建模成本往往是不必要的；可以考虑在 family 0 失败后直接跳到 2/3，或先做
轻量的可满足性预判。

### 3.5 `entries_from_cache`：每条约 0.24–0.27 µs

`unpack_key` 先 `make([]u8, key_len)`，校验后再 `strings.clone_from_bytes`，
每条 entry **两次分配**；随后 `[dynamic]Entry` 再扩容。n=5000 约 1.3 ms，适合
启动时加载，但可优化为一次分配（直接在最终 string 上校验）或使用 arena。

### 3.6 其它固定开销

- `wrap_ex` 成功时用 `fmt.aprintf` 生成 `info.message`，即使 `wrap` 的调用方
  随后丢弃；对高频短请求，这是一次不必要的格式化/分配。
- cache 用逐字 `append` 增长，容量按倍增策略摊销；已知总大小时可
  `reserve` 减少拷贝。
- Z3 首次加载会尝试多个路径；失败路径会遍历候选并 unload，属于一次性成本。
- `add_u32` 虽然省掉字节打包，但 key 仍要逐字符打包；key 很长时这部分会成为
  新的固定开销。

## 4. 瓶颈排序

| 排名 | 场景 | 量级 | 主要原因 |
|------|------|------|----------|
| 1 | family 3 的 Z3 Optimize | 0.6 s ~ 58 s | 多目标优化 + 大 `ite` 表达式 + 超时非硬实时 |
| 2 | 大 n 的 family 0 内存 | n=10k 约 5 MB 临时数组 | `counts` 为 n×64×8 字节稠密矩阵 |
| 3 | `entries_from_cache` | 0.25 µs/entry | 每 key 两次分配 |
| 4 | `read_data*` | 0.15–0.17 µs/次 | 一次分配 + 段校验 |
| 5 | `add_u32` 小载荷 | 约 0.5–0.7 µs/entry | key 克隆/打包与 map 写入 |

重复 key 检查已从 O(n²) 降为期望 O(1)，不再出现在瓶颈列表里。

## 5. 可选的优化方向（未实现）

1. **cache 预留**：提供 `reserve_cache(e, n)`，批量导入前一次性扩容。
2. **懒生成 `WrapInfo.message`**：只在调用方请求诊断时格式化；成功路径不再分配。
3. **收窄计数类型**：`counts` 用 `u32`，内存减半；或按实际字符列压缩。
4. **`entries_from_cache` 单次分配**：直接在最终 key 字符串上校验字符集。
5. **Z3 路径治理**：family 0 失败后跳过 family 1（可满足性等价），或把 Z3 放到
   可终止的子进程；对在线服务设置外部超时。
6. **硬超时**：目前 `timeout_ms` 只是协作式预算；若要硬保证，需要线程/进程级
   取消或 Z3 的 `Z3_interrupt`（当前绑定未暴露）。
7. **`add_u32` 的 key 打包**：key 很长时可先把 key 预打包成 u32 复用。

## 6. 结论

- family 0 是主路径：n=5000 约 6.5 ms，完全够用；
- `map[string]u32` 已消除 `add` 的 O(n²) 重复检查：10k 条从约 0.27 s 降到约
  6.6 ms；
- `add_u32` 对大载荷有效（4 KiB 约 8.5x），小载荷收益有限；
- Z3 family 3 是数量级更贵的最坏情况，且 `timeout_ms` 不能硬性截断，**不要把
  它放在延迟敏感的同步请求路径**；
- wrap 后的清理让常驻内存聚焦于 cache + 长度表；手工样本因无法从 cache 恢复
  而保留，verify 仍可用。
