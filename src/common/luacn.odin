package common

import "core:log"
import "core:os"
import "core:strings"
import "core:path/filepath"
import "core:unicode/utf8"

// LuaCN: Lua with Chinese keywords. A .luacn file transpiles to the .lua beside it, which is what
// gets loaded. The build converts every one (codegen); the engine converts one when it changes
// (asset_hot_reload.odin).

// Transpiles every .luacn under root.
luacn_scan_folder :: proc(root: string) {
	keywords := luacn_keywords()
	defer delete(keywords)
	_scan_dir_luacn(root, &keywords)
}

// Transpiles one .luacn file to the .lua beside it. False if it couldn't be read or written.
luacn_convert :: proc(path: string) -> bool {
	keywords := luacn_keywords()
	defer delete(keywords)
	return luacn_convert_file(path, &keywords)
}

@(private = "file")
luacn_keywords :: proc() -> (keywords: map[string]string) {
	keywords = make(map[string]string)
	keywords["否则如果"] = "elseif"
	keywords["如果"]     = "if"
	keywords["那么"]     = "then"
	keywords["否则"]     = "else"
	keywords["结束"]     = "end"
	keywords["当"]       = "while"
	keywords["重复"]     = "repeat"
	keywords["直到"]     = "until"
	keywords["对于"]     = "for"
	keywords["在"]       = "in"
	keywords["做"]       = "do"
	keywords["函数"]     = "function"
	keywords["返回"]     = "return"
	keywords["本地"]     = "local"
	keywords["真"]       = "true"
	keywords["假"]       = "false"
	keywords["空"]       = "nil"
	keywords["和"]       = "and"
	keywords["或"]       = "or"
	keywords["非"]       = "not"
	keywords["中断"]     = "break"
	return
}

@(private = "file")
_scan_dir_luacn :: proc(path: string, keywords: ^map[string]string) {
	f, err := os.open(path)
	if err != nil { return }
	defer os.close(f)

	it := os.read_directory_iterator_create(f)
	defer os.read_directory_iterator_destroy(&it)

	for info in os.read_directory_iterator(&it) {
		if info.type == .Directory {
			_scan_dir_luacn(info.fullpath, keywords)
		} else if filepath.ext(info.name) == ".luacn" {
			luacn_convert_file(info.fullpath, keywords)
		}
	}
}

@(private = "file")
luacn_convert_file :: proc(path: string, keywords: ^map[string]string) -> bool {
	src, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		log.errorf("LuaCN: failed to read %v", path)
		return false
	}
	defer delete(src)

	result := _transpile_luacn(string(src), keywords)
	defer delete(result)

	stem := strings.trim_suffix(path, ".luacn")
	out_path := strings.concatenate({stem, ".lua"})
	defer delete(out_path)

	write_err := os.write_entire_file(out_path, transmute([]byte)result)
	if write_err != nil {
		log.errorf("LuaCN: write error: %v", write_err)
		return false
	}
	log.infof("LuaCN: %v -> %v", path, out_path)
	return true
}

@(private = "file")
_transpile_luacn :: proc(src: string, keywords: ^map[string]string) -> string {
	sb: strings.Builder
	strings.builder_init(&sb)

	i := 0
	for i < len(src) {
		c := src[i]

		// Line or long comment: --
		if c == '-' && i+1 < len(src) && src[i+1] == '-' {
			if i+2 < len(src) && src[i+2] == '[' {
				level := _long_bracket_level(src, i+2)
				if level >= 0 {
					open_end := (i + 2) + 2 + level
					end := _long_bracket_end(src, open_end, level)
					if end >= 0 {
						strings.write_string(&sb, src[i:end])
						i = end
						continue
					}
				}
			}
			// Regular line comment — copy until newline
			j := i
			for j < len(src) && src[j] != '\n' { j += 1 }
			strings.write_string(&sb, src[i:j])
			i = j
			continue
		}

		// Short string literals: " or '
		if c == '"' || c == '\'' {
			j := i + 1
			for j < len(src) {
				if src[j] == '\\' { j += 2; continue }
				if src[j] == c    { j += 1; break }
				j += 1
			}
			strings.write_string(&sb, src[i:j])
			i = j
			continue
		}

		// Long strings: [[ or [=[
		if c == '[' && i+1 < len(src) && (src[i+1] == '[' || src[i+1] == '=') {
			level := _long_bracket_level(src, i)
			if level >= 0 {
				open_end := i + 2 + level
				end := _long_bracket_end(src, open_end, level)
				if end >= 0 {
					strings.write_string(&sb, src[i:end])
					i = end
					continue
				}
			}
		}

		// ASCII identifier — emit as-is, no keyword replacement
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' {
			j := i + 1
			for j < len(src) {
				d := src[j]
				if !((d >= 'a' && d <= 'z') || (d >= 'A' && d <= 'Z') || (d >= '0' && d <= '9') || d == '_') { break }
				j += 1
			}
			strings.write_string(&sb, src[i:j])
			i = j
			continue
		}

		// ASCII non-identifier (space, digit, operator, punctuation …)
		if c < 0x80 {
			strings.write_byte(&sb, c)
			i += 1
			continue
		}

		// Multi-byte UTF-8
		r, rsize := utf8.decode_rune_in_string(src[i:])
		if _is_cjk(r) {
			// Accumulate all consecutive CJK runes into one token
			j := i
			for j < len(src) {
				r2, s2 := utf8.decode_rune_in_string(src[j:])
				if !_is_cjk(r2) { break }
				j += s2
			}
			word := src[i:j]
			if replacement, ok := keywords[word]; ok {
				strings.write_string(&sb, replacement)
			} else {
				strings.write_string(&sb, word)
			}
			i = j
			continue
		}

		// Other non-ASCII, non-CJK — emit verbatim
		strings.write_string(&sb, src[i:i+rsize])
		i += rsize
	}

	return strings.to_string(sb)
}

// Returns the level (number of '=' signs) if src[pos] starts a valid long bracket opener,
// e.g. [[ → 0, [=[ → 1, [==[ → 2. Returns -1 if not a valid opener.
@(private = "file")
_long_bracket_level :: proc(src: string, pos: int) -> int {
	if pos >= len(src) || src[pos] != '[' { return -1 }
	i := pos + 1
	level := 0
	for i < len(src) && src[i] == '=' { level += 1; i += 1 }
	if i < len(src) && src[i] == '[' { return level }
	return -1
}

// Given that open_end is the index just after the opening bracket (e.g. after [[ or [=[),
// finds and returns the index just past the matching closing bracket. Returns -1 if not found.
@(private = "file")
_long_bracket_end :: proc(src: string, open_end: int, level: int) -> int {
	// Build closing bracket in a stack buffer: ] + level×= + ]
	buf: [66]byte
	buf[0] = ']'
	for j in 0..<level { buf[j+1] = '=' }
	buf[level+1] = ']'
	closing := string(buf[:level+2])

	idx := strings.index(src[open_end:], closing)
	if idx < 0 { return -1 }
	return open_end + idx + len(closing)
}

@(private = "file")
_is_cjk :: proc(r: rune) -> bool {
	return r >= 0x4E00 && r <= 0x9FFF
}
