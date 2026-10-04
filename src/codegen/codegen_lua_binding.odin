package codegen
import "core:log"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:path/filepath"
import "core:os"
import "core:odin/ast"
import "core:odin/parser"

Ffi_Type_Info :: struct {
    name:         string,
    lua_global:   string,
    transmute_as: string,
}

Codegen :: struct {
    structs:   map[string]Struct_Info,
    ffi_types: map[string]Ffi_Type_Info,
    procs:     map[string]Proc_Info,
    enum_types: map[string]bool,   // plain enum type names (marshalled to Lua as integers)
    flag_types: map[string]bool,   // bit_set alias type names (marshalled to Lua as integers)
    int_types:  map[string]string, // @(lua_int="<backing>") types (e.g. handles) marshalled via transmute
    logger:    log.Logger
}
codegen: Codegen

Struct_Info :: struct {
    name: string,
    fields: [dynamic]Struct_Field,
}

Struct_Field :: struct {
    name: string,
    type: string,
}

Proc_Info :: struct {
    odin_proc_name: string,
    odin_wrapper_name: string,
    lua_name: string,
    lua_name_zh: string,
    lua_table: string,
    is_method: bool,
    docs: string,   // the proc's // doc comment as LuaLS "---" lines (codegen_lua_defs.odin); "" = none
    params: [dynamic]Proc_Param,
    returns: [dynamic]Proc_Return,
}

Proc_Param :: struct {
    name: string,
    type: string,
    default: string,   // the default's source text ("1", "{0, 0, 0}"): the Lua argument is optional; "" = required
}

Proc_Return :: struct {
    type: string,
}

scan_folder :: proc(path: string) {
    f, err := os.open(path)
    if err != nil { return }
    defer os.close(f)

    it := os.read_directory_iterator_create(f)
    defer os.read_directory_iterator_destroy(&it)

    for info in os.read_directory_iterator(&it) {
        if info.type == .Directory && info.name != "codegen" {
            scan_folder(info.fullpath)
        } else if filepath.ext(info.name) == ".odin" && !strings.has_prefix(info.name, "gen_") {
            parse_file(info.fullpath)
        }
    }
}

parse_file :: proc(path: string) {
    src, err := os.read_entire_file(path, context.allocator)
    if err != nil do return

    file := ast.File{fullpath = path, src = string(src)}
    p := parser.default_parser()
    parser.parse_file(&p, &file)

    for decl in file.decls {
        val, ok := decl.derived.(^ast.Value_Decl)
        if !ok || len(val.names) == 0 || len(val.values) == 0 { continue }

        attr_map := make(map[string]string, context.temp_allocator)
        
        // Attributes
        for attr in val.attributes {
            for elem in attr.elems {
                // @(lua)
                if id, is_id := elem.derived_expr.(^ast.Ident); is_id {
                    attr_map[id.name] = ""
                }
                if fv, is_fv := elem.derived_expr.(^ast.Field_Value); is_fv {
                    if id, is_id := fv.field.derived.(^ast.Ident); is_id {
                        // @(lua=my_log)
                        if val_id, is_val_id := fv.value.derived_expr.(^ast.Ident); is_val_id {
                            attr_map[id.name] = val_id.name
                        }
                        // @(lua="my_log")
                        if lit, is_lit := fv.value.derived_expr.(^ast.Basic_Lit); is_lit {
                            raw := lit.tok.text
                            if len(raw) >= 2  do attr_map[id.name] = raw[1:len(raw)-1]
                        }
                    }
                }
            }
        }

        name_id, _ := val.names[0].derived_expr.(^ast.Ident)
        if name_id == nil { continue }

        if "lua_ffi" in attr_map {
            codegen.ffi_types[name_id.name] = Ffi_Type_Info{
                name         = strings.clone(name_id.name),
                lua_global   = strings.clone(attr_map["lua_ffi"]),
                transmute_as = strings.clone(attr_map["as"]),
            }
            continue
        }

        // @(lua_int="u32"): a distinct/handle type marshalled to Lua as an integer via transmute.
        if "lua_int" in attr_map {
            codegen.int_types[name_id.name] = strings.clone(attr_map["lua_int"])
            continue
        }

        if "lua" not_in attr_map { continue }
        
        #partial switch expr in val.values[0].derived_expr {
            case ^ast.Struct_Type: {
                if struct_info, struct_ok := parse_struct(name_id, expr); struct_ok {
                    codegen.structs[struct_info.name] = struct_info
                }
            }
            case ^ast.Proc_Lit: {
                if proc_type, is_pt := expr.type.derived_expr.(^ast.Proc_Type); is_pt {
                    if proc_info, proc_ok := parse_proc(name_id, proc_type, attr_map, file.src); proc_ok {
                        if val.docs != nil {
                            lines := make([dynamic]string, context.temp_allocator)
                            for tok in val.docs.list do if strings.has_prefix(tok.text, "//") do append(&lines, tok.text)
                            proc_info.docs = lua_doc_lines(lines[:])
                        }
                        codegen.procs[proc_info.odin_proc_name] = proc_info
                    }
                }
            }
        }
    }
}

parse_struct :: proc(struct_name: ^ast.Ident, struct_type: ^ast.Struct_Type) -> (Struct_Info, bool) {
    struct_info: Struct_Info

    // Struct names
    struct_info.name = strings.clone(struct_name.name)
    
    // Struct fields
    for field in struct_type.fields.list {
        type_id, type_ok := field.type.derived_expr.(^ast.Ident)
        if !type_ok {
            log.errorf("Codegen: Unrecognised struct field type: %v", field.type.derived_expr)
            return Struct_Info{}, false
        }
        for fname in field.names {
            field_name, field_ok := fname.derived_expr.(^ast.Ident)
            if !field_ok {
                log.errorf("Codegen: Unrecognised struct field name: %v", fname.derived_expr)
                return Struct_Info{}, false
            }
            append(&struct_info.fields, Struct_Field {
                name = strings.clone(field_name.name),
                type = strings.clone(type_id.name),
            })
        }
    }
    
    return struct_info, true
}

parse_proc :: proc(proc_name: ^ast.Ident, proc_type: ^ast.Proc_Type, attributes: map[string]string, src: string) -> (Proc_Info, bool) {
    proc_info: Proc_Info
    
    cc := proc_type.calling_convention
    if cc == "\"c\"" || cc == "c" do return Proc_Info{}, false
    
    // Proc names
    proc_info.odin_proc_name = strings.clone(proc_name.name)
    proc_info.odin_wrapper_name = strings.concatenate({"_lua_", proc_info.odin_proc_name})

    if attributes["lua"] != "" {
        proc_info.lua_name = strings.clone(attributes["lua"])
    }
    else {
        proc_info.lua_name = strings.clone(proc_name.name)
    }

    // Chinese alias
    if attributes["lua_zh"] != "" {
        proc_info.lua_name_zh = strings.clone(attributes["lua_zh"])
    }

    // Method flag — combined with table= to register as metatable methods
    if "method" in attributes {
        proc_info.is_method = true
    }

    // Proc table
    if attributes["table"] != "" {
        proc_info.lua_table = strings.clone(attributes["table"])
    }

    // Proc params
    if proc_type.params != nil {
        for field in proc_type.params.list {
            param_type, parm_ok := field.type.derived_expr.(^ast.Ident)
            if !parm_ok {
                log.errorf("Codegen: Unrecognised param type: %v", field.type.derived_expr)
                return Proc_Info{}, false
            }
            for fname in field.names {
                param_name, _ := fname.derived_expr.(^ast.Ident)
                if param_name == nil do return Proc_Info{}, false
                default: string
                if d := field.default_value; d != nil do default = strings.clone(src[d.pos.offset:d.end.offset])
                append(&proc_info.params, Proc_Param {
                    name = strings.clone(param_name.name),
                    type = strings.clone(param_type.name),
                    default = default,
                })
            }
        }
    }

    // Proc returns
    if proc_type.results != nil {
        for field in proc_type.results.list {
            result_type, result_ok := field.type.derived_expr.(^ast.Ident)
            if !result_ok {
                log.errorf("Codegen: Unrecognised result type: %v", field.type.derived_expr)
                return Proc_Info{}, false
            }
            append(&proc_info.returns, Proc_Return {strings.clone(result_type.name)})
        }
    }

    return proc_info, true
}

generate_file :: proc(out_path: string) {
    if len(codegen.procs) <= 0 && len(codegen.structs) <= 0 {
        return
    }

    sb: strings.Builder
    strings.builder_init(&sb)

    fmt.sbprintfln(&sb, `// AUTO GENERATED. DO NOT EDIT`)
    fmt.sbprintfln(&sb, "")
    fmt.sbprintfln(&sb, `package blimp`)
    fmt.sbprintfln(&sb, "")
    fmt.sbprintfln(&sb, `@(require) import "base:intrinsics"`)
    fmt.sbprintfln(&sb, `@(require) import "core:strings"`)
    fmt.sbprintfln(&sb, `@(require) import "core:c"`)
    fmt.sbprintfln(&sb, `@(require) import lua "vendor:lua/5.1"`)
    fmt.sbprintfln(&sb, "")

    if len(codegen.ffi_types) > 0 {
        generate_ffi_push(&sb)
    }

    if len(codegen.structs) > 0 {
        fmt.sbprintln(&sb, "//==================== Generate Structs ====================")
        fmt.sbprintln(&sb, "")
        for struct_info in sorted_values(codegen.structs) {
            generate_struct(&sb, struct_info)
        }
    }

    if len(codegen.procs) > 0 {
        fmt.sbprintln(&sb, "//==================== Generate Procs ====================")
        fmt.sbprintln(&sb, "")
        for proc_info in sorted_values(codegen.procs) {
            generate_proc(&sb, proc_info)
        }

        fmt.sbprintln(&sb, "//==================== Register Bindings ====================")
        fmt.sbprintln(&sb, "")
        generate_register(&sb)
    }

    write_generated(out_path, strings.to_string(sb))
}

generate_struct :: proc(sb: ^strings.Builder, info: Struct_Info) {
    struct_name := info.name

    // ------------- push table -----------------------
    fmt.sbprintfln(sb, "// Binding odin struct: %v to lua table.", struct_name)
    fmt.sbprintfln(sb, "_lua_push_table_%v :: proc(L: ^lua.State, v: %v) {{", struct_name, struct_name)
    fmt.sbprintfln(sb, "    lua.createtable(L, 0, %v)", len(info.fields))
    for field in info.fields {
        if code, ok := lua_push_code(field.type, fmt.tprintf("v.%v", field.name)); ok {
            fmt.sbprintfln(sb, "    %v", code)
        } else {
            fmt.sbprintfln(sb, "    lua.pushnil(L) // unsupported struct field type: %s", field.type)
            log.errorf("Codegen: Not supported struct field type: %v", field.type)
        }
        fmt.sbprintfln(sb, "    lua.setfield(L, -2, \"%v\")", field.name)
    }
    has_methods := false
    for p in sorted_values(codegen.procs) {
        if p.is_method && p.lua_table == struct_name { has_methods = true; break }
    }
    if has_methods {
        fmt.sbprintfln(sb, `    lua.getfield(L, lua.REGISTRYINDEX, "_mt_%v")`, struct_name)
        fmt.sbprintln(sb, `    if lua.type(L, -1) != .NIL { lua.setmetatable(L, -2) } else { lua.pop(L, 1) }`)
    }
    fmt.sbprintln(sb, "}")
    fmt.sbprintln(sb, "")

    //--------------- read table --------------------
    fmt.sbprintfln(sb, "_lua_read_table_%v :: proc(L: ^lua.State, idx: c.int) -> %v {{", struct_name, struct_name)
    fmt.sbprintfln(sb, "    v: %v", struct_name)
    for field in info.fields {
        fmt.sbprintfln(sb, "    lua.getfield(L, idx, \"%v\")", field.name)
        if code, ok := lua_read_code(field.type, "-1"); ok {
            fmt.sbprintfln(sb, "    v.%v = %v", field.name, code)
        } else {
            fmt.sbprintfln(sb, "    // unsupported field type: %v", field.type)
            log.errorf("Codegen: Not supported struct field type: %v", field.type)
        }
        fmt.sbprintln(sb, "    lua.pop(L, 1)")
    }
    fmt.sbprintln(sb, "    return v")
    fmt.sbprintln(sb, "}")
    fmt.sbprintln(sb, "")
}

generate_proc :: proc(sb: ^strings.Builder, info: Proc_Info) {
    fmt.sbprintfln(sb, "// Binding odin proc: %v to lua function: %v.", info.odin_proc_name, info.lua_name)
    fmt.sbprintfln(sb, "%v :: proc \"c\" (L: ^lua.State) -> c.int {{", info.odin_wrapper_name)
    fmt.sbprintfln(sb, `    context = app.g_context`)

    // Read parameters. One with a default is optional: a number reads with the default when absent; an FFI
    // value (Vec3…) keeps the default unless one was passed.
    for param, i in info.params {
        idx := fmt.tprintf("%v", i + 1)
        switch {
        case param.default != "" && (param.type == "f32" || param.type == "f64"):
            fmt.sbprintfln(sb, "    %v := %v(lua.L_optnumber(L, %v, %v))", param.name, param.type, idx, param.default)
        case param.default != "" && slice.contains(LUA_INT_TYPES, param.type):
            fmt.sbprintfln(sb, "    %v := %v(lua.L_optinteger(L, %v, %v))", param.name, param.type, idx, param.default)
        case param.default != "" && param.type in codegen.ffi_types:
            fmt.sbprintfln(sb, "    %v: %v = %v", param.name, param.type, param.default)
            fmt.sbprintfln(sb, "    if !lua.isnoneornil(L, %v) do %v = _lua_read_ffi_%v(L, %v)", idx, param.name, param.type, idx)
        case:
            if code, ok := lua_read_code(param.type, idx); ok {
                fmt.sbprintfln(sb, "    %v := %v", param.name, code)
            } else {
                fmt.sbprintfln(sb, "    // Unsupported type %v", param.type)
                log.errorf("Codegen: Not supported proc param type %v in %v", param.type, info.odin_proc_name)
            }
        }
    }

    // Call the odin proc
    fmt.sbprint(sb, "    ")
    if len(info.returns) > 0 {
        for i in 0..<len(info.returns) {
            if i > 0 { fmt.sbprint(sb, ", ") }
            fmt.sbprintf(sb, "r%v", i)
        }
        fmt.sbprint(sb, " := ")
    }

    fmt.sbprint(sb, info.odin_proc_name)
    
    fmt.sbprint(sb, "(")
    for p, i in info.params {
        if i > 0 { fmt.sbprint(sb, ", ") }
        fmt.sbprintf(sb, "%v", p.name)
    }
    fmt.sbprintln(sb, ")")

    // Pushes return values
    for ret, i in info.returns {
        if code, ok := lua_push_code(ret.type, fmt.tprintf("r%v", i)); ok {
            fmt.sbprintfln(sb, "    %v", code)
        } else {
            fmt.sbprintfln(sb, "    lua.pushnil(L) // unsupported return type: %s", ret.type)
            log.errorf("Codegen: Not supported proc return type: %v in %v", ret.type, info.odin_proc_name)
        }
    }

    fmt.sbprintfln(sb, "    return %v", len(info.returns))

    fmt.sbprintfln(sb, "}")
    fmt.sbprintfln(sb, "")
}

generate_register :: proc(sb: ^strings.Builder) {
    fmt.sbprintfln(sb, "_lua_register_all_bindings :: proc(L: ^lua.State) {{")
    fmt.sbprintln(sb, "")

    seen := make(map[string]bool, context.temp_allocator)

    // Procs with no table — register as globals
    for info in sorted_values(codegen.procs) {
        if info.lua_table != "" || info.is_method { continue }
        fmt.sbprintfln(sb, `    lua.pushcfunction(L, %v)`, info.odin_wrapper_name)
        fmt.sbprintfln(sb, `    lua.setglobal(L, "%v")`, info.lua_name)
        if info.lua_name_zh != "" {
            fmt.sbprintfln(sb, `    lua.pushcfunction(L, %v)`, info.odin_wrapper_name)
            fmt.sbprintfln(sb, `    lua.setglobal(L, "%v")`, info.lua_name_zh)
        }
    }

    // Procs grouped into tables — get-or-create each table, fill it, set as global
    for info in sorted_values(codegen.procs) {
        if info.lua_table == "" || info.is_method || info.lua_table in seen { continue }
        seen[info.lua_table] = true

        fmt.sbprintfln(sb, `    lua.getglobal(L, "%v")`, info.lua_table)
        fmt.sbprintfln(sb, `    if lua.type(L, -1) == .NIL {{ lua.pop(L, 1); lua.createtable(L, 0, 0) }}`)
        for p in sorted_values(codegen.procs) {
            if p.lua_table == info.lua_table && !p.is_method {
                fmt.sbprintfln(sb, `    lua.pushcfunction(L, %v)`, p.odin_wrapper_name)
                fmt.sbprintfln(sb, `    lua.setfield(L, -2, "%v")`, p.lua_name)
                if p.lua_name_zh != "" {
                    fmt.sbprintfln(sb, `    lua.pushcfunction(L, %v)`, p.odin_wrapper_name)
                    fmt.sbprintfln(sb, `    lua.setfield(L, -2, "%v")`, p.lua_name_zh)
                }
            }
        }
        fmt.sbprintfln(sb, `    lua.setglobal(L, "%v")`, info.lua_table)
        fmt.sbprintln(sb, "")
    }

    // Method procs — build a metatable per table name and store it in the Lua registry.
    // _lua_push_table_<Type> attaches the metatable so colon-call syntax works.
    seen_methods := make(map[string]bool, context.temp_allocator)
    for info in sorted_values(codegen.procs) {
        if !info.is_method || info.lua_table == "" || info.lua_table in seen_methods { continue }
        seen_methods[info.lua_table] = true

        fmt.sbprintfln(sb, `    lua.newtable(L) // __index for %v methods`, info.lua_table)
        for p in sorted_values(codegen.procs) {
            if p.lua_table == info.lua_table && p.is_method {
                fmt.sbprintfln(sb, `    lua.pushcfunction(L, %v)`, p.odin_wrapper_name)
                fmt.sbprintfln(sb, `    lua.setfield(L, -2, "%v")`, p.lua_name)
                if p.lua_name_zh != "" {
                    fmt.sbprintfln(sb, `    lua.pushcfunction(L, %v)`, p.odin_wrapper_name)
                    fmt.sbprintfln(sb, `    lua.setfield(L, -2, "%v")`, p.lua_name_zh)
                }
            }
        }
        fmt.sbprintfln(sb, `    lua.newtable(L)`)
        fmt.sbprintfln(sb, `    lua.pushvalue(L, -2)`)
        fmt.sbprintfln(sb, `    lua.setfield(L, -2, "__index")`)
        fmt.sbprintfln(sb, `    lua.setfield(L, lua.REGISTRYINDEX, "_mt_%v")`, info.lua_table)
        fmt.sbprintfln(sb, `    lua.pop(L, 1) // pop __index table`)
        fmt.sbprintln(sb, "")
    }

    fmt.sbprintln(sb, "}")
    fmt.sbprintln(sb, "")
}

generate_ffi_push :: proc(sb: ^strings.Builder) {
    fmt.sbprintln(sb, "//==================== FFI Push Helpers ====================")
    fmt.sbprintln(sb, "")
    fmt.sbprintln(sb, "@(private)")
    fmt.sbprintln(sb, "_lua_push_arr :: proc(L: ^lua.State, global: cstring, v: [$N]$T) {")
    fmt.sbprintln(sb, "    lua.getglobal(L, global)")
    fmt.sbprintln(sb, "    for elem in v {")
    fmt.sbprintln(sb, "        when intrinsics.type_is_float(T) {")
    fmt.sbprintln(sb, "            lua.pushnumber(L, lua.Number(elem))")
    fmt.sbprintln(sb, "        } else {")
    fmt.sbprintln(sb, "            lua.pushinteger(L, lua.Integer(elem))")
    fmt.sbprintln(sb, "        }")
    fmt.sbprintln(sb, "    }")
    fmt.sbprintln(sb, "    if lua.pcall(L, N, 1, 0) != c.int(lua.Status.OK) {")
    fmt.sbprintln(sb, "        err := lua.tostring(L, -1)")
    fmt.sbprintln(sb, "        lua.pop(L, 1)")
    fmt.sbprintln(sb, `        lua.L_error(L, "FFI push failed calling global '%s' (is it exposed in setup.lua?): %s", global, err)`)
    fmt.sbprintln(sb, "    }")
    fmt.sbprintln(sb, "}")
    fmt.sbprintln(sb, "")

    for info in sorted_values(codegen.ffi_types) {
        if info.lua_global == "" { continue }
        if info.transmute_as != "" {
            fmt.sbprintfln(sb, `_lua_push_ffi_%v :: proc(L: ^lua.State, v: %v) {{ _lua_push_arr(L, "%v", transmute(%v)v) }}`,
                info.name, info.name, info.lua_global, info.transmute_as)
        } else {
            fmt.sbprintfln(sb, `_lua_push_ffi_%v :: proc(L: ^lua.State, v: %v) {{ _lua_push_arr(L, "%v", v) }}`,
                info.name, info.name, info.lua_global)
        }
        // The cdata at idx; anything else is a Lua argument error, never a nil dereference.
        fmt.sbprintfln(sb, `_lua_read_ffi_%v :: proc(L: ^lua.State, idx: c.int) -> %v {{`, info.name, info.name)
        fmt.sbprintfln(sb, `    p := cast(^%v)lua.topointer(L, idx)`, info.name)
        fmt.sbprintfln(sb, `    if p == nil {{ lua.L_argerror(L, idx, "expected %v"); return {{}} }}`, info.lua_global)
        fmt.sbprintln(sb, `    return p^`)
        fmt.sbprintln(sb, `}`)
    }
    fmt.sbprintln(sb, "")
}

LUA_INT_TYPES :: []string{"int", "i32", "i64", "u32", "u64"}

// Code pushing the Odin expression `v` of type `type` onto the Lua stack. Every push the bindings make goes
// through this (proc returns, struct fields), so a type is marshalled the same way everywhere.
// ok = false for a type the bindings can't marshal.
lua_push_code :: proc(type, v: string) -> (code: string, ok: bool) {
    switch {
    case type == "f32" || type == "f64":       return fmt.tprintf("lua.pushnumber(L, lua.Number(%v))", v), true
    case slice.contains(LUA_INT_TYPES, type):  return fmt.tprintf("lua.pushinteger(L, lua.Integer(%v))", v), true
    case type == "bool":                       return fmt.tprintf("lua.pushboolean(L, b32(%v))", v), true
    case type == "string":                     return fmt.tprintf("lua.pushstring(L, strings.clone_to_cstring(%v, context.temp_allocator))", v), true
    case type in codegen.ffi_types:            return fmt.tprintf("_lua_push_ffi_%v(L, %v)", type, v), true
    case type in codegen.structs:              return fmt.tprintf("_lua_push_table_%v(L, %v)", type, v), true
    case type in codegen.flag_types:           return fmt.tprintf("lua.pushinteger(L, lua.Integer(transmute(u64)%v))", v), true
    case type in codegen.enum_types:           return fmt.tprintf("lua.pushinteger(L, lua.Integer(%v))", v), true
    }
    if bt, is_int := codegen.int_types[type]; is_int do return fmt.tprintf("lua.pushinteger(L, lua.Integer(transmute(%v)%v))", bt, v), true
    return "", false
}

// An expression reading Lua stack slot `idx` as `type`, raising a Lua error if it isn't one. Every read
// goes through this (proc params, struct fields). ok = false for a type the bindings can't marshal.
lua_read_code :: proc(type, idx: string) -> (code: string, ok: bool) {
    switch {
    case type == "f32" || type == "f64":       return fmt.tprintf("%v(lua.L_checknumber(L, %v))", type, idx), true
    case slice.contains(LUA_INT_TYPES, type):  return fmt.tprintf("%v(lua.L_checkinteger(L, %v))", type, idx), true
    case type == "bool":                       return fmt.tprintf("bool(lua.toboolean(L, %v))", idx), true
    case type == "string":                     return fmt.tprintf("string(lua.L_checkstring(L, %v))", idx), true
    case type in codegen.ffi_types:            return fmt.tprintf("_lua_read_ffi_%v(L, %v)", type, idx), true
    case type in codegen.structs:              return fmt.tprintf("_lua_read_table_%v(L, %v)", type, idx), true
    case type in codegen.flag_types:           return fmt.tprintf("transmute(%v)u64(lua.L_checkinteger(L, %v))", type, idx), true
    case type in codegen.enum_types:           return fmt.tprintf("%v(lua.L_checkinteger(L, %v))", type, idx), true
    }
    if bt, is_int := codegen.int_types[type]; is_int do return fmt.tprintf("transmute(%v)%v(lua.L_checkinteger(L, %v))", type, bt, idx), true
    return "", false
}

// A map's values in key order. Map iteration order is random; emitting in name order means the generated
// file only changes when its input does.
sorted_values :: proc(m: map[string]$T) -> []T {
    keys := make([dynamic]string, 0, len(m), context.temp_allocator)
    for k in m do append(&keys, k)
    slice.sort(keys[:])
    out := make([]T, len(keys), context.temp_allocator)
    for k, i in keys do out[i] = m[k]
    return out
}
