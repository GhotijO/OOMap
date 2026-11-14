# OOMap —— 64 字符地址编码器

用 Odin 实现的可解性精确判定器：给定若干 `(key, head)` 样本，为 64 个字符各求
一个 `u32` 操作参数，使每个 key 按从左到右求值后**严格等于**其 `head`；无解时明确
报告 `Infeasible`，不会伪造成功。求解结果最终都要经过纯 Odin 重放校验。

项目主要能力：

- 64 字符（`.`、`A`..`Z`、`_`、`a`..`z`）的 `u32` 操作编码与精确求解
- 4 档 family：纯 ADD → ADD/SUB → +XOR → +MOD；逐档尝试并共享总超时
- `add` / `add_framed` 两种样本写入格式，自动维护 `Entry{key, head}`
- `verify` 纯 Odin 重放校验；`read_data` 可用求解结果把字符串解码回数据
- Z3 运行时动态加载；缺少 Z3 时 family 0 仍可工作，其余返回 `.MissingZ3`
- `test.csv` 端到端测试与计时，附 Python 生成器
- `odin test` 单元测试 + 独立进程验收入口

## 快速开始

首次从仓库克隆后，`lib/libz3.dll` 等预编译二进制不在 Git 中；需要 Z3 时先执行：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\fetch_z3.ps1
```

然后构建并运行（family 0 不依赖 Z3，缺 Z3 时仍可运行）：

```bat
build.bat
bin\OOMap.exe
```

```sh
./build.sh
./bin/OOMap
```

Demo 会依次执行：`add` 若干样本 → `wrap` → `verify`，最后再跑一个只有 family 3
（MOD）能解的场景，演示 Z3 路径与缺 Z3 降级。

## 目录

```
OOMap/
├── src/
│   ├── encoder.odin        Entry / Encoder / add / add_framed / cache 布局
│   ├── eval.odin           Σ、char_index、apply、eval、verify、read_data
│   ├── wrap.odin           wrap 主流程、family 调度、Z3 建模
│   ├── wrap_pure.odin      family 0：纯 Odin 线性求解
│   ├── wrap_pure_kernel.odin  family 0 的核空间提升补充求解器
│   ├── z3_binding.odin     Z3 C API 子集（core:dynlib 运行时加载）
│   ├── csv_test.odin       test.csv 端到端测试与计时
│   ├── tests.odin          odin test 验收测试（family 0 / 回读相关）
│   └── main.odin           demo 与独立进程验收入口
├── lib/                    Z3 头文件与许可证（DLL 由 fetch 脚本下载）
├── scripts/fetch_z3.ps1        下载 Z3 5.3.3 预编译二进制到 lib/
├── scripts/run_acceptance.ps1  一键跑完整验收
├── scripts/gen_test_csv.py     生成 bin/test.csv
├── build.bat / build.sh
├── .gitignore / .gitattributes
├── LICENSE                 MIT
├── RELEASE.md              GitHub Release 描述（v1.0.0）
└── README.md
```

## 常量与字符集

```odin
CHAR_COUNT :: 64
X0         :: 31
Σ = "." + "0".."9" + "A".."Z" + "_" + "a".."z"
```

| 索引 | 字符 |
|------|------|
| 0 | `.` |
| 1..10 | `0`..`9` |
| 11..36 | `A`..`Z` |
| 37 | `_` |
| 38..63 | `a`..`z` |

所有整数按 `u32` 回绕。

## 保留区布局（cache[0..255]）

| 索引 | 用途 |
|------|------|
| 0..63 | `mode[i]`：0=ADD, 1=SUB, 2=XOR, 3=MOD |
| 64..127 | `param[i]` |
| 128..255 | 保留 |

`add` 从 `len(cache)` 起追加段：`0x00000000`、`key_len`、打包 key、`0xFFFF`、
data 字数、打包 data、`0xFFFF`，并返回段起点 `head`。

## add 与 add_framed

两个函数共用同一套校验（`frozen` / 空 key / Σ 外字符 / 重复 key）和
`Entry{key, head}` 语义，区别只在 cache 中的段格式：

| 函数 | 段格式 |
|------|--------|
| `add(e, key, data)` | 原始任务规格 第 6 节的 `0x0000` / `0xFFFF` 格式 |
| `add_framed(e, key, data)` | 下方 `0xFF00FFxx` 帧格式 |

`add_framed` 追加的内容（`head` 为段起点，字符串与数据均按小端、每 4 字节
占一个 u32，末位补 0）：

```
[0xFF00FF00][u32 字符串长度][0xFF00FF02]
[打包字符串；(key_len + 3) / 4 个 u32]
[0xFF00FF04][u32 ceil(data_len / 4)][0xFF00FF08]
[打包数据；每 4 个 u8 占一个 u32]
[0xFF00FF0F]
```

调用后函数返回 `head`，并把 `key` 克隆后与 `head` 组装成 `Entry` 追加到
`e.entries`；后续 `wrap` / `verify` 的求解与重放逻辑对两个 add 完全一致。

## 数据回读 read_data

```odin
read_data :: proc(e: ^Encoder, key: string) -> (data: []u8, ok: bool)
```

流程：

1. 用当前 cache 的 `mode/param` 对输入字符串求值，得到 `head`；
2. 检查 `head` 处段的标记，并校验段内记录的**字符串长度**与**字符串内容**都与
   输入一致；长度不符、内容不符、越界或标记非法时立即放弃（`ok=false`）；
3. 读段内的 u32 字数，按小端展开为 `[]u8` 返回；长度按 4 字节对齐，末位补 0
   （两种段格式都只记录 u32 字数，不记录原始字节数）。

`add`（`0x0000/0xFFFF`）与 `add_framed`（`0xFF00FFxx`）写入的段都支持。
返回的 `data` 由调用方 `delete`。

## 从 cache 还原 Entry

```odin
entries_from_cache :: proc(cache: []u32) -> (entries: [dynamic]Entry, err: ErrorCode)
```

从 `cache[256]`（`RESERVED_LEN`）开始顺序解析数据段，支持两种段格式，遇到
段间 0 填充会跳过；成功时返回新建的 `[dynamic]Entry`，每个 `Entry.head` 就是
该段起始下标。返回的 `Entry.key` 是新分配的，调用方需要：

```odin
entries, err := entries_from_cache(cache)
...
for entry in entries { delete(entry.key) }
delete(entries)
```

## 关于把 wrap 结果放进固定大小数组

`wrap` 的结果只占前 128 个 u32（64 个 mode + 64 个 param），大小固定；而
`Encoder.cache` 还承载 `add` 追加的变长数据段。分析结论：

| 方案 | 可行性 | 说明 |
|------|--------|------|
| 把整个 `cache` 换成 `make` 的固定数组 | 不可行（不做） | `add` 需要持续追加段，`head` 就是追加位置，动态数组是语义的一部分 |
| 只把结果区改成独立固定数组 `make([]u32, 128)`，段另存 | 可行，改动大 | 所有 `eval` / `verify` / `read_data` / `wrap` 都要换数据源，并会破坏 原始任务规格 约定的 cache 布局 |
| 保留 cache，提供固定大小只读快照 | 可行，风险最低 | 已实现 `solution_snapshot(e)`，返回 `make([]u32, 128)` 的副本 |

```odin
solution_snapshot :: proc(e: ^Encoder) -> []u32
```

性能上 128 个 u32 的复制可忽略；wrap 写入时动态数组不会扩容（`add` 才追加），
因此没有稳定性问题。当前选择“方案 3”：cache 仍是唯一事实来源，需要固定数组的
调用方用快照即可。

## 4 档 family

| family | mode 集合 | 求解器 |
|--------|-----------|--------|
| 0 | {ADD} | 纯 Odin：GF(2) + 逐位提升（满秩时用奇数主元高斯消元） |
| 1 | {ADD, SUB} | Z3 Solver |
| 2 | {ADD, SUB, XOR} | Z3 Solver |
| 3 | {ADD, SUB, XOR, MOD} | Z3 **Optimize**（最小化 Σ\|param\|，再最小化 Σmode） |

`wrap` 从 family 0 到 3 依次尝试，共享同一个总超时预算；每档候选解先写到工作
缓冲区，`verify` 通过后才一次性写入 `e.cache` 并置 `frozen=true`。任何失败都不
修改 cache。

## Z3 的获取与加载

`lib/` 中已放好 **Z3 5.3.3 x64** 官方 C SDK（`libz3.dll` + `libz3.lib` +
`include/`），来源与校验值见 [lib/README.md](lib/README.md)。若需重新获取：

1. 从 <https://github.com/Z3Prover/z3/releases/tag/z3-5.3.3> 下载
   `z3-5.3.3-x64-win.zip`；
2. 取 `bin/libz3.dll`、`bin/libz3.lib`、`include/*.h` 放入 `lib/`；
3. 运行前把 `libz3.dll` 放到 exe 同目录（`build.bat` 会自动复制），或让
   `lib/libz3.dll` 位于工作目录。

`z3_binding.odin` 用 `core:dynlib` 动态加载，因此**缺 Z3 时程序仍可启动**：
family 0 继续工作，family 1..3 返回 `.MissingZ3` 并提示“安装 Z3 后重试”。

## 测试与验收

```powershell
# 单元测试（格式、回读、快照、不可行、边界、回绕、frozen）
odin test src

# 往返 / 性能（family 0）
bin\OOMap.exe --check-pure

# family 3 最小 |p| 与超时
bin\OOMap.exe --check-z3

# test.csv 端到端（add -> wrap -> verify -> read_data）
python scripts\gen_test_csv.py
bin\OOMap.exe --test-csv

# 缺 Z3 降级（先隐藏 libz3.dll）
Rename-Item lib\libz3.dll libz3.dll.hidden
bin\OOMap.exe --check-missing-z3
Rename-Item lib\libz3.dll.hidden libz3.dll

# 或一键全跑（含生成 test.csv）
powershell -ExecutionPolicy Bypass -File scripts\run_acceptance.ps1
```

### test.csv 端到端测试

`scripts/gen_test_csv.py` 生成两列 CSV：第一列字符串、第二列大写十六进制数据，
默认写到 `bin/test.csv`（也就是 exe 同目录），行数默认 200：

```powershell
python scripts\gen_test_csv.py            # bin/test.csv, 200 行
python scripts\gen_test_csv.py bin\test.csv 500
```

`bin\OOMap.exe --test-csv` 会逐行执行完整链路并计时：

```text
CSV: file = ...\bin\test.csv
CSV: rows=200 passed=200 failed=0 elapsed=861.8ms avg=4.31ms
```

每行的 head 由一组隐藏参数决定，程序先把 cache 填充到该位置再 `add`，因此
`wrap` 必须真正求出能把字符串映射到段起点的参数；随后 `read_data` 再解码并
与原始数据逐字节比对。

| 原始任务规格 第 11 节 | 覆盖方式 |
|------|------|
| 1 格式测试 | `odin test`：`test_add_format`、`test_add_framed_format` |
| 2 往返测试（5/20/64/65/1000） | `--check-pure` |
| 3 不可行（同 key 不同 head） | `odin test`：`test_infeasible_duplicate` |
| 4 边界（空 key、非法字符、0xFF 往返） | `odin test`：`test_boundaries` |
| 5 回绕 | `odin test`：`test_wrap_around` |
| 6 超时（100 ms） | `--check-z3` |
| 7 frozen | `odin test`：`test_frozen` |
| 8 缺 Z3 | `--check-missing-z3`（隐藏 DLL 后独立进程运行） |
| 9 性能（1000 条 < 1 s） | `--check-pure`，本机约 1–3 ms |
| 10 多解最小 \|p\| | `--check-z3`（MOD 最小解 p=4） |
| 附加：数据回读 | `odin test`：`test_read_data`（两种段格式 + 错误字符串） |
| 附加：从 cache 还原 Entry | `odin test`：`test_entries_from_cache` |
| 附加：固定数组快照 | `odin test`：`test_solution_snapshot` |
| 附加：CSV 端到端 | `--test-csv`（配合 `scripts/gen_test_csv.py`） |

关于 `odin test`：Windows 上的 Odin 测试运行器会安装 Vectored Exception Handler，
而 Z3 内部会使用 SEH/C++ 异常做控制流，二者相遇会把正常调用误判成测试信号。
因此 **Z3 相关验收改为独立进程**（`OOMap.exe --check-*`），这也是上面的表里
把它们单独列出的原因；这不对产品代码产生任何特殊判断分支。

## 两处与 原始任务规格 字面表述的工程化说明

1. **family 0 方程右端**：prompt 第 7 节写的是 `head - key_len·X0`，但按第 5 节
   的求值函数 `x := X0` 只加一次初值，正确方程是
   `Σ count_j·p_j ≡ head - X0 (mod 2^32)`。实现采用后者；用前者在重复字符
   （如 `"AA"`）上会产生互不相容的方程，连 prompt 自己的往返测试都无法通过。
2. **重复 key**：`add` 一律返回 `.DuplicateKey`。`wrap` 对“同 key 同 head”的
   重复返回 `.DuplicateKey`；对“同 key 不同 head”（第 11.3 节手工构造的场景）
   因为约束互相矛盾，返回 `.Infeasible` 且 cache 不变。

## 实现要点

- family 0 不依赖 Z3：先解 `A x ≡ b (mod 2)`，再逐位提升到 mod 2^32；满秩时
  走奇数主元高斯消元，秩亏时用“同时提升核空间基”的补充求解器，二者都经过
  `verify` 重放。
- Z3 侧只为出现过的字符建变量；`u32` 全部用 `Z3_mk_bv_sort(ctx, 32)` 建模；
  不使用 `Z3_mk_int`，避免丢失回绕语义。
- family 3 用 `Optimize` 先最小化 `Σ|param|`（64 位求和防溢出、按有符号解释），
  再最小化 `Σmode`；family 1/2 是纯线性/XOR 约束，用普通 `Solver` 以获得可接受
  的 1000 条样本性能。
- 动态加载失败是正常降级路径，不是 panic。

## 限制

- 目前只在 Windows x64 + Odin `dev-2026-10-nightly` + Z3 5.3.3 上实测；Linux/macOS
  的加载路径已写好（`libz3.so` / `libz3.dylib`），但未在真机验证。
- `verify` 只做语义校验（mode ∈ 0..3），不校验 family 归属，符合第 8 节约定。
- 超时预算只在 family 边界检查；family 0 是同步求解，极端大的输入可能在返回
  `.Timeout` 前多跑一点时间。
- 两种段格式都只记录 `u32` 字数，不记录原始字节数，因此 `read_data` 返回的是
  4 字节对齐的数据（末位带补 0），无法区分原始末尾的 0 与填充。
- `entries_from_cache` 从 256 开始顺序扫描，允许段间 0 填充；但遇到损坏的非零
  段标记会返回 `.InternalError`，不保证从任意垃圾数据中恢复。
- family 1/2 为性能使用普通 `Solver`（不做最小化），最小 `Σ|param|` 只在
  family 3 的 `Optimize` 路径保证。

## 仓库约定

- 只提交源码、文档、脚本和 Z3 头文件；`bin/`、`*.exe`、`*.pdb` 以及
  `lib/*.dll`、`lib/*.lib` 等预编译二进制都通过 `.gitignore` 排除。
- 预编译的 Z3 运行时需要时执行：

  ```powershell
  powershell -ExecutionPolicy Bypass -File scripts\fetch_z3.ps1
  ```

- 换行与二进制属性由 [.gitattributes](.gitattributes) 统一（文本 LF；`.bat`/`.ps1`
  工作区 CRLF；DLL/LIB 标记为 binary）。

## 许可证

本项目采用 **MIT License**，见 [LICENSE](LICENSE)。

`lib/` 下的 Z3 C SDK 是第三方组件，同样使用 MIT 许可证，其原始许可证见
[lib/LICENSE.txt](lib/LICENSE.txt)，来源与版本见 [lib/README.md](lib/README.md)。

