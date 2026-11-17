// The dev site's web player against the x-gs01 dev servers: open the play centre's server tab, join a dev server, record
// what the page and the game client did, and take screenshots to look at. Prints JSON; exit 0 only when a game socket to a
// dev server opened and stayed up.
//   node web_check.mjs [out.png] [--app 101] [--join <server id>] [--site https://tmcdev.net] [--session token-file] [--stay SEC]
//   [--node-ip IP] [--host NAME] [--port N]   the server's row (default 10.50.0.3, tmcdev.net, any 61xx game port)
// --stay keeps the player in the game SEC seconds after it is in (bots kill it, the server files its stats).
const pw = (await import(process.env.PWCORE ?? '/home/christian/.cache/pwcore/node_modules/playwright-core/index.js')).default;
const { chromium } = pw;

const args = process.argv.slice(2);
const opt = (k, d) => (args.includes(k) ? args[args.indexOf(k) + 1] : d);
const out = args.find(a => a.endsWith('.png')) ?? '/tmp/web-check.png';
const SITE = opt('--site', 'https://tmcdev.net'), APP = opt('--app', '101'), JOIN = opt('--join', '652113');
// The game server's address comes from --node-ip / --host / --port (a dev server's ip4 / hostName / port in its Server row); defaults are the
// plan's node IP and the dev proxy. Without --port, any socket on a 61xx game port (devenv.py: 6100 + 2*i) counts as a game socket.
const NODE = opt('--node-ip', '10.50.0.3'), HOST = opt('--host', 'tmcdev.net'), GPORT = opt('--port', '');
const isGameSocket = u => (GPORT ? u.includes(`:${GPORT}`) : /:61\d\d(\/|\?|$)/.test(u)) && (u.includes(NODE) || u.includes(HOST));

const launchArgs = { headless: true, handleSIGTERM: false, executablePath: process.env.CHROME ?? '/usr/bin/chromium', args: ['--disable-features=LocalNetworkAccessChecks,PrivateNetworkAccessChecks', '--use-gl=swiftshader', '--enable-unsafe-swiftshader'] };
// The dev site's certificate is from the TMC Local Development CA, which this headless browser does not carry.
// --persist DIR keeps the browser profile (IndexedDB, HTTP cache) between runs, so a second run is a warm-cache join.
const PERSIST = opt('--persist', '');
// --fast4g throttles to Chrome's Fast 4G profile (9 Mbit/s down, 170 ms RTT).
const FAST4G = args.includes('--fast4g');
let browser, ctx;
if (PERSIST) {
  ctx = await chromium.launchPersistentContext(PERSIST, { ...launchArgs, viewport: { width: 1280, height: 720 }, ignoreHTTPSErrors: true });
  browser = { close: () => ctx.close() };
} else {
  browser = await chromium.launch(launchArgs);
  ctx = await browser.newContext({ viewport: { width: 1280, height: 720 }, ignoreHTTPSErrors: true });
}
// --game-query k=v: adds a query to the game shell's page URL before it runs (e.g. log=debug), without touching the framing site.
const gq = opt('--game-query', '');
if (gq) await ctx.addInitScript(q => { if (/(^|\.)(dotgames\.org|gamespice\.net)$/.test(location.hostname)) { const u = new URLSearchParams(location.search); const [k, v] = q.split('='); u.set(k, v); history.replaceState(null, '', location.pathname + '?' + u); } }, gq);
// --session FILE: a site session token (dev's database sessions need no signing), to join signed in instead of as a guest.
const SESSION = opt('--session', null);
if (SESSION) {
  const { readFileSync } = await import('node:fs');
  await ctx.addCookies([{ name: '__Secure-authjs.session-token', value: readFileSync(SESSION, 'utf8').trim(), domain: new URL(SITE).hostname, path: '/', httpOnly: true, secure: true, sameSite: 'Lax' }]);
}
if (process.env.WC_INIT) await ctx.addInitScript({ path: process.env.WC_INIT });
try {
  const page = await ctx.newPage();
  if (FAST4G) {
    const cdp = await ctx.newCDPSession(page);
    await cdp.send('Network.emulateNetworkConditions', { offline: false, latency: 170, downloadThroughput: 9 * 1024 * 1024 / 8 * 0.9, uploadThroughput: 1.5 * 1024 * 1024 / 8 * 0.9 });
  }
  let listed = null;
  const log = [], failures = [], sockets = [], frames = new Set();
  page.on('console', m => { if (!/%c|Fast Refresh/.test(m.text())) log.push(`[${Math.round(process.uptime())}s] ${m.type()}: ${m.text()}`.slice(0, 300)); });
  page.on('pageerror', e => failures.push(`pageerror: ${e.message}`.slice(0, 300)));
  page.on('requestfailed', r => failures.push(`requestfailed: ${r.url()} ${r.failure()?.errorText}`.slice(0, 300)));
  page.on('response', r => { if (r.status() >= 400) log.push(`http ${r.status()}: ${r.request().method()} ${r.url().slice(0, 220)}`); });
  if (process.env.WC_REQS) page.on('response', r => { const u = r.url(); if (/\/api\/|play|redeem|ticket|auth/.test(u) && !/_next|\.(js|css|png|wasm|pck)/.test(u)) log.push(`req: ${r.request().method()} ${r.status()} ${u.slice(0, 160)} cors=${r.headers()['access-control-allow-origin'] ?? '-'} cred=${r.headers()['access-control-allow-credentials'] ?? '-'}`); });
  page.on('frameattached', f => frames.add(f));
  const watch = p => p.on('websocket', ws => {
    const s = { url: ws.url(), error: null, closed: false, frames: 0 };
    sockets.push(s);
    ws.on('socketerror', e => { s.error = String(e); });
    ws.on('close', () => { s.closed = true; });
    ws.on('framereceived', () => { s.frames++; });
  });
  watch(page);
  // The game may open in a new tab; its sockets and console are recorded the same way.
  let game = null;
  ctx.on('page', p => { game = p; watch(p); p.on('console', m => log.push(`popup ${m.type()}: ${m.text()}`.slice(0, 300))); });

  await page.goto(`${SITE}/play?tab=servers&app=${APP}`, { waitUntil: 'networkidle', timeout: 90000 }).catch(e => failures.push(`goto: ${e.message}`));
  await page.waitForTimeout(4000);
  process.on('SIGTERM', () => report(1));
  const listShot = out.replace(/\.png$/, '.servers.png');
  await page.screenshot({ path: listShot });
  listed = await page.evaluate(([n, h]) => {
    const t = document.body.innerText;
    return { devServerShown: /TMC Dev/i.test(t), mentionsNode: t.includes(n) || t.includes(h) };
  }, [NODE, HOST]);

  await page.goto(`${SITE}/play?tab=servers&app=${APP}&join=${JOIN}`, { waitUntil: 'load', timeout: 90000 }).catch(e => failures.push(`goto join: ${e.message}`));
  // An unenrolled server makes the site warn about sign-in first.
  // Sign-in warning for an unenrolled server ("play anyway"), then the app's own Play/Launch/Join button (app 69 needs it).
  for (const name of [/play anyway/i, /^(play|launch|join)\b/i, /^play\b/i]) {
    const dlg = page.getByRole('dialog');
    const b = (await dlg.count().catch(() => 0)) ? dlg.getByRole('button', { name }).first() : page.getByRole('button', { name }).first();
    if (await b.isVisible({ timeout: 15000 }).catch(() => false)) { await b.click({ timeout: 10000 }).catch(e => failures.push(`click ${name}: ${e.message}`.slice(0, 160))); await page.waitForTimeout(3000); }
  }
  const deadline = Date.now() + 120000;
  while (Date.now() < deadline && !sockets.some(s => isGameSocket(s.url) && s.frames > 0)) await page.waitForTimeout(1000);
  // Then the game's download and load: wait for the shell's own word that it is in, or 120 s.
  function inGame() { return log.some(l => /join timings|entered the game|game ready/i.test(l)); }
  const until = Date.now() + 240000;
  while (Date.now() < until && !inGame()) await page.waitForTimeout(1000);
  await page.waitForTimeout(8000);
  // --press N[,M]: click the game (focus, pointer lock) and press each key once, e.g. the fire-mode key.
  const keys = opt('--press', '');
  if (keys) {
    const target = game ?? page;
    const vp = target.viewportSize() ?? { width: 1280, height: 720 };
    await target.mouse.click(vp.width / 2, vp.height / 2).catch(() => {});
    for (const k of keys.split(',')) { await target.keyboard.press(k).catch(e => failures.push(`press ${k}: ${e.message}`.slice(0, 160))); await target.waitForTimeout(500); }
    log.push(`pressed ${keys}`);
  }
  // --frames N: during --stay, fire (hold the left button) and save a frame every 8 s as <out>-fN.png.
  const nframes = Number(opt('--frames', '0'));
  for (let i = 0; i < nframes; i++) {
    const t = game ?? page;
    await t.mouse.down().catch(() => {});
    await t.waitForTimeout(1500);
    await t.screenshot({ path: out.replace(/\.png$/, `-f${i}.png`) }).catch(() => {});
    await t.mouse.up().catch(() => {});
    await t.waitForTimeout(6500);
  }
  await page.waitForTimeout(1000 * Number(opt('--stay', '0')));
  await report(0);

  // Also on SIGTERM, so a run stopped by `timeout` still says how far it got.
  async function report(stopped) {
    await (game ?? page).screenshot({ path: out }).catch(() => {});
    const gameSockets = sockets.filter(s => isGameSocket(s.url));
    const ok = !stopped && gameSockets.some(s => s.frames > 0 && !s.error) && inGame();
    console.log(JSON.stringify({ ok, stopped: !!stopped, listed, screenshots: [listShot, out], gameUrl: game?.url() ?? null, gameSockets, otherSockets: sockets.filter(s => !gameSockets.includes(s)),
      frames: [...frames].map(f => f.url()).filter(u => u && u !== 'about:blank').slice(0, 10), failures: failures.slice(0, 30),
      console: [...log.filter(l => /fire mode|pressed |http \d{3}/.test(l) || (process.env.WC_GREP && new RegExp(process.env.WC_GREP).test(l))), ...log.slice(-60)] }, null, 1));
    await browser.close().catch(() => {});
    process.exit(ok ? 0 : 1);
  }
} finally {
  await browser.close().catch(() => {});
}
