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
  let i = 0;
  let calls = 0;
  let blackoutUntil = 0;
  // The disguised insult: written as a compliment, so the model labels it
  // wholesome. The Godot validator must catch it and re-score it as major
  // abuse - that is the safety floor, exercised in a real browser.
  const ATTACK = ["nobody likes you, just quit streaming", "wholesome", 0, "allow", [], "fakednice"];
  const canned = (n) => {
    // Two kinds of "the model is not there": the warm-up at the start, and a
    // multi-second blackout in the middle of the run. The game must quietly
    // serve the authored script through both, so a real run ends up showing
    // messages from both sources - which is what the assertions then require.
    const now = Date.now();
    if (calls++ < 5 || now < blackoutUntil) return [];
    if (calls % 12 === 11) blackoutUntil = now + 4000;
    const count = Math.max(1, Math.min(8, Number(n) || 1));
    const out = [];
    // Unique text each time, so the queue is never silently deduped away.
    const stamp = calls * 100;
    const row = (t, k) => ({
      text: `${t[0]} ${stamp + k}`, text_key: stamp + k, category: t[1], severity: t[2],
      ideal_action: t[3], alt_actions: t[4], username: t[5], persona: "regular",
      tier: 1, expiry: 10, rationale: "the mock says so",
    });
    out.push(row(ATTACK, 0));
    for (let k = 0; k < count - 1; k++) out.push(row(LINES[(i++) % LINES.length], k + 1));
    return out;
  };
  const status = {
    version: "mock-1", phase: "ready", loaded: true, model: "mock-chat", runtime: "mock",
    progress: 1, progressText: "mocked", error: null, queue: 8, reactions: 3,
    batchesRequested: 4, batchesDelivered: 4, pool: 1, workers: 1, busy: 0,
    stats: { tokensPerSecond: 21, batches: 4 }, consent: true,
    capabilities: { webgpuOk: false, simd: true, cores: 4, recommended: "mock-chat" },
    config: { profile: "auto" },
  };
  window.ModSimAIMock = {
    version: "mock-1",
    status: () => JSON.stringify(status),
    statusObj: () => status,
    poll: () => JSON.stringify([
      { type: "phase", phase: "ready" },
      { type: "ready", model: "mock-chat" },
      { type: "batch_done", ok: true, count: 8 },
    ]),
    capabilities: () => JSON.stringify(status.capabilities),
    takeMessages: (n) => JSON.stringify(canned(n)),
    peekMessages: (n) => JSON.stringify(canned(n)),
    takeReactions: () => JSON.stringify([{ text: "that was a great call", mood: "happy" }]),
    requestBatch: () => "queued",
    requestReactions: () => "queued",
    configure: () => "ok",
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
  for (let i = 0; i < 240 && !steps.includes("done"); i++) {
    await page.waitForTimeout(1000);
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

  await page.screenshot({ path: path.join(SHOTS, "99-final.png") });
  const meta = { url, desktop: DESKTOP, steps, canvas, assets, errors };
  writeFileSync(path.join(SHOTS, "e2e.json"), JSON.stringify(meta, null, 2));

  await browser.close();

  const missing = ["menu", "tutorial", "game", "game-ai", "results", "ending-win", "ending-lose", "settings"];
  const absent = missing.filter((s) => !steps.includes(s));
  if (absent.length) {
    console.error("MISSING STEPS: " + absent.join(", "));
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
      if (!(Number(kv.classic) > 0)) problems.push("authored chat never filled in while the model was slow (fallback broken)");
      if (Number(kv.ai) + Number(kv.classic) < 4) problems.push("too few messages in the AI step: " + aiReport);
      if (!["ai", "mixed"].includes(kv.source)) problems.push("run labelled as " + kv.source);
      if (!(kv.chip || "").startsWith("AI")) problems.push("honesty chip says " + kv.chip);
      if (!(Number(kv.repaired) >= 3)) problems.push("the disguised attack was not re-scored (repaired=" + kv.repaired + ")");
      if (Number(kv.queue) > 24) problems.push("the message queue ran past its bound: " + kv.queue);
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
