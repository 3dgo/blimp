package blimp

import "core:strings"
import "core:unicode/utf8"

// Text matching for every search box: a case-insensitive substring, where Chinese characters also match
// their pinyin so a search can be typed without an IME. Whole syllables, initials or a mix all work
// ("dengguang", "dg", "dguang" find 灯光), the last syllable may be cut short ("dengg"), and a polyphone
// matches by any of its readings (gen_pinyin.odin; no tones).
search_matches :: proc(text, query: string) -> bool {
    q := strings.to_lower(strings.trim_space(query), context.temp_allocator)
    if q == "" do return true
    t := strings.to_lower(text, context.temp_allocator)
    if strings.contains(t, q) do return true

    runes := utf8.string_to_runes(t, context.temp_allocator)
    has_han := false
    for r in runes do if r >= PINYIN_FIRST && r <= PINYIN_LAST { has_han = true; break }
    if !has_han do return false
    for start in 0 ..< len(runes) do if search_match_at(runes[start:], q) do return true
    return false
}

// Whether `q` is matched by `runes` from their first one on. Each rune matches itself, and a Chinese
// character also one of its readings: in full, by its first letter, or (where the query ends) by a prefix.
@(private="file")
search_match_at :: proc(runes: []rune, q: string) -> bool {
    if q == "" do return true
    if len(runes) == 0 do return false
    r := runes[0]
    if r >= PINYIN_FIRST && r <= PINYIN_LAST {
        readings := PINYIN_READINGS[int(r - PINYIN_FIRST) * PINYIN_MAX_READINGS:][:PINYIN_MAX_READINGS]
        for id in readings {
            if id == 0 do break
            s := PINYIN_SYLLABLES[id]
            if strings.has_prefix(s, q) do return true                                             // the query ends inside it
            if strings.has_prefix(q, s) && search_match_at(runes[1:], q[len(s):]) do return true   // whole syllable
            if q[0] == s[0] && search_match_at(runes[1:], q[1:]) do return true                    // initial
        }
    }
    c, n := utf8.decode_rune_in_string(q)
    return c == r && search_match_at(runes[1:], q[n:])
}
