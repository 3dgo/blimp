package common
import "base:runtime"
import "core:mem"
import "core:os"

/* ------------------------------- Containers ------------------------------- */
contains :: proc{contains_slice, contains_const}

contains_slice :: proc(array: []$T, value: T) -> bool {
    for item in array {
        if item == value {
            return true
        }
    }
    return false
}

contains_const :: proc(array: [$N]$T, value: T) -> bool {
    for item in array {
        if item == value {
            return true
        }
    }
    return false
}

contains_all :: proc(array: []$T, values: []T) -> bool {
    for value in values {
        if !contains(array, value) {
            return false
        }
    }
    return true
}

keys :: proc(in_map: map[$K]$V, allocator: mem.Allocator) -> []K {
    result := make([]K, len(in_map), allocator)
    i := 0
    for key in in_map {
        result[i] = key
        i += 1
    }
    return result
}

values :: proc(in_map: map[$K]$V, allocator: mem.Allocator) -> []V {
    result := make([]V, len(in_map), allocator)
    i := 0
    for _, value in in_map {
        result[i] = value
        i += 1
    }
    return result
}

get_all_files :: proc(root: string, files: ^[dynamic]os.File_Info, allocator: runtime.Allocator) ->(out_err: os.Error) {
    fis := os.read_all_directory_by_path(root, context.temp_allocator) or_return
    for fi in fis {
        if fi.type == .Directory {
            get_all_files(fi.fullpath, files, allocator) or_return
        } else {
            append(files, fi)
        }
    }
    return nil
}