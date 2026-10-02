package blimp

import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

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
