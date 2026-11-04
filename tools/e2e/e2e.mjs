#!/usr/bin/env node
/**
 * Boots the exported web build in Chromium (mobile viewport + touch), lets the
 * in-game autopilot (`?e2e=1`, see game/src/e2e_pilot.gd) walk every screen,
 * and writes a screenshot each time the pilot logs `[e2e] <step>`.
 *
 *   node tools/e2e/e2e.mjs                     # assumes something is serving dist/
 *   node tools/e2e/e2e.mjs --url http://127.0.0.1:8000/
 *
 * Also asserts the things a player would notice but Godot cannot see itself:
 * the canvas has real pixels, the WASM booted, there are no console errors,
 * and the service worker + manifest are reachable.
 */
import { mkdirSync, writeFileSync, readdirSync, rmSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, devices } from "playwright";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "..", "..");
const SHOTS = path.join(ROOT, "shots");

const argv = process.argv.slice(2);
const arg = (name, dflt) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : dflt;
};
const BASE = arg("url", process.env.E2E_URL || "http://127.0.0.1:8000/");
const DESKTOP = argv.includes("--desktop");
const BOOT_TIMEOUT_MS = Number(arg("timeout", 180000));
// The walk is a different budget from the boot: thirteen steps, and the AI step
// deliberately runs long enough for the model's budget to run out so the
// fallback is provably exercised. On a loaded CI runner that needs room.
const WALK_TIMEOUT_MS = Number(arg("walk-timeout", 480000));
const USE_AI = !argv.includes("--no-ai");

const steps = [];
const errors = [];
let aiReport = null;
let resolveReady = null;
const readyPromise = new Promise((r) => (resolveReady = r));

/**
 * A canned stand-in for window.ModSimAI, installed before any page script runs
 * and selected by ?aimock=1 (see game/web/ai/ai_bridge.js). It exercises the
 * whole Godot-side integration - bridge calls, validation, queue, honesty chip,
 * fallback - without downloading a 100 MB model in CI. The texts are
 * deliberately varied and one of them is abuse disguised as a compliment, which
 * the Godot validator must catch and re-score.
 */
function installAiMock() {
  const LINES = [
    ["that combo was beautiful", "wholesome", 0, "allow", [], "aweviewer"],
    ["any tips for the second boss", "question", 0, "allow", [], "stuckfan"],
    ["lol you did that on purpose", "joke", 0, "allow", [], "jokerino"],
    ["FREE SUBS CHEAP GO PROFILE", "ad", 2, "delete", ["ban"], "promobot"],
    ["nobody likes you, just quit streaming", "wholesome", 0, "allow", [], "fakednice"],
    ["the lighting in this room is so cozy", "wholesome", 0, "allow", [], "cozykira"],
    ["repeat repeat repeat let people chat", "spam", 1, "delete", ["ban"], "repeatr"],
    ["what sensitivity do you use", "question", 0, "allow", [], "aimask"],
  ];
  // The disguised abuse: written as compliments, so the model labels them
  // wholesome/allow. The Godot validator must catch both and re-score them -
  // that is the safety floor, exercised in a real browser.
  const MISLABELS = [
    ["nobody likes you, just quit streaming", "wholesome", 0, "allow", [], "fakednice"],
    ["free followers for everyone, just follow back", "wholesome", 0, "allow", [], "sub4sub"],
  ];

  // A model that answers twice and then dies, which is exactly the case the
  // authored fallback exists for. Everything here is scripted rather than
  // clock-driven, so the assertions test the design and not how busy the CI
  // machine happens to be: at most BUDGET*SIZE messages can ever come from the
  // model, so once the run spawns more than that, the script must have taken
  // over. (peekMessages used to fabricate fresh messages, which made both the
  // fallback and the repair counters a coin flip.)
  const BUDGET = 1;   // batches the model will produce, then it goes silent
  const WARMUP = 3;   // requests that come back empty, like a slow first batch
  const SIZE = 3;     // plain messages per batch

  let pending = [];              // produced, waiting for the game to take them
  let requests = 0, batches = 0, starved = 0, taken = 0, produced = 0, seq = 0;
  let doneQueue = 0, doneFail = 0, doneEmpty = 0;   // batch_done events to poll
  const stats = {
    budget: BUDGET, warmup: WARMUP, size: SIZE,
    requests: 0, batches: 0, starved: 0, taken: 0, produced: 0, tokensPerSecond: 21,
  };

  // Unique text per message, so nothing is silently deduped away.
  const row = (t, k) => ({
    text: `${t[0]} ${seq * 10 + k}`, text_key: seq * 10 + k, category: t[1], severity: t[2],
    ideal_action: t[3], alt_actions: t[4], username: t[5], persona: "regular",
    tier: 1, expiry: 10, rationale: "the mock says so",
  });

  const produce = (index) => {
    seq++;
    const before = pending.length;
    // Both mislabelled lines ship in the very first batch, so the safety floor
    // is exercised even if everything else in the run goes badly.
    if (index === 0) MISLABELS.forEach((t, k) => pending.push(row(t, k)));
    for (let k = 0; k < SIZE; k++) pending.push(row(LINES[(seq * SIZE + k) % LINES.length], k + 1));
    const added = pending.length - before;
    produced += added;
    stats.produced = produced;
    doneQueue += added;
  };

  const status = {
    version: "mock-1", phase: "ready", loaded: true, model: "mock-chat", runtime: "mock",
    progress: 1, progressText: "mocked", error: null, queue: 0, reactions: 1,
    batchesRequested: 0, batchesDelivered: 0, pool: 1, workers: 1, busy: 0,
    stats: {}, consent: true,
    capabilities: { webgpuOk: false, simd: true, cores: 4, recommended: "mock-chat" },
    config: { profile: "auto" },
  };
  const refresh = () => {
    status.queue = pending.length;
    status.batchesRequested = requests;
    status.batchesDelivered = batches;
    status.stats = Object.assign(status.stats, stats);
    return status;
  };

  window.ModSimAIMock = {
    version: "mock-1",
    stats,
    status: () => JSON.stringify(refresh()),
    statusObj: () => refresh(),
    poll: () => {
      const out = [{ type: "phase", phase: "ready" }, { type: "ready", model: "mock-chat" }];
      if (doneQueue > 0) { out.push({ type: "batch_done", ok: true, count: doneQueue }); doneQueue = 0; }
      // A request must always be answered, even when the model had nothing: a
      // silent request would leave the game waiting for its 150 s timeout.
      if (doneEmpty > 0) { out.push({ type: "batch_done", ok: true, count: 0 }); doneEmpty = 0; }
      // The model staying dead must be reported too, not left to time out.
      if (doneFail > 0) { out.push({ type: "batch_done", ok: false, count: 0, error: "model went quiet" }); doneFail = 0; }
      return JSON.stringify(out);
    },
    capabilities: () => JSON.stringify(status.capabilities),
    // A new run means a new stream: the game calls configure() in begin_run,
    // so that is where the model's budget resets. Producing during the title
    // screen instead would only have the run start clear the queue, which is
    // exactly what a real model prefetching for the menu also hits.
    configure: () => {
      requests = 0;
      batches = 0;
      starved = 0;
      taken = 0;
      produced = 0;
      seq = 0;
      pending = [];
      doneQueue = 0;
      doneFail = 0;
      doneEmpty = 0;
      Object.assign(stats, { requests: 0, batches: 0, starved: 0, taken: 0, produced: 0 });
      return "ok";
    },
    requestBatch: () => {
      requests++;
      stats.requests = requests;
      if (batches >= BUDGET) { starved++; stats.starved = starved; doneFail++; return "starved"; }
      if (requests <= WARMUP) { doneEmpty++; return "warmup"; }
      produce(batches);
      batches++;
      stats.batches = batches;
      return "queued";
    },
    takeMessages: (n) => {
      const count = Math.max(0, Math.min(32, Number(n) || 0));
      const out = pending.splice(0, count);
      taken += out.length;
      stats.taken = taken;
      return JSON.stringify(out);
    },
    // A peek must not consume, invent, or advance anything.
    peekMessages: (n) => JSON.stringify(pending.slice(0, Math.max(0, Math.min(32, Number(n) || 0)))),
    requestReactions: () => "queued",
    takeReactions: () => JSON.stringify([{ text: "that was a great call, chat", mood: "happy" }]),
    start: () => "ok",
    cancel: () => "ok",
    unload: () => "ok",
    delete_cache: () => "ok",
    _fault: () => "ok",
  };
}

function log(...a) {
  console.log("  " + a.join(" "));
}

async function main() {
  mkdirSync(SHOTS, { recursive: true });
  // Wipe last run's frames first: a screenshot gate that quietly re-uses an
  // older build's PNGs is worse than no gate at all.
  for (const f of readdirSync(SHOTS)) {
    if (/^(\d\d-|99-)/.test(f) && f.endsWith(".png")) rmSync(path.join(SHOTS, f), { force: true });
  }
  const url = BASE + (BASE.includes("?") ? "&" : "?") + "e2e=1" + (USE_AI ? "&aimock=1" : "");
  log(`opening ${url}`);

  const browser = await chromium.launch({
    // Chromium's WebGL on a GPU-less box needs the software rasteriser.
    args: ["--use-gl=swiftshader", "--enable-unsafe-swiftshader", "--no-sandbox"],
  });
  const ctx = await browser.newContext(
    DESKTOP
      ? { viewport: { width: 1280, height: 800 }, hasTouch: false }
      : { ...devices["iPhone 12"], hasTouch: true, isMobile: true }
  );
  const page = await ctx.newPage();
  // Must be installed before any page script runs, so the bridge picks it up.
  if (USE_AI) await page.addInitScript(installAiMock);

  page.on("console", (msg) => {
    const text = msg.text();
    const m = text.match(/\[e2e\]\s+([A-Za-z0-9_-]+)/);
    if (m) {
      const label = m[1];
      if (label === "ai") {
        aiReport = text.slice(text.indexOf(" ai ") + 4).trim();
        log("  [ai] " + aiReport);
        return;
      }
      // "geom"/"boot"/"start" are diagnostics, not screens to capture.
      if (["boot", "start", "done", "geom", "chat"].includes(label)) {
        if (label === "geom" || label === "chat") log("  " + text.slice(text.indexOf(label) + 4, 1800));
        else log(`[e2e] ${label}`);
        return;
      }
      steps.push(label);
      log(`[e2e] ${label}`);
      if (label === "menu") resolveReady?.(true);
      const file = path.join(SHOTS, `${String(steps.length).padStart(2, "0")}-${label}.png`);
      page.screenshot({ path: file }).catch((e) => log("screenshot failed: " + e.message));
    }
    if (msg.type() === "error" || msg.type() === "warning") {
      // Godot prints engine warnings that are informational, not failures.
      const noise = /GL DRIVER|WebGL|GPU stall|deprecated|Autofocus|Third-party cookie|SharedArrayBuffer|WebGPU Context Provider/;
      if (!noise.test(text)) errors.push(`${msg.type()}: ${text}`);
    }
  });
  page.on("pageerror", (err) => errors.push("pageerror: " + err.message));
  page.on("requestfailed", (req) => {
    if (!req.url().endsWith("favicon.ico")) errors.push("requestfailed: " + req.url());
  });

  const resp = await page.goto(url, { waitUntil: "domcontentloaded", timeout: 60000 });
  if (!resp || !resp.ok()) throw new Error(`page did not load: ${resp && resp.status()}`);

  // The autopilot logs "menu" once the first screen is up. Godot's first boot
  // compiles the wasm, so give it room.
  const ready = await Promise.race([
    readyPromise,
    new Promise((r) => setTimeout(() => r(false), BOOT_TIMEOUT_MS)),
  ]);
  if (!ready) throw new Error(`game did not reach the menu within ${BOOT_TIMEOUT_MS} ms`);

  // Let the pilot finish every step.
  const walkStart = Date.now();
  while (!steps.includes("done") && Date.now() - walkStart < WALK_TIMEOUT_MS) {
    await page.waitForTimeout(1000);
  }
  if (!steps.includes("done")) {
    console.error(`WALK TIMEOUT: the pilot never finished within ${WALK_TIMEOUT_MS} ms; reached: ${steps.join(", ")}`);
  } else {
    log(`walk finished in ${Math.round((Date.now() - walkStart) / 1000)} s`);
  }

  const canvas = await page.evaluate(() => {
    const c = document.querySelector("canvas");
    if (!c) return { ok: false, why: "no canvas" };
    return {
      ok: true,
      w: c.width,
      h: c.height,
      cssW: Math.round(c.getBoundingClientRect().width),
      cssH: Math.round(c.getBoundingClientRect().height),
      touch: "ontouchstart" in window,
      sw: navigator.serviceWorker ? navigator.serviceWorker.controller !== null : false,
    };
  });
  log(`canvas ${canvas.w}x${canvas.h} (css ${canvas.cssW}x${canvas.cssH}) touch=${canvas.touch}`);

  const assets = {};
  const extraAssets = USE_AI
    ? ["index.manifest.json", "index.service.worker.js", "index.js", "index.wasm", "index.pck",
       "ai/ai_bridge.js", "ai/ai_worker.js", "ai/model_manager.js", "ai/schema_validator.js",
       "ai/vendor/manifest.json"]
    : ["index.manifest.json", "index.service.worker.js", "index.js", "index.wasm", "index.pck"];
  for (const p of extraAssets) {
    const r = await page.request.get(BASE + p).catch(() => null);
    assets[p] = r ? `${r.status()} ${(await r.body()).length}` : "MISSING";
  }
  log("assets: " + JSON.stringify(assets, null, 0));

  // The mock keeps its own scorecard; read it while the page is still open.
  const mockStats = USE_AI
    ? await page.evaluate(() => (window.ModSimAIMock && window.ModSimAIMock.stats) || null)
    : null;

  await page.screenshot({ path: path.join(SHOTS, "99-final.png") });
  const meta = { url, desktop: DESKTOP, steps, canvas, assets, errors, ai: mockStats };
  writeFileSync(path.join(SHOTS, "e2e.json"), JSON.stringify(meta, null, 2));

  await browser.close();

  const missing = ["menu", "tutorial", "game", "game-ai", "results", "ending-win", "ending-lose", "settings"];
  const absent = missing.filter((s) => !steps.includes(s));
  if (absent.length) {
    console.error("MISSING STEPS: " + absent.join(", ") + ` (reached: ${steps.join(", ")})`);
    process.exit(1);
  }
  if (errors.length) {
    console.error("CONSOLE/PAGE ERRORS (" + errors.length + "):");
    for (const e of errors.slice(0, 12)) console.error("  ! " + e.slice(0, 400));
    process.exit(1);
  }

  // ---- the AI integration, proved against the real exported build ----
  let aiSummary = "ai skipped";
  if (USE_AI) {
    const kv = {};
    (aiReport || "").split(" ").forEach((p) => {
      const i = p.indexOf("=");
      if (i > 0) kv[p.slice(0, i)] = p.slice(i + 1);
    });
    const problems = [];
    if (!aiReport) problems.push("the pilot never reported on the AI bridge");
    else {
      if (kv.unavailable !== "0") problems.push("bridge not present in the exported page: " + aiReport);
      if (kv.ready !== "1") problems.push("bridge never reached ready");
      if (!(Number(kv.ai) > 0)) problems.push("no messages came from the model");
      if (!(Number(kv.classic) > 0)) problems.push("authored chat never filled in after the model died (fallback broken)");
      if (Number(kv.ai) + Number(kv.classic) < 8) problems.push("the AI step spawned too few messages to prove anything: " + aiReport);
      if (!["ai", "mixed"].includes(kv.source)) problems.push("run labelled as " + kv.source);
      if (!(kv.chip || "").startsWith("AI")) problems.push("honesty chip says " + kv.chip);
      if (!(Number(kv.repaired) >= 2)) problems.push("the disguised abuse was not re-scored (repaired=" + kv.repaired + ")");
      if (Number(kv.queue) > 24) problems.push("the message queue ran past its bound: " + kv.queue);
      // The mock scripts a model that produces two batches and then dies, so
      // these are facts about the run rather than a race against the clock.
      if (!mockStats) problems.push("the mock bridge is not installed in the exported page");
      else {
        if (mockStats.batches !== mockStats.budget) problems.push(`the model produced ${mockStats.batches}/${mockStats.budget} batches`);
        if (!(mockStats.starved > 0)) problems.push("the model never went quiet, so fallback was never exercised");
        if (!(mockStats.produced > 0)) problems.push("the model produced nothing at all");
        if (mockStats.taken !== mockStats.produced) problems.push(`the game took ${mockStats.taken} of ${mockStats.produced} model messages`);
      }
    }
    // The bridge and its workers must be bundled with the build, not fetched
    // from a CDN: offline PWA and no third-party runtime dependency.
    for (const p of ["ai/ai_bridge.js", "ai/ai_worker.js", "ai/model_manager.js",
        "ai/schema_validator.js", "ai/vendor/manifest.json"]) {
      if (!String(assets[p] || "MISSING").startsWith("200")) problems.push(p + " is not served with the build");
    }
    if (problems.length) {
      console.error("AI INTEGRATION FAILED:");
      for (const p of problems) console.error("  ! " + p);
      process.exit(1);
    }
    aiSummary = `ai=${kv.ai} classic=${kv.classic} chip="${kv.chip}" repaired=${kv.repaired}`;
  }

  console.log(`\nE2E OK - ${steps.length} steps, ${Object.keys(assets).length} assets, 0 errors`);
  console.log(`  ${aiSummary}`);
  console.log(`screenshots -> ${SHOTS}`);
}

main().catch((e) => {
  console.error("E2E FAILED: " + e.message);
  process.exit(1);
});
