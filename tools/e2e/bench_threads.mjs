import { chromium } from 'playwright';
const MODEL = process.argv[2] || 'smollm2-135m-cpu';
const BASE = process.argv[3] || 'http://127.0.0.1:8766/';
const ctx = await chromium.launchPersistentContext('./.profile-ai', { args: ['--no-sandbox','--use-gl=swiftshader','--enable-unsafe-swiftshader'] });
const page = ctx.pages()[0] || await ctx.newPage();
page.on('console', m => console.log('   page:', m.text().slice(0,160)));
page.on('requestfailed', r => console.log('   reqfail:', r.url().slice(0,110), r.failure()?.errorText));
await page.goto(BASE + 'ai-lab.html', { waitUntil: 'domcontentloaded' });
const out = await page.evaluate(async ({MODEL, BASE}) => {
  const step = (s) => console.log('STEP ' + s);
  step('crossOriginIsolated=' + self.crossOriginIsolated + ' cores=' + navigator.hardwareConcurrency + ' SAB=' + (typeof SharedArrayBuffer));
  const { MODEL_CATALOG, createRuntime } = await import('./ai/model_manager.js');
  const { BATCH_SCHEMA } = await import('./ai/json_schema.js');
  const { buildBatchPrompt } = await import('./ai/chat_generator.js');
  const p = buildBatchPrompt({ count: 6, stream: { title: 'cozy games', streamer: 'Nori', viewers: 50, phase: 'busy stream', pressure: 0.6 } });
  const msgs = [{ role: 'system', content: p.system }, { role: 'user', content: p.user }];
  const rt = await createRuntime(MODEL_CATALOG.find(m => m.id === MODEL), { modelsBase: new URL('./ai/models/', location.href).href });
  const lt = performance.now();
  const info = await rt.load(() => {});
  step('loaded in ' + ((performance.now()-lt)/1000).toFixed(1) + 's threads=' + (info && info.threads));
  const res = { model: MODEL, threads: info && info.threads, loadSeconds: (performance.now()-lt)/1000 };
  for (const n of [6]) {
    const t = performance.now();
    const r = await rt.chat(msgs, { maxTokens: 90 + n * 75, jsonSchema: BATCH_SCHEMA });
    res['batch' + n] = { seconds: (performance.now()-t)/1000, usage: r.usage, chars: r.text.length, sample: r.text.slice(0, 300) };
    step('batch' + n + ' ' + JSON.stringify(res['batch' + n].usage));
  }
  await rt.unload();
  return res;
}, {MODEL, BASE});
console.log(JSON.stringify(out, null, 1));
await ctx.close();
