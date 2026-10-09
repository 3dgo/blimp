"""ImageMagick command lines and palette files. Everything here is a plain function over paths and colour lists."""

import glob
import os
import shutil
import struct
import subprocess

Color = tuple[int, int, int]

FILTERS = ["Point", "Box", "Triangle", "Lanczos"]
DITHERS = ["None", "FloydSteinberg", "Riemersma"]


def find_magick() -> str:
    path = shutil.which("magick")
    if path:
        return path
    found = sorted(glob.glob(r"C:\Program Files\ImageMagick*\magick.exe"))
    return found[-1] if found else ""


MAGICK = find_magick()


def run(args: list[str], stdin: bytes | None = None) -> bytes:
    if not MAGICK:
        raise RuntimeError("ImageMagick (magick.exe) not found")
    r = subprocess.run([MAGICK, *args], input=stdin, capture_output=True,
                       creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    if r.returncode != 0:
        raise RuntimeError(r.stderr.decode(errors="replace").strip())
    return r.stdout


def version() -> str:
    try:
        return run(["-version"]).decode().split()[2]
    except Exception:
        return ""


def image_size(path: str) -> tuple[int, int]:
    with open(path, "rb") as f:
        head = f.read(24)
    if head[:8] == b"\x89PNG\r\n\x1a\n":
        return struct.unpack(">II", head[16:24])
    w, h = run(["identify", "-format", "%w %h", path + "[0]"]).split()
    return int(w), int(h)


def snap555(c: int) -> int:
    """Nearest 5-bit level, expanded back to 8 bits (same levels as -posterize 32)."""
    return round(round(c * 31 / 255) * 255 / 31)


def stage(src: str, out: str, width: int, height: int, filt: str, brightness: int, contrast: int,
          saturation: int, gamma: float, sharpen: float, alpha_cutoff: int) -> bool:
    """Resize and adjust src into an RGBA png with 1-bit alpha. Returns True if every pixel is opaque."""
    args = [src + "[0]", "-alpha", "set", "-filter", filt, "-resize", f"{width}x{height}!"]
    if brightness or contrast:
        args += ["-brightness-contrast", f"{brightness}x{contrast}"]
    if saturation != 100:
        args += ["-modulate", f"100,{saturation},100"]
    if gamma != 1.0:
        args += ["-gamma", f"{gamma:g}"]
    if sharpen > 0:
        args += ["-unsharp", f"0x0.75+{sharpen:g}+0.02"]
    # Alpha above the cutoff is opaque, the rest fully transparent with black colour, so all
    # transparent pixels are one palette entry.
    args += ["-channel", "A", "-threshold", f"{alpha_cutoff / 255 * 100:g}%", "+channel",
             "-background", "black", "-alpha", "background", "-depth", "8",
             "-write", "PNG32:" + out, "-format", "%[opaque]", "info:"]
    return run(args).decode().strip().lower() == "true"


def opaque_rgb(staged: str, opaque: bool) -> bytes:
    """Raw RGB bytes of every opaque pixel."""
    if opaque:
        return run([staged, "-alpha", "off", "-depth", "8", "RGB:-"])
    rgba = run([staged, "-depth", "8", "RGBA:-"])
    out = bytearray()
    for i in range(0, len(rgba), 4):
        if rgba[i + 3]:
            out += rgba[i:i + 3]
    return bytes(out)


def quantize(rgb: bytes, n: int) -> list[Color]:
    """Up to n colours representing the pixels in rgb (ImageMagick's octree quantizer)."""
    count = len(rgb) // 3
    if n <= 0 or count == 0:
        return []
    width = min(count, 1024)
    height = -(-count // width)
    pad = width * height - count
    rgb = rgb + (rgb * (pad // max(count, 1) + 1))[:pad * 3]
    raw = run(["-size", f"{width}x{height}", "-depth", "8", "RGB:-", "+dither", "-colors", str(n),
               "-unique-colors", "-depth", "8", "RGB:-"], stdin=rgb)
    return [tuple(raw[i:i + 3]) for i in range(0, len(raw), 3)]


def remap(staged: str, opaque: bool, swatches: list[Color], dither: str, out: str, palette_png: str):
    """Map staged onto swatches and write an indexed png (4-bit when it fits, else 8-bit)."""
    write_palette_png(palette_png, swatches)
    dith = ["+dither"] if dither == "None" else ["-dither", dither]
    if opaque:
        args = [staged, "-alpha", "off", *dith, "-remap", palette_png]
    else:
        # Remap colour only, then put the 1-bit alpha back.
        args = [staged, "(", "+clone", "-alpha", "extract", ")",
                "(", "-clone", "0", "-alpha", "off", *dith, "-remap", palette_png, ")",
                "-delete", "0", "+swap", "-alpha", "off", "-compose", "CopyOpacity", "-composite",
                "-background", "black", "-alpha", "background"]
    entries = len(swatches) + (0 if opaque else 1)
    args += ["-define", f"png:bit-depth={4 if entries <= 16 else 8}", "-define", "png:color-type=3",
             "PNG8:" + out]
    run(args)


def truecolor(staged: str, rgb555: bool, out: str):
    run([staged, *(["+dither", "-posterize", "32"] if rgb555 else []), "-depth", "8", "PNG32:" + out])


# --- palette files -----------------------------------------------------------------------------

PALETTE_FILTER = "Palettes (*.gpl *.act *.pal *.hex *.png);;GIMP/Aseprite (*.gpl);;Photoshop (*.act);;" \
                 "JASC (*.pal);;Lospec hex (*.hex);;Image (*.png)"


def to_hex(c: Color) -> str:
    return "#%02x%02x%02x" % c


def from_hex(s: str) -> Color:
    s = s.strip().lstrip("#")
    return int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16)


def write_palette_png(path: str, colors: list[Color]):
    run(["-size", f"{max(len(colors), 1)}x1", "-depth", "8", "RGB:-", "PNG24:" + path],
        stdin=bytes(v for c in (colors or [(0, 0, 0)]) for v in c))


def load_palette(path: str) -> list[Color]:
    ext = os.path.splitext(path)[1].lower()
    colors: list[Color] = []
    if ext == ".act":
        data = open(path, "rb").read()
        count = struct.unpack(">H", data[768:770])[0] if len(data) >= 772 else 256
        colors = [tuple(data[i * 3:i * 3 + 3]) for i in range(min(count, 256))]
    elif ext == ".png":
        raw = run([path + "[0]", "-alpha", "off", "-depth", "8", "RGB:-"])
        colors = [tuple(raw[i:i + 3]) for i in range(0, len(raw), 3)]
    else:
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
        if ext == ".pal":
            lines = lines[3:]  # JASC-PAL, 0100, count
        for line in lines:
            parts = line.split()
            if ext == ".hex" and parts:
                colors.append(from_hex(parts[0]))
            elif len(parts) >= 3 and all(p.isdigit() for p in parts[:3]):
                colors.append((int(parts[0]), int(parts[1]), int(parts[2])))
    seen: list[Color] = []
    for c in colors:  # order-preserving dedupe (a scaled-up Lospec png repeats every colour)
        if c not in seen:
            seen.append(c)
    return seen


def save_palette(path: str, colors: list[Color]):
    ext = os.path.splitext(path)[1].lower()
    if ext == ".act":
        data = bytearray(768)
        for i, c in enumerate(colors[:256]):
            data[i * 3:i * 3 + 3] = bytes(c)
        data += struct.pack(">HH", min(len(colors), 256), 0xFFFF)
        open(path, "wb").write(data)
    elif ext == ".png":
        write_palette_png(path, colors)
    elif ext == ".pal":
        open(path, "w", newline="\r\n").write(
            "JASC-PAL\n0100\n%d\n" % len(colors) + "".join("%d %d %d\n" % c for c in colors))
    elif ext == ".hex":
        open(path, "w").write("".join("%02x%02x%02x\n" % c for c in colors))
    else:
        name = os.path.splitext(os.path.basename(path))[0]
        open(path, "w").write(f"GIMP Palette\nName: {name}\nColumns: 16\n#\n" +
                              "".join("%3d %3d %3d\t%s\n" % (*c, to_hex(c)) for c in colors))
