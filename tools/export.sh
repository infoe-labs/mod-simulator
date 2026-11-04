#!/usr/bin/env bash
# Export the web build into dist/ for GitHub Pages.
#
#   tools/export.sh                 # export from game/ into ../dist
#   tools/export.sh --clean         # wipe dist/ first
#   GODOT=godot4 tools/export.sh    # use a specific editor binary
#
# Requires the matching Web export templates:
#   Godot 4.x -> Editor > Manage Export Templates > Download
#   (or drop them in ~/.local/share/godot/export_templates/<version>/)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GAME="$ROOT/game"
DIST="$ROOT/dist"

GODOT="${GODOT:-}"
if [ -z "$GODOT" ]; then
  for c in godot godot4 ~/.local/bin/godot; do
    if command -v "$c" >/dev/null 2>&1; then GODOT="$(command -v "$c")"; break; fi
  done
fi
if [ -z "$GODOT" ]; then
  echo "error: no Godot editor found on PATH (set GODOT=/path/to/godot)" >&2
  exit 1
fi

VER="$("$GODOT" --version 2>/dev/null | head -1 | tr -d '\r')"
echo "godot: $GODOT ($VER)"
# "4.7.2.stable.official.abcd" -> ".../export_templates/4.7.2.stable"
TPL="$HOME/.local/share/godot/export_templates/$(echo "$VER" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+)\.([a-z]+)\..*/\1.\2/')"
if [ ! -d "$TPL" ]; then
  echo "error: missing export templates for $VER" >&2
  echo "       expected $TPL" >&2
  echo "       Editor > Manage Export Templates > Download, or:" >&2
  echo "       https://github.com/godotengine/godot-builds/releases (godot-export-templates.zip)" >&2
  exit 1
fi

if [ "${1:-}" = "--clean" ]; then
  rm -rf "$DIST"
  echo "cleaned $DIST"
fi
mkdir -p "$DIST"

# Import first: `--export-release` can otherwise write a .pck that is missing
# resources added since the last time the project was opened.
echo "import..."
"$GODOT" --headless --path "$GAME" --import 2>&1 \
  | grep -vE "^\s*$|Godot Engine|OpenGL|Vulkan|ALSA|PulseAudio|XInput|WASAPI" || true

echo "export..."
"$GODOT" --headless --path "$GAME" --export-release Web "$DIST/index.html" 2>&1 \
  | grep -vE "^\s*$|Godot Engine|OpenGL|Vulkan|ALSA|PulseAudio|XInput|WASAPI" || true

if [ ! -f "$DIST/index.html" ] || [ ! -f "$DIST/index.wasm" ] || [ ! -f "$DIST/index.pck" ]; then
  echo "error: export did not produce index.html/index.wasm/index.pck in $DIST" >&2
  exit 1
fi

# The service worker name changes between Godot point releases; never let a
# stale one survive a rebuild.
if [ -f "$DIST/manifest.json" ]; then
  SW="$(python3 - "$DIST" <<'PY'
import json, os, re, sys
d = sys.argv[1]
man = json.load(open(os.path.join(d, "manifest.json")))
sw = man.get("start_url") or ""
m = re.search(r"([^/?#]*\.service\.worker\.js)", sw)
print(m.group(1) if m else "")
PY
)"
  for old in "$DIST"/*.service.worker.js; do
    [ -e "$old" ] || continue
    if [ "$(basename "$old")" != "${SW:-none}" ]; then
      echo "removing stale service worker: $(basename "$old")"
      rm -f "$old"
    fi
  done
fi

# The offline page and any hand-written web/ extras ship next to the build.
if [ -d "$GAME/web" ]; then
  cp -r "$GAME/web/." "$DIST/"
  echo "copied web/ -> dist/"
fi

python3 - "$DIST" <<'PY'
import os, sys
d = sys.argv[1]
total = 0
print("\ndist/")
for f in sorted(os.listdir(d)):
    p = os.path.join(d, f)
    if os.path.isfile(p):
        kb = os.path.getsize(p) / 1024
        total += kb
        print(f"  {f:36s} {kb:9.1f} KB")
print(f"  {'':36s} --------")
print(f"  {'total':36s} {total:9.1f} KB")
PY
echo
echo "serve with:  python3 tools/serve.py --port 8000"
