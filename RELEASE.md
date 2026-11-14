# OOMap v1.0.0

**OOMap** 是一个用 Odin 实现的 **64 字符地址编码器**：给定若干 `(key, head)` 样本，
为字符集 `.`、`0`–`9`、`A`–`Z`、`_`、`a`–`z` 各求一个 `u32` 操作参数，使每个 key
按从左到右求值后严格等于其 `head`。有解则精确求解并通过重放校验，无解/超时/缺
Z3 时明确报告，不伪造成功。

## 核心特性

- **4 档 family 逐级求解**：纯 ADD → ADD/SUB → +XOR → +MOD，共享总超时预算
- **family 0 纯 Odin**：GF(2) 消元 + 逐位提升；满秩走奇数主元高斯消元，秩亏走
  核空间提升，1000 条样本约 1–4 ms
- **可选 Z3**：`core:dynlib` 运行时加载；family 3 用 `Optimize` 最小化
  `Σ|param|` 与 `Σmode`；缺 Z3 时 family 0 照常工作，其余返回 `.MissingZ3`
- **编码与回读**：`add` / `add_framed` 两种段格式；`read_data` 用求解结果把
  字符串解码回 `[]u8`
- **cache 还原**：`entries_from_cache` 从 `[]u32` 还原 `[dynamic]Entry`，支持两种
  段格式与段间 0 填充
- **64 字符 / 256 保留区**：`cache[0..63]` mode，`[64..127]` param，`[128..255]`
  保留；`solution_snapshot` 可复制前 128 个结果 u32
- **可复现测试**：10 个 `odin test` 单元测试、独立进程验收、`test.csv` 端到端
  计时（附 Python 生成器）

## 快速开始

```bat
:: 1. 获取 Z3 运行时（可选；family 0 不需要）
powershell -ExecutionPolicy Bypass -File scripts\fetch_z3.ps1

:: 2. 构建并运行 demo
build.bat
bin\OOMap.exe

:: 3. 测试
odin test src
bin\OOMap.exe --check-pure
bin\OOMap.exe --check-z3
python scripts\gen_test_csv.py
bin\OOMap.exe --test-csv
```

一键验收：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\run_acceptance.ps1
```

## 本版本验证

- `odin test src`：10/10 通过
- 往返（5/20/64/65/1000 条）与 1000 条性能：family 0 全部通过，约 1–4 ms
- family 3 多解最小 `|p|`：MOD 最小解 `p=4`、`mode=3`
- 100 ms 超时：`.Timeout`，约 140 ms 返回
- 缺 Z3：family 3 返回 `.MissingZ3`，family 0 仍成功
- `test.csv`：200/200，约 0.8 s

## 仓库与 Z3

仓库只跟踪源码、文档、脚本和 Z3 头文件；`bin/`、`*.exe`、`lib/*.dll`、
`lib/*.lib` 等构建产物/预编译二进制不进入 Git。首次 clone 后需要 Z3 时运行
`scripts/fetch_z3.ps1`（带 SHA256 校验），或按 `lib/README.md` 手动放置。

## 环境

- Windows x64（Linux/macOS 的加载路径已写，未实测）
- Odin `dev-2026-10-nightly`
- Z3 5.3.3（可选）

## 许可证

MIT。第三方 Z3 SDK 使用 MIT 许可证，详见 `lib/LICENSE.txt`。
