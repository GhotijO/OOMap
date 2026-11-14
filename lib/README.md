# Z3 C 库（Z3 C SDK，Windows x64）

本目录提供项目运行时可选的 Z3 C SDK。仓库只跟踪头文件与许可证；体积较大的
**DLL / LIB 二进制不进入 Git**，克隆后请运行：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\fetch_z3.ps1
```

| 项目 | 值 |
|------|-----|
| 版本 | Z3 5.3.3（64-bit，build hashcode `430d19e697e2ec9bad79ff210d41b4a7a5fcfa3e`） |
| 平台 | Windows x64（PE32+） |
| 来源 | <https://github.com/Z3Prover/z3/releases/tag/z3-5.3.3> |
| 发行包 | `z3-5.3.3-x64-win.zip` |
| 发行包 SHA256 | `4E48624A6895B49606B3CF91CA4FBCC069FB2973B9706532170A144BAA3FD798` |
| 许可证 | MIT（见 `LICENSE.txt`） |

## 目录内容

Git 跟踪：

| 路径 | 说明 |
|------|------|
| `include/` | 官方 C/C++ 头文件（`z3.h`、`z3_api.h`、`z3_optimization.h` 等 14 个） |
| `LICENSE.txt` | Z3 的 MIT 许可证 |
| `README.md` | 本说明 |

`fetch_z3.ps1` 生成（被 `.gitignore` 忽略）：

| 路径 | 说明 |
|------|------|
| `libz3.dll` | Z3 C API 动态库（运行时必需），SHA256 `B6A30C2922293C2A2CAB4299637935302D8FB0427762B5A3D2DC16F392F27B8C` |
| `libz3.lib` | 官方导入库（本项目通过 `core:dynlib` 动态加载，链接期不需要它，保留仅供其他 C 调用方使用） |
| `msvcp140*.dll`、`vcruntime140*.dll`、`vcomp140.dll` | Z3 发行包自带的 MSVC 运行库，需与 `libz3.dll` 同目录 |

注意：官方发行包里的 DLL 名是 **`libz3.dll`**（不是 `z3.dll`）。

## 运行时加载方式

`src/z3_binding.odin` 使用 `core:dynlib` 在运行时按以下顺序查找：

1. `libz3.dll`
2. `lib\libz3.dll`
3. `lib/libz3.dll`
4. 可执行文件同目录下的 `libz3.dll`、`lib\libz3.dll`

`build.bat` / `build.sh` 会把 `lib/*.dll` 复制到 `bin/`，因此从仓库根目录运行
`bin\OOMap.exe` 可以直接加载。缺 Z3 时程序仍可启动：family 0 正常，family 1..3
返回 `.MissingZ3`。

## 校验方式

```powershell
Get-FileHash .\libz3.dll, .\libz3.lib -Algorithm SHA256
```
