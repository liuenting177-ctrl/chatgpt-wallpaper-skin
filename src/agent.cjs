// Long-lived skin agent for the ChatGPT desktop app.
//
// The app is an Isolated Web App: its CSP blocks cross-origin fetches, and the only
// supported way around that is Page.setBypassCSP — which is scoped to a CDP session,
// so a session has to stay open for the skin to survive navigations. That is the whole
// reason this process must keep running.
//
// The app can have several windows (main page, detached windows, avatar overlay), each
// its own CDP page target, so this agent keeps one session per page target, rescans for
// new targets every few seconds, and re-injects after every page load.
//
// Usage: node agent.cjs [--config config.json] [--reload] [--once <seconds>]
const fs = require('fs');
const path = require('path');

const argv = process.argv.slice(2);
const opt = (name, def) => {
  const i = argv.indexOf('--' + name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : def;
};

const CONFIG_PATH = opt('config', path.join(__dirname, 'config.json'));
const CONFIG = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8').replace(/^\uFEFF/, ''));
const MEDIA_PORT = Number(CONFIG.mediaPort || 8756);
const PORT = Number(CONFIG.cdpPort || 9333);
const SRC = `http://127.0.0.1:${MEDIA_PORT}/wall`;
const SCRIM = Number(CONFIG.scrim == null ? 0.22 : CONFIG.scrim);
const OBJECT_FIT = CONFIG.videoObjectFit || 'cover';
const CSS_FILE = path.isAbsolute(CONFIG.cssFile || '')
  ? CONFIG.cssFile
  : path.join(__dirname, CONFIG.cssFile || 'glass.css');
const CSS_EXTRA = CONFIG.cssExtraFile
  ? (path.isAbsolute(CONFIG.cssExtraFile) ? CONFIG.cssExtraFile : path.join(__dirname, CONFIG.cssExtraFile))
  : '';
const DO_RELOAD = argv.includes('--reload');
const ONCE = argv.includes('--once') ? Number(opt('once', '8')) : 0;
const LOG_FILE = path.join(__dirname, 'agent.log');

function log(...a) {
  const line = new Date().toISOString().slice(11, 19) + ' ' + a.join(' ');
  console.log(line);
  try {
    if (fs.existsSync(LOG_FILE) && fs.statSync(LOG_FILE).size > 2 * 1024 * 1024) fs.truncateSync(LOG_FILE, 0);
    fs.appendFileSync(LOG_FILE, line + '\n');
  } catch (e) {
    /* logging must never break the agent */
  }
}

function buildCss() {
  let css = fs.readFileSync(CSS_FILE, 'utf8');
  css = css.replace(/__OBJECT_FIT__/g, OBJECT_FIT);
  if (CSS_EXTRA) {
    try {
      css += '\n/* ---- user overrides ---- */\n' + fs.readFileSync(CSS_EXTRA, 'utf8');
    } catch (e) {
      log('cssExtraFile unreadable: ' + CSS_EXTRA);
    }
  }
  return css;
}

function buildPayload() {
  const css = buildCss();
  return `(() => {
  if (!document.documentElement || !document.body) return 'not-ready';
  const SRC = ${JSON.stringify(SRC)};
  const CSS = ${JSON.stringify(css)};
  document.documentElement.setAttribute('data-wesk', '1');
  document.documentElement.style.setProperty('--wesk-scrim', String(${JSON.stringify(SCRIM)}));
  let style = document.getElementById('wesk-style');
  if (!style) { style = document.createElement('style'); style.id = 'wesk-style'; document.head.appendChild(style); }
  if (style.textContent !== CSS) style.textContent = CSS;
  let bg = document.getElementById('wesk-bg');
  if (!bg) {
    bg = document.createElement('div');
    bg.id = 'wesk-bg';
    bg.innerHTML = '<video id="wesk-video" autoplay muted loop playsinline preload="auto"></video>';
    document.body.appendChild(bg);
  }
  let veil = document.getElementById('wesk-veil');
  if (!veil) { veil = document.createElement('div'); veil.id = 'wesk-veil'; document.body.appendChild(veil); }
  const root = document.getElementById('root');
  if (root) { root.style.position = 'relative'; root.style.zIndex = '2'; }
  const v = document.getElementById('wesk-video');
  if (v.getAttribute('src') !== SRC) { v.src = SRC; v.load(); v.play().catch(() => {}); }
  if (!window.__weskWatch) {
    // Two failure modes matter, and a "how long did the loop stall" heuristic only
    // catches one of them:
    //  1) the element got paused (Chromium suspends background video)  -> just play()
    //  2) the media socket died (sleep/resume, server restart) and the element sits at
    //     readyState 4 with currentTime frozen                          -> reload the source
    window.__weskLastT = -1;
    window.__weskStuck = 0;
    window.__weskWatch = setInterval(function () {
      const el = document.getElementById('wesk-video');
      if (!el) return;
      if (document.hidden) { window.__weskLastT = -1; window.__weskStuck = 0; return; }
      if (el.paused) {
        el.play().catch(function () {});
        window.__weskLastT = -1;
        window.__weskStuck = 0;
        return;
      }
      const t = el.currentTime;
      if (window.__weskLastT >= 0 && Math.abs(t - window.__weskLastT) < 0.06) {
        window.__weskStuck++;
        if (window.__weskStuck >= 2) {            // ~8s with no progress: socket is dead
          window.__weskStuck = 0;
          try { el.load(); el.play().catch(function () {}); } catch (e) {}
        }
      } else {
        window.__weskStuck = 0;
      }
      window.__weskLastT = t;
    }, 4000);
    document.addEventListener('visibilitychange', function () {
      const el = document.getElementById('wesk-video');
      if (el && !document.hidden) { el.play().catch(function () {}); window.__weskLastT = -1; }
    });
  }
  return JSON.stringify({ rs: v.readyState, paused: v.paused, w: v.videoWidth, h: v.videoHeight, t: Math.round(v.currentTime) });
})()`;
}

async function listPages() {
  const res = await fetch(`http://127.0.0.1:${PORT}/json/list`);
  const all = await res.json();
  return all.filter((t) => t.type === 'page' && t.webSocketDebuggerUrl);
}

class Session {
  constructor(target) {
    this.target = target;
    this.label = (target.url || '').split('?')[0].slice(-32);
    this.alive = false;
  }

  async open() {
    const ws = new WebSocket(this.target.webSocketDebuggerUrl);
    this.ws = ws;
    this.pending = new Map();
    this.id = 0;
    ws.onmessage = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id && this.pending.has(m.id)) {
        const p = this.pending.get(m.id);
        this.pending.delete(m.id);
        m.error ? p.rej(new Error(JSON.stringify(m.error))) : p.res(m.result);
      } else if (m.method === 'Page.loadEventFired') {
        setTimeout(() => this.inject('load').catch(() => {}), 900);
      }
    };
    await new Promise((res, rej) => {
      ws.onopen = res;
      ws.onerror = () => rej(new Error('ws failed'));
      setTimeout(() => rej(new Error('ws timeout')), 8000);
    });
    ws.onclose = () => {
      this.alive = false;
      log(`session closed (${this.label})`);
    };
    this.send('Page.enable').catch(() => {});
    this.send('Runtime.enable').catch(() => {});
    await this.send('Page.setBypassCSP', { enabled: true });
    this.alive = true;
    log(`attached ${this.label} (csp bypass on)`);
  }

  send(method, params = {}) {
    return new Promise((res, rej) => {
      if (!this.ws || this.ws.readyState !== 1) return rej(new Error('socket not open'));
      const mid = ++this.id;
      this.pending.set(mid, { res, rej });
      this.ws.send(JSON.stringify({ id: mid, method, params }));
    });
  }

  async evaluate(expr) {
    const r = await this.send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true });
    if (r.exceptionDetails) return 'EXC ' + ((r.exceptionDetails.exception && r.exceptionDetails.exception.description) || '').slice(0, 160);
    return typeof r.result.value === 'string' ? r.result.value : JSON.stringify(r.result.value);
  }

  async inject(why) {
    const r = await this.evaluate(buildPayload());
    log(`injected [${why}] ${this.label}: ${r}`);
    if (r === 'not-ready') {
      // document is still being created (splash screens); try again shortly
      setTimeout(() => this.inject('retry').catch(() => {}), 800);
      return r;
    }
    // MEDIA_ERR_SRC_NOT_SUPPORTED (4) means this document was loaded before the CSP
    // bypass existed, so the media request was blocked. The bypass only applies to
    // documents loaded afterwards => reload once and re-inject. The media error shows
    // up a moment after src is set, so check later.
    setTimeout(async () => {
      try {
        const err = await this.evaluate(
          "(function(){const v=document.getElementById('wesk-video');return String(v && v.error ? v.error.code : 0)})()"
        );
        if (err === '4' && (this.reloads || 0) < 2) {
          this.reloads = (this.reloads || 0) + 1;
          log(`csp reload #${this.reloads} ${this.label}`);
          await this.send('Page.reload', { ignoreCache: true });
        }
      } catch (e) {
        /* session may be gone; supervisor handles it */
      }
    }, 4000);
    return r;
  }

  close() {
    try { this.ws && this.ws.close(); } catch (e) { /* ignore */ }
    this.alive = false;
  }
}

const sessions = new Map(); // targetId -> Session

async function ensureSessions() {
  let pages;
  try {
    pages = await listPages();
  } catch (e) {
    return; // app not up yet
  }
  const ids = new Set(pages.map((p) => p.id));
  for (const [id, s] of sessions) {
    if (!ids.has(id) || !s.alive) {
      s.close();
      sessions.delete(id);
    }
  }
  for (const page of pages) {
    if (sessions.has(page.id)) continue;
    const s = new Session(page);
    sessions.set(page.id, s);
    try {
      await s.open();
      await s.inject('attach');
    } catch (e) {
      log(`attach failed ${s.label}: ${e.message}`);
      s.close();
      sessions.delete(page.id);
    }
  }
}

async function broadcast(why) {
  for (const s of [...sessions.values()]) {
    try { await s.inject(why); } catch (e) { /* supervisor handles it */ }
  }
}

async function main() {
  log(`agent start src=${SRC} scrim=${SCRIM} css=${CSS_FILE}`);

  if (DO_RELOAD) {
    await ensureSessions();
    for (const s of [...sessions.values()]) {
      s.send('Page.reload', { ignoreCache: true }).catch(() => {});
    }
    await new Promise((r) => setTimeout(r, 4000));
    await broadcast('after-reload');
  } else {
    await ensureSessions();
  }

  let cssStamp = '';
  let ticks = 0;
  let lastLoopAt = Date.now();

  const loop = setInterval(async () => {
    // Sleep / hibernate: timers do not fire while the machine is suspended, so a big
    // gap means we just woke up. A long suspension usually leaves the <video> holding a
    // dead socket (frozen or black wallpaper), so reload the pages once and re-inject.
    // Shorter sleeps are covered by the in-page watchdog above.
    const nowMs = Date.now();
    const gapS = Math.round((nowMs - lastLoopAt) / 1000);
    if (gapS > 90) {
      log(`resume detected (gap ${gapS}s) -> reloading pages`);
      for (const s of [...sessions.values()]) {
        s.send('Page.reload', { ignoreCache: true }).catch(() => {});
      }
      await new Promise((r) => setTimeout(r, 3500));
      await broadcast('after-resume');
    }
    lastLoopAt = nowMs;

    await ensureSessions();
    ticks += 1;

    // stylesheet hot reload
    try {
      const st = fs.statSync(CSS_FILE);
      const stamp = String(st.mtimeMs) + ':' + st.size;
      if (cssStamp && cssStamp !== stamp) await broadcast('css');
      cssStamp = stamp;
    } catch (e) { /* ignore */ }

    // every ~12s: make sure the layer is still there (SPA transitions can nuke it)
    if (ticks % 4 === 0) {
      for (const s of [...sessions.values()]) {
        try {
          const present = await s.evaluate("!!document.getElementById('wesk-video')");
          if (present !== 'true') await s.inject('tick');
        } catch (e) { /* supervisor handles it */ }
      }
    }
  }, 3000);

  if (ONCE) {
    setTimeout(() => {
      clearInterval(loop);
      for (const s of sessions.values()) s.close();
      process.exit(0);
    }, ONCE * 1000);
  }
}

main().catch((e) => {
  log('AGENT FAILED: ' + e.message);
  process.exit(1);
});
