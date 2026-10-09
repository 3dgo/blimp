"""TexLab's data model (assets_src/texlab.json), the build pipeline over it, and the PS1 VRAM maths.

Sources live in assets_src/<rel>, outputs go to assets/<rel>. A palette's unlocked swatches are never stored:
they are derived from the current inputs (deterministic), so only locked swatches are user data.
"""

import copy
import dataclasses
import hashlib
import json
import os
import shutil
import tempfile
import threading
from dataclasses import dataclass, field

import magick
from magick import Color

IMAGE_EXTS = (".png", ".jpg", ".jpeg")
CACHE_DIR = os.path.join(tempfile.gettempdir(), "texlab")
VRAM_BYTES = 1024 * 1024
FRAMEBUFFER_BYTES = 2 * 320 * 240 * 2  # double-buffered 320x240, 16-bit
TPAGE = 256


@dataclass
class Palette:
    colors: int = 256
    rgb555: bool = True
    locked: list[str] = field(default_factory=list)  # "#rrggbb", always kept, listed first


@dataclass
class Texture:
    width: int = 128
    height: int = 128
    filter: str = "Box"
    brightness: int = 0
    contrast: int = 0
    saturation: int = 100
    gamma: float = 1.0
    sharpen: float = 0.0
    alpha_cutoff: int = 128
    palette: str = "own"  # "none", "own" or a group name
    own: Palette = field(default_factory=Palette)
    rgb555: bool = True  # used when palette is "none"
    dither: str = "None"
    built: str = ""  # build_key at the last build


STAGE_FIELDS = ("width", "height", "filter", "brightness", "contrast", "saturation", "gamma", "sharpen",
                "alpha_cutoff")


def pow2_floor(v: int) -> int:
    p = 1
    while p * 2 <= v:
        p *= 2
    return p


def is_pow2(v: int) -> bool:
    return v > 0 and v & (v - 1) == 0


def _hash(*parts) -> str:
    return hashlib.sha1(json.dumps(parts, sort_keys=True, default=str).encode()).hexdigest()[:16]


class Project:
    def __init__(self, root: str):
        self.root = root
        self.src_dir = os.path.join(root, "assets_src")
        self.out_dir = os.path.join(root, "assets")
        self.json_path = os.path.join(self.src_dir, "texlab.json")
        self.textures: dict[str, Texture] = {}
        self.groups: dict[str, Palette] = {}
        self.load()
        self.scan()

    # --- files ---

    def src(self, rel: str) -> str:
        return os.path.join(self.src_dir, rel)

    def out(self, rel: str) -> str:
        return os.path.join(self.out_dir, rel)

    def load(self):
        if not os.path.exists(self.json_path):
            return
        data = json.load(open(self.json_path, encoding="utf-8"))
        self.groups = {k: Palette(**v) for k, v in data.get("groups", {}).items()}
        for rel, v in data.get("textures", {}).items():
            v["own"] = Palette(**v.get("own", {}))
            self.textures[rel] = Texture(**v)

    def save(self):
        os.makedirs(self.src_dir, exist_ok=True)
        data = {"groups": {k: dataclasses.asdict(v) for k, v in sorted(self.groups.items())},
                "textures": {k: dataclasses.asdict(v) for k, v in sorted(self.textures.items())}}
        tmp = self.json_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=1, ensure_ascii=False)
        os.replace(tmp, self.json_path)

    def _walk(self, top: str) -> list[str]:
        rels = []
        for dirpath, _, files in os.walk(top):
            for name in files:
                if name.lower().endswith(IMAGE_EXTS):
                    rels.append(os.path.relpath(os.path.join(dirpath, name), top).replace("\\", "/"))
        return sorted(rels)

    def scan(self) -> list[str]:
        """Add settings for source files that have none yet. Returns the new ones."""
        new = [rel for rel in self._walk(self.src_dir) if rel not in self.textures]
        for rel in new:
            self.textures[rel] = self.default_texture(rel)
        return new

    def default_texture(self, rel: str) -> Texture:
        w, h = magick.image_size(self.src(rel))
        return Texture(width=min(pow2_floor(w), TPAGE), height=min(pow2_floor(h), TPAGE))

    def adopt_candidates(self) -> list[str]:
        """Textures in assets/ with no original. One TexLab already has settings for is build output whose
        original went missing: adopting it would make the small palettized copy the new original."""
        return [rel for rel in self._walk(self.out_dir)
                if not os.path.exists(self.src(rel)) and rel not in self.textures]

    def missing_sources(self) -> list[str]:
        return [rel for rel in self.textures if not os.path.exists(self.src(rel))]

    def forget(self, rels: list[str]):
        """Drop settings for textures whose originals were deleted on purpose. Outputs in assets/ stay."""
        for rel in rels:
            if not os.path.exists(self.src(rel)):
                del self.textures[rel]

    def adopt(self, rels: list[str]):
        """Copy textures from assets/ into assets_src/ as the full-res originals."""
        for rel in rels:
            os.makedirs(os.path.dirname(self.src(rel)), exist_ok=True)
            shutil.copy2(self.out(rel), self.src(rel))
        self.scan()

    # --- queries ---

    def palette_of(self, tex: Texture) -> Palette | None:
        if tex.palette == "none":
            return None
        return tex.own if tex.palette == "own" else self.groups.get(tex.palette)

    def members(self, rel: str) -> list[str]:
        """Textures sharing rel's palette, rel included."""
        name = self.textures[rel].palette
        if name in ("none", "own"):
            return [rel]
        return [r for r, t in self.textures.items() if t.palette == name and os.path.exists(self.src(r))]

    def problem(self, rel: str) -> str:
        if not os.path.exists(self.src(rel)):
            return "missing source"
        if rel.lower().endswith((".jpg", ".jpeg")):
            return "jpg: convert to png and re-point the glTF"
        if self.textures[rel].palette not in ("none", "own") and self.textures[rel].palette not in self.groups:
            return "unknown group"
        return ""

    def warnings(self, rel: str) -> list[str]:
        t = self.textures[rel]
        out = []
        if not (is_pow2(t.width) and is_pow2(t.height)):
            out.append("not a power of two")
        if t.width > TPAGE or t.height > TPAGE:
            out.append("larger than a 256x256 texture page")
        return out

    def stage_key(self, rel: str) -> str:
        st = os.stat(self.src(rel))
        t = self.textures[rel]
        return _hash(rel, st.st_mtime_ns, st.st_size, [getattr(t, f) for f in STAGE_FIELDS])

    def palette_key(self, rel: str) -> str:
        pal = self.palette_of(self.textures[rel])
        if pal is None:
            return _hash("none", self.textures[rel].rgb555)
        return _hash(dataclasses.asdict(pal), [(m, self.stage_key(m)) for m in self.members(rel)])

    def build_key(self, rel: str) -> str:
        return _hash(self.stage_key(rel), self.palette_key(rel), self.textures[rel].dither)

    def status(self, rel: str) -> str:
        if self.problem(rel):
            return "error"
        if not os.path.exists(self.out(rel)) or not self.textures[rel].built:
            return "not built"
        return "built" if self.textures[rel].built == self.build_key(rel) else "stale"

    # --- PS1 VRAM ---

    @staticmethod
    def clut_bytes(pal: Palette) -> int:
        """A PS1 CLUT holds 16 entries (4-bit textures) or 256 (8-bit), 2 bytes each, however many are used."""
        return 32 if pal.colors <= 16 else 512

    def bpp(self, tex: Texture) -> int:
        pal = self.palette_of(tex)
        return 16 if pal is None else (4 if pal.colors <= 16 else 8)

    def vram(self, rel: str) -> int:
        """Texture bytes plus its CLUT when the CLUT is its own."""
        t = self.textures[rel]
        pal = self.palette_of(t)
        clut = self.clut_bytes(pal) if t.palette == "own" else 0
        return t.width * t.height * self.bpp(t) // 8 + clut

    def vram_total(self) -> int:
        total = sum(self.vram(r) for r in self.textures if not self.problem(r))
        used = {t.palette for r, t in self.textures.items() if not self.problem(r)}
        return total + sum(self.clut_bytes(g) for name, g in self.groups.items() if name in used)

    def snapshot(self) -> "Project":
        """A copy for worker threads, so UI edits can't change settings under a running job."""
        snap = copy.copy(self)
        snap.textures = copy.deepcopy(self.textures)
        snap.groups = copy.deepcopy(self.groups)
        return snap


# --- pipeline (thread-safe; run on a snapshot) -------------------------------------------------

_lock = threading.Lock()
_palette_cache: dict[str, tuple[list[Color], bool]] = {}


def stage(proj: Project, rel: str) -> tuple[str, bool]:
    """Staged (resized, adjusted, 1-bit alpha) png in the disk cache, and whether it is opaque."""
    key = proj.stage_key(rel)
    os.makedirs(CACHE_DIR, exist_ok=True)
    for opaque, tag in ((True, "o"), (False, "a")):
        path = os.path.join(CACHE_DIR, f"stage_{key}_{tag}.png")
        if os.path.exists(path):
            return path, opaque
    t = proj.textures[rel]
    tmp = os.path.join(CACHE_DIR, f"stage_{key}_{threading.get_ident()}.tmp.png")
    opaque = magick.stage(proj.src(rel), tmp, t.width, t.height, t.filter, t.brightness, t.contrast,
                          t.saturation, t.gamma, t.sharpen, t.alpha_cutoff)
    path = os.path.join(CACHE_DIR, f"stage_{key}_{'o' if opaque else 'a'}.png")
    os.replace(tmp, path)
    return path, opaque


def swatches(proj: Project, rel: str) -> tuple[list[Color], bool]:
    """Full palette for rel (locked first, then derived) and whether a transparent entry is reserved."""
    pal = proj.palette_of(proj.textures[rel])
    key = proj.palette_key(rel)
    with _lock:
        if key in _palette_cache:
            return _palette_cache[key]
    staged = [stage(proj, m) for m in proj.members(rel)]
    alpha = not all(opaque for _, opaque in staged)
    locked = [magick.from_hex(h) for h in pal.locked][:pal.colors - alpha]
    derived = magick.quantize(b"".join(magick.opaque_rgb(p, o) for p, o in staged),
                              pal.colors - alpha - len(locked))
    colors = locked + derived
    if pal.rgb555:
        colors = [tuple(magick.snap555(v) for v in c) for c in colors]
    result = list(dict.fromkeys(colors)), alpha
    with _lock:
        _palette_cache[key] = result
    return result


def build(proj: Project, rel: str, out: str) -> list[Color]:
    """Write rel's final texture to out. Returns its palette ([] for truecolor)."""
    staged, opaque = stage(proj, rel)
    t = proj.textures[rel]
    if proj.palette_of(t) is None:
        magick.truecolor(staged, t.rgb555, out)
        return []
    pal, _ = swatches(proj, rel)
    pal_png = os.path.join(CACHE_DIR, f"pal_{threading.get_ident()}.png")
    magick.remap(staged, opaque, pal, t.dither, out, pal_png)
    return pal
