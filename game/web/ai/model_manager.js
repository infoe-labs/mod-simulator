/**
 * Runtime selection, model catalogue, download/loading and inference stats.
 *
 * Two real runtimes, chosen by what the device can actually do:
 *
 *   webllm  - @mlc-ai/web-llm on WebGPU. Best quality per second on a phone or
 *             laptop with a real GPU. Needs navigator.gpu.
 *   wllama  - @wllama/wllama (llama.cpp compiled to WASM). Pure CPU + SIMD,
 *             works everywhere, including browsers with no WebGPU. Slower, so
 *             it gets the smaller models and a conservative token budget.
 *
 * Neither runtime is fetched from a CDN: the JavaScript and the .wasm files are
 * vendored next to this file by tools/ai/vendor.sh. Model *weights* come from
 * Hugging Face on first use, behind an explicit consent, and are cached by the
 * runtime afterwards - or served from our own origin when the build was made
 * with tools/ai/fetch_models.sh (see README, "Hosting the weights yourself").
 */

export const VENDOR = {
  webllm: './vendor/webllm/web-llm.mjs',
  wllama: './vendor/wllama/wllama.mjs',
  wllamaWasm: './vendor/wllama/wllama.wasm',
  webllmLibs: './vendor/webllm/libs/',
};

/**
 * Everything we know how to run. `downloadMB` is the measured weights size,
 * shown verbatim in the consent dialog - we do not guess it.
 */
export const MODEL_CATALOG = [
  {
    id: 'qwen3-0.6b-webgpu',
    runtime: 'webllm',
    modelId: 'Qwen3-0.6B-q4f16_1-MLC',
    family: 'Qwen3 0.6B',
    quant: 'q4f16_1',
    lib: 'Qwen3-0.6B-q4f16_1_cs1k-webgpu.wasm',
    downloadMB: 352,
    vramMB: 1403,
    tier: 'standard',
    maxTokens: 900,
    context: 4096,
    note: 'the default on any device with WebGPU',
  },
  {
    id: 'qwen25-0.5b-webgpu',
    runtime: 'webllm',
    modelId: 'Qwen2.5-0.5B-Instruct-q4f16_1-MLC',
    family: 'Qwen2.5 0.5B Instruct',
    quant: 'q4f16_1',
    lib: 'Qwen2-0.5B-Instruct-q4f16_1_cs1k-webgpu.wasm',
    downloadMB: 290,
    vramMB: 945,
    tier: 'light',
    maxTokens: 700,
    context: 4096,
    note: 'small download, low VRAM, first pick on low-end GPUs',
  },
  {
    id: 'llama32-1b-webgpu',
    runtime: 'webllm',
    modelId: 'Llama-3.2-1B-Instruct-q4f16_1-MLC',
    family: 'Llama 3.2 1B Instruct',
    quant: 'q4f16_1',
    lib: 'Llama-3.2-1B-Instruct-q4f16_1_cs1k-webgpu.wasm',
    downloadMB: 705,
    vramMB: 879,
    tier: 'quality',
    maxTokens: 1000,
    context: 4096,
    note: 'best labels, biggest download',
  },
  {
    id: 'qwen25-0.5b-cpu',
    runtime: 'wllama',
    repo: 'bartowski/Qwen2.5-0.5B-Instruct-GGUF',
    file: 'Qwen2.5-0.5B-Instruct-Q4_K_M.gguf',
    family: 'Qwen2.5 0.5B Instruct',
    quant: 'Q4_K_M',
    downloadMB: 398,
    tier: 'standard',
    maxTokens: 700,
    context: 3072,
    note: 'CPU fallback when there is no WebGPU',
  },
  {
    id: 'smollm2-135m-cpu',
    runtime: 'wllama',
    repo: 'mradermacher/SmolLM2-135M-Instruct-GGUF',
    file: 'SmolLM2-135M-Instruct.Q4_K_M.gguf',
    family: 'SmolLM2 135M Instruct',
    quant: 'Q4_K_M',
    downloadMB: 106,
    tier: 'light',
    maxTokens: 550,
    context: 3072,
    note: 'smallest download; weak labels, better than nothing',
  },
];

export function modelById(id) {
  return MODEL_CATALOG.find((m) => m.id === id) || null;
}

export function modelsForRuntime(runtime) {
  return MODEL_CATALOG.filter((m) => m.runtime === runtime);
}

function isMobileUA(ua) {
  return /Android|iPhone|iPad|iPod|Mobile|Silk/i.test(ua || '');
}

function isIOS(ua, platform) {
  return /iPhone|iPad|iPod/i.test(ua || '') || (platform === 'MacIntel' && navigator.maxTouchPoints > 1);
}

/** A minimal module that only validates if v128 (SIMD) exists: () -> v128 with
 *  a v128.const. `WebAssembly.validate` is the only portable SIMD probe that
 *  behaves the same on Chrome, Safari and Firefox. */
const SIMD_PROBE_B64 = 'AGFzbQEAAAABBQFgAAF7AwIBAAcFAQFmAAAKFgEUAP0MAAAAAAAAAAAAAAAAAAAAAAs=';
const EMPTY_MODULE_B64 = 'AGFzbQEAAAA=';

function b64bytes(s) {
  return Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
}

/** Cheap, synchronous, main-thread checks. Nothing here touches the network. */
export function quickCapabilities() {
  const ua = typeof navigator !== 'undefined' ? navigator.userAgent : '';
  let wasm = false, simd = false, threads = false;
  try {
    if (typeof WebAssembly === 'object' && typeof WebAssembly.validate === 'function') {
      wasm = WebAssembly.validate(b64bytes(EMPTY_MODULE_B64));
      simd = wasm && WebAssembly.validate(b64bytes(SIMD_PROBE_B64));
    }
  } catch (e) { /* wasm unsupported */ }
  threads = typeof SharedArrayBuffer === 'function';
  const canvas = typeof OffscreenCanvas === 'function' ? new OffscreenCanvas(1, 1)
    : (typeof document !== 'undefined' ? document.createElement('canvas') : null);
  const gl = canvas ? canvas.getContext('webgl2') : null;
  let renderer = null;
  try {
    if (gl) {
      const dbg = gl.getExtension('WEBGL_debug_renderer_info');
      renderer = dbg ? String(gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL)) : 'webgl2';
    }
  } catch (e) { /* ignore */ }

  return {
    ua,
    platform: (navigator && navigator.platform) || '',
    isMobile: isMobileUA(ua),
    isIOS: isIOS(ua, navigator && navigator.platform),
    hasWebGPU: !!(typeof navigator !== 'undefined' && navigator.gpu),
    hasWebGL2: !!gl,
    glRenderer: renderer,
    hasWASM: wasm,
    hasSIMD: simd,
    hasThreads: threads,
    crossOriginIsolated: !!self.crossOriginIsolated,
    deviceMemoryGB: navigator && navigator.deviceMemory ? Number(navigator.deviceMemory) : null,
    cores: navigator && navigator.hardwareConcurrency ? Number(navigator.hardwareConcurrency) : null,
    worker: typeof Worker === 'function',
  };
}

/** Ask the GPU adapter directly; this is the only trustworthy WebGPU check. */
export async function probeWebGPU() {
  if (typeof navigator === 'undefined' || !navigator.gpu) return { ok: false, reason: 'no navigator.gpu' };
  try {
    const adapter = await navigator.gpu.requestAdapter({ powerPreference: 'high-performance' });
    if (!adapter) return { ok: false, reason: 'no adapter' };
    let info = {};
    try { info = adapter.requestAdapterInfo ? await adapter.requestAdapterInfo() : {}; } catch (e) { /* optional */ }
    const maxBuffer = adapter.limits ? adapter.limits.maxBufferSize : 0;
    const maxTexture = adapter.limits ? adapter.limits.maxTextureDimension2D : 0;
    // A 1GB buffer limit is roughly where small LLMs stop failing mid-prefill.
    const ok = !maxBuffer || maxBuffer >= 256 * 1024 * 1024;
    return {
      ok,
      reason: ok ? null : 'maxBufferSize too small',
      name: info.description || info.architecture || adapter.name || 'webgpu',
      vendor: info.vendor || null,
      features: adapter.features ? [...adapter.features].slice(0, 20) : [],
      maxBufferSize: maxBuffer,
      maxTextureDimension2D: maxTexture,
    };
  } catch (e) {
    return { ok: false, reason: String(e && e.message ? e.message : e) };
  }
}

export async function storageEstimate() {
  try {
    if (navigator.storage && navigator.storage.estimate) {
      const e = await navigator.storage.estimate();
      return { usage: e.usage || 0, quota: e.quota || 0 };
    }
  } catch (e) { /* not available */ }
  return { usage: null, quota: null };
}

/**
 * Which model to offer. `profile` is the player's choice ('auto', 'light',
 * 'standard', 'quality'); phones get pushed down a tier on purpose.
 */
export function recommendModel(caps, profile = 'auto') {
  const gpuUsable = caps.webgpu && caps.webgpu.ok;
  let pool = MODEL_CATALOG.filter((m) => (m.runtime === 'webllm' ? gpuUsable : caps.hasWASM && caps.hasSIMD));
  if (!pool.length) return null;
  const order = { light: 0, standard: 1, quality: 2 };
  if (profile === 'auto') {
    const small = (caps.deviceMemoryGB && caps.deviceMemoryGB <= 4) || (caps.isMobile && caps.isIOS);
    profile = small ? 'light' : (caps.isMobile ? 'standard' : 'standard');
    if (!gpuUsable && profile === 'standard' && (caps.deviceMemoryGB || 8) <= 4) profile = 'light';
  }
  const want = order[profile] != null ? order[profile] : 1;
  pool = pool.slice().sort((a, b) => Math.abs(order[a.tier] - want) - Math.abs(order[b.tier] - want));
  return pool[0] || null;
}

/**
 * A runtime is a small object so ai_worker.js does not care which engine it got:
 *   { id, model, load(onProgress), chat(messages, opts), unload(), cached(), stats() }
 */
async function createWebLLMRuntime(entry, cfg) {
  const mod = await import(new URL(VENDOR.webllm, import.meta.url).href);
  const localBase = cfg && cfg.modelsBase;   // e.g. './models/' when weights are self-hosted
  const appConfig = { model_list: mod.prebuiltAppConfig.model_list.map((r) => ({ ...r })) };
  const rec = appConfig.model_list.find((r) => r.model_id === entry.modelId);
  if (!rec) throw new Error('model ' + entry.modelId + ' is not in the vendored webllm catalogue');
  // Never call a CDN for runtime code: the model library is served from us.
  rec.model_lib = new URL(VENDOR.webllmLibs + entry.lib, import.meta.url).href;
  if (localBase) {
    // Self-hosted weights live at <modelsBase>/<catalogue id>/ (fetch_models.sh).
    rec.model = new URL(localBase.replace(/\/?$/, '/') + entry.id + '/', import.meta.url).href;
  }

  let engine = null;
  let lastUsage = { promptTokens: 0, completionTokens: 0, seconds: 0 };

  return {
    id: 'webllm',
    model: entry,
    async cached() {
      try { return !!(await mod.hasModelInCache(entry.modelId, appConfig)); } catch (e) { return false; }
    },
    async load(onProgress) {
      const t0 = performance.now();
      engine = await mod.CreateMLCEngine(entry.modelId, {
        appConfig,
        initProgressCallback: (p) => {
          onProgress({
            stage: /loading model params|fetching/i.test(p.text || '') ? 'download' : 'load',
            progress: Math.max(0, Math.min(1, p.progress || 0)),
            message: p.text || 'loading',
          });
        },
      });
      lastUsage.seconds = (performance.now() - t0) / 1000;
      onProgress({ stage: 'ready', progress: 1, message: 'ready' });
      return { seconds: lastUsage.seconds };
    },
    async chat(messages, opts = {}) {
      if (!engine) throw new Error('engine not loaded');
      const t0 = performance.now();
      const req = {
        messages,
        temperature: opts.temperature != null ? opts.temperature : 0.9,
        top_p: opts.top_p != null ? opts.top_p : 0.95,
        max_tokens: Math.min(opts.maxTokens || entry.maxTokens, entry.maxTokens),
        stream: false,
      };
      if (opts.stop) req.stop = opts.stop;
      const reply = await engine.chat.completions.create(req);
      const seconds = (performance.now() - t0) / 1000;
      const usage = reply.usage || {};
      lastUsage = {
        promptTokens: usage.prompt_tokens || 0,
        completionTokens: usage.completion_tokens || 0,
        seconds,
      };
      const text = (reply.choices && reply.choices[0] && reply.choices[0].message.content) || '';
      return { text, usage: { ...lastUsage, tokensPerSecond: lastUsage.completionTokens / Math.max(0.001, seconds) } };
    },
    async interrupt() { try { if (engine) engine.interruptGenerate(); } catch (e) { /* ignore */ } },
    async unload() {
      if (engine) { try { await engine.unload(); } catch (e) { /* ignore */ } engine = null; }
    },
    async deleteCache() {
      try { await mod.deleteModelAllInfoInCache(entry.modelId, appConfig); return true; } catch (e) { return false; }
    },
    stats() { return { runtime: 'webllm', model: entry.modelId, ...lastUsage }; },
  };
}

async function createWllamaRuntime(entry, cfg) {
  const mod = await import(new URL(VENDOR.wllama, import.meta.url).href);
  const Wllama = mod.Wllama || (mod.default && mod.default.Wllama);
  if (!Wllama) throw new Error('wllama build did not export Wllama');
  const wasmPath = new URL(VENDOR.wllamaWasm, import.meta.url).href;
  let wllama = null;
  let abort = null;
  let lastUsage = { promptTokens: 0, completionTokens: 0, seconds: 0 };
  const cores = (typeof navigator !== 'undefined' && navigator.hardwareConcurrency) || 4;
  const threads = self.crossOriginIsolated ? Math.max(1, Math.min(8, cores - 1)) : 1;

  return {
    id: 'wllama',
    model: entry,
    async cached() {
      try {
        const probe = new Wllama({ default: wasmPath }, { suppressNativeLog: true });
        const entries = (await probe.cacheManager.list()) || [];
        await probe.exit();
        return entries.some((e) => String((e.metadata && e.metadata.originalURL) || e.name || '').includes(entry.file));
      } catch (e) { return false; }
    },
    async load(onProgress) {
      const t0 = performance.now();
      wllama = new Wllama({ default: wasmPath }, {
        suppressNativeLog: true,
        allowOffline: true,       // a cached model must load with the network off
        parallelDownloads: 3,
      });
      const params = {
        n_ctx: entry.context || 3072,
        n_threads: threads,
        n_gpu_layers: 0,          // CPU: keep the whole thing on the wasm heap
        log_level: 3,             // errors only
        flash_attn: false,
        warmup: false,
        progressCallback: (p) => {
          const total = p && p.total ? p.total : 0;
          const loaded = p && p.loaded ? p.loaded : 0;
          onProgress({
            stage: 'download',
            progress: total ? Math.max(0, Math.min(1, loaded / total)) : 0,
            loadedBytes: loaded,
            totalBytes: total,
            message: 'downloading weights',
          });
        },
      };
      if (cfg && cfg.modelsBase) {
        // Self-hosted weights: <modelsBase>/<catalogue id>/<file> (tools/ai/fetch_models.sh)
        const base = new URL(cfg.modelsBase, import.meta.url).href.replace(/\/?$/, '/');
        await wllama.loadModelFromUrl(base + entry.id + '/' + entry.file, params);
      } else {
        await wllama.loadModelFromHF({ repo: entry.repo, file: entry.file }, params);
      }
      onProgress({ stage: 'load', progress: 1, message: 'weights in memory' });
      lastUsage.seconds = (performance.now() - t0) / 1000;
      onProgress({ stage: 'ready', progress: 1, message: 'ready' });
      return { seconds: lastUsage.seconds, threads };
    },
    async chat(messages, opts = {}) {
      if (!wllama || !wllama.isModelLoaded()) throw new Error('model not loaded');
      abort = new AbortController();
      const t0 = performance.now();
      const maxTokens = Math.min(opts.maxTokens || entry.maxTokens, entry.maxTokens);
      // Constrained decoding. This is the difference between a 0.5B model
      // producing parseable JSON and producing poetry: with a grammar the
      // sampler can only emit tokens that keep the output valid, and the
      // enums make an unknown category literally unrepresentable.
      const response_format = opts.jsonSchema
        ? { type: 'json_schema', json_schema: { name: opts.schemaName || 'reply', schema: opts.jsonSchema, strict: true } }
        : (opts.json === false ? { type: 'text' } : { type: 'json_object' });
      const out = await wllama.createChatCompletion({
        messages,
        max_tokens: maxTokens,
        temperature: opts.temperature != null ? opts.temperature : 0.85,
        top_p: opts.top_p != null ? opts.top_p : 0.92,
        top_k: 40,
        response_format,
        // Small models loop. Repetition penalty plus a min-p floor keeps the
        // chat from turning into "first first first first" after message 4.
        penalty_repeat: opts.repeatPenalty != null ? opts.repeatPenalty : 1.12,
        min_p: opts.minP != null ? opts.minP : 0.05,
        penalty_last_n: 64,
        abortSignal: abort.signal,
        cache_prompt: true,
      });
      const seconds = (performance.now() - t0) / 1000;
      const usage = (out && out.usage) || {};
      const text = (out && out.choices && out.choices[0] && out.choices[0].message.content) || '';
      // wllama does not always report usage. Rather than show 0 tok/s, fall
      // back to the usual ~4 chars/token estimate and say so: the UI prints a
      // "~" in front of an estimated rate.
      const reportedTokens = Number(usage.completion_tokens || usage.completionTokens || 0);
      const estimated = reportedTokens <= 0;
      const tokens = estimated ? Math.max(1, Math.round(text.length / 4)) : reportedTokens;
      const reportedTps = Number(usage.predicted_per_second || usage.tokensPerSecond || 0);
      lastUsage = {
        promptTokens: Number(usage.prompt_tokens || usage.promptTokens || 0),
        completionTokens: tokens,
        tokensEstimated: estimated,
        seconds,
      };
      const tps = reportedTps > 0 ? reportedTps : tokens / Math.max(0.001, seconds);
      return { text, usage: { ...lastUsage, tokensPerSecond: tps } };
    },
    async interrupt() { try { if (abort) abort.abort(); } catch (e) { /* ignore */ } },
    async unload() {
      if (wllama) { try { await wllama.exit(); } catch (e) { /* ignore */ } wllama = null; }
    },
    async deleteCache() {
      try {
        const probe = wllama || new Wllama({ default: wasmPath }, { suppressNativeLog: true });
        await probe.cacheManager.deleteMany((e) => String((e.metadata && e.metadata.originalURL) || e.name || '').includes(entry.file));
        if (!wllama) await probe.exit();
        return true;
      } catch (e) { return false; }
    },
    stats() { return { runtime: 'wllama', model: entry.file, threads, ...lastUsage }; },
  };
}

export async function createRuntime(entry, cfg) {
  if (!entry) throw new Error('no model selected');
  if (entry.runtime === 'webllm') return createWebLLMRuntime(entry, cfg);
  if (entry.runtime === 'wllama') return createWllamaRuntime(entry, cfg);
  throw new Error('unknown runtime ' + entry.runtime);
}
