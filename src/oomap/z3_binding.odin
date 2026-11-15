package oomap

// 64 字符地址编码器 —— Z3 C API 最小子集绑定（运行时动态加载）
//
// prompt.md 要求 Z3 不可用时 family 0 仍可工作，family 1..3 返回 .MissingZ3。
// 因此这里不用编译期 foreign import，而是用 core:dynlib 在运行时加载
// libz3.dll / libz3.so / libz3.dylib，函数签名与 Z3 官方 C API 保持一致
// （见 include/z3_api.h，调用约定为 cdecl）。
//
// 对应 prompt.md 第 5、7、10 节。

import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:reflect"
import "core:sync"

Z3_config :: distinct rawptr
Z3_context :: distinct rawptr
Z3_sort :: distinct rawptr
Z3_ast :: distinct rawptr
Z3_symbol :: distinct rawptr
Z3_solver :: distinct rawptr
Z3_model :: distinct rawptr
Z3_optimize :: distinct rawptr
Z3_params :: distinct rawptr

// prompt.md 第 10 节要求的最小 FFI 集合，外加建模需要的少量函数。
Z3_API :: struct {
	__handle:                     dynlib.Library,
	Z3_get_version:               proc "c" (major, minor, build, revision: ^u32),
	Z3_mk_config:                 proc "c" () -> Z3_config,
	Z3_del_config:                proc "c" (cfg: Z3_config),
	Z3_mk_context:                proc "c" (cfg: Z3_config) -> Z3_context,
	Z3_del_context:               proc "c" (ctx: Z3_context),

	Z3_mk_bv_sort:                proc "c" (ctx: Z3_context, sz: u32) -> Z3_sort,
	Z3_mk_string_symbol:          proc "c" (ctx: Z3_context, s: cstring) -> Z3_symbol,
	Z3_mk_const:                  proc "c" (ctx: Z3_context, name: Z3_symbol, ty: Z3_sort) -> Z3_ast,
	Z3_mk_unsigned_int:           proc "c" (ctx: Z3_context, v: u64, ty: Z3_sort) -> Z3_ast,

	Z3_mk_bvadd:                  proc "c" (ctx: Z3_context, a, b: Z3_ast) -> Z3_ast,
	Z3_mk_bvsub:                  proc "c" (ctx: Z3_context, a, b: Z3_ast) -> Z3_ast,
	Z3_mk_bvxor:                  proc "c" (ctx: Z3_context, a, b: Z3_ast) -> Z3_ast,
	Z3_mk_bvurem:                 proc "c" (ctx: Z3_context, a, b: Z3_ast) -> Z3_ast,
	Z3_mk_bvslt:                  proc "c" (ctx: Z3_context, a, b: Z3_ast) -> Z3_ast,
	Z3_mk_bvule:                  proc "c" (ctx: Z3_context, a, b: Z3_ast) -> Z3_ast,
	Z3_mk_zero_ext:               proc "c" (ctx: Z3_context, i: u32, a: Z3_ast) -> Z3_ast,

	Z3_mk_eq:                     proc "c" (ctx: Z3_context, a, b: Z3_ast) -> Z3_ast,
	Z3_mk_and:                    proc "c" (ctx: Z3_context, num: u32, args: [^]Z3_ast) -> Z3_ast,
	Z3_mk_or:                     proc "c" (ctx: Z3_context, num: u32, args: [^]Z3_ast) -> Z3_ast,
	Z3_mk_ite:                    proc "c" (ctx: Z3_context, c, a, b: Z3_ast) -> Z3_ast,

	Z3_mk_solver:                 proc "c" (ctx: Z3_context) -> Z3_solver,
	Z3_solver_inc_ref:            proc "c" (ctx: Z3_context, s: Z3_solver),
	Z3_solver_dec_ref:            proc "c" (ctx: Z3_context, s: Z3_solver),
	Z3_solver_assert:             proc "c" (ctx: Z3_context, s: Z3_solver, a: Z3_ast),
	Z3_solver_check:              proc "c" (ctx: Z3_context, s: Z3_solver) -> i32,
	Z3_solver_get_model:          proc "c" (ctx: Z3_context, s: Z3_solver) -> Z3_model,
	Z3_solver_set_params:         proc "c" (ctx: Z3_context, s: Z3_solver, p: Z3_params),

	Z3_model_eval:                proc "c" (ctx: Z3_context, m: Z3_model, t: Z3_ast, model_completion: b32, out: ^Z3_ast) -> bool,
	Z3_get_numeral_uint64:        proc "c" (ctx: Z3_context, v: Z3_ast, out: ^u64) -> bool,

	Z3_mk_optimize:               proc "c" (ctx: Z3_context) -> Z3_optimize,
	Z3_optimize_inc_ref:          proc "c" (ctx: Z3_context, o: Z3_optimize),
	Z3_optimize_dec_ref:          proc "c" (ctx: Z3_context, o: Z3_optimize),
	Z3_optimize_assert:           proc "c" (ctx: Z3_context, o: Z3_optimize, a: Z3_ast),
	Z3_optimize_minimize:         proc "c" (ctx: Z3_context, o: Z3_optimize, a: Z3_ast) -> u32,
	Z3_optimize_check:            proc "c" (ctx: Z3_context, o: Z3_optimize, num_assumptions: u32, assumptions: [^]Z3_ast) -> i32,
	Z3_optimize_get_model:        proc "c" (ctx: Z3_context, o: Z3_optimize) -> Z3_model,
	Z3_optimize_set_params:       proc "c" (ctx: Z3_context, o: Z3_optimize, p: Z3_params),

	Z3_mk_params:                 proc "c" (ctx: Z3_context) -> Z3_params,
	Z3_params_inc_ref:            proc "c" (ctx: Z3_context, p: Z3_params),
	Z3_params_dec_ref:            proc "c" (ctx: Z3_context, p: Z3_params),
	Z3_params_set_uint:           proc "c" (ctx: Z3_context, p: Z3_params, k: Z3_symbol, v: u32),

	Z3_get_error_code:            proc "c" (ctx: Z3_context) -> u32,
	Z3_get_error_msg:             proc "c" (ctx: Z3_context, code: u32) -> cstring,
}

WHEN_OS :: ODIN_OS

z3_api: Z3_API
z3_loaded: bool
z3_attempted: bool
z3_override_path: string
z3_version_cache: [4]u32
z3_mutex: sync.Mutex

/*
是否可用（首次调用时尝试加载）。不可用时不会 panic，只返回 false。
*/
z3_available :: proc() -> bool {
	if z3_attempted {
		return z3_loaded
	}
	sync.mutex_lock(&z3_mutex)
	defer sync.mutex_unlock(&z3_mutex)
	if !z3_attempted {
		z3_attempted = true
		z3_loaded = z3_try_load()
	}
	return z3_loaded
}

/*
强制重新探测（测试用：传非空 override 时只尝试该路径）。
*/
@(private)
z3_reset :: proc(override_path: string = "") {
	sync.mutex_lock(&z3_mutex)
	defer sync.mutex_unlock(&z3_mutex)
	if z3_loaded {
		dynlib.unload_library(z3_api.__handle)
	}
	z3_api = {}
	z3_loaded = false
	z3_attempted = false
	z3_override_path = override_path
	z3_version_cache = {}
}

z3_version :: proc() -> [4]u32 {
	if !z3_available() {
		return {}
	}
	if z3_version_cache == {} {
		major, minor, build, revision: u32
		z3_api.Z3_get_version(&major, &minor, &build, &revision)
		z3_version_cache = {major, minor, build, revision}
	}
	return z3_version_cache
}

z3_version_string :: proc() -> string {
	if !z3_available() {
		return "Z3 不可用"
	}
	v := z3_version()
	return fmt.aprintf("Z3 %d.%d.%d", v[0], v[1], v[2])
}

@(private)
z3_try_load :: proc() -> bool {
	paths: [8]string
	count := 0

	if len(z3_override_path) > 0 {
		paths[count] = z3_override_path
		count += 1
	} else {
		when ODIN_OS == .Windows {
			paths[count] = "libz3.dll"
			count += 1
			paths[count] = "lib\\libz3.dll"
			count += 1
			paths[count] = "lib/libz3.dll"
			count += 1
			if dir, err := os.get_executable_directory(context.temp_allocator); err == nil {
				paths[count] = fmt.aprintf("%s\\libz3.dll", dir, allocator = context.temp_allocator)
				count += 1
				paths[count] = fmt.aprintf("%s\\lib\\libz3.dll", dir, allocator = context.temp_allocator)
				count += 1
			}
		} else {
			paths[count] = "libz3.so"
			count += 1
			paths[count] = "lib/libz3.so"
			count += 1
			paths[count] = "libz3.dylib"
			count += 1
			paths[count] = "lib/libz3.dylib"
			count += 1
		}
	}

	for i in 0 ..< count {
		z3_api = {}
		symbols, _ := dynlib.initialize_symbols(&z3_api, paths[i])
		if symbols <= 0 {
			continue
		}
		if z3_api_complete() {
			return true
		}
		if z3_api.__handle != nil {
			dynlib.unload_library(z3_api.__handle)
		}
		z3_api = {}
	}
	return false
}

@(private)
z3_api_complete :: proc() -> bool {
	for field in reflect.struct_fields_zipped(Z3_API) {
		if field.name == "__handle" || field.name == "Z3_get_version" {
			continue
		}
		if !reflect.is_procedure(field.type) {
			continue
		}
		ptr := rawptr(uintptr(&z3_api) + field.offset)
		if (^rawptr)(ptr)^ == nil {
			return false
		}
	}
	return z3_api.Z3_get_version != nil
}

