/**
 * The AI worker. All inference happens here, never on Godot's render thread.
 *
 * Jobs are serialised: one generation at a time, because two overlapping
 * completions on a phone is a guaranteed stutter. The main thread never waits
 * on us - it asks, and reads the answer out of the event queue when it is done.
 */

import { createRuntime, modelById, quickCapabilities, probeWebGPU } from './model_manager.js';
import { buildBatchPrompt, buildReactionPrompt, parseBatch, defaultMix, FLAVOURS } from './chat_generator.js';
import { buildClassifyPrompt, parseClassification } from './moderation_classifier.js';
import { validateReactions, extractJson } from './schema_validator.js';

let runtime = null;         // active runtime adapter
let runtimeEntry = null;    // catalogue entry it was built from
let lastError = null;
let pending = null;         // {interrupt} for the job in flight

const stats = {
  batches: 0,
  batchesFailed: 0,
  messagesAccepted: 0,
  messagesDropped: 0,
  messagesRepaired: 0,
  classifications: 0,
  tokensLast: 0,
  tokensPerSecond: 0,
  secondsLastBatch: 0,
  lastError: null,
  loadedAt: 0,
};

const queue = [];
let running = false;

function send(msg) {
  self.postMessage(msg);
}

function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

async function withTimeout(promise, ms, onTimeout) {
  let timer = null;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(() => {
          try { if (onTimeout) onTimeout(); } catch (e) { /* ignore */ }
          reject(new Error('timeout after ' + ms + 'ms'));
        }, ms);
      }),
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

async function handle(job) {
  const { id, type } = job;
  const payload = job.payload || {};

  switch (type) {
    case 'probe': {
      const caps = quickCapabilities();
      const webgpu = caps.hasWebGPU ? await probeWebGPU() : { ok: false, reason: 'no navigator.gpu' };
      let cached = null;
      if (payload.entryId) {
        const entry = modelById(payload.entryId);
        if (entry && (!payload.runtime || entry.runtime === payload.runtime)) {
          const rt = await createRuntime(entry, payload.cfg).catch(() => null);
          cached = rt ? await rt.cached() : false;
          if (rt) await rt.unload().catch(() => {});
        }
      }
      send({ id, type: 'result', payload: { capabilities: { ...caps, webgpu }, cached } });
      return;
    }

    case 'load': {
      const entry = payload.entry || modelById(payload.modelId);
      if (!entry) throw new Error('unknown model ' + payload.modelId);
      if (runtime && runtimeEntry && runtimeEntry.id === entry.id) {
        send({ id, type: 'result', payload: { already: true, model: entry.id } });
        return;
      }
      if (runtime) { await runtime.unload().catch(() => {}); runtime = null; runtimeEntry = null; }
      const rt = await createRuntime(entry, payload.cfg);
      const onProgress = (p) => send({ id, type: 'progress', payload: { ...p, model: entry.id } });
      const info = await rt.load(onProgress);
      runtime = rt;
      runtimeEntry = entry;
      stats.loadedAt = Date.now();
      lastError = null;
      send({ id, type: 'result', payload: { model: entry.id, runtime: rt.id, info } });
      return;
    }

    case 'generate_batch': {
      if (!runtime) throw new Error('no model loaded');
      const count = Math.max(1, Math.min(24, payload.count || 10));
      const mix = payload.mix && Object.keys(payload.mix).length ? payload.mix : defaultMix(count, payload.pressure || 0.3);
      const flavour = FLAVOURS[(payload.rotate || 0) % FLAVOURS.length];
      const prompts = buildBatchPrompt({
        count,
        mix,
        flavour,
        recent: payload.recent || [],
        cast: payload.cast || [],
        banned: payload.banned || [],
        stream: payload.stream || {},
        tier: payload.tier || 1,
      });
      const timeoutMs = payload.timeoutMs || 60000;
      const t0 = performance.now();
      const out = await withTimeout(
        runtime.chat([
          { role: 'system', content: prompts.system },
          { role: 'user', content: prompts.user },
        ], {
          // ~70 tokens per labelled message, plus slack for JSON punctuation.
          maxTokens: payload.maxTokens || Math.min(1400, 90 + count * 75),
          temperature: payload.temperature,
          jsonSchema: prompts.schema,
          schemaName: 'chat_batch',
        }),
        timeoutMs,
        () => { if (runtime) runtime.interrupt(); },
      );
      const parsed = parseBatch(out.text, {
        expect: count,
        banned: payload.banned || [],
        minKeep: payload.minKeep || Math.max(2, Math.ceil(count * 0.4)),
        tier: payload.tier || 1,
      });
      stats.secondsLastBatch = (performance.now() - t0) / 1000;
      stats.tokensLast = (out.usage && out.usage.completionTokens) || 0;
      stats.tokensPerSecond = (out.usage && out.usage.tokensPerSecond) || 0;
      if (!parsed.ok) {
        stats.batchesFailed++;
        stats.messagesDropped += parsed.dropped;
        lastError = 'batch rejected: ' + parsed.problems.slice(0, 3).join('; ');
        send({ id, type: 'error', payload: { code: 'invalid_batch', problems: parsed.problems.slice(0, 8), raw: String(out.text || '').slice(0, 400) } });
        return;
      }
      stats.batches++;
      stats.messagesAccepted += parsed.messages.length;
      stats.messagesDropped += parsed.dropped;
      stats.messagesRepaired += parsed.repaired;
      send({
        id, type: 'result',
        payload: {
          messages: parsed.messages,
          dropped: parsed.dropped,
          repaired: parsed.repaired,
          problems: parsed.problems.slice(0, 6),
          usage: out.usage,
          seconds: stats.secondsLastBatch,
          rawSample: String(out.text || '').slice(0, 240),
        },
      });
      return;
    }

    case 'classify': {
      if (!runtime) throw new Error('no model loaded');
      const prompts = buildClassifyPrompt(payload);
      const out = await withTimeout(
        runtime.chat([
          { role: 'system', content: prompts.system },
          { role: 'user', content: prompts.user },
        ], { maxTokens: 260, temperature: 0.1, jsonSchema: prompts.schema, schemaName: 'judgement' }),
        payload.timeoutMs || 45000,
        () => { if (runtime) runtime.interrupt(); },
      );
      const parsed = parseClassification(out.text);
      if (!parsed.ok) {
        lastError = 'classification rejected: ' + parsed.problems.join('; ');
        send({ id, type: 'error', payload: { code: 'invalid_classification', problems: parsed.problems, raw: String(out.text || '').slice(0, 400) } });
        return;
      }
      stats.classifications++;
      send({ id, type: 'result', payload: { classification: parsed.classification, usage: out.usage, seconds: out.usage && out.usage.seconds } });
      return;
    }

    case 'reactions': {
      if (!runtime) throw new Error('no model loaded');
      const prompts = buildReactionPrompt(payload);
      const out = await withTimeout(
        runtime.chat([
          { role: 'system', content: prompts.system },
          { role: 'user', content: prompts.user },
        ], { maxTokens: 320, temperature: 0.95, jsonSchema: prompts.schema, schemaName: 'lines' }),
        payload.timeoutMs || 30000,
        () => { if (runtime) runtime.interrupt(); },
      );
      const data = extractJson(out.text) || [];
      const parsed = validateReactions(Array.isArray(data) ? data : [data]);
      if (!parsed.ok) {
        send({ id, type: 'error', payload: { code: 'invalid_reactions', problems: parsed.problems, raw: String(out.text || '').slice(0, 300) } });
        return;
      }
      send({ id, type: 'result', payload: { reactions: parsed.reactions, usage: out.usage } });
      return;
    }

    case 'cancel': {
      if (runtime && runtime.interrupt) await runtime.interrupt();
      send({ id, type: 'result', payload: { cancelled: true } });
      return;
    }

    case 'unload': {
      if (runtime) { await runtime.unload().catch(() => {}); runtime = null; runtimeEntry = null; }
      send({ id, type: 'result', payload: { unloaded: true } });
      return;
    }

    case 'delete_cache': {
      const entry = payload.entry || modelById(payload.modelId) || runtimeEntry;
      if (!entry) throw new Error('nothing to delete');
      const rt = runtime && runtimeEntry && runtimeEntry.id === entry.id
        ? runtime
        : await createRuntime(entry, payload.cfg);
      const ok = await rt.deleteCache();
      if (rt !== runtime) await rt.unload().catch(() => {});
      send({ id, type: 'result', payload: { deleted: ok, model: entry.id } });
      return;
    }

    case 'stats': {
      send({
        id, type: 'result',
        payload: {
          stats,
          loaded: !!runtime,
          model: runtimeEntry ? runtimeEntry.id : null,
          runtime: runtime ? runtime.id : null,
          runtimeStats: runtime && runtime.stats ? runtime.stats() : null,
        },
      });
      return;
    }

    default:
      throw new Error('unknown job type ' + type);
  }
}

async function pump() {
  if (running) return;
  running = true;
  while (queue.length) {
    const job = queue.shift();
    try {
      await handle(job);
    } catch (e) {
      lastError = String((e && e.message) || e);
      stats.lastError = lastError;
      send({ id: job.id, type: 'error', payload: { code: 'runtime', message: lastError } });
      // A timeout or an abort is normal on a slow phone: keep the weights and
      // try again next batch. Only a genuinely broken engine gets dropped.
      if (runtime && /out of memory|OOM|model failed to start|unreachable|corrupt| Aborted\(/i.test(lastError)) {
        await runtime.unload().catch(() => {});
        runtime = null;
        runtimeEntry = null;
      }
    }
    // Yield so the browser can breathe between two generations.
    await sleep(0);
  }
  running = false;
}

self.onmessage = (ev) => {
  const job = ev.data;
  if (!job || !job.type) return;
  // Cancels jump the queue.
  if (job.type === 'cancel') {
    queue.length = 0;
    if (runtime && runtime.interrupt) runtime.interrupt();
    running = false;
  }
  queue.push(job);
  pump();
};

self.postMessage({ type: 'hello', worker: 'modsim-ai', loaded: false });
