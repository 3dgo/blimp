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
ICON_CHARACTER    :: "\uE7FD"   // person
ICON_SEARCH       :: "\uE8B6"   // search (the older codepoint: this font file predates the EF7A one)
ICON_COPY         :: "\uE14D"   // content_copy
ICON_DUPLICATE    :: "\uE3BB"   // control_point_duplicate
ICON_DELETE       :: "\uE872"   // delete
ICON_LOCK         :: "\uE897"   // lock
ICON_ARROW_UP     :: "\uE5D8"   // arrow_upward
ICON_ARROW_DOWN   :: "\uE5DB"   // arrow_downward
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
ICON_PANELS       :: "\uF114"   // view_sidebar
ICON_RENAME       :: "\uE3C9"   // edit
ICON_LIGHT_POINT  :: "\uE42E"   // wb_incandescent
ICON_LIGHT_SPOT   :: "\uF00B"   // flashlight_on
ICON_LIGHT_BEAM   :: "\uE436"   // wb_iridescent
ICON_LIGHT_SUN    :: "\uE430"   // wb_sunny
ICON_CAMERA       :: "\uE04B"   // videocam
ICON_GAME_VIEW    :: "\uE338"   // videogame_asset
ICON_RETRO        :: "\uE3EA"   // grain
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
// overlay (editor_overlay.odin) at a constant screen size, in front of everything. G (game view) hides
// them all. The icon is what you click: it wins over a mesh behind it (view_pick), marquee tests it,
// F frames it.

// One icon as a view shows it this frame.
Editor_Icon :: struct {
    handle: Entity_Handle,
    icon:   string,
    center: vec2,   // screen
    radius: f32,    // pixels
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

// How `ev` shows `e`'s icon this frame; false when it shows none (no icon, game view, behind the camera
// or off the view).
editor_icon_of :: proc(ev: ^Editor_View, e: ^Entity) -> (ic: Editor_Icon, ok: bool) {
    if ev.game_view do return   // G: no icons, so none to click either
    icon := editor_entity_icon(e) or_return
    center, front := world_to_screen(ev, e.position)
    if !front do return
    radius := OVERLAY_ICON_RADIUS * app.display_scale
    lo, hi := ev.screen_min - radius, ev.screen_min + ev.screen_size + radius
    if center.x < lo.x || center.y < lo.y || center.x > hi.x || center.y > hi.y do return
    return {e.handle, icon, center, radius}, true
}

// Draws every icon in `ev`'s view. Call right after the image item, before the gizmo, so the gizmo
// draws over them.
editor_draw_icons :: proc(ev: ^Editor_View) {
    o := overlay_begin(ev)
    defer overlay_end(o)
    w := ev.view.world
    it := hm.iterator_make(&w.entities)
    for e, h in hm.iterate(&it) {
        ic := editor_icon_of(ev, e) or_continue
        ring: vec4
        if e.selected do ring = selection_color(w, h)
        col := e.light_type != .None ? editor_light_color(e) : vec4{0.9, 0.9, 0.95, 1}
        overlay_icon(o, e.position, ic.icon, col, ring, ic.radius)
    }
}

// The entity whose icon is under screen point `p` (the nearest, if several overlap).
editor_icon_pick :: proc(ev: ^Editor_View, p: vec2) -> (handle: Entity_Handle, ok: bool) {
    best := max(f32)
    it := hm.iterator_make(&ev.view.world.entities)
    for e, _ in hm.iterate(&it) {
        ic := editor_icon_of(ev, e) or_continue
        if d := linalg.length(ic.center - p); d <= ic.radius && d < best {
            best, handle, ok = d, ic.handle, true
        }
    }
    return
}

// The screen rect a marquee tests for an entity with an icon but no model.
editor_icon_rect :: proc(ev: ^Editor_View, e: ^Entity) -> (lo, hi: vec2, ok: bool) {
    ic := editor_icon_of(ev, e) or_return
    return ic.center - ic.radius, ic.center + ic.radius, true
}
