#!/usr/bin/env python3
"""生成 OOMap 的 test.csv（两列：字符串, 十六进制数据）。

默认写到项目根目录的 bin/test.csv，即 build.bat 生成的 OOMap.exe 同目录，
这样 `bin\\OOMap.exe --test-csv` 能直接找到它。

用法:
    python scripts/gen_test_csv.py [输出路径] [行数]

示例:
    python scripts/gen_test_csv.py
    python scripts/gen_test_csv.py bin/test.csv 500
"""

from __future__ import annotations

import random
import sys
from pathlib import Path

SIGMA = ".0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz"
DEFAULT_ROWS = 200
SEED = 2026_1114


def make_key(rng: random.Random) -> str:
    length = rng.randint(1, 12)
    return "".join(rng.choice(SIGMA) for _ in range(length))


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "bin" / "test.csv"
    rows = int(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_ROWS
    if rows <= 0:
        print("rows must be positive", file=sys.stderr)
        return 2

    rng = random.Random(SEED)
    seen: set[str] = set()
    lines: list[str] = []
    while len(lines) < rows:
        key = make_key(rng)
        if key in seen:
            continue
        seen.add(key)
        size = rng.randint(0, 16)
        data = bytes(rng.randrange(256) for _ in range(size))
        lines.append(f"{key},{data.hex().upper()}")

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines) + "\n", encoding="ascii")
    print(f"wrote {len(lines)} rows to {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
