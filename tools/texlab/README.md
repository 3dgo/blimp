# TexLab

TexLab prepares PS1-style textures for Blimp:
- resizes textures, one at a time or in batches;
- adjusts them before the palette step;
- reduces them to 2-256 colours, with a palette per texture or one shared by a group.

## Setup

- [ImageMagick 7](https://imagemagick.org): `winget install ImageMagick.ImageMagick`. TexLab finds
  `magick.exe` on PATH or in `C:\Program Files\ImageMagick*`.
- `pip install -r tools/texlab/requirements.txt`, which installs PySide6.
- Run `tools\texlab\run.bat`. It works on the project two folders up; to use another project, pass its root
  folder.

## How it works

- **Originals** live in `assets_src/`, laid out like `assets/`. For example,
  `assets_src/models/Victorian/wall.png` becomes `assets/models/Victorian/wall.png`.
  - **Adopt from assets/** copies existing textures into `assets_src/` the first time.
  - New art goes straight into `assets_src/`. Press **Rescan** to pick it up.
  - Adopt never offers a texture TexLab already manages, even if its original is missing, because that file is
    build output. If you deleted an original on purpose, right-click the texture and choose **Forget**. That
    drops its settings and leaves its file in `assets/` alone.
- **Build** writes the processed textures into `assets/`. A running editor hot-reloads them.
  - All files in one build are swapped in together, so the engine reloads once.
  - The engine never reads `assets_src/`, so originals are never loaded or shipped.
- **Settings** live in `assets_src/texlab.json`. When you select several textures, an edit applies to all of
  them. Amber labels mark settings whose values differ across the selection.
- **Status** shows whether each output is up to date:
  - *built*: up to date;
  - *stale*: the source, the settings or a palette changed since the last build;
  - *not built*: no output written yet;
  - *(!)*: a warning, such as not a power of two, larger than a 256×256 texture page, or a jpg source.

## Palettes

- **None** keeps truecolour. You can still snap it to 15-bit colour (RGB555).
- **Own** gives the texture its own palette, like a PS1 CLUT.
- **Colours** can be anything from 2 to 256; the arrows step through common counts. The PS1 only has
  two formats with a palette:
  - up to 16 colours: a 4-bit texture with a 16-entry CLUT;
  - 17 to 256: an 8-bit texture with a 256-entry CLUT.

  Within each band, fewer colours cost the same VRAM, so the count is purely a look choice. With RGB555 on,
  near-identical colours merge, so you may get a few fewer than you asked for.
- **Group** shares one palette across every member. Use **New group...** with textures selected.
- **Locked swatches** are always kept.
  - Right-click a swatch to lock or unlock it.
  - Double-click a swatch to edit it; an edited colour becomes locked.
  - Every unlocked swatch is re-derived from the textures whenever their inputs change.
- **Import** loads a palette file as locked swatches. Formats: `.gpl` (GIMP/Aseprite), `.act` (Photoshop),
  JASC `.pal`, Lospec `.hex`, or a `.png`. If the palette has exactly as many colours as the texture's
  setting, it's used as a fixed palette.
- **Alpha** is 1-bit, set by **Alpha cutoff**. A texture with transparency uses one palette entry for it.
- **Dither** is error diffusion while remapping. Blimp's retro view already adds ordered dither on screen, so
  None is usually enough.

## Notes

- Staged images are cached in `%TEMP%\texlab`. You can delete that folder at any time.
- The VRAM bar estimates what the textures would take on a real PS1, against 1 MB including two 320×240
  framebuffers. Blimp itself uploads RGBA8.
- Textures embedded in a `.glb` can't be reached. Export the model as `.gltf` with separate png files.
