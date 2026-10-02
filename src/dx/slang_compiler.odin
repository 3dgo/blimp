package dx

import "base:runtime"
import "core:log"
import "core:strings"
import "core:slice"
import slang "lib:odin-slang/slang"

Slang_Compiler :: struct {
    global_session: ^slang.IGlobalSession,
    session: ^slang.ISession,

    shader_paths: [dynamic]cstring,
    
    allocator: runtime.Allocator,
}

Compiled_Shader :: struct {
    vs_bytecode: []byte,
    ps_bytecode: []byte,
    vs_blob: ^slang.IBlob,
    ps_blob: ^slang.IBlob,
}

slang_compiler_create :: proc(shader_dir: string, allocator: runtime.Allocator) -> Slang_Compiler {
    sc: Slang_Compiler
    sc.allocator = allocator
    slang.createGlobalSession2(slang.kGlobalSessionDescDefaultValues, &sc.global_session)
    if sc.global_session == nil {log.error("Failed to create slang global session")}

    sc.shader_paths = make([dynamic]cstring, allocator)
    append(&sc.shader_paths, strings.clone_to_cstring(shader_dir, allocator))

    profile_id := sc.global_session->findProfile("sm_6_8")
    if profile_id == .Unknown {log.errorf("Unkown slang profile name %s", "sm_6_8")}

    target_desc := slang.TargetDesc {
        structureSize = size_of(slang.TargetDesc),
        format        = .DXIL,
        profile       = profile_id,
    }
    session_desc := slang.SessionDesc {
        structureSize    = size_of(slang.SessionDesc),
        targets          = &target_desc,
        targetCount      = 1,
        searchPaths      = raw_data(sc.shader_paths),
        searchPathCount  = len(sc.shader_paths),
    }
    sc.global_session->createSession(session_desc, &sc.session)
    if sc.session == nil {log.error("Failed to create slang session")}
    return sc
}

slang_compiler_destroy :: proc(sc: Slang_Compiler) {
    sc.session->release()
    sc.global_session->release()
    for path in sc.shader_paths {
        delete(path, sc.allocator)
    }
    delete(sc.shader_paths)
}

slang_compiler_compile_shader :: proc(sc: Slang_Compiler, module_name: string, vs_entry: string, ps_entry: string) -> Compiled_Shader {
    module_name_c := strings.clone_to_cstring(module_name, context.temp_allocator)
    vs_entry_c := strings.clone_to_cstring(vs_entry, context.temp_allocator)
    ps_entry_c := strings.clone_to_cstring(ps_entry, context.temp_allocator)

    module: ^slang.IModule
    module_diag: ^slang.IBlob
    module = sc.session->loadModule(module_name_c, &module_diag)
    check_slang_diagnostics(module_diag, true)
    if module == nil { log.panicf("Slang: failed to load module '%s'", module_name) }
    defer module->release()

    vs_entrypoint, ps_entrypoint: ^slang.IEntryPoint
    if r := module->findEntryPointByName(vs_entry_c, &vs_entrypoint); r < 0 || vs_entrypoint == nil {
        log.panicf("Slang: failed to find VS entry point '%s' (result=0x%x)", vs_entry, u32(r))
    }
    if r := module->findEntryPointByName(ps_entry_c, &ps_entrypoint); r < 0 || ps_entrypoint == nil {
        log.panicf("Slang: failed to find PS entry point '%s' (result=0x%x)", ps_entry, u32(r))
    }
    defer vs_entrypoint->release()
    defer ps_entrypoint->release()

    component_types := []^slang.IComponentType{module, vs_entrypoint, ps_entrypoint}
    composite: ^slang.IComponentType
    composite_diag: ^slang.IBlob
    if r := sc.session->createCompositeComponentType(raw_data(component_types), len(component_types), &composite, &composite_diag); r < 0 || composite == nil {
        check_slang_diagnostics(composite_diag, true)
        log.panicf("Slang: failed to create composite component type (result=0x%x)", u32(r))
    }
    check_slang_diagnostics(composite_diag)
    defer composite->release()

    linked: ^slang.IComponentType
    link_diag: ^slang.IBlob
    if r := composite->link(&linked, &link_diag); r < 0 || linked == nil {
        check_slang_diagnostics(link_diag, true)
        log.panicf("Slang: failed to link composite (result=0x%x)", u32(r))
    }
    check_slang_diagnostics(link_diag)
    defer linked->release()

    vs_code, ps_code: ^slang.IBlob
    vs_diag, ps_diag: ^slang.IBlob
    if r := linked->getEntryPointCode(0, 0, &vs_code, &vs_diag); r < 0 || vs_code == nil {
        check_slang_diagnostics(vs_diag, true)
        log.panicf("Slang: failed to compile VS entry point '%s' (result=0x%x)", vs_entry, u32(r))
    }
    if r := linked->getEntryPointCode(1, 0, &ps_code, &ps_diag); r < 0 || ps_code == nil {
        check_slang_diagnostics(ps_diag, true)
        log.panicf("Slang: failed to compile PS entry point '%s' (result=0x%x)", ps_entry, u32(r))
    }

    compiled: Compiled_Shader
    compiled.vs_blob = vs_code
    compiled.ps_blob = ps_code
    compiled.vs_bytecode = slice.from_ptr((^byte)(vs_code->getBufferPointer()), int(vs_code->getBufferSize()))
    compiled.ps_bytecode = slice.from_ptr((^byte)(ps_code->getBufferPointer()), int(ps_code->getBufferSize()))

    return compiled
}

slang_compiler_destroy_shader :: proc(shader: Compiled_Shader) {
    if shader.vs_blob != nil do shader.vs_blob->release()
    if shader.ps_blob != nil do shader.ps_blob->release()
}

check_slang_diagnostics :: proc(diagnostics: ^slang.IBlob, failed := false) {
    if diagnostics == nil do return
    defer diagnostics->release()

    ptr := diagnostics->getBufferPointer()
    if ptr == nil do return

    msg := cstring(ptr)
    if len(msg) == 0 do return

    if failed {
        log.errorf("Slang: %s", msg)
    } else {
        log.warnf("Slang: %s", msg)
    }
}