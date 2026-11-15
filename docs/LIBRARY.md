# 作为第三方 Odin 库使用 OOMap

本文面向**在自己的 Odin 项目里导入 OOMap** 的调用方。仓库自带的
`cmd/oomap_demo` 是一个外部调用示例；库本身的包名是 `oomap`。

> 版本：Odin `dev-2026-10-nightly`，Windows x64 实测；Z3 为可选运行时依赖。

## 1. 导入

库代码在 `src/oomap/`，包名 `oomap`。Odin 的相对导入路径相对于**发起导入的
源文件**，例如从 `cmd/oomap_demo/main.odin` 导入：

```odin
import oomap "../../src/oomap"
```

如果你的项目把库复制到了 `vendor/oomap/`，则写：

```odin
import oomap "../../vendor/oomap"
```

Odin 没有 `using`/点导入；调用时统一加 `oomap.` 前缀。所有**没有**标注
`@(private)` 的声明都可以从包外访问。

## 2. 最小示例

```odin
package main

import "core:fmt"
import oomap "../../src/oomap"

main :: proc() {
    e := oomap.encoder_init()
    defer oomap.encoder_destroy(&e)

    data := []u8{0xDE, 0xAD, 0xBE, 0xEF}
    head, err := oomap.add(&e, "A", data)
    if err != .None {
        fmt.eprintln("add failed:", err)
        return
    }
    fmt.println("segment head =", head)

    info: oomap.WrapInfo
    defer oomap.wrap_info_destroy(&info)
    if wrap_err := oomap.wrap_ex(&e, 5_000, &info); wrap_err != .None {
        fmt.eprintln("wrap failed:", wrap_err, info.message)
        return
    }
    fmt.println("solved by family", info.solved_family)

    ok, bad := oomap.verify(&e)
    if !ok {
        if b, has := bad.?; has {
            fmt.eprintln("verify failed:", b.key, b.want, b.got)
        }
        return
    }

    // 原始字节 + 原始长度（4 字节，无填充）
    got, length, read_ok := oomap.read_data_exact(&e, "A")
    defer delete(got)
    if !read_ok || length != len(data) {
        fmt.eprintln("read failed")
        return
    }
    fmt.println("read", length, "bytes:", got)

    // wrap 结果只占前 128 个 u32，可作为固定大小数组交给服务端
    solution := oomap.solution_snapshot(&e)
    defer delete(solution)
    fmt.println("solution words =", len(solution))
}
```

## 3. 公开 API

### 3.1 生命周期

| API | 说明 |
|-----|------|
| `encoder_init() -> Encoder` | 创建空编码器：cache 256 个 u32 全 0，entries 为空 |
| `encoder_destroy(*Encoder)` | 释放 cache、entries 中克隆的 key、精确长度表；之后编码器不可再用 |
| `encoder_from_cache(cache []u32) -> (Encoder, ErrorCode)` | 从完整 cache 复制重建；Entries 自动恢复，初始为 `frozen` |

`Encoder` 内部持有动态数组和 `map`，**不要按值复制**（`e2 := e` 会造成双重释放/
共享状态）。`encoder_init` 的返回值、`encoder_from_cache` 的返回值可以正常移动。

### 3.2 写入样本

| API | 说明 |
|-----|------|
| `add(e, key, data []u8) -> (head u32, ErrorCode)` | 旧格式段；返回段起点 head |
| `add_u32(e, key, data []u32) -> (head u32, ErrorCode)` | 旧格式段的快速路径：`data` 已是小端 u32 字，直接整段写入 |
| `add_framed(e, key, data []u8) -> (head u32, ErrorCode)` | `0xFF00FFxx` 帧格式；语义与 add 相同 |

三者都会：校验 frozen / 空 key / Σ 外字符 / 重复 key；把 key 克隆进
`e.entries`；把原始数据长度记录到内存表。失败时**不修改任何状态**。
重复 key 检查由 `Encoder` 内的 `map[string]u32` 完成，正常批量写入是期望 O(1)。

`add_u32` 的段格式与 `add` 完全一致，只是省掉逐字节打包循环；原始字节数固定为
`4 * len(data)`，没有填充。数据较小（例如 1~2 个 word）时固定开销仍占主导，
优势主要在大载荷；实测 4 KiB 载荷约快 8 倍（见
[PERFORMANCE.md](PERFORMANCE.md)）。

`head` 由 `len(cache)` 决定，所以调用方不能指定 head。若需要固定 head，可先用
`cache_view` 读出 cache 长度并追加 0 填充，但这是高级用法，且必须保证后续
`add` / `add_u32` / `add_framed` 的段起点与目标 head 一致。

### 3.3 求解与校验

| API | 说明 |
|-----|------|
| `wrap(e, timeout_ms = 30_000) -> ErrorCode` | 便捷入口，丢弃诊断信息 |
| `wrap_ex(e, timeout_ms, *WrapInfo) -> ErrorCode` | 主流程；成功后写 cache 并置 frozen |
| `wrap_info_destroy(*WrapInfo)` | 释放 `message` |
| `verify(e) -> (bool, Maybe(VerifyBad))` | 纯 Odin 重放；不调用 Z3 |
| `eval(cache []u32, key) -> (u32, bool)` | 只按 mode/param 求值，不读数据段 |

**wrap 成功后的只读模式**：`wrap_ex` 在提交解之后会删除重复检查索引；如果每个
entry 都能在 cache 中找到对应数据段，则释放 `entries`（样本 key），只保留 cache
与长度表，便于长期服务外部读取。此时：

- `read_data` / `read_data_exact` / `data_length` / `solution_snapshot` 正常；
- `verify` 会按需从 cache 重建 entries，成功后立即释放；失败时保留它们，以便
  `bad.key` 在调用方读取期间有效；
- `add` / `add_framed` / `add_u32` 返回 `.Frozen`。

如果需要保留 samples 做别的事情，请在调用 `wrap` 之前自行复制 `entries`。

`WrapInfo` 字段：`solved_family`（-1 表示失败）、`families_tried`、`missing_z3`、
`timed_out`、`message`。`message` 由 `wrap_info_destroy` 释放，不要自己 `delete`。

`ErrorCode`：

| 值 | 含义 |
|----|------|
| `.None` | 成功 |
| `.EmptyKey` | key 为空 |
| `.InvalidCharacter` | key 含 Σ 外字符 |
| `.DuplicateKey` | 重复 key |
| `.Frozen` | wrap 已成功，或从 cache 恢复，禁止再改 |
| `.Infeasible` | 所有 family 都无解 |
| `.Timeout` | 总预算耗尽 |
| `.MissingZ3` | 需要 family 1..3 但 Z3 动态库不可用 |
| `.InternalError` | 内部一致性错误（损坏的 cache 等） |

### 3.4 数据回读

| API | 返回长度 | 说明 |
|-----|----------|------|
| `read_data(e, key)` | `ceil(n/4)*4` | 4 字节对齐，末尾补 0 |
| `read_data_exact(e, key)` | `n` | **原始字节数**；要求本 Encoder 记录过长度 |
| `read_data_exact_len(e, key, n)` | `n` | 由调用方给出长度；校验 n 不超过段字数*4 且填充全 0 |
| `data_length(e, key)` | — | 查询记录的原始长度（不读数据） |

返回的 `[]u8` 都由调用方 `delete`（长度为 0 时也可安全 `delete`）。

`n = 0`、末尾恰好是 `0x00` 的数据都能正确区分：`read_data_exact` 只按记录的
长度截断，不会把原始尾随 0 当成填充。`add_u32` 写入的段，其 `n` 为
`4 * len(data)`。

### 3.5 持久化

| API | 说明 |
|-----|------|
| `cache_view(e) -> []u32` | cache 的只读切片；仅在 Encoder 存活且未扩容期间有效 |
| `encoder_from_cache(cache) -> (Encoder, ErrorCode)` | 复制 cache 并恢复 Entries |
| `solution_snapshot(e) -> []u32` | 前 128 个 u32 的独立副本（mode+param） |
| `entries_from_cache(cache) -> ([dynamic]Entry, ErrorCode)` | 只解析 Entries，不构造 Encoder |

保存示例：

```odin
view := oomap.cache_view(&e)
saved := make([]u32, len(view))
copy(saved, view)
// 把 saved 按小端写成字节；同时另存每个 key 的 data_length
```

加载：

```odin
restored, err := oomap.encoder_from_cache(saved)
defer oomap.encoder_destroy(&restored)
```

**重要限制**：两种段格式只保存 `u32` 字数，不保存原始字节数；原始长度只存在
Encoder 的内存表里。`encoder_from_cache` 恢复出的编码器：

- `read_data`、`read_data_exact_len` 可用；
- `read_data_exact` 返回 `ok=false`；
- 需要精确长度时，调用方必须自己持久化 `data_length(e, key)`，加载后用
  `read_data_exact_len(e, key, saved_len)`。

### 3.6 字符集与诊断

| API | 说明 |
|-----|------|
| `char_index(ch rune) -> (u8, bool)` | 字符在 Σ 中的下标 |
| `z3_available() -> bool` | 动态库是否可加载；首次调用探测，之后缓存结果 |
| `z3_version() -> [4]u32` | major/minor/build/revision；不可用时全 0 |
| `z3_version_string() -> string` | 人类可读版本；**返回的是分配字符串，调用方 delete** |

常量：`CHAR_COUNT = 64`、`X0 = 31`、`SIGMA`、`PARAM_OFFSET = 64`、
`MODE_PARAM_END = 128`、`RESERVED_LEN = 256`。

## 4. 所有权与内存规则

1. `Encoder` 拥有 `entries` 中每个 `key` 的副本；`encoder_destroy` 统一释放。
2. `read_data*`、`solution_snapshot`、`z3_version_string` 返回调用方拥有的内存；
   必须 `delete`。
3. `entries_from_cache` 返回的每个 `Entry.key` 都是新分配的；释放方式：

   ```odin
   entries, err := oomap.entries_from_cache(cache)
   defer {
       for entry in entries { delete(entry.key) }
       delete(entries)
   }
   ```

4. `wrap_info_destroy` 之后 `WrapInfo.message` 失效；不要复制 `WrapInfo` 后重复
   destroy。
5. `cache_view` 返回的切片在 `add` / `add_u32` / `add_framed` 导致 cache 扩容后失效。
6. `wrap` 成功会删除 `index`，并在 entries 可恢复时释放 `entries`；不要继续持有
   旧的 `Entry.key` 指针。

## 5. 线程安全

- 一个 `Encoder` 同一时刻只能被一个线程使用；`add`、`wrap`、`read_data` 都会读写
  cache/entries。
- 多个 Encoder 可以并行，但 `wrap` 的 Z3 路径共享进程级动态库句柄；Z3 为每次
  求解创建独立 context，常规并发可用，但本项目没有做压力验证。
- `z3_available` 的首次加载有互斥保护；`z3_reset` 是测试用内部函数，已标记
  `@(private)`，外部不可调用。
- `verify` 只读；但前提是没有其他线程同时修改同一个 Encoder。

## 6. 应禁止外部调用的函数

### 6.1 编译期强制（`@(private)`）

下面这些声明只能在 `oomap` 包内使用；包外调用会编译失败：

| 函数 | 原因 |
|------|------|
| `check_addable` | 入参校验的一部分，必须先于任何 append |
| `free_entry_list` / `parse_legacy_entry` / `parse_framed_entry` / `unpack_key` | cache 解析内部实现，错误处理会释放已分配的 key |
| `apply` | 单字符运算原语；mode 范围和回绕语义由 `eval` 保证 |
| `verify_with` | 对任意工作缓冲区重放；会绕过“只有提交后才改 cache”的约定 |
| `locate_segment*` / `read_segment_exact` / `packed_key_matches` / `unpack_words` | 段定位/解包内部实现，越界检查与 key 校验耦合 |
| `pure_solve` / `solve_full_rank` / `solve_mod_2_32` / `lift_solution` / `solve_gf2` / `solve_kernel_lift` / `gf2_solve_k` / `inv_odd` | family 0 求解器内部步骤，不保证输入/输出契约 |
| `elapsed_ms` / `tried_families_string` / `commit_solution` / `compact_after_wrap` / `entries_recoverable` / `z3_solve_family` / `z3_model_uint64` / `z3_release` | wrap 调度、清理与 Z3 资源释放内部实现 |
| `z3_reset` / `z3_try_load` / `z3_api_complete` | 进程级 Z3 全局状态；`z3_reset` 会让正在进行的求解失效 |

### 6.2 公开但“不要碰”的状态

Odin 的字段没有 `@(private)`，下面这些字段从包外**语法上可见**，但属于内部状态：

| 字段 | 风险 |
|------|------|
| `Encoder.cache` | 直接 append/改元素会破坏 head、段边界、frozen 语义；扩容会让 `cache_view` 失效 |
| `Encoder.entries` | 直接 append 不会克隆 key、不会去重、不会更新精确长度表 |
| `Encoder.index` | 重复检查索引；手工修改会破坏 O(1) 检查，wrap 后会被清空 |
| `Encoder.data_lens` | 长度表必须与段内容一致，否则 `read_data_exact` 会误判 |
| `Encoder.frozen` | 绕过 frozen 会让已提交的 wrap 结果失效 |
| `WrapInfo.*` | `message` 由 destroy 释放；复制结构体会双重释放 |
| `Entry.key/head` | 修改后 verify/wrap/read 的约束将不再一致 |

安全做法：只用本文列出的函数和只读访问器（`cache_view`、`solution_snapshot`、
`data_length`）。如果确实需要构造自定义 head 的样本，请在库的 issue/需求里提出，
不要直接改字段。

### 6.3 可以用但要注意

- `eval(cache, key)`：服务端只需要前 128 个 u32（`solution_snapshot` 的结果）即可
  计算 head；cache 少于 128 个 u32 或 mode > 3 时返回 `ok=false`。
- `verify(e)`：只做语义重放，**不校验** mode 是否属于某个 family；这是第 8 节
  规格的约定，不是安全边界。
- `read_data_exact_len`：长度由调用方给出；只会检查“不超过段字数*4 且填充全 0”，
  如果长度本身就错，仍可能返回错误数据。优先用 `read_data_exact`。
- `z3_version_string`：每次调用都会分配；热路径请缓存结果。

## 7. Z3 的部署

OOMap 不链接 `libz3.lib`，而是在运行时用 `core:dynlib` 加载：
Windows 依次尝试 `libz3.dll`、`lib\libz3.dll`、exe 同目录、exe 同目录下的
`lib\libz3.dll`；Linux/macOS 尝试 `libz3.so` / `libz3.dylib`。

- 没有 Z3：`add` / `wrap` 仍可用；family 0 正常，需要 1..3 时返回 `.MissingZ3`。
- 有 Z3：放到 exe 同目录或工作目录的 `lib/` 下即可；不需要重新编译。
- 仓库里的 `lib/` 默认不包含 DLL，用
  `powershell -ExecutionPolicy Bypass -File scripts\fetch_z3.ps1` 获取。

## 8. 兼容性与限制

- 目前只在 Windows x64 + Odin `dev-2026-10-nightly` + Z3 5.3.3 上实测。
- `wrap` 的总超时不是硬实时：family 0 是同步求解，Z3 Optimize 可能在
  `timeout_ms` 之后才返回（见 [PERFORMANCE.md](PERFORMANCE.md) 的实测）。
- 重复 key：`add` / `add_u32` / `add_framed` 拒绝；`wrap` 对“同 key 不同 head”
  返回 `.Infeasible`，对“同 key 同 head”返回 `.DuplicateKey`。
- `wrap` 成功后 `index` 会被清空；可恢复的 `entries` 也会被释放。`verify` 之后的
  调用是“按需重建”，比 wrap 之前多一次 cache 解析开销，但不会长期占用样本内存。
  手工构造、没有数据段的 samples 无法从 cache 恢复，会保留 `entries` 供 verify
  使用。
- `read_data_exact` 依赖内存中的长度表；从 cache 恢复后必须用
  `read_data_exact_len` 或另存长度。
- `entries_from_cache` 从下标 256 开始顺序扫描，允许段间 0 填充；损坏的非零
  标记返回 `.InternalError`。
