package blimp

import "core:math/linalg"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import hm "core:container/handle_map"

// Editor icons: Material Symbols Outlined (assets_engine/fonts/MaterialSymbolsOutlined[...].ttf,
// Apache 2.0), merged into the UI font in ui_init so an icon sits inline in any label:
// fmt.ctprintf("%s %s", ICON_SAVE, tr(.Btn_Save_Level)). Codepoints from Google's .codepoints list
// for the font (github.com/google/material-design-icons, variablefont/). Add one = one line here.
// Written as \u escapes: the glyphs are in the Private Use Area, which editor fonts can't show.
ICON_SELECT       :: "\uF82F"   // arrow_selector_tool
ICON_MOVE         :: "\uE89F"   // open_with
ICON_ROTATE       :: "\uE627"   // sync
ICON_SCALE        :: "\uF1CE"   // open_in_full
ICON_GLOBAL       :: "\uE80B"   // public
ICON_LOCAL        :: "\uF720"   // deployed_code
ICON_PIVOT_CENTER :: "\uE3B4"   // center_focus_strong
ICON_PIVOT_EACH   :: "\uEA0F"   // workspaces
ICON_SNAP         :: "\uF016"   // grid_4x4
ICON_SAVE         :: "\uE161"   // save
ICON_SETTINGS     :: "\uE8B8"   // settings
ICON_ADD          :: "\uE145"   // add
ICON_CLOSE        :: "\uE5CD"   // close
ICON_REFRESH      :: "\uE5D5"   // refresh
ICON_PASTE        :: "\uE14F"   // content_paste
ICON_SCENE        :: "\uE55B"   // map
ICON_KIT          :: "\uE1A1"   // inventory_2
ICON_SEARCH       :: "\uE8B6"   // search (the older codepoint: this font file predates the EF7A one)
ICON_COPY         :: "\uE14D"   // content_copy
ICON_PASTE_OVER   :: "\uE243"   // format_paint
ICON_DUPLICATE    :: "\uE3BB"   // control_point_duplicate
ICON_DELETE       :: "\uE872"   // delete
ICON_SELECT_ALL   :: "\uE162"   // select_all
ICON_DESELECT     :: "\uEBB6"   // deselect
ICON_FRAME        :: "\uE3B5"   // center_focus_weak
ICON_HIDE         :: "\uE8F5"   // visibility_off
ICON_SHOW         :: "\uE8F4"   // visibility
ICON_PLAY         :: "\uE037"   // play_arrow
ICON_PAUSE        :: "\uE034"   // pause
ICON_STOP         :: "\uE047"   // stop
ICON_STEP         :: "\uE044"   // skip_next
ICON_FULLSCREEN   :: "\uE5D0"   // fullscreen
ICON_FULLSCREEN_EXIT :: "\uE5D1"   // fullscreen_exit
ICON_RENAME       :: "\uE3C9"   // edit
ICON_LIGHT_POINT  :: "\uE42E"   // wb_incandescent
ICON_LIGHT_SPOT   :: "\uF00B"   // flashlight_on
ICON_LIGHT_BEAM   :: "\uE436"   // wb_iridescent
ICON_LIGHT_SUN    :: "\uE430"   // wb_sunny
ICON_CAMERA       :: "\uE04B"   // videocam
ICON_GAME_VIEW    :: "\uE338"   // videogame_asset
ICON_RETRO        :: "\uE3EA"   // grain
ICON_RETRO_SETTINGS :: "\uE429"   // tune
ICON_LIGHTING     :: "\uE0F0"   // lightbulb
ICON_BAKE         :: "\uE80E"   // whatshot
ICON_SCRIPT       :: "\uE86F"   // code
ICON_FOLDER_OPEN  :: "\uE2C8"   // folder_open
ICON_BACK         :: "\uE5C4"   // arrow_back

ICON_FONT_PATH :: "assets_engine/fonts/MaterialSymbolsOutlined[FILL,GRAD,opsz,wght].ttf"

// The icon `e` shows in the viewport and the entity and template lists: its `icon` field (a hex codepoint, decoded to
// the glyph in temp memory) if set and valid, else its light or camera type's icon; none otherwise.
entity_icon :: proc(e: ^Entity) -> (icon: string, ok: bool) {
    if g, g_ok := icon_from_hex(sbuf_str(&e.icon)); g_ok do return g, true
    return entity_type_icon(e)
}

// The glyph for a hex codepoint ("E835"), in temp memory. ok=false for empty or invalid text.
icon_from_hex :: proc(hex: string) -> (glyph: string, ok: bool) {
    cp, cp_ok := strconv.parse_u64_of_base(strings.trim_space(hex), 16)
    if !cp_ok || cp == 0 || cp > u64(utf8.MAX_RUNE) do return
    bytes, n := utf8.encode_rune(rune(cp))
    return strings.clone(string(bytes[:n]), context.temp_allocator), true
}

/* ---------------------------------- Icons ---------------------------------- */
// A camera or light also gets an icon at its position, like Unity's gizmo icons, drawn on the view's
// overlay (editor_overlay.odin). So that a city's hundreds of lights don't become a carpet of markers:
// - it has a size in the world, so it shrinks with distance (clamped between a few pixels and full size);
// - it fades out with distance and is gone past EDITOR_ICON_FADE_END;
// - it dims while geometry stands between it and the camera (a CPU ray against the picking BVH).
// Selected icons always stay faintly visible. What can be clicked or marquee'd is what's drawn, except a
// dimmed unselected icon: a click on the wall in front of it picks the wall.

EDITOR_ICON_WORLD_RADIUS       :: 0.5    // world units: an icon's size where it stands (full size within ~15 units)
EDITOR_ICON_MIN_PX             :: 6      // …never smaller on screen than this (× display scale), nor bigger than OVERLAY_ICON_RADIUS
EDITOR_ICON_FADE_START         :: 40.0   // distance from the camera where icons start fading out
EDITOR_ICON_FADE_END           :: 80.0   // …and are gone
EDITOR_ICON_OCCLUDED_ALPHA     :: 0.2    // alpha scale for an icon behind geometry
EDITOR_ICON_SELECTED_MIN_ALPHA :: 0.35   // a selected icon never fades or hides below this
EDITOR_ICON_RAYS_PER_FRAME     :: 48     // occlusion rays per view per frame; with more icons they take turns

// One icon as a view shows it this frame.
Editor_Icon :: struct {
    handle:   Entity_Handle,
    icon:     string,
    center:   vec2,   // screen
    radius:   f32,    // pixels
    alpha:    f32,
    pickable: bool,   // false while dimmed behind geometry and not selected
}

// The icon `e` shows in the viewport, if any: entity_icon (its own icon, else its light or camera
// type's), while it's enabled and unhidden.
editor_entity_icon :: proc(e: ^Entity) -> (icon: string, ok: bool) {
    if !entity_editor_visible(e) do return
    return entity_icon(e)
}

// The icon of `e`'s light or camera type, whatever its flags; none for other entities. A light wins
// over a camera on the same entity (two roles are normally two entities).
entity_type_icon :: proc(e: ^Entity) -> (icon: string, ok: bool) {
    switch e.light_type {
    case .None:
    case .Point:       return ICON_LIGHT_POINT, true
    case .Spot:        return ICON_LIGHT_SPOT, true
    case .Cylinder:    return ICON_LIGHT_BEAM, true
    case .Directional: return ICON_LIGHT_SUN, true
    }
    if e.camera_type != .None do return ICON_CAMERA, true
    return
}

// How `ev` shows `e`'s icon this frame; false when it shows none (no icon, off screen or faded out).
// Behind geometry it's dimmed, and not pickable unless selected.
editor_icon_of :: proc(ev: ^Editor_View, e: ^Entity) -> (ic: Editor_Icon, ok: bool) {
    if ev.game_view do return   // G: no icons, so none to click either
    icon := editor_entity_icon(e) or_return
    center, front := world_to_screen(ev, e.position)
    if !front do return
    full := OVERLAY_ICON_RADIUS * app.display_scale
    if !on_view(ev, center, full) do return

    dist := linalg.length(e.position - camera_eye(ev.view.camera))
    alpha := 1 - clamp((dist - EDITOR_ICON_FADE_START) / (EDITOR_ICON_FADE_END - EDITOR_ICON_FADE_START), 0, 1)
    occluded := ev.icon_hidden[e.handle.idx]
    if occluded do alpha *= EDITOR_ICON_OCCLUDED_ALPHA
    if e.selected do alpha = max(alpha, EDITOR_ICON_SELECTED_MIN_ALPHA)
    if alpha <= 0.01 do return

    radius := clamp(EDITOR_ICON_WORLD_RADIUS * overlay_pixels_per_unit(ev, e.position), EDITOR_ICON_MIN_PX * app.display_scale, full)
    return {e.handle, icon, center, radius, alpha, !occluded || e.selected}, true
}

// Whether screen point `s` is on `ev`'s image, or within `margin` pixels of it.
@(private="file")
on_view :: proc(ev: ^Editor_View, s: vec2, margin: f32) -> bool {
    lo, hi := ev.screen_min - margin, ev.screen_min + ev.screen_size + margin
    return s.x >= lo.x && s.y >= lo.y && s.x <= hi.x && s.y <= hi.y
}

// Re-tests which icons geometry hides from `ev`'s camera: a ray from the eye to each icon against the
// scene (pick_entity, so hidden/disabled meshes don't block). Up to EDITOR_ICON_RAYS_PER_FRAME per frame,
// taking turns over the icons that could be seen (on screen, not faded out), so the cost stays flat
// however many lights there are; a hidden flag may lag the camera by a few frames. A light inside its own
// model (a lantern) isn't hidden by it.
editor_icons_update_occlusion :: proc(ev: ^Editor_View) {
    w := ev.view.world
    eye := camera_eye(ev.view.camera)
    candidates := make([dynamic]Entity_Handle, context.temp_allocator)
    it := hm.iterator_make(&w.entities)
    for e, h in hm.iterate(&it) {
        if _, has := editor_entity_icon(e); !has do continue
        if linalg.length(e.position - eye) >= EDITOR_ICON_FADE_END && !e.selected do continue
        s, front := world_to_screen(ev, e.position)
        if !front || !on_view(ev, s, 0) do continue
        append(&candidates, h)
    }
    n := len(candidates)
    if n == 0 do return
    for k in 0 ..< min(n, EDITOR_ICON_RAYS_PER_FRAME) {
        h := candidates[(ev.icon_cursor + k) % n]
        e := entity_get(w, h) or_continue
        to := e.position - eye
        dist := linalg.length(to)
        if dist < 1e-4 { ev.icon_hidden[h.idx] = false; continue }
        hit, blocked := pick_entity(w, Ray{origin = eye, dir = to / dist})
        ev.icon_hidden[h.idx] = blocked && hit.entity != h && hit.t < dist - 0.05
    }
    ev.icon_cursor = (ev.icon_cursor + EDITOR_ICON_RAYS_PER_FRAME) % n
}

// Draws every icon in `ev`'s view. Call right after the image item, before the gizmo, so the gizmo
// draws over them.
editor_draw_icons :: proc(ev: ^Editor_View) {
    editor_icons_update_occlusion(ev)
    o := overlay_begin(ev)
    defer overlay_end(o)
    w := ev.view.world
    it := hm.iterator_make(&w.entities)
    for e, h in hm.iterate(&it) {
        ic := editor_icon_of(ev, e) or_continue
        ring: vec4
        if e.selected do ring = selection_color(w, h)
        col := e.light_type != .None ? editor_light_color(e) : vec4{0.9, 0.9, 0.95, 1}
        col.a = ic.alpha
        overlay_icon(o, e.position, ic.icon, col, ring, ic.radius)
    }
}

// The entity whose icon is under screen point `p` (the nearest, if several overlap). Only icons that are
// drawn count; a small one still has a few pixels of slack.
editor_icon_pick :: proc(ev: ^Editor_View, p: vec2) -> (handle: Entity_Handle, ok: bool) {
    best := max(f32)
    it := hm.iterator_make(&ev.view.world.entities)
    for e, _ in hm.iterate(&it) {
        ic := editor_icon_of(ev, e) or_continue
        if !ic.pickable do continue
        if d := linalg.length(ic.center - p); d <= max(ic.radius, 7 * app.display_scale) && d < best {
            best, handle, ok = d, ic.handle, true
        }
    }
    return
}

// The screen rect a marquee tests for an entity with an icon but no model (only while it's drawn).
editor_icon_rect :: proc(ev: ^Editor_View, e: ^Entity) -> (lo, hi: vec2, ok: bool) {
    ic := editor_icon_of(ev, e) or_return
    if !ic.pickable do return
    return ic.center - ic.radius, ic.center + ic.radius, true
}
