/**
 * The bridge between the game and the language model.
 *
 * Godot talks to this object through JavaScriptBridge with *synchronous*
 * one-liners (see src/ai/browser_ai_bridge.gd). Nothing here ever blocks: the
 * expensive part lives in ai_worker.js, and results land in an event queue the
 * game drains when it feels like it. A model that is downloading, thinking, or
 * completely broken must be indistinguishable, from the player's side, from a
 * slightly slow network.
 *
 *   window.ModSimAI.status()        -> JSON, cheap, polled every few frames
 *   window.ModSimAI.poll()          -> JSON array of events, drains the queue
 *   window.ModSimAI.start({...})    -> consent + download + load, returns at once
 *   window.ModSimAI.requestBatch()  -> ask the worker(s) for the next messages
 *   window.ModSimAI.takeMessages(n) -> hand the game up to n queued messages
 *
 * The lab page (ai-lab.html) uses the promise API (ModSimAI.request.*), which
 * sits on the same workers and the same validation.
 *
 * The CPU runtime is single-threaded (a GitHub Pages deployment cannot send
 * COOP/COEP headers, so there is no SharedArrayBuffer and llama.cpp cannot use
 * pthreads). To stop that from being the whole story, the bridge keeps a small
 * pool of workers each holding its own copy of a small model and generates
 * different halves of a batch at the same time: two cores doing two halves is
 * roughly twice as fast as one core doing the whole thing.
 */

import { BRIDGE_VERSION, PROTOCOL, LIMITS } from './constants.js';
import { MODEL_CATALOG, quickCapabilities, probeWebGPU, recommendModel, modelById, storageEstimate } from './model_manager.js';

const EVENT_CAP = 80;

const state = {
  phase: 'off',          // off|probing|consent|downloading|loading|ready|generating|error|unsupported
  modelId: null,
  runtime: null,
  progress: 0,
  progressText: '',
  error: null,
  consent: false,
  capabilities: null,
  webgpu: null,
  pendingMessages: [],
  pendingReactions: [],
  lastBatchAt: 0,
  batchesRequested: 0,
  batchesDelivered: 0,
  stats: {},
  loaded: false,
  lastErrorAt: 0,
  pool: 1,
};

/** @type {{w: Worker, busy: boolean, alive: boolean}[]} */
let workers = [];
const waiters = [];
let jobSeq = 0;
const jobs = new Map();          // id -> {resolve, reject, worker}
const events = [];               // drained by poll()
const listeners = new Set();     // lab page subscriptions
let cfg = {
  modelId: null,           // null -> recommend
  profile: 'auto',
  maxDownloadMB: 1500,
  maxQueue: 40,
  batchTarget: null,       // null -> 6 on CPU, 12 on GPU
  batchLowWater: 3,
  generationTimeoutMs: 150000,
  modelsBase: null,        // './models/' when the weights are self-hosted
  pool: 'auto',            // 'auto' | 1..3 CPU workers (ignored by WebGPU)
  debug: false,
};

function log(...a) { if (cfg.debug) console.log('[ModSimAI]', ...a); }
function warn(...a) { console.warn('[ModSimAI]', ...a); }

function emit(type, payload = {}) {
  const ev = { type, at: Date.now(), ...payload };
  events.push(ev);
  while (events.length > EVENT_CAP) events.shift();
  for (const fn of listeners) {
    try { fn(ev); } catch (e) { /* a listener must never break the game */ }
  }
}

function setPhase(phase, extra = {}) {
  if (state.phase !== phase) emit('phase', { phase, ...extra });
  state.phase = phase;
  Object.assign(state, extra);
}

function stringify(v) {
  try { return JSON.stringify(v); } catch (e) { return '{}'; }
}

function workerUrl() {
  return new URL('./ai_worker.js', import.meta.url).href;
}

/** cfg as the worker should see it: relative paths resolved against the page,
 *  because the worker lives in ai/ and would resolve them against ai/ too. */
function runtimeCfg() {
  const base = (typeof document !== 'undefined' && document.baseURI) || location.href;
  const out = { ...cfg };
  if (out.modelsBase) {
    try { out.modelsBase = new URL(out.modelsBase, base).href; } catch (e) { /* keep as typed */ }
  }
  return out;
}

function poolSize() {
  if (state.runtime === 'webllm') return 1;      // one GPU, one queue, no point
  if (typeof cfg.pool === 'number') return Math.max(1, Math.min(3, cfg.pool));
  const caps = state.capabilities || {};
  const mem = caps.deviceMemoryGB || (caps.isMobile ? 4 : 8);
  const cores = caps.cores || 4;
  const entry = modelById(state.modelId);
  // Each extra worker holds its own copy of the weights, so only double up when
  // the model is small and the machine has cores to spare.
  if (entry && entry.downloadMB > 160) return 1;
  if (cores < 8 || mem < 6) return 1;
  // Without SharedArrayBuffer (GitHub Pages sends no COOP/COEP) wllama is stuck
  // on one core per worker - measured at ~5 tok/s where the threaded build
  // reaches ~25. Several single-threaded workers are the only way to use the
  // other cores, so run more of them when the model is small enough to copy.
  const threaded = typeof SharedArrayBuffer === 'function';
  if (!threaded) return mem >= 8 ? 3 : 2;
  return 2;
}

function spawnWorker() {
  if (typeof Worker !== 'function') { setPhase('unsupported', { error: 'no Worker support' }); return null; }
  const handle = { w: null, busy: false, alive: false };
  try {
    handle.w = new Worker(workerUrl(), { type: 'module', name: 'modsim-ai' });
  } catch (e) {
    warn('worker failed to start', e);
    setPhase('unsupported', { error: 'worker: ' + (e && e.message) });
    return null;
  }
  handle.alive = true;
  handle.w.onmessage = (ev) => {
    const msg = ev.data || {};
    if (msg.type === 'hello') { emit('worker', { ready: true }); return; }
    if (msg.type === 'progress') {
      state.progress = typeof msg.payload.progress === 'number' ? msg.payload.progress : state.progress;
      state.progressText = msg.payload.message || state.progressText;
      emit('progress', msg.payload);
      return;
    }
    const job = jobs.get(msg.id);
    if (job) {
      jobs.delete(msg.id);
      if (job.worker) { job.worker.busy = false; drainWaiters(); }
    }
    if (msg.type === 'result') {
      emit(msg.payload && msg.payload.messages ? 'batch' : 'job', { id: msg.id, ...msg.payload });
      if (job) job.resolve(msg.payload);
    } else if (msg.type === 'error') {
      state.error = msg.payload.message || (msg.payload.problems || []).join('; ') || 'ai error';
      state.lastErrorAt = Date.now();
      emit('error', { id: msg.id, ...msg.payload });
      if (job) job.reject(new Error(state.error));
    }
  };
  handle.w.onerror = (e) => {
    // Never let a worker crash escape as an uncaught console error: the game
    // simply keeps playing with the authored dataset.
    state.error = 'worker: ' + (e && e.message ? e.message : 'error');
    state.lastErrorAt = Date.now();
    handle.alive = false;
    for (const [, job] of jobs) {
      if (job.worker === handle) {
        try { job.reject(new Error(state.error)); } catch (err) { /* ignore */ }
        jobs.delete(job.id);
      }
    }
    try { handle.w.terminate(); } catch (err) { /* ignore */ }
    handle.w = null;
    emit('error', { code: 'worker', message: state.error });
  };
  workers.push(handle);
  return handle;
}

function ensureWorkers(n = 1) {
  while (workers.filter((h) => h.alive).length < n) {
    if (!spawnWorker()) break;
  }
  return workers.filter((h) => h.alive);
}

function drainWaiters() {
  while (waiters.length) {
    const free = workers.find((h) => h.alive && !h.busy);
    if (!free) return;
    const waiter = waiters.shift();
    free.busy = true;
    waiter(free);
  }
}

function acquire() {
  const free = workers.find((h) => h.alive && !h.busy);
  if (free) { free.busy = true; return Promise.resolve(free); }
  return new Promise((resolve) => {
    waiters.push(resolve);
    if (!workers.some((h) => h.alive)) spawnWorker();
  });
}

function release(handle) {
  if (!handle) return;
  handle.busy = false;
  drainWaiters();
}

function call(type, payload = {}, timeoutMs = 0, handle = null) {
  return acquire().then((h) => {
    const id = ++jobSeq;
    return new Promise((resolve, reject) => {
      const timer = timeoutMs > 0 ? setTimeout(() => {
        if (jobs.has(id)) {
          jobs.delete(id);
          release(h);
          reject(new Error('worker job ' + type + ' timed out'));
        }
      }, timeoutMs) : null;
      jobs.set(id, {
        id,
        worker: h,
        resolve: (v) => { if (timer) clearTimeout(timer); release(h); resolve(v); },
        reject: (e) => { if (timer) clearTimeout(timer); release(h); reject(e); },
      });
      try {
        (handle && handle.w ? handle.w : h.w).postMessage({ id, type, payload });
      } catch (e) {
        jobs.delete(id);
        release(h);
        reject(e);
      }
    });
  });
}

async function callAll(type, payload = {}, timeoutMs = 0) {
  const list = workers.filter((h) => h.alive);
  return Promise.all(list.map((h) => call(type, payload, timeoutMs, h)));
}

async function refreshCapabilities() {
  const caps = quickCapabilities();
  const webgpu = caps.hasWebGPU ? await probeWebGPU() : { ok: false, reason: 'no navigator.gpu' };
  const storage = await storageEstimate();
  const supported = webgpu.ok || (caps.hasWASM && caps.hasSIMD);
  state.capabilities = { ...caps, storage, webgpu: webgpu.reason || null, webgpuOk: webgpu.ok };
  state.webgpu = webgpu;
  const recommended = recommendModel({ ...caps, webgpu }, cfg.profile);
  const offer = MODEL_CATALOG.map((m) => ({
    id: m.id, runtime: m.runtime, family: m.family, quant: m.quant, tier: m.tier,
    downloadMB: m.downloadMB, vramMB: m.vramMB || null, note: m.note,
    usable: m.runtime === 'webllm' ? webgpu.ok : (caps.hasWASM && caps.hasSIMD),
    recommended: recommended && recommended.id === m.id,
  }));
  emit('capabilities', { capabilities: state.capabilities, recommended: recommended ? recommended.id : null, offer });
  if (!supported) setPhase('unsupported', { error: 'this browser cannot run a local model' });
  return state.capabilities;
}

function pickEntry(overrideId = null) {
  if (overrideId) { const e = modelById(overrideId); if (e) return e; }
  if (cfg.modelId) { const e = modelById(cfg.modelId); if (e) return e; }
  if (cfg.runtime) {
    const ok = MODEL_CATALOG.filter((m) => m.runtime === cfg.runtime
      && (m.runtime === 'webllm' ? !!(state.webgpu && state.webgpu.ok) : true));
    if (ok.length) return ok[0];
  }
  return recommendModel({ ...(state.capabilities || {}), webgpu: state.webgpu }, cfg.profile);
}

function enforceLimits(entry) {
  if (!entry) return { ok: false, reason: 'no model fits this device' };
  if (entry.runtime === 'webllm' && !(state.webgpu && state.webgpu.ok)) {
    return { ok: false, reason: 'model ' + entry.id + ' needs WebGPU' };
  }
  if (entry.downloadMB > cfg.maxDownloadMB) {
    return { ok: false, reason: 'model is ' + entry.downloadMB + ' MB, over the ' + cfg.maxDownloadMB + ' MB budget', tooBig: true };
  }
  return { ok: true };
}

async function doLoad(options = {}) {
  const entry = options.entry || pickEntry(options.modelId);
  // Consent is only ever given explicitly - by the in-game dialog or by the
  // tickbox on the lab page. Nothing here downloads bytes without it.
  if (options.consent) state.consent = true;
  const limits = enforceLimits(entry);
  if (!limits.ok) {
    setPhase('error', { error: limits.reason });
    emit('error', { code: limits.toBig ? 'too_big' : 'model_unusable', message: limits.reason, model: entry ? entry.id : null });
    return { ok: false, reason: limits.reason };
  }
  ensureWorkers(1);
  const probe = await call('probe', { entryId: entry.id, cfg: runtimeCfg() }, 20000).catch(() => ({ cached: false }));
  const isCached = !!probe.cached;
  if (!isCached && !state.consent) {
    setPhase('consent', { progress: 0 });
    emit('consent_required', {
      model: entry.id, family: entry.family, runtime: entry.runtime,
      downloadMB: entry.downloadMB, message:
        'AI chat wants to download ' + entry.family + ' (' + entry.downloadMB + ' MB). '
        + 'It is cached on this device afterwards and the game works offline without it.',
    });
    return { ok: false, reason: 'consent_required', downloadMB: entry.downloadMB };
  }
  setPhase(isCached ? 'loading' : 'downloading', { progress: 0, progressText: isCached ? 'from cache' : 'downloading', error: null });
  state.modelId = entry.id;
  state.runtime = entry.runtime;
  const n = poolSize();
  state.pool = n;
  ensureWorkers(n);
  const job = { entry, cfg: runtimeCfg(), consent: true };
  try {
    // Load the first worker on its own: it does the download, the others then
    // read the same bytes out of the runtime's cache instead of thrashing it.
    const first = await call('load', job, 20 * 60 * 1000, workers.filter((h) => h.alive)[0]);
    const rest = await Promise.all(workers.filter((h) => h.alive).slice(1)
      .map((h) => call('load', job, 20 * 60 * 1000, h).catch((e) => ({ error: String(e && e.message || e) }))));
    const broken = rest.filter((r) => r && r.error);
    state.loaded = true;
    state.progress = 1;
    state.progressText = 'ready';
    setPhase('ready', { error: null });
    emit('ready', {
      model: entry.id, runtime: entry.runtime, fromCache: isCached,
      info: (first && first.info) || null, pool: n - broken.length,
    });
    return { ok: true, model: entry.id, pool: n - broken.length };
  } catch (e) {
    state.loaded = false;
    setPhase('error', { error: String((e && e.message) || e) });
    emit('error', { code: 'load_failed', message: String((e && e.message) || e), model: entry.id });
    return { ok: false, reason: String((e && e.message) || e) };
  }
}

/** Split `count` into n pieces that differ a little, so two workers do not
 *  write the same chat at the same time. */
function splitRequest(request, n) {
  if (n <= 1) return [request];
  const parts = [];
  const base = request.count || cfg.batchTarget;
  const recent = request.recent || [];
  // Spread the requested category mix over the workers instead of asking each
  // of them for the whole mix (which would just duplicate work).
  const queue = [];
  if (request.mix) {
    for (const [cat, num] of Object.entries(request.mix)) {
      for (let i = 0; i < num; i++) queue.push(cat);
    }
  }
  for (let i = 0; i < n; i++) {
    const share = Math.ceil(base / n) + (i === n - 1 ? base - Math.ceil(base / n) * n : 0);
    const subMix = {};
    for (let k = i; k < queue.length; k += n) {
      subMix[queue[k]] = (subMix[queue[k]] || 0) + 1;
    }
    parts.push({
      ...request,
      count: Math.max(2, share),
      mix: request.mix ? subMix : undefined,
      // Nudge each worker to a different part of the topic list.
      rotate: i,
      recent: recent.slice(i % 2 === 0 ? 0 : Math.max(0, recent.length - 4)),
      seed: (request.seed || 0) + i,
    });
  }
  return parts.filter((p) => p.count > 0);
}

async function doGenerateBatch(request = {}) {
  if (!state.loaded) return { ok: false, reason: 'not ready' };
  if (state.pendingMessages.length >= cfg.maxQueue) return { ok: true, queued: state.pendingMessages.length, skipped: true };
  if (state.phase === 'generating') return { ok: true, queued: state.pendingMessages.length, skipped: true };
  setPhase('generating');
  const target = cfg.batchTarget || (state.runtime === 'wllama' ? 6 : 12);
  const count = Math.max(4, Math.min(LIMITS.batch_max, request.count || target));
  state.batchesRequested++;
  const n = Math.min(poolSize(), Math.max(1, Math.ceil(count / 4)));
  const parts = splitRequest({ ...request, count }, n);
  const started = Date.now();
  try {
    const results = await Promise.all(parts.map((p) => call('generate_batch', {
      ...p, timeoutMs: cfg.generationTimeoutMs,
    }, cfg.generationTimeoutMs + 15000)));
    const good = results.filter((r) => r && r.messages && r.messages.length);
    if (!good.length) {
      setPhase('ready');
      return { ok: false, reason: 'every worker returned an unusable batch' };
    }
    const merged = [];
    const seen = new Set();
    let dropped = 0, repaired = 0, tokens = 0, seconds = 0;
    for (const r of good) {
      dropped += r.dropped || 0;
      repaired += r.repaired || 0;
      tokens += (r.usage && r.usage.completionTokens) || 0;
      seconds = Math.max(seconds, (r.usage && r.usage.seconds) || 0);
      for (const m of r.messages) {
        const key = m.text.toLowerCase().replace(/[^\w]+/g, ' ').trim();
        if (seen.has(key)) continue;
        seen.add(key);
        merged.push({ ...m, source: 'ai', model: state.modelId });
      }
    }
    const fresh = merged.filter((m) => !state.pendingMessages.some((p) => p.text === m.text));
    state.pendingMessages.push(...fresh);
    while (state.pendingMessages.length > cfg.maxQueue) state.pendingMessages.shift();
    state.batchesDelivered++;
    state.lastBatchAt = Date.now();
    setPhase('ready');
    const wall = (Date.now() - started) / 1000;
    return {
      ok: true, accepted: fresh.length, dropped, repaired,
      queue: state.pendingMessages.length,
      usage: { completionTokens: tokens, seconds, tokensPerSecond: tokens / Math.max(0.001, seconds), wall },
      workers: good.length,
    };
  } catch (e) {
    setPhase('ready');
    return { ok: false, reason: String((e && e.message) || e) };
  }
}

/* ---------------------------------------------------------------- public */

const api = {
  version: BRIDGE_VERSION,
  protocol: PROTOCOL,
  models: MODEL_CATALOG.map((m) => ({ id: m.id, runtime: m.runtime, family: m.family, downloadMB: m.downloadMB, tier: m.tier })),

  /** Always true: the file loaded. Capability is a separate question. */
  available() { return true; },

  on(fn) { listeners.add(fn); return () => listeners.delete(fn); },

  /** Cheap snapshot for Godot's polling loop. */
  status() {
    return stringify({
      version: BRIDGE_VERSION,
      phase: state.phase,
      loaded: state.loaded,
      model: state.modelId,
      runtime: state.runtime,
      progress: state.progress,
      progressText: state.progressText,
      error: state.error,
      queue: state.pendingMessages.length,
      reactions: state.pendingReactions.length,
      batchesRequested: state.batchesRequested,
      batchesDelivered: state.batchesDelivered,
      lastBatchAt: state.lastBatchAt,
      pool: state.pool,
      workers: workers.filter((h) => h.alive).length,
      busy: workers.filter((h) => h.busy).length,
      stats: state.stats,
      capabilities: state.capabilities,
      consent: state.consent,
      config: {
        profile: cfg.profile, maxDownloadMB: cfg.maxDownloadMB, batchTarget: cfg.batchTarget,
        maxQueue: cfg.maxQueue, modelId: cfg.modelId, runtime: cfg.runtime, pool: cfg.pool,
      },
    });
  },

  /** Drain the event queue (Godot polls this; nothing is lost if nobody does). */
  poll() {
    const out = events.splice(0, events.length);
    return stringify(out);
  },

  capabilities() { return stringify(state.capabilities || quickCapabilities()); },

  configure(json) {
    try {
      const patch = typeof json === 'string' ? JSON.parse(json || '{}') : (json || {});
      Object.assign(cfg, patch);
      if (patch.consent === true) state.consent = true;
      emit('configure', { config: cfg });
    } catch (e) { warn('bad configure json', e); }
    return 'ok';
  },

  /** Consent + capability + download + load. Returns immediately. */
  start(json) {
    let opts = {};
    try { opts = typeof json === 'string' ? JSON.parse(json || '{}') : (json || {}); } catch (e) { opts = {}; }
    if (opts.consent) state.consent = true;
    if (opts.modelId) cfg.modelId = opts.modelId;
    if (opts.profile) cfg.profile = opts.profile;
    (async () => {
      if (!state.capabilities) await refreshCapabilities();
      await doLoad(opts);
    })();
    return 'started';
  },

  probe(json) {
    refreshCapabilities().catch((e) => warn('probe failed', e));
    return 'probing';
  },

  requestBatch(json) {
    let req = {};
    try { req = typeof json === 'string' ? JSON.parse(json || '{}') : (json || {}); } catch (e) { req = {}; }
    (async () => {
      const r = await doGenerateBatch(req);
      emit('batch_done', r);
    })();
    return 'requested';
  },

  /** Hand the game up to n validated messages and remove them from the queue. */
  takeMessages(n) {
    const count = Math.max(0, Math.min(32, n == null ? 1 : Number(n)));
    const out = state.pendingMessages.splice(0, count);
    return stringify(out);
  },

  /** Everything the model produced, without consuming it (lab page, debugging). */
  peekMessages(n) {
    return stringify(state.pendingMessages.slice(0, Math.max(0, Math.min(32, Number(n) || 8))));
  },

  requestReactions(json) {
    let req = {};
    try { req = typeof json === 'string' ? JSON.parse(json || '{}') : (json || {}); } catch (e) { req = {}; }
    call('reactions', req, (req.timeoutMs || 30000) + 8000)
      .then((res) => {
        state.pendingReactions.push(...(res.reactions || []).map((r) => ({ ...r, source: 'ai' })));
        while (state.pendingReactions.length > 8) state.pendingReactions.shift();
        emit('reactions', { count: (res.reactions || []).length });
      })
      .catch((e) => emit('error', { code: 'reactions', message: String(e && e.message || e) }));
    return 'requested';
  },

  takeReactions(n) {
    const out = state.pendingReactions.splice(0, Math.max(0, Math.min(8, Number(n) || 1)));
    return stringify(out);
  },

  cancel() {
    callAll('cancel', {}).catch(() => {});
    setPhase(state.loaded ? 'ready' : 'off');
    return 'cancelled';
  },

  unload() {
    callAll('unload', {}, 20000).catch(() => {});
    state.loaded = false;
    state.pendingMessages.length = 0;
    setPhase('off');
    for (const h of workers) { try { h.w && h.w.terminate(); } catch (e) { /* ignore */ } }
    workers = [];
    return 'unloaded';
  },

  deleteCache(json) {
    let opts = {};
    try { opts = typeof json === 'string' ? JSON.parse(json || '{}') : (json || {}); } catch (e) { opts = {}; }
    const w = ensureWorkers(1)[0];
    if (!w) return 'no worker';
    call('delete_cache', { modelId: opts.modelId || state.modelId, cfg: runtimeCfg() }, 60000, w)
      .then((r) => emit('cache_cleared', r))
      .catch((e) => emit('error', { code: 'cache', message: String(e && e.message || e) }));
    return 'clearing';
  },

  /** Fetch inference stats (async; result arrives as a 'job' event). */
  stats() {
    call('stats', {}, 15000).then((r) => { state.stats = r.stats || {}; emit('stats', r); }).catch(() => {});
    return 'requested';
  },

  /** Promise API for the lab page and for tests. */
  request: {
    async capabilities() { return refreshCapabilities(); },
    async load(opts = {}) {
      if (!state.capabilities) await refreshCapabilities();
      return doLoad(opts);
    },
    async batch(req = {}) {
      if (!state.loaded) { const r = await api.request.load({ consent: true }); if (!r.ok) throw new Error(r.reason); }
      const target = cfg.batchTarget || (state.runtime === 'wllama' ? 6 : 12);
      const count = Math.max(4, Math.min(LIMITS.batch_max, req.count || target));
      const parts = splitRequest({ ...req, count }, Math.min(poolSize(), Math.max(1, Math.ceil(count / 4))));
      const results = await Promise.all(parts.map((p) => call('generate_batch', {
        ...p, timeoutMs: cfg.generationTimeoutMs }, cfg.generationTimeoutMs + 15000)));
      const good = results.filter((r) => r && r.messages && r.messages.length);
      if (!good.length) throw new Error((results[0] && results[0].message) || 'no usable batch');
      const merged = [], seen = new Set();
      let usage = { completionTokens: 0, seconds: 0 };
      for (const r of good) {
        for (const m of r.messages) {
          const k = m.text.toLowerCase().replace(/[^\w]+/g, ' ').trim();
          if (seen.has(k)) continue;
          seen.add(k); merged.push(m);
        }
        usage.completionTokens += (r.usage && r.usage.completionTokens) || 0;
        usage.seconds = Math.max(usage.seconds, (r.usage && r.usage.seconds) || 0);
      }
      usage.tokensPerSecond = usage.completionTokens / Math.max(0.001, usage.seconds);
      return {
        messages: merged, dropped: good.reduce((a, r) => a + (r.dropped || 0), 0),
        repaired: good.reduce((a, r) => a + (r.repaired || 0), 0),
        problems: good.flatMap((r) => r.problems || []).slice(0, 6),
        usage, rawSample: good[0].rawSample,
      };
    },
    async classify(req = {}) {
      if (!state.loaded) { const r = await api.request.load({ consent: true }); if (!r.ok) throw new Error(r.reason); }
      return call('classify', req, (req.timeoutMs || 60000) + 10000);
    },
    async reactions(req = {}) {
      if (!state.loaded) { const r = await api.request.load({ consent: true }); if (!r.ok) throw new Error(r.reason); }
      return call('reactions', req, (req.timeoutMs || 30000) + 10000);
    },
    async stats() { return callAll('stats', {}, 15000).then((r) => r[0]); },
    async unload() { return callAll('unload', {}, 20000); },
  },

  /** Only used by the test harness: force a failure to exercise the fallback. */
  _fault(kind) {
    if (kind === 'corrupt') {
      state.pendingMessages.push({ username: 'x', text: 'ok', category: 'nonsense_category', source: 'ai' });
      return 'injected';
    }
    if (kind === 'worker') {
      const h = workers[0];
      if (h && h.w) h.w.postMessage({ id: -999, type: 'nonsense' });
      return 'injected';
    }
    return 'ignored';
  },
};

// Never let the bridge's own start-up throw: the game must still boot Classic.
try {
  if (typeof window !== 'undefined') {
    // Test hook: tools/e2e installs window.ModSimAIMock before this module
    // loads (Playwright addInitScript) so the Godot integration can be driven
    // with canned messages instead of a 100 MB download. Opt-in by URL, so a
    // real player can never land on it by accident.
    const mocked = /[?&]aimock=1/.test(location.search)
      && typeof window.ModSimAIMock === 'object' && window.ModSimAIMock;
    if (window.ModSimAI && window.ModSimAI.version === BRIDGE_VERSION) {
      log('bridge already registered');
    } else {
      window.ModSimAI = mocked ? window.ModSimAIMock : api;
      if (mocked) log('using ModSimAIMock (aimock=1)');
      else setTimeout(() => { refreshCapabilities().catch(() => {}); }, 200);
    }
  }
} catch (e) {
  warn('bridge could not register', e);
}

if (typeof self !== 'undefined' && typeof window === 'undefined') {
  self.ModSimAI = api;
}

export { cfg as _config, state as _state };
