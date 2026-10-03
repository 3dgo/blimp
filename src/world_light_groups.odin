package blimp

import "core:math"
import "core:strings"

// Light groups (claude/rendering.md → Lighting): every light belongs to one (Entity.light_group). Group 0 is
// static and always at full strength. Groups 1–MAX_LIGHT_GROUPS can be scaled at runtime — the power goes
// out, a candle flickers — and the scale applies to everything the light gives: its realtime direct light
// (the light buffer) and its baked bounce (its own probe layer, editor_bake.odin). World_Settings saves
// where each group starts; Lua and the editor's Lighting menu override that at runtime, never saved.

MAX_LIGHT_GROUPS :: 4

// One switchable group (World_Settings.light_groups).
Light_Group :: struct {
    name:    sbuf64 `loc:Light_Group_Name`,      // what Lua calls it, e.g. "electric"
    scale:   f32    `loc:Light_Group_Scale`,     // × every light in the group, realtime and baked
    pattern: sbuf64 `loc:Light_Group_Pattern`,   // flicker, Quake lightstyle: a letter per 1/10 s, a = 0, m = 1, z = 2; empty = steady
}

// Four named fields rather than [4]Light_Group, which the serializer and inspector don't take. Laid out
// like the array, so light_group_settings indexes it.
Light_Groups :: struct {
    group_1: Light_Group `loc:Light_Group_1`,
    group_2: Light_Group `loc:Light_Group_2`,
    group_3: Light_Group `loc:Light_Group_3`,
    group_4: Light_Group `loc:Light_Group_4`,
}
#assert(size_of(Light_Groups) == MAX_LIGHT_GROUPS * size_of(Light_Group))

LIGHT_PATTERN_RATE :: 10   // pattern letters per second, as in Quake

// Group `g` (1…MAX_LIGHT_GROUPS) of w's saved settings.
light_group_settings :: proc(w: ^World, g: int) -> ^Light_Group {
    assert(g >= 1 && g <= MAX_LIGHT_GROUPS)
    return &([^]Light_Group)(&w.settings.light_groups)[g - 1]
}

entity_light_group :: proc(e: ^Entity) -> int {
    return clamp(int(e.light_group), 0, MAX_LIGHT_GROUPS)
}

// The group named `name` (1…MAX_LIGHT_GROUPS), or 0 when none is.
light_group_find :: proc(w: ^World, name: string) -> int {
    for g in 1..=MAX_LIGHT_GROUPS do if strings.equal_fold(sbuf_str(&light_group_settings(w, g).name), name) do return g
    return 0
}

// The scale before its flicker: the runtime override, else the saved value.
// Sets group `name`'s runtime scale over the saved one (Lua, the Lighting menu); false if no group has that name.
light_group_set_override :: proc(w: ^World, name: string, scale: f32) -> bool {
    g := light_group_find(w, name)
    if g == 0 do return false
    w.light_group_override[g] = scale
    return true
}

light_group_base_scale :: proc(w: ^World, g: int) -> f32 {
    if g == 0 do return 1
    if s, ok := w.light_group_override[g].?; ok do return s
    return light_group_settings(w, g).scale
}

// Every group's scale this frame, indexed by group number (scales[0] = 1). `time` drives the patterns.
light_group_scales :: proc(w: ^World, time: f64) -> (scales: [MAX_LIGHT_GROUPS + 1]f32) {
    scales[0] = 1
    for g in 1..=MAX_LIGHT_GROUPS {
        scales[g] = light_group_base_scale(w, g) * light_pattern_value(sbuf_str(&light_group_settings(w, g).pattern), time)
    }
    return
}

// A Quake lightstyle string at `time`: one letter per 1/LIGHT_PATTERN_RATE s, looping, stepped (no blend).
// 'a' is off, 'm' normal, 'z' about double. Empty is steady 1; letters outside a–z count as 'm'.
light_pattern_value :: proc(pattern: string, time: f64) -> f32 {
    if len(pattern) == 0 do return 1
    c := pattern[int(math.floor(time * LIGHT_PATTERN_RATE)) % len(pattern)]
    if c < 'a' || c > 'z' do return 1
    return f32(c - 'a') / f32('m' - 'a')
}

