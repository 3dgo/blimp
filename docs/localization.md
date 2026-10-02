# Localization


Engine/editor UI is bilingual — English and Simplified Chinese — default **zh** (the
primary user). One enumerated table in `loc.odin`, no framework:

- `Loc_ID` enum keys → `loc_text: [Loc_ID][Lang]cstring`, both languages on one row.
  Enumerated array, **not a map**: O(1) index, zero-alloc, rodata. `tr(.Key)` returns a
  `cstring` ImGui consumes directly (no per-frame `clone_to_cstring`). `loc_verify` asserts
  no cell is empty at init. Adding a language = one `Lang` value + one column; `tr` untouched.
- **Scope: user-facing UI labels only.** Logs, asserts, asset keys and file paths stay ASCII
  English — diagnostics, and keys must stay portable.
- Window titles carry a stable `###id` suffix so switching language doesn't reset ImGui
  docking. Must be triple-hash: ImGui hashes a window's whole label for its id, and `##`
  still includes the visible (translated) half — only `###` keys the id off the suffix alone.
- The reflection inspector localizes struct fields by a `loc:<Loc_ID>` backtick tag, and an
  enum/bit_set field's *member* names by an optional `loc_items:<prefix>` tag (member `M` →
  loc key `<prefix>_M`). Odin can't tag enum members directly, so members are keyed by this
  per-field prefix; an untagged or unresolved name falls back to the raw identifier.
- odin-imgui's dynamic font atlas rasterizes CJK on demand — no `GlyphRanges` setup.
- Orthogonal to the `.luacn` / `@(lua_zh)` Chinese-scripting tooling (that's script *input*,
  not UI).

