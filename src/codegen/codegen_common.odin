package codegen

import "core:log"
import "core:os"
import "../common"

// Entry point for all codegen passes. Runs before `odin build src` (see build.odin), so
// every generated file exists before the engine is compiled.
main :: proc() {
    codegen.logger = log.create_console_logger()
    context.logger = codegen.logger

    // Structural codegen from data.
    generate_entity()

    // Lua bindings: scan Odin source for @(lua) and emit wrappers.
    scan_folder("src")
    generate_file("src/gen_lua_bindings.odin")
    generate_lua_defs("assets_engine/scripts/gen_lua_api_defs.lua")

    // LuaCN: transpile Chinese-keyword .luacn scripts to .lua.
    common.luacn_scan_folder("assets_engine")
    common.luacn_scan_folder("assets")
}

// Writes a generated file and logs the outcome. Shared by every pass.
write_generated :: proc(out_path: string, content: string) {
    if err := os.write_entire_file(out_path, content); err == nil {
        log.infof("Codegen: wrote %v", out_path)
    } else {
        log.errorf("Codegen: write error for %v: %v", out_path, err)
    }
}
