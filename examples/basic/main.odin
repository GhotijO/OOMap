package main

// 最小第三方调用示例：只导入库包，不复制任何库内符号。
// 构建：odin build examples/basic -out:bin/oomap_example.exe

import "core:fmt"
import oomap "../../src/oomap"

main :: proc() {
	e := oomap.encoder_init()
	defer oomap.encoder_destroy(&e)

	data := []u8{0xDE, 0xAD, 0xBE, 0xEF, 0x00}
	head, add_err := oomap.add(&e, "A", data)
	if add_err != .None {
		fmt.eprintln("add failed:", add_err)
		return
	}
	fmt.println("head =", head)

	info: oomap.WrapInfo
	defer oomap.wrap_info_destroy(&info)
	if wrap_err := oomap.wrap_ex(&e, 5_000, &info); wrap_err != .None {
		fmt.eprintln("wrap failed:", wrap_err, info.message)
		return
	}

	got, length, ok := oomap.read_data_exact(&e, "A")
	defer delete(got)
	if !ok || length != len(data) {
		fmt.eprintln("read_data_exact failed")
		return
	}
	fmt.println("exact bytes =", length, "family =", info.solved_family)

	solution := oomap.solution_snapshot(&e)
	defer delete(solution)
	fmt.println("solution words =", len(solution))
}
