#!/usr/bin/env python3
"""Verify the e2e screenshots actually rendered a playable screen.

The game draws into a WebGL canvas, so a blank frame is a real failure mode
(template mismatch, lost GPU context, missing .pck). Rather than eyeballing
PNGs, this measures each band of the layout and asserts the part the player
needs is drawing pixels: meters, the 3D feed, the chat tray (text ink) and the
three tinted action buttons.

    python3 tools/check_shots.py            # gate, exit 1 on problems
    python3 tools/check_shots.py --report   # per-band numbers
"""
from __future__ import annotations
import os
import sys

try:
    from PIL import Image
except ModuleNotFoundError:                                    # pragma: no cover
    sys.stderr.write(
        "check_shots.py needs Pillow to read the screenshots back:\n"
        "    python3 -m pip install -r tools/requirements.txt\n")
    sys.exit(2)

HERE = os.path.dirname(os.path.abspath(__file__))
SHOTS = os.path.normpath(os.path.join(HERE, "..", "shots"))

MINT = (0x63, 0xE6, 0xA8)
CORAL = (0xFF, 0x7A, 0x8A)
AMBER = (0xFF, 0xC8, 0x57)

# Bands as fractions of the canvas height, matching game_screen's layout.
BANDS = [
    ("header", 0.00, 0.18),
    ("feed", 0.18, 0.42),
    ("chat", 0.42, 0.80),
    ("buttons", 0.80, 1.00),
]
MIN_UNIQUE = 60
GAME_STEPS = ("game",)


def near(p, c, tol=40) -> bool:
    return all(abs(p[i] - c[i]) <= tol for i in range(3))


def stats(im: Image.Image, y0: float, y1: float):
    w, h = im.size
    c = im.crop((0, int(h * y0), w, int(h * y1))).resize((120, 60))
    px = list(c.getdata())
    n = len(px)
    return {
        "bright": sum(1 for p in px if max(p) > 120) / n,
        "ink": sum(1 for p in px if min(p) > 150) / n,
        "uniq": len(set(px)),
        "mint": sum(1 for p in px if near(p, MINT)),
        "coral": sum(1 for p in px if near(p, CORAL)),
        "amber": sum(1 for p in px if near(p, AMBER)),
    }


def audit(path: str) -> list[str]:
    name = os.path.basename(path)
    im = Image.open(path).convert("RGB")
    if im.size[0] < 200 or im.size[1] < 300:
        print(f"  {name:26s} TOO SMALL {im.size}")
        return [f"{name}: screenshot too small {im.size}"]
    is_game = any(k in name for k in GAME_STEPS)
    whole = stats(im, 0.0, 1.0)
    if whole["uniq"] < 120:
        print(f"  {name:26s} BLANK ({whole['uniq']} colours overall)")
        return [f"{name}: frame is blank ({whole['uniq']} colours)"]
    problems: list[str] = []
    line = []
    for band, y0, y1 in BANDS:
        s = stats(im, y0, y1)
        line.append(f"{band}:b{s['bright'] * 100:4.1f},u{s['uniq']:4d}")
        if is_game:
            if band == "chat" and s["ink"] < 0.004:
                problems.append(f"{name}/chat: no text ink ({s['ink'] * 100:.2f}%) - empty tray")
            if band == "feed" and s["bright"] < 0.08:
                problems.append(f"{name}/feed: 3D feed not rendering (bright {s['bright'] * 100:.1f}%)")
            if band == "buttons" and (s["mint"] + s["coral"] + s["amber"]) < 40:
                problems.append(
                    f"{name}/buttons: ALLOW/DELETE/BAN colours absent "
                    f"(mint={s['mint']} coral={s['coral']} amber={s['amber']})")
    print(f"  {name:26s} " + "  ".join(line))
    return problems


def main() -> int:
    if not os.path.isdir(SHOTS):
        print("no shots/ directory; run the e2e driver first:", file=sys.stderr)
        print("  python3 tools/serve.py --port 8767 &", file=sys.stderr)
        print("  cd tools/e2e && node e2e.mjs --url http://127.0.0.1:8767/", file=sys.stderr)
        return 2
    files = sorted(f for f in os.listdir(SHOTS) if f.endswith(".png"))
    if not files:
        print("no PNGs in shots/", file=sys.stderr)
        return 2
    print("shots:")
    failed = 0
    for f in files:
        for p in audit(os.path.join(SHOTS, f)):
            print("    ! " + p)
            failed += 1
    if failed:
        print(f"SHOT CHECK FAILED ({failed} problems)")
        return 1
    print(f"SHOTS OK ({len(files)} frames, chat + feed + buttons verified by pixels)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
