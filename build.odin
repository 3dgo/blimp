package build

import "core:log"
import "core:strings"
import "core:fmt"
import "core:slice"
import "core:os"
import "core:path/filepath"

SRC_PATH :: "src"
LIB_PATH :: "E:/Libraries/odin_lib"

CODEGEN_SRC :: "src/codegen"
CODEGEN_OUT :: "bin/codegen.exe"

OUT :: "bin/blimp.exe"

// `odin run build.odin -file -- game`: the shippable game in GAME_DIR, a release build (no -debug, so
// ODIN_DEBUG is false: no editor, blimpctl, hot reload or console) that plays game.ini's start_level.
// Beside it go the DLLs from bin/, game.ini, and assets/ + assets_engine/ without the DCC sources.
GAME_DIR :: "out/game"
GAME_EXE :: "out/game/game.exe"
GAME_SKIP_EXTS :: [?]string{".max", ".psd", ".blend", ".bak", ".luacn", ".kra", ".xcf"}   // sources, not loaded at runtime

// `odin run build.odin -file -- editor`: the editor for people who don't build the engine, zipped to
// EDITOR_ZIP for a GitHub release: an optimized -debug build (ODIN_DEBUG keeps the editor, hot reload
// and blimpctl), blimpctl and the DLLs, under bin/. Unzipped at a project root, it runs like a local build
// of the same commit; shaders and .luacn compile at runtime, only Odin and entity_schema.ini need Odin.
EDITOR_BIN :: "out/editor/bin"
EDITOR_ZIP :: "out/editor.zip"

BLIMPCTL_SRC ::"tools/blimpctl"   // remote-control CLI for a running debug build (src/app_remote.odin)
BLIMPCTL_OUT :: "bin/blimpctl.exe"

CUSTOM_ATTRIBUTES :[7]string : {"lua", "lua_zh", "table", "method", "lua_ffi", "as", "lua_int"}

main :: proc() {
    context.logger = log.create_console_logger()

    run_str(fmt.aprintf("odin build %v -debug -vet -collection:lib=%v -out:%v", CODEGEN_SRC, LIB_PATH, CODEGEN_OUT, allocator = context.temp_allocator))
    run_str(CODEGEN_OUT)

    if slice.contains(os.args, "game") {
        build_game()
        return
    }
    if slice.contains(os.args, "editor") {
        build_editor()
        return
    }

    build_src("-debug", OUT)
    run_str(fmt.aprintf("odin build %v -vet -out:%v", BLIMPCTL_SRC, BLIMPCTL_OUT, allocator = context.temp_allocator))

    if slice.contains(os.args, "run") do run_str(OUT)
}

// Compiles the engine (src/) to `out` with `flags` (space-separated) on top of the shared ones.
build_src :: proc(flags, out: string) {
    sb: strings.Builder
    strings.builder_init(&sb, context.temp_allocator)
    fmt.sbprintf(&sb, "odin build %v %v -vet -collection:lib=%v -out:%v -extra-linker-flags:/ignore:4075", SRC_PATH, flags, LIB_PATH, out)
    for ca in CUSTOM_ATTRIBUTES {
        fmt.sbprintf(&sb, " -custom-attribute:%v", ca)
    }
    run_str(strings.to_string(sb))
}

// Deletes `dir` if it exists and creates it empty.
fresh_dir :: proc(dir: string) {
    if os.exists(dir) {
        if err := os.remove_all(dir); err != nil {
            log.errorf("Can't clear %v (is something in it running?): %v", dir, err)
            os.exit(1)
        }
    }
    if err := os.make_directory_all(dir); err != nil {
        log.errorf("Can't create %v: %v", dir, err)
        os.exit(1)
    }
}

build_editor :: proc() {
    fresh_dir(EDITOR_BIN)
    build_src("-debug -o:speed", join({EDITOR_BIN, "blimp.exe"}))
    run_str(fmt.aprintf("odin build %v -o:speed -vet -out:%v", BLIMPCTL_SRC, join({EDITOR_BIN, "blimpctl.exe"}), allocator = context.temp_allocator))

    bin, _ := os.read_all_directory_by_path("bin", context.temp_allocator)
    for fi in bin do if filepath.ext(fi.name) == ".dll" do copy_or_exit(join({EDITOR_BIN, fi.name}), fi.fullpath)

    // Only the exes and DLLs go in the zip, under bin/ (the debug build's .pdb stays in EDITOR_BIN).
    // Windows' own tar (bsdtar) writes zips; Git's GNU tar on PATH can't.
    tar := join({os.get_env("SystemRoot", context.temp_allocator), "System32", "tar.exe"})
    cmd := make([dynamic]string, context.temp_allocator)
    append(&cmd, tar, "-a", "-c", "-f", EDITOR_ZIP, "-C", filepath.dir(EDITOR_BIN))
    built, _ := os.read_all_directory_by_path(EDITOR_BIN, context.temp_allocator)
    for fi in built {
        ext := filepath.ext(fi.name)
        if ext == ".exe" || ext == ".dll" do append(&cmd, fmt.aprintf("bin/%v", fi.name, allocator = context.temp_allocator))
    }
    os.remove(EDITOR_ZIP)
    run(cmd[:])
    log.infof("Editor: %v (unzip at a project root, beside assets/)", EDITOR_ZIP)
}

build_game :: proc() {
    fresh_dir(GAME_DIR)
    build_src("-o:speed -subsystem:windows", GAME_EXE)

    bin, _ := os.read_all_directory_by_path("bin", context.temp_allocator)
    for fi in bin do if filepath.ext(fi.name) == ".dll" do copy_or_exit(join({GAME_DIR, fi.name}), fi.fullpath)
    copy_or_exit(join({GAME_DIR, "game.ini"}), "game.ini")
    files := 0
    files += copy_tree(join({GAME_DIR, "assets"}), "assets")
    files += copy_tree(join({GAME_DIR, "assets_engine"}), "assets_engine")
    log.infof("Game: %v, with %v asset files", GAME_EXE, files)
}

// Copies the directory tree src into dst, leaving out GAME_SKIP_EXTS. Returns how many files it copied.
copy_tree :: proc(dst, src: string) -> (count: int) {
    if err := os.make_directory_all(dst); err != nil {
        log.errorf("Can't create %v: %v", dst, err)
        os.exit(1)
    }
    entries, _ := os.read_all_directory_by_path(src, context.temp_allocator)
    for fi in entries {
        target := join({dst, fi.name})
        if fi.type == .Directory {
            count += copy_tree(target, fi.fullpath)
            continue
        }
        skip := GAME_SKIP_EXTS
        if slice.contains(skip[:], strings.to_lower(filepath.ext(fi.name), context.temp_allocator)) do continue
        copy_or_exit(target, fi.fullpath)
        count += 1
    }
    return
}

copy_or_exit :: proc(dst, src: string) {
    if err := os.copy_file(dst, src); err != nil {
        log.errorf("Can't copy %v to %v: %v", src, dst, err)
        os.exit(1)
    }
}

join :: proc(parts: []string) -> string {
    p, _ := filepath.join(parts, context.temp_allocator)
    return p
}

run_str :: proc(cmd: string) {
    run(strings.split(cmd, " "))
}

run :: proc(cmd: []string) {
    log.infof("Running %v", cmd)
    code, err := exec(cmd)
    if err != nil {
        log.errorf("Failed executing process. Error: %v", err)
        os.exit(1)
    }
    if code != 0 {
        log.errorf("Process exited with non zero code: %v", code)
        os.exit(1)
    }
}

exec :: proc(cmd: []string) -> (code: int, err: os.Error) {
    process := os.process_start(
        os.Process_Desc{
            command = cmd,
            stdin = os.stdin,
            stdout = os.stdout,
            stderr = os.stderr,
        }) or_return
    state := os.process_wait(process) or_return
    code = state.exit_code
    return
}