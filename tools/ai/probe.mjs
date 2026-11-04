import { chromium } from 'playwright';
const args = ['--enable-unsafe-swiftshader','--no-sandbox'];
const variants = {
  swiftshader: [...args, '--use-gl=angle', '--use-angle=swiftshader'],
  vulkan: [...args, '--use-gl=vulkan'],
  default: args,
};
for (const [name, a] of Object.entries(variants)) {
  let b;
  try {
    b = await chromium.launch({ args: a });
    const p = await (await b.newContext()).newPage();
    const r = await p.evaluate(async () => {
      const out = { hasGpu: !!navigator.gpu };
      if (navigator.gpu) {
        try {
          const ad = await navigator.gpu.requestAdapter({ powerPreference: 'high-performance' });
          out.adapter = ad ? { name: ad.name, features: ad.features.size } : null;
          if (ad?.requestAdapterInfo) { const f = await ad.requestAdapterInfo(); out.info = { vendor: f.vendor, architecture: f.architecture, description: f.description }; }
        } catch (e) { out.err = String(e); }
      }
      return out;
    });
    console.log(name, JSON.stringify(r));
  } catch (e) { console.log(name, 'LAUNCH FAIL', e.message.slice(0,150)); }
  finally { await b?.close(); }
}
