#!/usr/bin/env python3
"""Palette + typography gate.

The brief asks for thumb-sized targets and readable text on a phone. This
script turns those into numbers so the look can be retuned freely in
themes/*.json without quietly drifting below the floor.

    python3 tools/check_palette.py            # gate, exit 1 on violation
    python3 tools/check_palette.py --report   # print the table
"""
from __future__ import annotations
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
THEME = os.path.join(ROOT, "game", "themes", "warm_cozy.json")

# A 390 CSS px wide phone is the narrowest common target; the canvas is 720
# reference px wide, so one reference px = 390/720 CSS px.
REFERENCE_WIDTH = 720.0
NARROW_CSS_WIDTH = 390.0
SCALE = NARROW_CSS_WIDTH / REFERENCE_WIDTH

MIN_TEXT_CONTRAST = 4.5      # WCAG AA for body text
MIN_GRAPHIC_CONTRAST = 3.0   # WCAG AA for non-text (meters, stripes)
MIN_BODY_CSS = 16.0          # chat + body copy
MIN_LABEL_CSS = 13.5         # ALL-CAPS meta labels
MIN_TAP_CSS = 44.0           # thumb target


def lum(h: str) -> float:
    h = h.lstrip("#")
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    ch = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    lin = [(c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4) for c in ch]
    return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]


def cr(a: str, b: str) -> float:
    la, lb = lum(a), lum(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def main() -> int:
    theme = json.load(open(THEME))
    c = theme["colors"]
    fs = theme["font_sizes"]
    m = theme["metrics"]
    fails: list[str] = []
    rows: list[str] = []

    # --- button inks: UI.readable_fg() picks the better of two inks ---------
    inks = ["#ffffff", "#140f22"]
    for key in ("mint", "coral", "amber", "violet", "blue", "gold"):
        bg = c[key]
        best = max(cr(bg, ink) for ink in inks)
        rows.append(f"  {'button ' + key:22s} best ink contrast {best:5.2f}")
        if best < MIN_TEXT_CONTRAST:
            fails.append(f"button '{key}' best contrast {best:.2f} < {MIN_TEXT_CONTRAST}")

    # --- copy on surfaces ---------------------------------------------------
    surfaces = {"bg": c["bg"], "panel": c["panel"], "panel_alt": c["panel_alt"],
                "chat_normal": c["chat_normal"], "chat_banned": c["chat_banned"],
                "chat_flagged": c["chat_flagged"]}
    for tname in ("text", "text_dim", "text_faint"):
        for sname, sbg in surfaces.items():
            r = cr(c[tname], sbg)
            rows.append(f"  {tname} on {sname:14s} contrast {r:5.2f}")
            if r < MIN_TEXT_CONTRAST:
                fails.append(f"{tname} on {sname}: {r:.2f} < {MIN_TEXT_CONTRAST}")

    # --- meters / stripes are graphics, 3:1 ---------------------------------
    for gname, bg in (("meter_happiness", "panel"), ("meter_trust", "panel"),
                      ("meter_bad", "panel"), ("chat_edited_stripe", "chat_normal"),
                      ("chat_flag_stripe", "chat_flagged")):
        r = cr(c[gname], c[bg])
        rows.append(f"  {gname} on {bg:14s} contrast {r:5.2f}")
        if r < MIN_GRAPHIC_CONTRAST:
            fails.append(f"{gname} on {bg}: {r:.2f} < {MIN_GRAPHIC_CONTRAST}")

    # --- typography, expressed in CSS px on a narrow phone ------------------
    for name, ref in fs.items():
        css = ref * SCALE
        floor = MIN_BODY_CSS if name in ("body", "chat", "small", "banner") else MIN_LABEL_CSS
        rows.append(f"  font {name:12s} {ref:3d} ref px = {css:5.1f} CSS px (floor {floor})")
        if css < floor:
            fails.append(f"font '{name}' is {css:.1f} CSS px on a {NARROW_CSS_WIDTH:.0f} px phone (< {floor})")

    # --- touch targets ------------------------------------------------------
    for name, ref in (("min_tap", m["min_tap"]), ("action_button_height", m["action_button_height"]),
                      ("row_height", m["row_height"])):
        css = ref * SCALE
        rows.append(f"  metric {name:20s} {ref:3d} ref px = {css:5.1f} CSS px")
        if css < MIN_TAP_CSS:
            fails.append(f"metric '{name}' is {css:.1f} CSS px (< {MIN_TAP_CSS})")

    if "--report" in sys.argv:
        print("\n".join(rows))
    if fails:
        print("PALETTE GATE FAILED")
        for f in fails:
            print("  ! " + f)
        return 1
    print(f"PALETTE OK ({len(rows)} checks, {NARROW_CSS_WIDTH:.0f} CSS px phone)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
