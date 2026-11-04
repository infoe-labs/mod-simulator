#!/usr/bin/env bash
# Vendor the browser LLM runtimes into the game so the deployed PWA never
# calls a JavaScript CDN.
#
#   tools/ai/vendor.sh            # install deps + copy everything
#   tools/ai/vendor.sh --check    # verify what is already there, download nothing
#
# What ends up in game/web/ai/vendor/:
#   webllm/web-llm.mjs        @mlc-ai/web-llm (ESM bundle, runs inside our worker)
#   webllm/libs/*.wasm        the compiled model libraries for the catalogued models
#   wllama/wllama.mjs         @wllama/wllama glue
#   wllama/wllama.wasm        llama.cpp compiled to WASM (single + multi thread)
#   manifest.json             versions, sizes, sha256 - checked by tools/check_ai.py
#
# Model *weights* are not vendored here: they are ~100-700 MB each and are
# downloaded on demand behind an explicit consent (tools/ai/fetch_models.sh can
# host them under the project path instead).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DEST="$ROOT/game/web/ai/vendor"
LIBS="$DEST/webllm/libs"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

command -v node >/dev/null || { echo "node is required to vendor the AI runtimes" >&2; exit 1; }

if [ "$CHECK_ONLY" -eq 0 ]; then
  ( cd "$HERE" && npm install --no-audit --no-fund >/dev/null )
fi

WLLM_VER=$(node -e "console.log(require('$HERE/node_modules/@mlc-ai/web-llm/package.json').version)")
WLM_VER=$(node -e "console.log(require('$HERE/node_modules/@wllama/wllama/package.json').version)")
# The model libraries must match the npm version exactly.
MODEL_VERSION=$(node -e "
const fs=require('fs');
const s=fs.readFileSync('$HERE/node_modules/@mlc-ai/web-llm/lib/index.js','utf8');
const m=s.match(/modelVersion\s*=\s*\"([^\"]+)\"/);
if(!m){console.error('could not read modelVersion from web-llm');process.exit(1)}
console.log(m[1]);")
echo "web-llm $WLLM_VER (libs $MODEL_VERSION), wllama $WLM_VER"

# The model library files we need are the ones our catalogue names.
mapfile -t LIBS_NEEDED < <(node -e "
import('$ROOT/game/web/ai/model_manager.js').then((m)=>{
  for (const e of m.MODEL_CATALOG) if (e.runtime==='webllm') console.log(e.lib);
});")
if [ "${#LIBS_NEEDED[@]}" -eq 0 ]; then
  echo "could not read the model catalogue from game/web/ai/model_manager.js" >&2
  exit 1
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  missing=0
  for f in webllm/web-llm.mjs wllama/wllama.mjs wllama/wllama.wasm; do
    [ -f "$DEST/$f" ] || { echo "missing vendor/$f"; missing=1; }
  done
  for lib in "${LIBS_NEEDED[@]}"; do
    [ -f "$LIBS/$lib" ] || { echo "missing vendor/webllm/libs/$lib"; missing=1; }
  done
  [ "$missing" -eq 0 ] && echo "vendor ok (web-llm $WLLM_VER, wllama $WLM_VER)" || exit 1
  exit 0
fi

mkdir -p "$DEST/webllm" "$LIBS" "$DEST/wllama"

echo "copy web-llm ..."
# Strip the sourceMappingURL: we do not ship .map files and the browser should
# not 404 looking for one.
sed 's|//# sourceMappingURL=.*||' \
  "$HERE/node_modules/@mlc-ai/web-llm/lib/index.js" > "$DEST/webllm/web-llm.mjs"

echo "copy wllama ..."
cp "$HERE/node_modules/@wllama/wllama/esm/index.js" "$DEST/wllama/wllama.mjs"
cp "$HERE/node_modules/@wllama/wllama/esm/wasm/wllama.wasm" "$DEST/wllama/wllama.wasm"

echo "fetch model libraries ..."
BASE="https://raw.githubusercontent.com/mlc-ai/binary-mlc-llm-libs/main/web-llm-models/$MODEL_VERSION"
for lib in "${LIBS_NEEDED[@]}"; do
  if [ -s "$LIBS/$lib" ]; then echo "  have $lib"; continue; fi
  echo "  get $lib"
  curl -fsSL --retry 3 -o "$LIBS/$lib.part" "$BASE/$lib"
  mv "$LIBS/$lib.part" "$LIBS/$lib"
done

python3 - "$DEST" "$WLLM_VER" "$WLM_VER" "$MODEL_VERSION" <<'PY'
import hashlib, json, os, sys
dest, wllm, wlm, model_version = sys.argv[1:5]
entries = []
for root, _dirs, files in os.walk(dest):
    for name in sorted(files):
        if name == "manifest.json":
            continue
        p = os.path.join(root, name)
        rel = os.path.relpath(p, dest).replace(os.sep, "/")
        with open(p, "rb") as fh:
            blob = fh.read()
        entries.append({
            "path": rel,
            "bytes": len(blob),
            "sha256": hashlib.sha256(blob).hexdigest(),
        })
manifest = {
    "runtimes": {
        "@mlc-ai/web-llm": wllm,
        "@wllama/wllama": wlm,
        "webllm_model_version": model_version,
    },
    "files": sorted(entries, key=lambda e: e["path"]),
    "total_bytes": sum(e["bytes"] for e in entries),
}
with open(os.path.join(dest, "manifest.json"), "w") as fh:
    json.dump(manifest, fh, indent=2)
    fh.write("\n")
print("vendor/manifest.json: %d files, %.1f MB"
      % (len(entries), manifest["total_bytes"] / 1e6))
PY

echo
echo "vendored into $DEST"
