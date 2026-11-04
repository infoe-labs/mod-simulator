#!/usr/bin/env bash
# Optionally host model weights under the project path so the deployed game
# needs no model CDN at all - and so it can run the CPU runtime with threads.
#
#   tools/ai/fetch_models.sh                      # everything in the catalogue
#   tools/ai/fetch_models.sh smollm2-135m-cpu     # just one
#   tools/ai/fetch_models.sh --list
#
# Files land in game/web/ai/models/<catalogue-id>/ and are copied into dist/ by
# tools/export.sh. They are git-ignored on purpose: a normal GitHub Pages
# deploy downloads the weights on first play instead (see README,
# "Hosting the weights yourself").
#
# Why you might want this:
#   * offline-first install (nothing but the page itself is fetched)
#   * it lets you serve the game with COOP/COEP, which unlocks the
#     multi-threaded wllama build - several times faster on a laptop CPU
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DEST="$ROOT/game/web/ai/models"

models=$(node -e "
import('$ROOT/game/web/ai/model_manager.js').then((m)=>{
  for (const e of m.MODEL_CATALOG) console.log([e.id,e.runtime,e.repo||e.modelId,e.file||'',e.downloadMB].join('\t'));
});")

if [ "${1:-}" = "--list" ]; then
  printf '%-22s %-8s %-46s %-8s\n' id runtime repo download
  while IFS=$'\t' read -r id runtime repo file mb; do
    printf '%-22s %-8s %-46s %5s MB\n' "$id" "$runtime" "${repo}${file:+/$file}" "$mb"
  done <<< "$models"
  exit 0
fi

mkdir -p "$DEST"
wanted="${*:-}"
while IFS=$'\t' read -r id runtime repo file mb; do
  [ -n "$id" ] || continue
  if [ -n "$wanted" ] && ! grep -qw "$id" <<<"$wanted"; then continue; fi
  dir="$DEST/$id"
  mkdir -p "$dir"
  if [ "$runtime" = "wllama" ]; then
    url="https://huggingface.co/$repo/resolve/main/$file"
    out="$dir/$file"
    if [ -s "$out" ]; then echo "have $id/$file"; continue; fi
    echo "get  $id  $url"
    curl -fL --retry 3 -o "$out.part" "$url"
    mv "$out.part" "$out"
  else
    # WebLLM: the whole model directory (params + tokenizer + mlc-chat-config).
    base="https://huggingface.co/mlc-ai/$repo/resolve/main"
    echo "get  $id (webllm bundle)"
    for f in mlc-chat-config.json ndarray-cache.json tokenize.json params; do
      # params is a directory: use the HF tree listing instead for the rest.
      if [ "$f" = "params" ]; then
        curl -fsSL "https://huggingface.co/api/models/mlc-ai/$repo/tree/main/params?recursive=true" \
          | python3 - "$dir/params" "$base/params" <<'PY'
import json, os, sys, urllib.request
dest, base = sys.argv[1], sys.argv[2]
tree = json.load(sys.stdin)
os.makedirs(dest, exist_ok=True)
for e in tree:
    if e["type"] != "file":
        continue
    url = base + "/" + e["path"]
    out = os.path.join(dest, e["path"])
    if os.path.exists(out) and os.path.getsize(out) == e.get("size", -1):
        continue
    os.makedirs(os.path.dirname(out), exist_ok=True)
    print("   ", e["path"], e.get("size", 0))
    urllib.request.urlretrieve(url, out + ".part")
    os.replace(out + ".part", out)
PY
        continue
      fi
      curl -fsSL --retry 3 -o "$dir/$f" "$base/$f" || echo "   (missing $f)"
    done
  fi
done <<< "$models"

python3 - "$DEST" <<'PY'
import json, os, sys
dest = sys.argv[1]
manifest = {}
for mid in sorted(os.listdir(dest)):
    d = os.path.join(dest, mid)
    if not os.path.isdir(d):
        continue
    files = []
    total = 0
    for root, _dirs, names in os.walk(d):
        for n in sorted(names):
            p = os.path.join(root, n)
            sz = os.path.getsize(p)
            total += sz
            files.append({"path": os.path.relpath(p, d).replace(os.sep, "/"), "bytes": sz})
    manifest[mid] = {"bytes": total, "files": files}
with open(os.path.join(dest, "manifest.json"), "w") as fh:
    json.dump(manifest, fh, indent=2)
    fh.write("\n")
for mid, v in manifest.items():
    print(f"{mid:24s} {v['bytes']/1e6:8.1f} MB  {len(v['files'])} files")
PY
echo
echo "weights in $DEST - export.sh copies them to dist/ai/models/ and the game"
echo "uses them when ModSimAI is configured with modelsBase: './ai/models/'"
