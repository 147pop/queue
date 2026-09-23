// monitor.mjs - Vigila la pestaña de TARGET_URL via CDP y emite "QUEUE_EVENT 403"
// cuando el documento principal responde 403 o muestra una pagina de bloqueo
// (WAF/Cloudflare). queue.sh rota IP+UA de la instancia y reintenta.
//
// Se conecta al ws del browser con Target.attachToTarget (flat) para coexistir
// con la sesion que login.mjs mantiene abierta sobre la misma pestaña, y escucha
// Network.responseReceived (lo emite el proceso browser) para detectar aunque el
// renderer este congelado. Como respaldo sondea Runtime.evaluate con timeout.
const {
  TARGET_URL = 'https://www.deportick.com',
  CDP_PORT = '9222',
} = process.env;

const HOST = new URL(TARGET_URL).hostname;
const POLL_MS = 3000;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (m) => console.log(`[monitor] ${m}`);
const emit = (ev) => console.log(`QUEUE_EVENT ${ev}`);

async function browserWsUrl() {
  for (;;) {
    try {
      const v = await (await fetch(`http://127.0.0.1:${CDP_PORT}/json/version`)).json();
      if (v.webSocketDebuggerUrl) return v.webSocketDebuggerUrl;
    } catch {}
    await sleep(1000);
  }
}

function connect(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    const pending = new Map();
    const listeners = new Map();
    let id = 0;
    const send = (method, params = {}, sessionId) =>
      new Promise((res, rej) => {
        if (ws.readyState !== WebSocket.OPEN) return rej(new Error('ws cerrado'));
        const mid = ++id;
        pending.set(mid, { res, rej });
        setTimeout(() => pending.delete(mid) && rej(new Error(`timeout ${method}`)), 8000);
        ws.send(JSON.stringify({ id: mid, method, params, sessionId }));
      });
    send.on = (method, fn) => {
      if (!listeners.has(method)) listeners.set(method, new Set());
      listeners.get(method).add(fn);
    };
    send.onclose = (fn) => ws.addEventListener('close', fn);
    ws.onmessage = ({ data }) => {
      const msg = JSON.parse(data);
      const p = pending.get(msg.id);
      if (p) {
        pending.delete(msg.id);
        msg.error ? p.rej(new Error(msg.error.message)) : p.res(msg.result);
      } else if (msg.method) {
        for (const fn of listeners.get(msg.method) || []) fn(msg.params || {});
      }
    };
    ws.onerror = () => reject(new Error('no pude conectar a CDP'));
    ws.onclose = () => {
      for (const p of pending.values()) p.rej(new Error('ws cerrado'));
      pending.clear();
    };
    ws.onopen = () => resolve(send);
  });
}

// responseStatus es el status HTTP del documento principal (navigation timing).
// El titulo es fallback para paginas de desafio/bloqueo que no siempre dan 403.
const PROBE = `(() => {
  const nav = performance.getEntriesByType('navigation')[0];
  return {
    key: performance.timeOrigin + ':' + (nav ? nav.startTime : 0),
    status: (nav && nav.responseStatus) || 0,
    title: document.title || '',
    url: location.href,
  };
})()`;

const BLOCKED_TITLE = /access denied|attention required|just a moment|are you a robot|verify you are|forbidden/i;

async function run(send) {
  const seen = new Set(); // requestIds ya reportados
  let lastKey = '';     // ultima navegacion reportada por sondeo
  let targetId = null, sessionId = null, gone = false;

  send.on('Network.responseReceived', (p) => {
    if (p.type !== 'Document' || !p.response || p.response.status !== 403) return;
    if (!p.response.url.includes(HOST) || seen.has(p.requestId)) return;
    seen.add(p.requestId);
    log(`HTTP 403 en ${p.response.url}`);
    emit('403');
  });
  send.on('Target.detachedFromTarget', (p) => { if (p.sessionId === sessionId) gone = true; });
  send.on('Target.targetDestroyed', (p) => { if (p.targetId === targetId) gone = true; });
  send.onclose(() => { gone = true; });

  for (;;) {
    const { targetInfos = [] } = await send('Target.getTargets').catch(() => ({}));
    const t = targetInfos.find((t) => t.type === 'page' && t.url.includes(HOST));
    if (t) {
      targetId = t.targetId;
      ({ sessionId } = await send('Target.attachToTarget', { targetId, flatten: true }));
      break;
    }
    await sleep(1000);
  }
  await send('Network.enable', {}, sessionId).catch(() => {});
  log(`observando pestaña de ${HOST}`);

  let hangs = 0;
  for (;;) {
    await sleep(POLL_MS);
    if (gone) throw new Error('pestaña cerrada');
    const ev = await send('Runtime.evaluate', { expression: PROBE, returnByValue: true }, sessionId)
      .catch(() => null);
    if (ev === null) {
      // Renderer no responde: forzar una recarga; el status llega por
      // Network.responseReceived aunque el renderer siga colgado.
      if (++hangs === 1 || hangs % 20 === 0) {
        log('renderer no responde, recargando la pagina');
        send('Page.reload', { ignoreCache: true }, sessionId).catch(() => {});
      }
      continue;
    }
    hangs = 0;
    const s = ev.result && ev.result.value;
    if (!s || s.key === lastKey || !s.url.includes(HOST)) continue;
    if (s.status === 403 || BLOCKED_TITLE.test(s.title)) {
      lastKey = s.key;
      log(`pagina bloqueada (HTTP ${s.status || '?'}: "${s.title.slice(0, 60)}")`);
      emit('403');
    }
  }
}

for (;;) {
  try {
    await run(await connect(await browserWsUrl()));
  } catch (e) {
    log(`${e.message}, reintento`);
    await sleep(2000);
  }
}
