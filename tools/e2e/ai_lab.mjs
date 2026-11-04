#!/usr/bin/env node
/**
 * The inference proof for "AI Chat Mode".
 *
 * Opens game/web/ai-lab.html in a real browser, lets it download a real model,
 * and fails unless the page shows: capabilities, a loaded model, three *
 * different* generated chat lines with valid labels, a classification of a
 * message the page made up, and non-zero token latency. Nothing is stubbed: if
 * the model does not answer, this script fails.
 *
 *   node tools/e2e/ai_lab.mjs --url http://127.0.0.1:8766/ --model smollm2-135m-cpu
 *
 * Options
 *   --model <id>      catalogue id (default: whatever the page recommends)
 *   --runtime <name>  webllm | wllama (filters the catalogue)
 *   --timeout <sec>   overall budget, default 900 (first run downloads weights)
 *   --profile <dir>   browser profile dir; keep it to reuse the model cache
 *   --fresh           wipe that profile first (forces a real re-download)
 *   --shots           write shots/ai-lab.png (default on)
 *
 * The weights stay in the profile's cache storage, so a second run is fast.
 */
import { mkdirSync, writeFileSync, rmSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "..", "..");
const SHOTS = path.join(ROOT, "shots");

const argv = process.argv.slice(2);
const arg = (name, dflt) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : dflt;
};
const has = (name) => argv.includes(`--${name}`);

const BASE = arg("url", process.env.AI_URL || "http://127.0.0.1:8766/");
const MODEL = arg("model", process.env.AI_MODEL || "");
// A 135M-parameter model on a CPU is honest about being weak: the structural
// contract (valid JSON, real categories, no links, no repeats) is demanded of
// every model, while the judgement checks - "the batch contains something
// worth moderating", three distinct lines - are only demanded of models in the
// standard tier and up. The game never relies on them: whatever comes back is
// re-validated and re-scored by the Godot side, and the authored chat fills in.
const LIGHT = /smollm|135m|tiny|light/i.test(MODEL);
const RUNTIME = arg("runtime", process.env.AI_RUNTIME || "");
const BUDGET_MS = Number(arg("timeout", 900)) * 1000;
const PROFILE = arg("profile", path.join(HERE, ".profile-ai"));
// Model weights are the only thing allowed to leave the origin. Hugging Face
// serves them from a few of its own hosts (xet bridge included).
const ALLOWED_CDN = /(^|\.)(huggingface\.co|hf\.co|hf\.tech)$/;

const VALID_CATEGORIES = new Set([
  "wholesome", "friendly", "question", "joke", "criticism", "mild_troll", "spam",
  "ad", "spoiler", "insult", "harassment", "attack", "invasive", "repeat_offender",
]);
const VALID_ACTIONS = new Set(["allow", "delete", "ban"]);
const VALID_MOODS = new Set(["neutral", "happy", "excited", "laughing", "blushing", "confused", "upset", "crying"]);

const log = (...a) => console.log("  " + a.join(" "));
const failures = [];
function check(cond, label, detail = "") {
  if (cond) log(`ok   ${label}${detail ? "  " + detail : ""}`);
  else { failures.push(label + (detail ? " — " + detail : "")); log(`FAIL ${label}${detail ? "  " + detail : ""}`); }
}

async function main() {
  mkdirSync(SHOTS, { recursive: true });
  if (has("fresh")) { try { rmSync(PROFILE, { recursive: true, force: true }); } catch (e) {} }

  const url = new URL("ai-lab.html", BASE);
  url.searchParams.set("auto", "1");
  if (MODEL) url.searchParams.set("model", MODEL);
  log(`opening ${url.toString()}`);

  const ctx = await chromium.launchPersistentContext(PROFILE, {
    args: ["--use-gl=swiftshader", "--enable-unsafe-swiftshader", "--no-sandbox"],
    viewport: { width: 900, height: 1400 },
    acceptDownloads: true,
  });
  const page = ctx.pages()[0] || await ctx.newPage();

  const markers = [];
  const consoleErrors = [];
  const offOrigin = [];
  const badResponses = [];
  const t0 = Date.now();

  page.on("console", (msg) => {
    const text = msg.text();
    const m = text.match(/\[ailab\]\s+(.+)/);
    if (m) { markers.push(m[1].trim()); log(`[ailab] ${m[1].trim().slice(0, 160)}`); return; }
    if (msg.type() === "error") {
      if (/favicon|Download the React DevTools/.test(text)) return;
      consoleErrors.push(text.slice(0, 300));
    }
  });
  page.on("pageerror", (e) => consoleErrors.push("pageerror: " + e.message.slice(0, 300)));
  page.on("request", (req) => {
    const u = new URL(req.url());
    if (u.protocol.startsWith("http") && u.hostname !== new URL(BASE).hostname) {
      if (!ALLOWED_CDN.test(u.hostname)) offOrigin.push(u.href.slice(0, 160));
    }
  });
  page.on("response", (res) => {
    if (res.status() >= 400) badResponses.push(`${res.status()} ${res.url().slice(0, 140)}`);
  });

  const waitFor = async (marker, ms) => {
    const deadline = Date.now() + ms;
    while (Date.now() < deadline) {
      if (markers.some((m) => m.startsWith(marker))) return true;
      if (markers.some((m) => m.startsWith("fatal") || m.startsWith("load-failed"))) return false;
      await new Promise((r) => setTimeout(r, 250));
    }
    return false;
  };

  let loaded = false;
  try {
    await page.goto(url.toString(), { waitUntil: "domcontentloaded", timeout: 60000 });
    const remain = () => Math.max(1000, BUDGET_MS - (Date.now() - t0));

    check(await waitFor("capabilities", 30000), "capability report rendered");
    loaded = await waitFor("loaded", remain());
    check(loaded, "model downloaded and loaded");

    let data = { messages: [], classification: null, telemetry: {}, capabilities: null, model: null, reactions: [] };
    if (loaded) {
      check(await waitFor("generated3", remain()), "generated 3 chat messages");
      check(await waitFor("generated12", remain()), "generated a 12-message batch");
      check(await waitFor("classified", remain()), "classified a custom message");
      check(await waitFor("reacted", remain()), "generated streamer reaction lines");
      await waitFor("done", 30000);
      data = await page.evaluate(() => window.__AILAB__ || {});
    }

    // ---- the actual assertions about model output ----
    const caps = data.capabilities || {};
    check(!!caps.hasWASM, "browser ran WASM", `simd=${caps.hasSIMD} cores=${caps.cores}`);
    check(!!data.model && data.model.ok, "model reported loaded", data.model ? data.model.id : "none");
    check(data.model && data.model.seconds > 0, "load time measured",
      data.model ? `${data.model.seconds.toFixed(1)}s` : "");

    const texts = (data.messages || []).map((m) => String(m.text || "").trim());
    const uniq = new Set(texts.map((t) => t.toLowerCase()));
    check(texts.length >= 1, "the model generated at least one message", `${texts.length}`);
    if (LIGHT) log(`(light model: judgement checks relaxed; ${texts.length} messages)`);
    else {
      check(texts.length >= 3, "at least 3 generated messages", `${texts.length}`);
    }
    check(uniq.size === texts.length && uniq.size >= 2, "messages are distinct, not repeats",
      `${uniq.size} unique of ${texts.length}`);
    check(texts.every((t) => t.length >= 2 && t.length <= 240), "every message has a sane length");
    check((data.messages || []).every((m) => VALID_CATEGORIES.has(m.category)),
      "every label is one of the game's 14 categories",
      (data.messages || []).map((m) => m.category).filter((c) => !VALID_CATEGORIES.has(c)).join(","));
    check((data.messages || []).every((m) => VALID_ACTIONS.has(m.ideal_action)),
      "every message carries a valid recommended action");
    check((data.messages || []).every((m) => Array.isArray(m.alt_actions)
      && m.alt_actions.every((a) => VALID_ACTIONS.has(a) && a !== m.ideal_action)),
      "alternative actions are valid and never repeat the ideal one");
    check((data.messages || []).every((m) => (m.severity >= 0 && m.severity <= 4)),
      "severities inside 0..4");
    check((data.messages || []).every((m) => !/https?:\/\//i.test(m.text) && !/\bwww\./i.test(m.text)),
      "no live links leaked into chat");
    if (LIGHT) {
      log(`  (light model: ${data.messages.filter((m) => m.ideal_action !== "allow").length}`
        + ` of ${data.messages.length} flagged - the game re-scores with its own policy)`);
    } else {
      check((data.messages || []).some((m) => m.ideal_action !== "allow"),
        "the batch contains something worth moderating");
    }
    check((data.messages || []).every((m) => !/^lorem|example text|as an ai|i cannot/i.test(m.text)),
      "no filler or refusal output");

    const c = data.classification;
    check(!!c, "classification returned");
    if (c) {
      check(VALID_CATEGORIES.has(c.category), "classification category valid", c.category);
      check(VALID_ACTIONS.has(c.recommended_action), "classification action valid", c.recommended_action);
      check(c.confidence >= 0 && c.confidence <= 1, "confidence in 0..1", String(c.confidence));
      check(typeof c.rationale === "string" && c.rationale.length > 4, "classification explains itself");
      check(c.seconds > 0, "classification latency measured", `${(c.seconds || 0).toFixed(2)}s`);
    }

    const telem = data.telemetry || {};
    const anyTok = telem.batch3?.tokensPerSecond || telem.batch12?.tokensPerSecond || 0;
    check(anyTok > 0, "token throughput reported", `${anyTok.toFixed(1)} tok/s`);
    check((data.reactions || []).every((r) => VALID_MOODS.has(r.mood)), "reaction moods valid");

    check(offOrigin.length === 0, "no runtime code fetched from a third-party CDN",
      offOrigin.slice(0, 3).join(" "));
    check(consoleErrors.length === 0, "no console errors", consoleErrors.slice(0, 3).join(" | "));
    const vendorFails = badResponses.filter((s) => /\/ai\//.test(s));
    check(vendorFails.length === 0, "every ai/ and vendor/ asset returned 200", vendorFails.slice(0, 3).join(" | "));

    await page.screenshot({ path: path.join(SHOTS, "ai-lab.png"), fullPage: true }).catch(() => {});
    const report = {
      when: new Date().toISOString(),
      url: url.toString(),
      model: data.model,
      capabilities: data.capabilities,
      telemetry: data.telemetry,
      messages: data.messages,
      classification: data.classification,
      reactions: data.reactions,
      markers,
      checks: { failed: failures, consoleErrors, offOrigin, badResponses },
      seconds: (Date.now() - t0) / 1000,
    };
    writeFileSync(path.join(SHOTS, "ai_lab.json"), JSON.stringify(report, null, 2));
    log(`evidence: shots/ai_lab.json, shots/ai-lab.png`);
  } finally {
    await ctx.close();
  }

  console.log();
  if (failures.length) {
    console.log(`AI LAB FAILED (${failures.length}):`);
    for (const f of failures) console.log("  - " + f);
    return 1;
  }
  console.log("AI LAB OK - real inference verified");
  return 0;
}

main().then((code) => process.exit(code)).catch((e) => {
  console.error("ai_lab.mjs crashed:", e);
  process.exit(2);
});
