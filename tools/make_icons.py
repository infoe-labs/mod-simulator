#!/usr/bin/env python3
"""Generate the game's icons and PWA icons.

Everything in this repo is generated or hand-authored: no downloaded art, no
stock icons, no third-party fonts. Re-run after changing the palette:

    python3 tools/make_icons.py

Writes into game/icons/.
"""
from __future__ import annotations
import math
import os

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "game", "assets", "icons"))

WARM_BG_TOP = (43, 36, 82)
WARM_BG_BOTTOM = (18, 14, 36)
LAPTOP = (34, 30, 58)
LAPTOP_EDGE = (70, 62, 110)
SCREEN = (24, 20, 44)
MINT = (99, 230, 168)
CORAL = (255, 122, 138)
AMBER = (255, 200, 87)
CREAM = (244, 240, 255)


def rounded(draw, box, r, fill=None, outline=None, width=1):
    draw.rounded_rectangle(box, radius=r, fill=fill, outline=outline, width=width)


def gradient(size, top, bottom):
    w, h = size
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        t = y / max(1, h - 1)
        c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        for x in range(w):
            px[x, y] = c
    return img


def draw_scene(img: Image.Image, pad_ratio: float = 0.0) -> None:
    """Cozy desk: laptop, chat bubbles, moderation stamp. pad_ratio 0.1 keeps a
    safe margin for maskable icons."""
    w, h = img.size
    draw = ImageDraw.Draw(img)
    pad = int(w * pad_ratio)
    cx = w // 2

    # soft glow behind the laptop
    glow_r = int(w * 0.34)
    cxg, cyg = cx, int(h * 0.44)
    glow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    for i in range(glow_r, 0, -6):
        a = int(38 * (1 - i / glow_r))
        gd.ellipse([cxg - i, cyg - i, cxg + i, cyg + i], fill=(99, 230, 168, a))
    img.paste(glow, (0, 0), glow)

    scr_w = w - 2 * pad - int(w * 0.12)
    scr_h = int(scr_w * 0.66)
    sx = cx - scr_w // 2
    sy = int(h * 0.44) - scr_h // 2
    # laptop lid
    rounded(draw, [sx - 10, sy - 10, sx + scr_w + 10, sy + scr_h + 10],
            int(w * 0.035), fill=LAPTOP, outline=LAPTOP_EDGE, width=max(2, w // 128))
    # screen
    rounded(draw, [sx, sy, sx + scr_w, sy + scr_h], int(w * 0.02), fill=SCREEN)

    # chat bubbles inside the screen
    bw = int(scr_w * 0.52)
    bx = sx + int(scr_w * 0.10)
    by = sy + int(scr_h * 0.16)
    gap = int(scr_h * 0.22)
    for i, (frac, col) in enumerate([(0.52, CREAM), (0.34, MINT), (0.62, CORAL)]):
        wdt = int(bw * (frac / 0.52))
        rounded(draw, [bx, by + i * gap, bx + wdt, by + i * gap + int(gap * 0.62)],
                int(gap * 0.3), fill=col)

    # moderation stamp on the screen
    r = int(scr_w * 0.115)
    stx = sx + scr_w - int(scr_w * 0.2)
    sty = sy + scr_h - int(scr_h * 0.26)
    draw.ellipse([stx - r, sty - r, stx + r, sty + r], fill=AMBER)
    lw = max(3, w // 100)
    draw.line([stx - r * 0.45, sty, stx - r * 0.05, sty + r * 0.42], fill=(26, 20, 8), width=lw)
    draw.line([stx - r * 0.05, sty + r * 0.42, stx + r * 0.5, sty - r * 0.4], fill=(26, 20, 8), width=lw)

    # laptop base
    base_y = sy + scr_h + int(h * 0.03)
    half = int(scr_w * 0.62)
    draw.polygon([(cx - half, base_y), (cx + half, base_y),
                  (cx + int(half * 0.86), base_y + int(h * 0.045)),
                  (cx - int(half * 0.86), base_y + int(h * 0.045))],
                 fill=LAPTOP, outline=LAPTOP_EDGE)
    rounded(draw, [cx - int(half * 0.3), base_y + int(h * 0.012),
                   cx + int(half * 0.3), base_y + int(h * 0.026)],
            int(h * 0.008), fill=LAPTOP_EDGE)

    # little string lights above
    for i in range(5):
        t = i / 4.0
        x = int(w * (0.16 + 0.68 * t))
        y = int(h * (0.16 + 0.045 * math.sin(t * math.pi * 2.0)))
        rr = int(w * 0.022)
        col = [MINT, AMBER, CORAL, (143, 216, 255), MINT][i]
        draw.ellipse([x - rr, y - rr, x + rr, y + rr], fill=col)


def save_variant(name: str, size: int, radius: int | None, pad_ratio: float) -> None:
    img = gradient((size, size), WARM_BG_TOP, WARM_BG_BOTTOM).convert("RGBA")
    draw_scene(img, pad_ratio)
    if radius:
        mask = Image.new("L", (size, size), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
        img.putalpha(mask)
    img.save(os.path.join(OUT, name), "PNG")
    print(f"  assets/icons/{name}  {size}x{size}")


def main() -> None:
    os.makedirs(OUT, exist_ok=True)
    print("icons:")
    # Names follow what export_presets.cfg references for the PWA manifest.
    save_variant("icon_512x512.png", 512, 108, 0.02)
    save_variant("icon_192x192.png", 192, 42, 0.02)
    save_variant("icon_180x180.png", 180, None, 0.04)
    save_variant("icon_144x144.png", 144, None, 0.04)
    save_variant("icon_1536x1536.png", 1536, None, 0.14)  # Play Store 512px+ slot
    save_variant("favicon.png", 64, 14, 0.02)


if __name__ == "__main__":
    main()
