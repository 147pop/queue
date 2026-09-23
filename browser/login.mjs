// login.mjs - Login automatico en Deportick (plataforma Crowder) manejando el
// Chromium visible via CDP. Si aparece captcha o MFA emite "QUEUE_EVENT <evento>"
// por stdout para que queue.sh abra el noVNC de esta instancia.
const {
  DEPORTICK_USER: USER,
  DEPORTICK_PASS: PASS,
  TARGET_URL = 'https://www.deportick.com',
  CDP_PORT = '9222',
} = process.env;

const HOST = new URL(TARGET_URL).hostname;
const CAPTCHA_WAIT_MS = 10000;
const CAPTCHA_RENDER_MS = 15000;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const rand = (a, b) => a + Math.random() * (b - a);
const log = (m) => console.log(`[login] ${m}`);
const emit = (ev) => console.log(`QUEUE_EVENT ${ev}`);

async function findPage() {
  for (;;) {
    try {
      const targets = await (await fetch(`http://127.0.0.1:${CDP_PORT}/json/list`)).json();
      const t = targets.find((t) => t.type === 'page' && t.url.includes(HOST));
      if (t) return t.webSocketDebuggerUrl;
    } catch {}
    await sleep(1000);
  }
}

function connect(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    const pending = new Map();
    let id = 0;
    const send = (method, params = {}) =>
      new Promise((res, rej) => {
        if (ws.readyState !== WebSocket.OPEN) return rej(new Error('pestaña cerrada'));
        pending.set(++id, { resolve: res, reject: rej });
        ws.send(JSON.stringify({ id, method, params }));
      });
    send.closed = () => ws.readyState !== WebSocket.OPEN;
    send.close = () => ws.close();
    ws.onmessage = ({ data }) => {
      const msg = JSON.parse(data);
      const p = pending.get(msg.id);
      if (!p) return;
      pending.delete(msg.id);
      msg.error ? p.reject(new Error(msg.error.message)) : p.resolve(msg.result);
    };
    ws.onerror = () => reject(new Error('no pude conectar a CDP'));
    ws.onclose = () => {
      for (const p of pending.values()) p.reject(new Error('pestaña cerrada'));
      pending.clear();
    };
    ws.onopen = () => resolve(send);
  });
}

const evaluate = async (send, expression) =>
  (await send('Runtime.evaluate', { expression, returnByValue: true })).result.value;

const VIS = `const vis = (el) => !!el && el.getClientRects().length > 0 && getComputedStyle(el).visibility !== 'hidden';`;

const PROBE = `(() => {
  ${VIS}
  const q = (s) => document.querySelector(s);
  let s = {};
  try { s = JSON.parse(localStorage.getItem('crowder')) || {}; } catch {}
  const cap = q('#loginCaptcha');
  return {
    loggedIn: !!s.access_token,
    ingresar: [...document.querySelectorAll('#ingresar, #ingresar2')].some(vis),
    form: vis(q('#loginForm input[name=username]')),
    captcha: !!cap,
    captchaReady: typeof window.grecaptcha?.render === 'function' || typeof window.turnstile?.render === 'function',
    captchaShown: vis(cap && cap.querySelector('iframe')),
    challenge: [...document.querySelectorAll('iframe[src*="recaptcha/api2/bframe"]')].some(vis),
    token: (cap && cap.querySelector('textarea') || {}).value || '',
    mfa: vis(q('#mfa_part')),
    error: [...document.querySelectorAll('#login_part .notificationMessages, #loginForm .notification.error')]
      .map((e) => e.innerText.replace(/[×\\s]+/g, ' ').trim()).filter(Boolean).join(' | '),
  };
})()`;

const rectOf = (sel) => `(() => {
  ${VIS}
  const el = [...document.querySelectorAll(${JSON.stringify(sel)})].find(vis);
  if (!el) return null;
  el.scrollIntoView({ block: 'center' });
  const r = el.getBoundingClientRect();
  return { x: r.x, y: r.y, w: r.width, h: r.height };
})()`;

// Mueve el mouse en varios pasos con curva y jitter hasta (x, y) y hace click
const mouse = { x: rand(200, 900), y: rand(100, 600) };
async function mouseClick(send, x, y) {
  const steps = Math.round(rand(10, 20)), from = { ...mouse };
  const cx = (from.x + x) / 2 + rand(-80, 80), cy = (from.y + y) / 2 + rand(-80, 80);
  for (let i = 1; i <= steps; i++) {
    const t = i / steps, u = 1 - t;
    mouse.x = u * u * from.x + 2 * u * t * cx + t * t * x;
    mouse.y = u * u * from.y + 2 * u * t * cy + t * t * y;
    await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: mouse.x, y: mouse.y });
    await sleep(rand(8, 25));
  }
  await sleep(rand(80, 200));
  await send('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', clickCount: 1 });
  await sleep(rand(40, 120));
  await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', clickCount: 1 });
}

async function click(send, sel) {
  const r = await evaluate(send, rectOf(sel));
  if (!r) return false;
  await mouseClick(send, r.x + r.w / 2 + rand(-3, 3), r.y + r.h / 2 + rand(-2, 2));
  return true;
}

// Posicion del checkbox dentro del iframe del reCAPTCHA (es un target CDP aparte)
async function checkboxOffset() {
  const fallback = { x: 13, y: 23, w: 28, h: 28 };
  try {
    const list = await (await fetch(`http://127.0.0.1:${CDP_PORT}/json/list`)).json();
    const t = list.find((t) => t.type === 'iframe' && t.url.includes('recaptcha/api2/anchor'));
    if (!t) return fallback;
    const frame = await connect(t.webSocketDebuggerUrl);
    const r = await evaluate(frame, rectOf('#recaptcha-anchor'));
    frame.close();
    return r || fallback;
  } catch {
    return fallback;
  }
}

async function clickCaptcha(send) {
  const f = await evaluate(send, rectOf('#loginCaptcha iframe'));
  if (!f) return false;
  const c = await checkboxOffset();
  await mouseClick(send, f.x + c.x + c.w / 2 + rand(-5, 5), f.y + c.y + c.h / 2 + rand(-5, 5));
  return true;
}

async function type(send, sel, text) {
  await click(send, sel);
  await evaluate(send, `(() => { const el = document.querySelector(${JSON.stringify(sel)}); el.focus(); el.select(); })()`);
  for (const ch of text) {
    await send('Input.insertText', { text: ch });
    await sleep(rand(40, 140));
  }
}

async function run(send) {
  await send('Page.bringToFront');
  let lastOpen = 0, lastWait = 0, filled = false, submitted = null, notified = null, waiting = false, lastError = '';
  let auto = true, clickedAt = 0, ingresarSince = 0, emptySince = 0;
  for (;;) {
    await sleep(500);
    if (send.closed()) throw new Error('pestaña cerrada');
    const s = await evaluate(send, PROBE).catch(() => null);
    if (!s) continue;

    if (s.loggedIn) {
      log('sesion iniciada');
      emit('login_ok');
      return;
    }
    if (s.error !== lastError) {
      lastError = s.error;
      if (s.error) {
        auto = false;
        log(`error: ${s.error} (dejo de reintentar solo, sigue por VNC)`);
        emit('login_error');
      }
    }
    if (s.mfa) {
      if (notified !== 'mfa') {
        notified = 'mfa';
        log('pide codigo MFA, completalo por VNC');
        emit('mfa');
      }
      continue;
    }
    if (!s.form) {
      filled = false;
      clickedAt = 0;
      if (s.ingresar && !ingresarSince) ingresarSince = Date.now();
      // El sitio dibuja el captcha solo si reCAPTCHA ya cargo al abrir el form
      const ready = s.captchaReady || Date.now() - ingresarSince > CAPTCHA_RENDER_MS;
      if (s.ingresar && ready && Date.now() - lastOpen > 5000) {
        lastOpen = Date.now();
        log('abriendo formulario de login');
        await click(send, '#ingresar, #ingresar2');
      } else if (!s.ingresar && Date.now() - lastWait > 30000) {
        lastWait = Date.now();
        log('esperando que cargue la pagina...');
      }
      continue;
    }
    if (!filled) {
      await sleep(rand(400, 900));
      await type(send, '#loginForm input[name=username]', USER);
      await sleep(rand(200, 500));
      await type(send, '#loginForm input[name=password]', PASS);
      filled = true;
      log('credenciales cargadas');
      continue;
    }
    if (s.captcha && !s.token) {
      if (!s.captchaShown) {
        if (!emptySince) emptySince = Date.now();
        if (Date.now() - emptySince > CAPTCHA_RENDER_MS) {
          log('el captcha no aparecio, recargo la pagina');
          emptySince = ingresarSince = 0;
          await send('Page.reload');
          await sleep(3000);
        }
        continue;
      }
      emptySince = 0;
      if (auto && !clickedAt) {
        await sleep(rand(300, 700));
        log('clickeando captcha');
        await clickCaptcha(send);
        clickedAt = Date.now();
        continue;
      }
      if (auto && !s.challenge && Date.now() - clickedAt < CAPTCHA_WAIT_MS) continue;
      if (!waiting) {
        waiting = true;
        log(s.challenge ? 'el captcha pide desafio, resolvelo por VNC' : 'captcha sin resolver, resolvelo por VNC');
        if (!notified) emit('captcha');
        notified = 'captcha';
      }
      continue;
    }
    const key = s.token || 'sin-captcha';
    if (submitted !== key) {
      if (s.token && clickedAt && !waiting) log('captcha pasado sin desafio');
      submitted = key;
      waiting = false;
      clickedAt = 0;
      await sleep(rand(300, 800));
      log('enviando login');
      await click(send, '#loginForm button.settings_save');
    }
  }
}

if (!USER || !PASS) {
  log('faltan DEPORTICK_USER / DEPORTICK_PASS, no hago login');
  process.exit(0);
}

for (;;) {
  try {
    log(`buscando pestaña de ${HOST}`);
    await run(await connect(await findPage()));
    break;
  } catch (e) {
    log(`${e.message}, reintento`);
    await sleep(2000);
  }
}
