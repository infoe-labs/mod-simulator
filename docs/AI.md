# The chat model: how AI chat works here

The game can be played two ways, and both are complete games:

* **Classic Mode** — chat comes from 169 hand-written lines in
  `game/data/messages.json`. Always available, always the fallback.
* **AI Chat Mode** — an instruction-tuned language model that runs **in the
  player's browser** writes the viewers' messages, usernames and (sometimes)
  the streamer's reactions, live.

There is no backend, no API key and no paid service anywhere in this. The
model bytes come from Hugging Face once, with an explicit yes from the player,
and are then cached on that device.

---

## Where the code lives

```
game/web/ai/                     the JavaScript half (runs in the page)
  constants.js                   actions, categories, traits, limits, blocked content
  chat_generator.js              prompt + schema for a batch of chat messages
  moderation_classifier.js       prompt + schema for labelling one message
  json_schema.js                 the JSON schemas used for constrained decoding
  schema_validator.js            strict validation, normalisation, salvage parser
  model_manager.js               capability probe, model catalog, runtime adapters
  ai_worker.js                   inference in Web Workers: load/generate/classify
  ai_bridge.js                   window.ModSimAI, the only thing Godot talks to
  vendor/                        @mlc-ai/web-llm and @wllama/wllama, vendored

game/src/ai/                     the Godot half
  browser_ai_bridge.gd           thin, safe wrapper around window.ModSimAI
  ai_content.gd                  the second validator, and the moderation policy
  ai_chat_manager.gd             queue, prefetch, timeouts, fallback, statistics

game/src/ui/ai_status_row.gd     the opt-in UI: state, consent, download, unload
```

The data path, once, in words:

```
Godot                          page                          Web Workers
  │  ModSimAI.requestBatch() ──▶ queue ──────────────────────▶ build prompt
  │                                                            run the model
  │  ModSimAI.poll() ◀── events (phase / ready / batch_done / error)
  │  ModSimAI.takeMessages(n) ──▶ validated messages
  ▼
AIContent.validate_batch()      ← the rules live HERE, in Godot
  ▼
Sim spawns the message, scores it exactly like an authored one
```

### Two validators, on purpose

`schema_validator.js` rejects garbage before it crosses the bridge: unknown
keys, wrong types, links, blocked content, duplicate lines, banned usernames.
A completion cut off at the token limit is salvaged object-by-object rather
than thrown away (`extractObjects`).

`ai_content.gd` then decides what the game will actually do with the message,
and it does not ask the model's permission:

* the **category decides the moderation group** (`positive` / `neutral` /
  `minor` / `major`) through the same `MessageCatalog` the authored content
  uses, so scoring is identical for both sources;
* a harmless message can never be a ban, an abusive one can never be `allow`,
  `ban` is never offered as an alternative on a low-severity nuisance;
* damage, expiry and escalation come from the balance file, not from the model;
* a **safety floor** only ever *raises* severity. Measured example: SmolLM2
  labelled `nobody likes you, just quit streaming already` as `wholesome`,
  severity 0, action `allow`. The floor re-categorises it as harassment,
  severity 4, action delete with ban as an alternative, and counts the repair.

Every repair, drop and fallback is counted and shown in Settings — the game
never quietly pretends the model did better than it did.

### Honesty rules the UI obeys

* The header chip says **SCRIPT** unless the model really wrote the majority of
  tonight's messages, **AI + SCRIPT** when it carried a minority, **AI CHAT**
  when it carried the majority. It reads the sim's counters, not a setting.
* `RESULTS` reports `chat written by: AI on this device` / `AI 24 · script 12` /
  `authored script`, from the same counters.
* Nothing is downloaded until the player taps a button that names the model and
  its size in megabytes.
* When the device cannot run a model, the toggle disappears and the row says so
  plainly. Classic Mode is the game, not a degraded mode.

---

## Runtimes (both vendored, nothing fetched from a CDN)

| Runtime | Engine | Version | Needs | Used for |
|---------|--------|---------|-------|----------|
| `webllm` | `@mlc-ai/web-llm` | 0.2.87 | WebGPU (`navigator.gpu` + a working adapter) | the default wherever it works |
| `wllama` | `@wllama/wllama` | 3.8.1 | WASM + SIMD; threads need COOP/COEP | CPU fallback for everything else |

`tools/ai/vendor.sh` copies both from npm into `game/web/ai/vendor/` (33 MB,
sha256-summed in `vendor/manifest.json`) and pulls the WebLLM model libraries
for the catalogued models. `tools/ai/package.json` holds those build-time
dependencies; nothing at runtime reaches out to a CDN.

## Model catalog

Selected by `recommendModel(capabilities, profile)`; the player can force
LIGHT / AUTO / STRONG in Settings.

| id | family | quant | runtime | download | tier | notes |
|----|--------|-------|---------|----------|------|-------|
| `qwen3-0.6b-webgpu` | Qwen3 0.6B | q4f16_1 | webllm | 352 MB | standard | default on any device with WebGPU |
| `qwen25-0.5b-webgpu` | Qwen2.5 0.5B Instruct | q4f16_1 | webllm | 290 MB | light | low VRAM (945 MB), low-end GPUs |
| `llama32-1b-webgpu` | Llama 3.2 1B Instruct | q4f16_1 | webllm | 705 MB | quality | best labels, biggest download |
| `qwen25-0.5b-cpu` | Qwen2.5 0.5B Instruct | Q4_K_M | wllama | 398 MB | standard | CPU fallback when WebGPU is missing |
| `smollm2-135m-cpu` | SmolLM2 135M Instruct | Q4_K_M | wllama | 106 MB | light | smallest download; weak labels |

Weights are **not** in git. They are fetched from Hugging Face on consent
(`bartowski/…`, `mradermacher/…`, mlc-ai model dicts) and cached by the runtime
in the browser's Cache API, so the download happens once per device.

---

## Measured performance

Measured on the CI machine used for this project: 16 logical cores, ~8 GB
reported device memory, headless Chromium with SwiftShader WebGL, **no usable
WebGPU adapter** (Chromium exposes `navigator.gpu` but `requestAdapter()` fails,
so every run landed on the CPU runtime). Numbers are from
`tools/e2e/ai_lab.mjs`, whose evidence lands in `shots/ai_lab.json`.

| configuration | result |
|---------------|--------|
| `smollm2-135m-cpu`, COOP/COEP present (threads on) | 3-message batch **15.3 s**, **~25 tok/s**, one classification 9.5 s |
| `smollm2-135m-cpu`, no COOP/COEP — i.e. GitHub Pages | same batch **81.9 s**, ~5 tok/s |
| `qwen25-0.5b-cpu`, warm cache | load **1.7 s** |
| WebGPU / WebLLM path | **not verified here** — no adapter in this environment |

Token rates move with machine load: the same 3-message SmolLM2 batch measured
15.3 s on an idle machine and 38 s while the browser game e2e was running
alongside it. Treat these as orders of magnitude, not benchmarks.

Two consequences worth stating out loud:

1. **On GitHub Pages, CPU inference is roughly five times slower** than the
   same code served with COOP/COEP headers, because `SharedArrayBuffer` (and
   therefore wllama's threads) requires those headers and Pages cannot send
   them. The bridge compensates by running up to three single-threaded workers
   in parallel when the model is small, but a four-minute run still needs chat
   every couple of seconds. The answer is not to make the player wait: the
   queue prefetches, and when it runs dry the authored chat takes over inside
   the same frame. That is why both modes exist.
2. **The WebGPU path is the one that would feel live**, and it is the one this
   environment cannot test. Run `node tools/e2e/ai_lab.mjs` on a machine with a
   real GPU browser to fill in that row; until then it is unverified rather
   than assumed.

Token counts come from the runtime when it reports them. wllama sometimes does
not, in which case the lab and the UI show an estimated rate (≈4 chars/token)
labelled "(estimated)" rather than showing 0.

---

## What AI mode is *not*

* It is not a keyword classifier. The model writes and labels the messages;
  the code only validates, normalises and applies policy.
* It is not required. Turning it off (or lacking WebGPU/WASM-SIMD) changes the
  origin of the text, never the rules, the scoring or the win condition.
* It is not a chatbot you can talk to. The model only ever writes fictional
  viewer messages and short streamer reaction lines from a fixed schema; it is
  not given the player's words.
* It is not a networked service. No telemetry, no analytics, no account, no
  request leaves the page except the one-time weight download.

## Known limitations

* Small models mislabel real abuse. The safety floor catches the patterns it
  knows (`ai_content.GUARD_PATTERNS`) and the policy makes the label stick, but
  a 135M model will still produce nonsense occasionally — which is exactly why
  the authored dataset is always ready to fill in.
* Constrained decoding (a grammar per request) is what makes 0.5B-class models
  emit parseable JSON at all. Without it the same model returns prose.
* `SharedArrayBuffer` is unavailable without COOP/COEP; see above.
* iOS Safari below 16.4 has no WASM SIMD, so `wllama` will refuse to run there
  and the game stays in Classic Mode.
* A model download is 106–705 MB. It is cached, but the first tap needs Wi-Fi,
  and the consent dialog quotes the size before anything is fetched.
* Memory: each CPU worker holds its own copy of the weights, so the pool is
  capped at 3 and only for models under 160 MB.

---

## Playing with it

In the game: title screen (or **Settings → Live chat model**) → tap **AI CHAT**
→ tap **DOWNLOAD <family> (NNN MB)**. The row shows phase, model, runtime,
tokens/second and queue depth. `UNLOAD MODEL` frees the memory; `delete model`
drops the cached weights.

## Testing it

```bash
# headless: validation, policy, safety floor, queue bounds, fallback, honesty
godot --headless --path game -s res://tests/ai_tests.gd

# the game with a stubbed bridge: proves the Godot integration in the real
# exported build without downloading a model (part of the normal browser pass)
python3 tools/serve.py --port 8000
cd tools/e2e && node e2e.mjs --url http://127.0.0.1:8000/

# real inference, in an isolated proof page
python3 tools/serve.py --dir game/web --port 8766 --coi      # --coi = threads
cd tools/e2e && node ai_lab.mjs --url http://127.0.0.1:8766/ --model smollm2-135m-cpu
```

`tools/check_all.sh` runs the headless AI suite with the other gates. The real
inference run is opt-in because it downloads a model:

```bash
AI_LAB=1 AI_MODEL=smollm2-135m-cpu tools/check_all.sh
```

The e2e driver injects `window.ModSimAIMock` (selected by `?aimock=1`) so the
Godot side — bridge calls, validation, queue, honesty chip, fallback while the
model is "slow" — is exercised on every browser pass with no download.

## Reproducing the numbers

The two bench scripts use a persistent Chromium profile, so the weights are
downloaded once and every later run measures inference only:

```bash
python3 tools/serve.py --dir game/web --port 8766 --coi
cd tools/e2e
node bench_threads.mjs smollm2-135m-cpu     # threaded (COOP/COEP) throughput
node bench_llm.mjs qwen25-0.5b-cpu          # one real batch, token by token
node ../ai/probe.mjs                        # which WebGPU flags, if any, work
```

`tools/ai/probe.mjs` is how the WebGPU row above was shown to be unverifiable
here: Chromium exposes `navigator.gpu`, but `requestAdapter()` fails under
SwiftShader with every GL/ANGLE/Vulkan flag combination the script tries.

## Self-hosting the weights

Useful for classrooms, air-gapped machines, or just avoiding a 400 MB dependency
on Hugging Face at play time:

```bash
tools/ai/fetch_models.sh --list
tools/ai/fetch_models.sh smollm2-135m-cpu     # ~106 MB into game/web/ai/models/
```

`tools/export.sh` copies `game/web/` into `dist/`, so the weights ship with
your build and the bridge resolves them from `ai/models/` instead of the
network. `game/web/ai/models/` is git-ignored on purpose.

Serving it yourself with threads enabled (about five times faster on CPU):

```bash
python3 tools/serve.py --dir game/web --port 8766 --coi
```

which sends

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

The same headers on nginx/Cloudflare Pages/`_headers` give the same speedup;
GitHub Pages cannot send them, so Pages visitors get either the WebGPU path or
the (correctly-labelled) single-threaded CPU trickle.

## Rebuilding the vendored runtimes

```bash
tools/ai/vendor.sh          # npm ci in tools/ai, copy into game/web/ai/vendor/
```

`vendor/manifest.json` records the exact package versions and the sha256 of
every file, and the browser tests fail if any `ai/` or `vendor/` asset does not
return 200 from *our* origin — so a silent switch back to a CDN would break the
build rather than ship.
