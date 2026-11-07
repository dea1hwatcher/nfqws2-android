/* nfqws2 WebUI - core: utilities, locale, module bridge, navigation */

/* Data comes from bin/nfqws2-ctl only; the UI degrades without it */
const MOD = '/data/adb/modules/nfqws2-android', CTL = MOD + '/bin/nfqws2-ctl';
const $ = id => document.getElementById(id);
let S = {}, seq = 0, pkgs = [];
const q = s => "'" + String(s).replace(/'/g, "'\\''") + "'";
const b64 = s => btoa(unescape(encodeURIComponent(s)));
const unb64 = s => { try { return decodeURIComponent(escape(atob(s))); } catch(e) { return atob(s); } };
function b64toBlob(b64Data, contentType){
  contentType = contentType || 'application/x-tar';
  const bin = atob(String(b64Data || '').replace(/\s+/g, ''));
  const len = bin.length;
  const bytes = new Uint8Array(len);
  for(let i = 0; i < len; i++) bytes[i] = bin.charCodeAt(i);
  return new Blob([bytes], { type: contentType });
}
function blobToB64(blob){
  return new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => {
      const s = String(r.result || '');
      resolve(s.includes(',') ? s.split(',')[1] : s);
    };
    r.onerror = reject;
    r.readAsDataURL(blob);
  });
}
async function promptSaveDir(titleKey){
  let targetDir = (typeof store !== 'undefined' && store.get('nfq_save_dir')) || '/sdcard/Download';
  if(typeof window !== 'undefined' && window.ksu && typeof mdPrompt === 'function'){
    const chosen = await mdPrompt(
      t(titleKey),
      t('Укажите папку для сохранения архива:'),
      targetDir,
      t('Папка для сохранения'),
      { ok: t('Сохранить') }
    );
    if(chosen === null) return null;
    targetDir = (chosen || targetDir).trim().replace(/\/+$/, '') || '/sdcard/Download';
    if(!targetDir.startsWith('/')) targetDir = '/sdcard/' + targetDir;
    if(typeof store !== 'undefined') store.set('nfq_save_dir', targetDir);
  }
  return targetDir;
}
async function copyText(text, okMsg, errMsg){
  let ok = false;
  try {
    if(navigator.clipboard && navigator.clipboard.writeText){
      await navigator.clipboard.writeText(text);
      ok = true;
    } else throw new Error();
  } catch(e){
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.style.cssText = 'position:fixed;opacity:0;pointer-events:none';
    document.body.append(ta);
    ta.select();
    try { ok = document.execCommand('copy'); } catch(e2) {}
    ta.remove();
  }
  toast(ok ? okMsg : (errMsg || t('Не удалось скопировать: выделите текст вручную')));
}
async function exportBlobFile(blob, filename, mimeType, localFilePath, targetDir){
  mimeType = mimeType || 'application/x-tar';
  targetDir = (targetDir || (typeof store !== 'undefined' && store.get('nfq_save_dir')) || '/sdcard/Download').trim().replace(/\/+$/, '');
  if(!targetDir.startsWith('/')) targetDir = '/sdcard/' + targetDir;
  const targetFile = targetDir.endsWith('.tar') ? targetDir : (targetDir + '/' + filename);
  const destFolder = targetFile.substring(0, targetFile.lastIndexOf('/')) || '/sdcard/Download';
  if(!window?.ksu && typeof window !== 'undefined' && window.showSaveFilePicker){
    try {
      const handle = await window.showSaveFilePicker({
        suggestedName: filename,
        types: [{ description: filename, accept: { [mimeType]: ['.tar'], 'application/octet-stream': ['.tar'] } }]
      });
      const writable = await handle.createWritable();
      await writable.write(blob);
      await writable.close();
      toast(t('Файл сохранён: {0}', filename));
      return true;
    } catch(e){
      if(e && e.name === 'AbortError') return false;
    }
  }
  if(!window?.ksu && typeof navigator !== 'undefined' && navigator.canShare && typeof File !== 'undefined'){
    try {
      let file = new File([blob], filename, { type: mimeType });
      if(!navigator.canShare({ files: [file] })){
        file = new File([blob], filename, { type: 'application/octet-stream' });
      }
      if(!navigator.canShare({ files: [file] })){
        file = new File([blob], filename, { type: '' });
      }
      if(navigator.canShare({ files: [file] })){
        await navigator.share({ files: [file], title: filename });
        toast(t('Экспорт завершён: {0}', filename));
        return true;
      }
    } catch(e){
      if(e && e.name === 'AbortError') return false;
    }
  }
  try {
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    setTimeout(() => { a.remove(); URL.revokeObjectURL(url); }, 2000);
  } catch(e) {}
  if(localFilePath && typeof window !== 'undefined' && window.ksu){
    try {
      const cmd =
        'f=' + q(localFilePath) + '; tf=' + q(targetFile) + '; td=' + q(destFolder) + '; ' +
        'mkdir -p "$td" 2>/dev/null; ' +
        'if [ "$f" != "$tf" ]; then cp -f "$f" "$tf" 2>/dev/null; chmod 666 "$tf" 2>/dev/null; fi; ' +
        q(CTL) + ' share-saved "$tf" >/dev/null 2>&1';
      await sh(cmd);
    } catch(e) {}
    toast(t('Архив сохранён: {0}', targetFile));
    return true;
  }
  toast(t('Экспорт завершён: {0}', filename));
  return true;
}
const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'}[c]));
/* esc() alone is not enough inside onclick: HTML decoding restores &#39; before JS parses it */
const jsArg = v => esc(JSON.stringify(String(v == null ? '' : v)));
const icon = (name, cls) => '<svg aria-hidden="true" class="icon ' + (cls || 's20') + '"><use href="#i-' + name + '"/></svg>';

/* localStorage can be unavailable */
const store = {
  get(k){ try { return localStorage.getItem(k); } catch(e) { return null; } },
  set(k, v){ try { localStorage.setItem(k, v); } catch(e) {} },
  del(k){ try { localStorage.removeItem(k); } catch(e) {} }
};
/* Страницы прокручиваются в #scroller, а не в окне (см. base.css: корень
   неподвижен, чтобы WebView не растягивал шапку и навигацию) */
const scroller = document.getElementById('scroller');
const scrollPos = () => scroller.scrollTop;
const scrollToY = y => { scroller.scrollTop = y; };

/* Keys are the Russian strings themselves; EN maps them. data-t / data-ta mark static nodes */
let LANG = store.get('nfq_lang') === 'en' ? 'en' : 'ru';
let EN = {};
function t(s){
  let r = (LANG === 'en' && EN[s] != null) ? EN[s] : s;
  for(let i = 1; i < arguments.length; i++) r = r.split('{' + (i - 1) + '}').join(arguments[i]);
  return r;
}
function translateStatic(){
  document.documentElement.lang = LANG;
  document.querySelectorAll('[data-t]').forEach(el => {
    if(el.dataset.ru == null) el.dataset.ru = el.textContent.trim();
    const key = el.getAttribute('data-t') || el.dataset.ru;
    el.textContent = (LANG === 'en' && EN[key] != null) ? EN[key] : el.dataset.ru;
  });
  document.querySelectorAll('[data-ta]').forEach(el => el.dataset.ta.split(',').forEach(a => {
    const k = 'ru_' + a.replace(/-/g, '_');
    if(el.dataset[k] == null) el.dataset[k] = el.getAttribute(a) || '';
    el.setAttribute(a, t(el.dataset[k]));
  }));
}
const fmtCount = n => Number(n).toLocaleString(LANG === 'en' ? 'en-US' : 'ru-RU');

/* Ripple, delegated so it survives innerHTML */
document.addEventListener('pointerdown', e => {
  if(typeof isAnimationsDisabled === 'function' && isAnimationsDisabled()) return;
  let el = e.target.closest && e.target.closest('.state, .nav-dest');
  if(el && el.classList.contains('nav-dest')) el = el.querySelector('.nav-ind');
  if(!el || el.classList.contains('is-disabled') || el.disabled) return;
  const r = el.getBoundingClientRect();
  const size = Math.max(r.width, r.height) * 2.2;
  const s = document.createElement('span');
  s.className = 'ripple';
  s.style.cssText = 'width:' + size + 'px;height:' + size + 'px;left:' +
    ((e.clientX || r.left + r.width / 2) - r.left - size / 2) + 'px;top:' +
    ((e.clientY || r.top + r.height / 2) - r.top - size / 2) + 'px';
  el.append(s);
  setTimeout(() => s.remove(), 520);
}, {passive: true});

document.addEventListener('keydown', e => {
  if(e.key !== 'Enter' && e.key !== ' ') return;
  const el = e.target && e.target.closest && e.target.closest('[role="button"]:not(button)');
  if(el && !el.classList.contains('is-disabled')){ e.preventDefault(); el.click(); }
});

/* Menu opens under the anchor, flips up when there is no room; outside click only closes */
let openMenuEntry = null;
function closeMenu(){ if(openMenuEntry) openMenuEntry.close(); }
function openMenu(anchor, items, opts){
  if(openMenuEntry && openMenuEntry.anchor === anchor){ closeMenu(); return null; }
  closeMenu();
  const viaKeyboard = anchor.matches(':focus-visible');
  const menu = document.createElement('div');
  menu.className = 'menu';
  menu.setAttribute('role', 'menu');
  for(const it of items){
    if(it === '-'){ const sep = document.createElement('div'); sep.className = 'sep'; sep.setAttribute('role', 'separator'); menu.append(sep); continue; }
    const mi = document.createElement('button');
    mi.className = 'mi state';
    mi.type = 'button';
    mi.setAttribute('role', 'menuitem');
    mi.innerHTML = ('icon' in it ? '<span class="mi-icon">' + (it.icon ? icon(it.icon, 's24') :
        '<span style="display:block;width:24px;height:24px"></span>') + '</span>' : '') +
      '<span class="mi-text">' + esc(it.label) + (it.sub ? '<span class="mi-sub">' + esc(it.sub) + '</span>' : '') + '</span>';
    mi.onclick = () => { close(); if(it.onClick) it.onClick(); };
    menu.append(mi);
  }
  const back = document.createElement('div');
  back.className = 'menu-back';
  let backHeld = false;
  const dropBack = () => { backHeld = false; back.remove(); };
  back.addEventListener('pointerdown', () => { backHeld = true; close(); });
  ['pointerup', 'pointercancel'].forEach(ev => back.addEventListener(ev, () => { if(backHeld) setTimeout(dropBack, 0); }));
  back.addEventListener('click', e => { e.preventDefault(); close(); dropBack(); });
  back.addEventListener('wheel', () => { close(); dropBack(); }, {passive: true});
  $('layer').append(back, menu);
  const r = anchor.getBoundingClientRect(), mw = menu.offsetWidth, mh = menu.offsetHeight;
  let top = r.bottom + 4;
  if(top + mh > innerHeight - 8){ top = Math.max(8, r.top - mh - 4); menu.classList.add('up'); }
  const end = r.left + r.width / 2 > innerWidth / 2;
  if(end) menu.classList.add('end');
  menu.style.left = Math.max(8, Math.min(end ? r.right - mw : r.left, innerWidth - mw - 8)) + 'px';
  menu.style.top = top + 'px';
  anchor.setAttribute('aria-expanded', 'true');
  void menu.offsetWidth;
  (window.requestAnimationFrame || setTimeout)(() => menu.classList.add('open'), 16);
  const itemsEls = () => [...menu.querySelectorAll('.mi')];
  const onKey = e => {
    if(e.key === 'Escape'){ e.stopPropagation(); e.preventDefault(); close(); anchor.focus(); return; }
    if(e.key === 'ArrowDown' || e.key === 'ArrowUp'){
      e.preventDefault();
      const els = itemsEls(), i = els.indexOf(document.activeElement);
      const n = e.key === 'ArrowDown' ? (i + 1) % els.length : (i - 1 + els.length) % els.length;
      els[i < 0 ? 0 : n].focus();
    }
    if(e.key === 'Tab') close();
  };
  addEventListener('keydown', onKey, true);
  if(viaKeyboard){ const f = itemsEls()[0]; if(f) f.focus(); }
  let closed = false;
  const entry = { close, anchor };
  openMenuEntry = entry;
  const scrim = opts && opts.scrim && $('nav-scrim');
  if(scrim) scrim.classList.add('show');
  scheduleSync();
  function close(){
    if(closed) return; closed = true;
    if(scrim) scrim.classList.remove('show');
    removeEventListener('keydown', onKey, true);
    back.style.pointerEvents = 'none';
    if(!backHeld) back.remove(); else setTimeout(dropBack, 700);
    menu.classList.remove('open');
    menu.classList.add('closing');
    setTimeout(() => {
      back.remove();
      menu.remove();
    }, 120);
    anchor.setAttribute('aria-expanded', 'false');
    if(openMenuEntry === entry) openMenuEntry = null;
    scheduleSync();
  }
  return entry;
}


/* ksu.exec blocks the page thread and stutters transitions; use spawn when it answers correctly, exec as fallback */
let spawnOK = false;
function makeEmitter(){
  const h = {};
  return {
    on(ev, fn){ (h[ev] = h[ev] || []).push(fn); return this; },
    emit(ev){ const a = [].slice.call(arguments, 1); (h[ev] || []).forEach(f => { try { f.apply(null, a); } catch(e) {} }); }
  };
}
/* spawn stdout arrives inconsistently, so output frames itself: each line ends with \x1e, exit code last */
const REC = '\x1e', RC_TAG = '__nfq_rc=';
const frameCmd = cmd => '{ ' + cmd + '\nprintf \'\\n' + RC_TAG + '%s\\n\' "$?"; } | awk \'{ printf "%s\\036\\n", $0; fflush() }\'';
function spawnRun(cmd, ms, onLine){
  return new Promise(res => {
    const id = '__sp' + (++seq), out = [], err = [];
    let done = 0, tm = 0, buf = '', rc = null;
    const child = makeEmitter();
    child.stdout = makeEmitter();
    child.stderr = makeEmitter();
    const fin = (c, extraErr) => {
      if(done) return; done = 1; clearTimeout(tm);
      setTimeout(() => { delete window[id]; }, 1000);
      if(buf.replace(/[\r\n]/g, '')) take(buf.replace(/[\r\n]/g, ''));
      if(extraErr) err.push(extraErr);
      while(out.length && out[out.length - 1] === '') out.pop();   // trailing blank before the exit code
      res({code: rc != null ? rc : (+c || 0), out: out.join('\n'), err: err.join('\n')});
    };
    const take = rec => {
      if(rec.indexOf(RC_TAG) === 0){ rc = parseInt(rec.slice(RC_TAG.length), 10) || 0; return; }
      out.push(rec);
      if(onLine) try { onLine(rec); } catch(e) {}
    };
    child.stdout.on('data', d => {
      buf += String(d).replace(/[\r\n]/g, '');
      let i;
      while((i = buf.indexOf(REC)) >= 0){ take(buf.slice(0, i)); buf = buf.slice(i + 1); }
    });
    child.stderr.on('data', d => err.push(String(d)));
    child.on('exit', c => fin(rc == null && c != null ? c : rc));
    child.on('error', e => fin(1, String(e)));
    window[id] = child;
    tm = setTimeout(() => fin(-1, t('Таймаут')), ms);
    // KernelSU joins args with spaces and adds no quoting: send one command string, empty arg list
    try { window.ksu.spawn(frameCmd(cmd), '[]', '{}', id); } catch(e) { fin(1, String(e)); }
  });
}
function execRun(cmd, ms){
  return new Promise(res => {
    const k = window.ksu;
    if(!k || !k.exec){ res({code: 1, out: '', err: t('Нет моста ksu.exec')}); return; }
    const id = '__cb' + (++seq); let done = 0;
    const fin = (c, o, e) => { if(done) return; done = 1; clearTimeout(tm); delete window[id]; res({code: +c || 0, out: String(o || ''), err: String(e || '')}); };
    const tm = setTimeout(() => fin(-1, '', t('Таймаут')), ms);
    window[id] = fin;
    try { k.exec(cmd, '{}', id); } catch(e) { try { k.exec(cmd, id); } catch(e2) { fin(1, '', String(e2)); } }
  });
}
async function sh(cmd, ms, onLine){
  ms = ms || 15000;
  if(spawnOK) return spawnRun(cmd, ms, onLine);
  const r = await execRun(cmd, ms);
  if(onLine) r.out.split('\n').forEach(l => { try { onLine(l); } catch(e) {} });
  return r;
}
async function detectSpawn(){
  if(!window.ksu || typeof window.ksu.spawn !== 'function') return;
  const r = await spawnRun("printf 'nfq_a\\n\\nnfq_b\\n'; (exit 3)", 3000);
  spawnOK = r.code === 3 && r.out === 'nfq_a\n\nnfq_b';
}
const ctlCmd = a => (LANG === 'en' ? 'NFQWS_LANG=en ' : '') + 'sh ' + q(CTL) + ' ' + a.map(q).join(' ');
/* Длинный аргумент (base64 архива или большого списка) одной командой не
   пройдёт: предел ядра на длину аргумента ~128 КБ. Такой уходит частями
   командой upload, а в саму команду идёт ссылка @up:<метка>. */
const UPLOAD_CHUNK = 48000;
async function uploadArgs(a){
  const out = [];
  for(const v of a){
    if(typeof v !== 'string' || v.length <= UPLOAD_CHUNK){ out.push(v); continue; }
    const tk = 'u' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
    for(let i = 0; i < v.length; i += UPLOAD_CHUNK){
      const r = await sh(ctlCmd(['upload', tk, v.slice(i, i + UPLOAD_CHUNK)]), 20000);
      if(r.code) throw new Error((r.err || r.out || 'upload').trim());
    }
    out.push('@up:' + tk);
  }
  return out;
}
async function ctl(a, ms){
  try { a = await uploadArgs(a); } catch(e){ toast(String(e.message || e).slice(0, 160)); return ''; }
  const r = await sh(ctlCmd(a), ms);
  if(r.code && r.err && !r.out) toast(r.err.slice(0, 160));
  return r.out + (r.code && r.err ? '\n' + r.err : '');
}
async function ctlx(a, ms, onLine){
  try { a = await uploadArgs(a); } catch(e){ return {code: 1, out: '', err: String(e.message || e)}; }
  return await sh(ctlCmd(a), ms, onLine);
}
const errText = (r, fallback) => ((r.err || '').trim() || (r.out || '').trim().split('\n').pop() || t(fallback));

/* Snackbar */
let snackAction = null;
function toast(m, action){
  $('prompt-msg').textContent = m;
  const b = $('prompt-action');
  snackAction = action || null;
  b.hidden = !action;
  if(action) b.textContent = action.label || t('Повторить');
  const pc = $('prompt-container');
  pc.classList.add('show');
  clearTimeout(pc._t);
  pc._t = setTimeout(() => pc.classList.remove('show'), action ? 8000 : 4000);
}
$('prompt-action').onclick = () => {
  $('prompt-container').classList.remove('show');
  const a = snackAction; snackAction = null;
  if(a && a.fn) a.fn();
};

/* Системные жесты Android: полоса навигации снизу и узкие полосы
   слева/справа («назад»). Касание оттуда — жест системы, а не нажатие на
   то, что под пальцем. Нижняя зона — не меньше системного отступа снизу. */
let insetProbe = null;
function inGestureZone(x, y){
  if(!insetProbe){
    insetProbe = document.createElement('div');
    insetProbe.style.cssText = 'position:fixed;left:0;bottom:0;width:0;visibility:hidden;pointer-events:none;height:var(--bottom-inset)';
    document.body.append(insetProbe);
  }
  const inset = insetProbe.offsetHeight || 0;
  return y > innerHeight - Math.max(32, inset + 8) || x < 24 || x > innerWidth - 24;
}

/* ── Долгое нажатие (500ms): контекстное меню или выбор ──────────────────
   root слушает, sel выбирает элемент (без sel — сам root). Click, который
   приходит после срабатывания, гасится на уровне документа — до onclick
   элемента и до переключения radio в label (и до подложки открытого меню). Касание у края экрана — жест
   системы Android, его не считаем; свернули WebView или увели экран — отмена. */
let longGuard = null;
document.addEventListener('click', e => {
  const g = longGuard;
  if(!g) return;
  longGuard = null;
  if(performance.now() - g.at < 1500){ e.stopPropagation(); e.preventDefault(); }
}, true);
document.addEventListener('pointerdown', () => { longGuard = null; }, true);
const longCancels = [];
['blur', 'pagehide'].forEach(ev => addEventListener(ev, () => longCancels.forEach(c => c())));
document.addEventListener('visibilitychange', () => longCancels.forEach(c => c()));
function onLongPress(root, sel, fn){
  if(!root) return;
  let tm = 0, x0 = 0, y0 = 0;
  const cancel = () => { clearTimeout(tm); tm = 0; };
  longCancels.push(cancel);
  root.addEventListener('pointerdown', e => {
    cancel();
    longGuard = null;
    if(e.pointerType === 'mouse' && e.button !== 0) return;
    const el = sel ? e.target.closest(sel) : root;
    if(!el || !root.contains(el)) return;
    if(e.pointerType !== 'mouse' && inGestureZone(e.clientX, e.clientY)) return;
    x0 = e.clientX; y0 = e.clientY;
    const page = currentPage;
    tm = setTimeout(() => {
      tm = 0;
      if(!el.isConnected || currentPage !== page || document.hidden) return;
      longGuard = {el, at: performance.now()};
      document.querySelectorAll('.ripple').forEach(r => r.remove());
      fn(el);
    }, 500);
  });
  root.addEventListener('pointermove', e => { if(tm && Math.hypot(e.clientX - x0, e.clientY - y0) > 10) cancel(); });
  ['pointerup', 'pointercancel', 'pointerleave'].forEach(ev => root.addEventListener(ev, cancel));
  root.addEventListener('contextmenu', e => { if(!sel || e.target.closest(sel)) e.preventDefault(); });
}

/* Busy indicator under the app bar */
let busyCount = 0;
function busy(on){
  busyCount = Math.max(0, busyCount + (on ? 1 : -1));
  const idle = busyCount === 0;
  $('progress-top').hidden = idle;
  $('content').setAttribute('aria-busy', idle ? 'false' : 'true');
}
async function withBusy(a, ms){
  busy(true);
  try { return await ctlx(a, ms); } finally { busy(false); }
}

/* «Поделиться» файлом модуля: файлом (file:// на настоящий путь — root-
   проводник вроде MT Manager откроет его на месте) или текстом (в чат). */
const CONFFILE_PATH = '/data/adb/nfqws2/nfqws2.conf';
function shareFileMenu(anchor, path){
  openMenu(anchor, [
    {label: t('Файлом'), sub: t('MT Manager и другие root-проводники'), icon: 'file', onClick: () => shareFile('file', path)},
    {label: t('Текстом'), sub: t('В чат, заметки, почту'), icon: 'copy', onClick: () => shareFile('text', path)}
  ]);
}
async function shareFile(how, path){
  const r = await withBusy(['share', how, path]);
  if(r.code) toast(errText(r, 'Не удалось поделиться'));
}

/* Repaint only when the content really differs */
function setHTML(el, html, animate, keep){
  if(typeof el === 'string') el = $(el);
  if(!el || (keep !== false && el._html === html)) return false;
  // keep=false for markup holding base64 images: the DOM has parsed them
  // already, and a copy would sit next to the same strings in the model
  el._html = keep === false ? null : html;
  el.innerHTML = html;
  if(animate !== false){ el.classList.remove('appear'); void el.offsetWidth; el.classList.add('appear'); }
  return true;
}

/* Dialog replacing native confirm/prompt: focus stays inside and returns to the opener */
let dialogCb = null, dialogReturnFocus = null;
function dialogResolve(val){
  if(!$('dialog-wrap').classList.contains('open')) return;
  const cb = dialogCb; dialogCb = null;
  $('dialog-wrap').classList.remove('open');
  const back = dialogReturnFocus; dialogReturnFocus = null;
  if(back && document.contains(back)) try { back.focus({preventScroll: true}); } catch(e) {}
  scheduleSync();
  if(cb) cb(val);
}
function mdDialog(opts){
  if(dialogCb) dialogResolve(false);
  return new Promise(res => {
    dialogCb = res;
    dialogReturnFocus = document.activeElement;
    const dlg = $('dialog');
    $('d-title').textContent = opts.title || '';
    $('d-body').textContent = opts.text || '';
    $('d-body').hidden = !opts.text;
    const showIcon = opts.icon !== false;
    const ic = $('d-icon');
    ic.hidden = !showIcon;
    ic.className = 'd-icon' + (opts.danger ? ' danger' : '');
    ic.innerHTML = icon(opts.iconName || (opts.danger ? 'error' : 'warn'), 's24');
    dlg.classList.toggle('has-icon', showIcon);
    const ok = $('d-ok');
    ok.className = 'btn text state' + (opts.danger ? ' danger' : '');
    ok.textContent = opts.ok || t('ОК');
    const cancel = $('d-cancel');
    cancel.hidden = opts.cancel === false;
    cancel.textContent = typeof opts.cancel === 'string' ? opts.cancel : t('Отмена');
    const f = $('d-field');
    f.hidden = !opts.input;
    if(opts.input){
      const di = $('d-input');
      di.type = opts.input.type || 'text';
      di.inputMode = opts.input.inputmode || '';
      di.value = opts.input.value || '';
      $('d-label').textContent = opts.input.label || t('Значение');
    }
    /* alertdialog for interrupting confirmations only; an input is a plain dialog */
    dlg.setAttribute('role', opts.input ? 'dialog' : 'alertdialog');
    $('dialog-wrap').classList.add('open');
    scheduleSync();
    setTimeout(() => { (opts.input ? $('d-input') : dlg).focus(); }, 80);
  });
}
const mdConfirm = (title, text, o) => mdDialog(Object.assign({title, text}, o || {})).then(v => !!v);
async function mdPrompt(title, text, value, label, extra){
  extra = extra || {};
  return mdDialog({title, text, ok: extra.ok || t('Сохранить'), icon: false,
    input: {value, label, type: extra.type, inputmode: extra.inputmode}})
    .then(v => (v === false ? null : v));
}
$('d-ok').onclick = () => dialogResolve($('d-field').hidden ? true : $('d-input').value.trim());
$('d-input').onkeydown = e => { if(e.key === 'Enter') dialogResolve($('d-input').value.trim()); };
$('dialog-wrap').addEventListener('keydown', e => {
  if(e.key !== 'Tab') return;
  const els = [...$('dialog').querySelectorAll('button, input')].filter(el => el.offsetParent !== null && !el.disabled);
  if(!els.length) return;
  const first = els[0], last = els[els.length - 1], a = document.activeElement;
  if(e.shiftKey && (a === first || a === $('dialog'))){ e.preventDefault(); last.focus(); }
  else if(!e.shiftKey && a === last){ e.preventDefault(); first.focus(); }
});

/* Top-level sections live in the navigation bar; settings and below are child screens */
const PAGE_META = {
  control:  {title: 'Состояние', init: () => { renderStatus(); stat(); initStrategySelector(); }},
  lists:    {title: 'Списки', init: () => { renderMode(); renderListFiles(); stat(); }},
  logs:     {title: 'Журналы', init: () => loadLog(),
             actions: [{icon: 'refresh', label: 'Обновить журнал', fn: () => loadLog()}]},
  config:   {title: 'Конфиг', init: () => confInit()},
  settings: {title: 'Настройки', child: true, init: () => renderSettings()},
  smart:    {title: 'Умный режим', child: true, parent: 'settings', init: () => smartInit()},
  wifi:     {title: 'Домашняя Wi‑Fi', child: true, parent: 'settings', init: () => wifiInit()},
  apps:     {title: 'Фильтр приложений', child: true, parent: 'settings', init: () => appsInit(),
             actions: [{icon: 'refresh', label: 'Обновить список приложений', fn: () => loadPk(true)}]},
  test:     {title: 'Проверка доступности', child: true, parent: 'settings', init: () => testInit()},
  diag:     {title: 'Диагностика', child: true, parent: 'settings', init: () => diagInit(),
             actions: [{icon: 'refresh', label: 'Проверить снова', fn: () => diagInit()}]}
};
let currentPage = 'control', lastTop = 'control', transitionCleanup = null;
const pageDepth = p => { const m = PAGE_META[p]; return !m.child ? 0 : (m.parent ? pageDepth(m.parent) + 1 : 1); };

function renderAppBar(page, animate){
  const m = PAGE_META[page];
  $('back-btn').hidden = !m.child;
  $('settings-btn').hidden = !!m.child;
  const tEl = $('app-title');
  tEl.textContent = t(m.title);
  if(animate !== false && !isAnimationsDisabled()){ tEl.classList.remove('swap'); void tEl.offsetWidth; tEl.classList.add('swap'); }
  fillBarActions(m.actions);
}
function fillBarActions(actions){
  const box = $('bar-actions');
  box.innerHTML = '';
  (actions || []).forEach(a => {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'icon-btn state';
    b.title = t(a.label);
    b.setAttribute('aria-label', t(a.label));
    b.innerHTML = icon(a.icon, 's24');
    b.onclick = a.fn;
    if(a.disabled) b.disabled = true;
    box.append(b);
  });
}
function renderNavBar(page){
  document.querySelectorAll('.nav-dest').forEach(b => {
    if(b.dataset.page === page) b.setAttribute('aria-current', 'page');
    else b.removeAttribute('aria-current');
  });
  document.body.classList.toggle('nav-hidden', !!PAGE_META[page].child);
}

/* Прокрутка экранов: уходя, экран запоминает её; вперёд (в дочерний экран)
   открываем с начала, а назад и по вкладкам — там, где пользователь был. */
const pageScroll = {};
function showPage(page, mode, slide){
  if(transitionCleanup) transitionCleanup();
  const from = document.querySelector('.page.active');
  const to = document.querySelector('.page[data-page="' + page + '"]');
  if(!to || from === to) return;
  const animate = !matchMedia('(prefers-reduced-motion: reduce)').matches && !isAnimationsDisabled();
  if(mode === 'slide' && from && animate) return slidePages(from, to, slide);
  if(mode === 'slide') mode = 'fade';
  if(from){
    if(animate){
      const r = from.getBoundingClientRect();
      from.style.cssText = 'position:fixed;top:' + r.top + 'px;left:' + r.left + 'px;width:' + r.width + 'px';
      from.classList.add('leaving', 'leave-' + mode);
    }
    from.classList.remove('active');
  }
  to.classList.add('active');
  if(animate) to.classList.add('enter-' + mode);
  const y = mode === 'forward' ? 0 : (pageScroll[page] || 0);
  scrollToY(y);
  $('app-bar').classList.toggle('scrolled', scrollPos() > 8);
  let timer = 0;
  const onEnd = e => { if(e.target === to && e.animationName === 'fade-in') cleanup(); };
  const cleanup = () => {
    clearTimeout(timer);
    to.removeEventListener('animationend', onEnd);
    if(from){ from.classList.remove('leaving', 'leave-' + mode); from.style.cssText = ''; }
    to.classList.remove('enter-' + mode);
    if(transitionCleanup === cleanup) transitionCleanup = null;
  };
  transitionCleanup = cleanup;
  if(animate){ to.addEventListener('animationend', onEnd); timer = setTimeout(cleanup, 1200); }
  else cleanup();
}

/* ── Вкладки листаются по горизонтали, как в Telegram ─────────────────────
   Порядок — как в нижней панели. Уходящая страница закрепляется fixed на
   своём месте и уезжает в сторону, новая — в потоке, со своей прокруткой,
   въезжает с другой стороны. dx — откуда начать (палец уже сдвинул пару
   страниц), v — скорость отпускания: от неё зависит длительность доводки. */
const TOP_PAGES = ['control', 'lists', 'logs', 'config'];
const SLIDE_EASE = 'cubic-bezier(.2, .8, .2, 1)';
function pageBox(el){
  const r = el.getBoundingClientRect();
  return {top: r.top, left: r.left, width: r.width};
}
function slideDuration(dist, v){
  const W = innerWidth || 1;
  let ms = 300 * Math.min(1, Math.abs(dist) / W) + 40;
  if(v) ms = Math.min(ms, Math.abs(dist) / Math.abs(v) * 1.6);
  return Math.max(140, Math.min(320, ms));
}
function slidePages(from, to, opt){
  const dir = opt.dir, W = innerWidth, dx = opt.dx || 0;
  const box = opt.box || pageBox(from);
  to.classList.remove('peek');
  to.style.cssText = '';
  from.style.cssText = 'position:fixed;top:' + box.top + 'px;left:' + box.left + 'px;width:' + box.width + 'px;transform:translateX(' + dx + 'px)';
  from.classList.add('leaving');
  from.classList.remove('active');
  to.classList.add('active');
  scrollToY(pageScroll[to.dataset.page] || 0);
  $('app-bar').classList.toggle('scrolled', scrollPos() > 8);
  const ms = slideDuration(W - Math.abs(dx), opt.v);
  const timing = {duration: ms, easing: SLIDE_EASE, fill: 'forwards'};
  const a1 = from.animate([{transform: 'translateX(' + dx + 'px)'}, {transform: 'translateX(' + (-dir * W) + 'px)'}], timing);
  const a2 = to.animate([{transform: 'translateX(' + (dx + dir * W) + 'px)'}, {transform: 'none'}], timing);
  const cleanup = () => {
    a1.cancel(); a2.cancel();
    from.classList.remove('leaving');
    from.style.cssText = '';
    if(transitionCleanup === cleanup) transitionCleanup = null;
  };
  transitionCleanup = cleanup;
  a2.onfinish = cleanup;
}

/* Свайп влево-вправо по странице. Вертикальная прокрутка главнее: на
   .content стоит touch-action: pan-y, и браузер сам забирает жест, который
   начался вертикально (тогда приходит pointercancel). Горизонталь
   захватывается при естественном движении пальца вбок, не конфликтуя с
   вертикальной прокруткой и системными жестами. Поле в фокусе, ползунки
   и внутренние горизонтальные списки свайп не трогает. */
const swipe = {st: 0}, pageInited = new Set(['control']);
function swipeBlocked(t){
  if(!t || !t.closest || !t.closest('#content, #nav-bar, #app-bar') || t.closest('.no-swipe')) return true;
  const ed = t.closest('input, textarea, select, [contenteditable="true"]');
  if(ed && (ed === document.activeElement || ed.type === 'range')) return true;
  for(let el = t; el && el.id !== 'content' && el.id !== 'nav-bar' && el.id !== 'app-bar'; el = el.parentElement){
    if(el.classList && el.classList.contains('log-view')) continue;
    if(el.scrollWidth > el.clientWidth + 1){
      const ox = getComputedStyle(el).overflowX;
      if(ox === 'auto' || ox === 'scroll') return true;
    }
  }
  return false;
}
function swipeAllowed(){
  return !PAGE_META[currentPage].child && TOP_PAGES.includes(currentPage) && !openSheetId && !openMenuEntry &&
    !editorCtx && !$('dialog-wrap').classList.contains('open') &&
    !document.documentElement.classList.contains('scroll-locked') && !transitionCleanup &&
    !matchMedia('(prefers-reduced-motion: reduce)').matches && !isAnimationsDisabled();
}
function swipePeek(dir){
  const i = TOP_PAGES.indexOf(currentPage) + dir;
  if(swipe.peek){ swipe.peek.classList.remove('peek'); swipe.peek.style.cssText = ''; swipe.peek = null; }
  swipe.peekDir = dir;
  if(i < 0 || i >= TOP_PAGES.length) return;
  const el = document.querySelector('.page[data-page="' + TOP_PAGES[i] + '"]');
  if(!el) return;
  const b = swipe.box, top = b.top + scrollPos() - (pageScroll[TOP_PAGES[i]] || 0);
  el.style.cssText = 'top:' + top + 'px;left:' + b.left + 'px;width:' + b.width + 'px';
  el.classList.add('peek');
  swipe.peek = el;
  const pg = TOP_PAGES[i];
  if(!pageInited.has(pg)){ pageInited.add(pg); Promise.resolve(PAGE_META[pg].init()).catch(() => {}); }
}
function swipeMove(dx){
  if(!swipe.peek) dx = Math.sign(dx) * Math.min(Math.abs(dx) * .25, 64);
  swipe.dx = dx;
  if(swipe.from) swipe.from.style.transform = 'translateX(' + dx + 'px)';
  if(swipe.peek) swipe.peek.style.transform = 'translateX(' + (dx + swipe.peekDir * innerWidth) + 'px)';
}
function swipeEnd(commit, v){
  const from = swipe.from, peek = swipe.peek, dx = swipe.dx, dir = swipe.peekDir;
  document.body.classList.remove('swiping');
  swipe.st = 0; swipe.from = swipe.peek = null;
  if(commit && peek){
    navigate(peek.dataset.page, {dir, dx, v, box: swipe.box});
    return;
  }
  const timing = {duration: slideDuration(dx), easing: SLIDE_EASE};
  const back = [{transform: 'translateX(' + dx + 'px)'}, {transform: 'none'}];
  if(from){
    from.style.transform = '';
    from.animate(back, timing);
  }
  if(peek){
    const a = peek.animate([{transform: 'translateX(' + (dx + dir * innerWidth) + 'px)'},
                            {transform: 'translateX(' + dir * innerWidth + 'px)'}], timing);
    a.onfinish = () => { if(swipe.peek !== peek){ peek.classList.remove('peek'); peek.style.cssText = ''; } };
  }
}
document.addEventListener('pointerdown', e => {
  if(swipe.st || !e.isPrimary || (e.pointerType === 'mouse' && e.button !== 0)) return;
  if(!swipeAllowed() || swipeBlocked(e.target)) return;
  if(e.pointerType !== 'mouse' && (e.clientX < 10 || e.clientX > innerWidth - 10)) return;
  swipe.st = 1; swipe.id = e.pointerId;
  swipe.x0 = e.clientX; swipe.y0 = e.clientY;
  swipe.trail = [[e.timeStamp, e.clientX]];
});
document.addEventListener('pointermove', e => {
  if(!swipe.st || e.pointerId !== swipe.id) return;
  const dx = e.clientX - swipe.x0, dy = e.clientY - swipe.y0;
  if(swipe.st === 1){
    const adx = Math.abs(dx), ady = Math.abs(dy);
    if(ady > 16 && ady > adx * 1.2){ swipe.st = 0; return; }
    if(adx < 10 || adx < ady * 0.9) return;
    swipe.st = 2;
    swipe.from = document.querySelector('.page.active');
    if(!swipe.from){ swipe.st = 0; return; }
    swipe.box = pageBox(swipe.from);
    swipe.slop = Math.sign(dx) * 10;
    swipe.peekDir = 0;
    document.body.classList.add('swiping');
    document.querySelectorAll('.ripple').forEach(r => r.remove());
  }
  const d = dx - swipe.slop;
  const dir = d < 0 ? 1 : -1;
  if(dir !== swipe.peekDir) swipePeek(dir);
  swipeMove(d);
  swipe.trail.push([e.timeStamp, e.clientX]);
  if(swipe.trail.length > 6) swipe.trail.shift();
});
function swipeRelease(e, cancel){
  if(!swipe.st || e.pointerId !== swipe.id) return;
  if(swipe.st === 1){ swipe.st = 0; return; }
  const tr = swipe.trail, a = tr[0], b = tr[tr.length - 1];
  const v = b[0] > a[0] ? (b[1] - a[1]) / (b[0] - a[0]) : 0;
  const dx = swipe.dx, W = innerWidth || 1;
  const fling = Math.abs(v) > .25 && Math.sign(v) === Math.sign(dx) && Math.abs(dx) > 16;
  const commitDist = Math.max(48, Math.min(W * .22, 120));
  swipeEnd(!cancel && (Math.abs(dx) > commitDist || fling), fling ? v : 0);
  swipe.clickGuard = e.timeStamp + 60;
}
document.addEventListener('click', ev => {
  if(swipe.clickGuard && ev.timeStamp <= swipe.clickGuard){ ev.stopPropagation(); ev.preventDefault(); }
  swipe.clickGuard = 0;
}, true);
document.addEventListener('touchmove', e => { if(swipe.st === 2 && e.cancelable) e.preventDefault(); }, {passive: false});
document.addEventListener('pointerup', e => swipeRelease(e, false));
document.addEventListener('pointercancel', e => swipeRelease(e, true));

/* Данные экрана грузятся после того, как анимация пошла */
function afterTransition(fn){
  if(typeof isAnimationsDisabled === 'function' && isAnimationsDisabled()){ fn(); return; }
  requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(fn, spawnOK ? 0 : 320)));
}
function navigate(page, slide){
  if(page === currentPage){
    if(!PAGE_META[page].child) scroller.scrollTo({top: 0, behavior: (typeof isAnimationsDisabled === 'function' && isAnimationsDisabled()) ? 'auto' : 'smooth'});
    return;
  }
  closeMenu();
  const d0 = pageDepth(currentPage), d1 = pageDepth(page);
  const ti0 = TOP_PAGES.indexOf(currentPage), ti1 = TOP_PAGES.indexOf(page);
  const mode = ti0 >= 0 && ti1 >= 0 ? 'slide' : (d1 > d0 ? 'forward' : (d1 < d0 ? 'back' : 'fade'));
  if(mode === 'slide') slide = Object.assign({dir: ti1 > ti0 ? 1 : -1, dx: 0}, slide);
  pageScroll[currentPage] = scrollPos();
  if(mode === 'forward') delete pageScroll[page];
  currentPage = page;
  if(!PAGE_META[page].child) lastTop = page;
  renderNavBar(page);
  renderAppBar(page, mode !== 'slide');
  showPage(page, mode, slide);
  const target = page;
  afterTransition(() => {
    if(currentPage !== target) return;
    const want = pageScroll[target] || 0, had = scrollPos();
    pageInited.add(target);
    Promise.resolve(PAGE_META[target].init()).then(() => {
      if(currentPage === target && want > had && scrollPos() === had) scrollToY(want);
    }).catch(() => {});
  });
  scheduleSync();
}
function goBack(){
  navigate(PAGE_META[currentPage].parent || lastTop);
}

/* Нажатие на вкладку засчитывается по pointerup */
function bindNavTap(b, go){
  let down = null, handled = 0;
  b.addEventListener('pointerdown', e => { down = {id: e.pointerId, x: e.clientX, y: e.clientY}; });
  b.addEventListener('pointercancel', () => { down = null; });
  b.addEventListener('pointerup', e => {
    const d = down; down = null;
    if(!d || d.id !== e.pointerId || e.button > 0) return;
    if(longGuard && longGuard.el === b) return;
    if(Math.abs(e.clientX - d.x) > 12 || Math.abs(e.clientY - d.y) > 12) return;
    handled = e.timeStamp;
    go();
  });
  b.addEventListener('click', e => {
    const h = handled; handled = 0;
    if(h && e.timeStamp - h < 800) return;
    go();
  });
}
document.querySelectorAll('.nav-dest').forEach(b => bindNavTap(b, () => navigate(b.dataset.page)));

/* ── Быстрые действия: долгое нажатие на вкладку ───────────────────────── */
function goThen(page, fn){
  if(currentPage === page){ fn(); return; }
  navigate(page);
  setTimeout(() => { if(currentPage === page) fn(); }, 420);
}
function prevListMode(){
  const p = store.get('nfq_prev_mode'), cur = S.mode;
  return ['auto', 'list', 'all'].includes(p) && p !== cur ? p : (cur === 'auto' ? 'list' : 'auto');
}
const NAV_QUICK = {
  control: () => [
    {icon: 'restart', label: t('Перезапуск'), onClick: () => goThen('control', restartSvc)},
    S.running
      ? {icon: 'stop', label: t('Остановить'), onClick: () => goThen('control', () => act('stop'))}
      : {icon: 'play', label: t('Запустить'), onClick: () => goThen('control', () => act('start'))},
    {icon: 'tune', label: t('Выбор стратегии'), onClick: () => goThen('control', openStrategySheet)}
  ],
  lists: () => {
    const m = prevListMode();
    return [
      {icon: 'trash', label: t('Очистить auto.list'), onClick: () => goThen('lists', clearAuto)},
      {icon: 'list', label: t('Режим работы: {0}', m), sub: t('сейчас {0}', S.mode || '—'), onClick: () => goThen('lists', () => setMode(m))}
    ];
  },
  logs: () => [
    {icon: 'refresh', label: t('Обновить журнал'), onClick: () => goThen('logs', loadLog)},
    {icon: 'trash', label: t('Очистить'), onClick: () => goThen('logs', clearLogs)}
  ],
  config: () => [
    {icon: 'edit', label: t('Редактировать'), onClick: () => goThen('config', () => openSlideEditor('conf'))},
    {icon: 'upload', label: t('Импортировать'), onClick: () => goThen('config', () => $('impFile').click())},
    {icon: 'share', label: t('Поделиться'), onClick: () => shareFileMenu(document.querySelector('.nav-dest[data-page="config"]'), CONFFILE_PATH)}
  ]
};
document.querySelectorAll('.nav-dest').forEach(b => onLongPress(b, null, () => {
  const f = NAV_QUICK[b.dataset.page];
  if(f) openMenu(b, f(), {scrim: true});
}));

let devMode = store.get('nfq_dev') !== '0';
function toggleDevMode(){
  devMode = !devMode;
  store.set('nfq_dev', devMode ? '1' : '0');
  renderParams(S);
  // force: the incremental path only updates the live switches, and the
  // developer block has to appear or disappear right away
  if(currentPage === 'settings') renderSettings(true);
  toast(devMode ? t('Режим разработчика включён') : t('Режим разработчика выключен'));
}
(function bindSettingsPress(){
  const b = $('settings-btn');
  if(!b) return;
  onLongPress(b, null, toggleDevMode);
  b.addEventListener('click', () => navigate('settings'));
})();
['app-title', 'brand-logo'].forEach(id => {
  const el = $(id);
  if(el) onLongPress(el, null, () => {
    if($('app-bar').classList.contains('top')) toggleDevMode();
  });
});

/* ── Растяжение при упоре в край, как в Android 12+ ─────────────────────── */
const stretch = {el: null, pull: 0, y: 0};
function stretchApply(){
  const el = stretch.el, p = stretch.pull;
  if(!el) return;
  const k = 1 + .06 * (1 - Math.exp(-Math.abs(p) / 450));
  const oy = p > 0 ? 0 : scroller.clientHeight - el.getBoundingClientRect().top;
  el.style.transformOrigin = '50% ' + oy + 'px';
  el.style.transform = 'scaleY(' + k + ')';
  if(currentPage === 'control' && !ptrBusy) p > 0 ? ptrShow(p) : ptrHide();
}

const PTR_PULL = 110;
let ptrBusy = false;
function ptrShow(p){
  const el = $('ptr');
  if(!el) return;
  const k = Math.min(1, p / PTR_PULL);
  el.classList.remove('hide');
  el.style.opacity = k;
  el.style.transform = 'translateY(' + Math.round(k * 24) + 'px) rotate(' + Math.round(k * 270) + 'deg) scale(' + (.6 + .4 * k) + ')';
  el.classList.toggle('ready', k >= 1);
}
function ptrHide(){
  const el = $('ptr');
  if(!el) return;
  el.classList.add('hide');
  el.classList.remove('ready', 'spin');
  el.style.opacity = 0;
  el.style.transform = '';
}
async function refreshStatusPage(){
  if(ptrBusy) return;
  ptrBusy = true;
  const el = $('ptr');
  if(el){
    el.classList.add('spin');
    el.style.transform = 'translateY(24px)';
  }
  try {
    await ctlx(['net-recheck'], 30000);
    await Promise.all([stat(), initStrategySelector()]);
  } finally { ptrBusy = false; ptrHide(); }
}
function stretchRelease(){
  const el = stretch.el, pulled = stretch.pull;
  if(el && currentPage === 'control' && !ptrBusy){
    if(pulled >= PTR_PULL) refreshStatusPage(); else ptrHide();
  }
  stretch.el = null; stretch.pull = 0;
  if(!el || !el.classList.contains('stretch')) return;
  el.classList.add('stretch-release');
  el.style.transform = '';
  const done = () => { el.classList.remove('stretch', 'stretch-release'); el.style.transformOrigin = ''; };
  el.addEventListener('transitionend', done, {once: true});
  setTimeout(done, 500);
}
document.addEventListener('touchstart', e => {
  stretchRelease();
  if(e.touches.length !== 1 || !e.target.closest || !e.target.closest('#content')) return;
  if(openSheetId || editorCtx || transitionCleanup || matchMedia('(prefers-reduced-motion: reduce)').matches || isAnimationsDisabled()) return;
  for(let el = e.target; el && el.id !== 'content'; el = el.parentElement){
    if(el.scrollHeight > el.clientHeight + 1 && /auto|scroll/.test(getComputedStyle(el).overflowY)) return;
  }
  stretch.el = document.querySelector('.page.active');
  stretch.y = e.touches[0].clientY;
  stretch.pull = 0;
}, {passive: true});
document.addEventListener('touchmove', e => {
  const el = stretch.el;
  if(!el || e.touches.length !== 1) return;
  if(swipe.st === 2){ stretchRelease(); return; }
  const y = e.touches[0].clientY, dy = y - stretch.y;
  stretch.y = y;
  const maxY = scroller.scrollHeight - scroller.clientHeight;
  const atTop = scrollPos() <= 0, atBottom = scrollPos() >= maxY - 1;
  let p = stretch.pull;
  if(p > 0 || (p === 0 && dy > 0 && atTop)) p = Math.max(0, p + dy);
  else if(p < 0 || (p === 0 && dy < 0 && atBottom)) p = Math.min(0, p + dy);
  if(p !== 0 && e.cancelable) e.preventDefault();
  if(p === stretch.pull) return;
  stretch.pull = p;
  if(p === 0){
    el.classList.remove('stretch'); el.style.transform = ''; el.style.transformOrigin = '';
    if(currentPage === 'control' && !ptrBusy) ptrHide();
    return;
  }
  el.classList.add('stretch');
  el.classList.remove('stretch-release');
  stretchApply();
}, {passive: false});
document.addEventListener('touchend', e => { if(!e.touches.length) stretchRelease(); }, {passive: true});

const fling = {top: 0, t: 0, v: 0, touching: 0, last: 0};
document.addEventListener('touchstart', e => { fling.touching = e.touches.length; }, {passive: true, capture: true});
document.addEventListener('touchend', e => { fling.touching = e.touches.length; }, {passive: true, capture: true});
document.addEventListener('touchcancel', () => { fling.touching = 0; }, {passive: true, capture: true});
function stretchAbsorb(fromTop, v){
  const el = document.querySelector('.page.active');
  if(!el || stretch.el || transitionCleanup || matchMedia('(prefers-reduced-motion: reduce)').matches || isAnimationsDisabled()) return;
  const k = 1 + Math.min(.05, .012 + Math.abs(v) * .008);
  const oy = fromTop ? 0 : scroller.clientHeight - el.getBoundingClientRect().top;
  el.style.transformOrigin = '50% ' + oy + 'px';
  const a = el.animate([{transform: 'none'}, {transform: 'scaleY(' + k + ')', offset: .3}, {transform: 'none'}],
    {duration: 420, easing: 'cubic-bezier(.2, .8, .3, 1)'});
  a.onfinish = a.oncancel = () => { if(!el.classList.contains('stretch')) el.style.transformOrigin = ''; };
}
scroller.addEventListener('scroll', () => {
  const now = performance.now(), top = scrollPos(), dt = now - fling.t;
  if(dt > 0 && dt < 100) fling.v = .5 * fling.v + .5 * (top - fling.top) / dt;
  else fling.v = 0;
  fling.top = top; fling.t = now;
  if(fling.touching || now - fling.last < 500) return;
  const max = scroller.scrollHeight - scroller.clientHeight;
  if(top <= 0 && fling.v < -.3){ fling.last = now; stretchAbsorb(true, fling.v); }
  else if(top >= max - 1 && fling.v > .3){ fling.last = now; stretchAbsorb(false, fling.v); }
}, {passive: true});
document.addEventListener('touchcancel', stretchRelease, {passive: true});

/* elevation on scroll: surface → surface-container */
scroller.addEventListener('scroll', () => $('app-bar').classList.toggle('scrolled', scrollPos() > 8), {passive: true});

/* ── Modal bottom sheets: один scrim на все листы ──────────────────────── */
let openSheetId = null, sheetReturnFocus = null;
function setBackgroundInert(on){
  if(!('inert' in HTMLElement.prototype)) return;
  ['#content', '.app-bar', '.nav-bar'].forEach(sel => {
    const el = document.querySelector(sel);
    if(el) el.inert = on;
  });
}
function openSheet(id){
  if(openSheetId && openSheetId !== id) closeSheet();
  openSheetId = id;
  const el = $(id);
  sheetReturnFocus = document.activeElement;
  el.tabIndex = -1;
  el.classList.add('open');
  $('sheet-scrim').classList.add('show');
  setBackgroundInert(true);
  setTimeout(() => el.focus({ preventScroll: true }), 60);
  scheduleSync();
}
function closeSheet(){
  if(!openSheetId) return;
  const el = $(openSheetId);
  el.classList.remove('open');
  el.style.transform = '';
  sheetScrimRelease();
  $('sheet-scrim').classList.remove('show');
  setBackgroundInert(false);
  if(sheetReturnFocus && sheetReturnFocus.focus) sheetReturnFocus.focus({ preventScroll: true });
  sheetReturnFocus = null;
  openSheetId = null;
  scheduleSync();
}
function openMonetModal(){ drawThemeUI(); openSheet('monet-modal'); }

/* ── «Назад»: сначала оверлеи, потом дочерний экран, потом домой, потом выход ── */
function handleBack(allowExit){
  if(openMenuEntry){ closeMenu(); return true; }
  if($('dialog-wrap').classList.contains('open')){ dialogResolve(false); return true; }
  if($('editor-panel').classList.contains('open')){
    if(typeof closeEditorSearch === 'function' && !$('editor-search-bar').hidden){ closeEditorSearch(); return true; }
    closeSlideEditor(); return true;
  }
  if(openSheetId){ closeSheet(); return true; }
  if(PAGE_META[currentPage].child){ goBack(); return true; }
  if(allowExit && currentPage !== 'control'){ navigate('control'); return true; }
  return false;
}
/* config.json: backInterceptor = javascript - the manager calls this handler itself */
window.onBackKeyPressed = function(){
  if(handleBack(true)) return;
  try { window.ksu && window.ksu.exit && window.ksu.exit(); } catch(e) {}
};
document.addEventListener('keydown', e => { if(e.key === 'Escape') handleBack(false); });

/* ── Жест «Назад» через историю WebView ────────────────────────────────── */
let histDepth = (history.state && history.state.nfq) || 0, histPending = false, syncTimer = 0;
function uiLayers(){
  let n = pageDepth(currentPage) + (PAGE_META[currentPage].child ? (lastTop !== 'control' ? 1 : 0) : (currentPage !== 'control' ? 1 : 0));
  if(openSheetId) n++;
  if(editorCtx) n++;
  if(editorCtx && $('editor-search-bar') && !$('editor-search-bar').hidden) n++;
  if($('dialog-wrap').classList.contains('open')) n++;
  if(openMenuEntry) n++;
  return n;
}
const canPush = () => !navigator.userActivation || navigator.userActivation.isActive;
function syncHistory(){
  syncTimer = 0;
  updateScrollLock();
  if(histPending) return;
  const layers = uiLayers(), target = layers ? layers + 1 : 0;
  try {
    if(target > histDepth){
      if(!canPush()) return;
      while(histDepth < target) history.pushState({nfq: ++histDepth}, '');
    } else if(target < histDepth){
      histPending = true;
      history.go(target - histDepth);
    }
  } catch(e) { histPending = false; }
}
function scheduleSync(){ if(!syncTimer) syncTimer = setTimeout(syncHistory, 0); }
addEventListener('popstate', e => {
  const d = (e.state && e.state.nfq) || 0;
  if(histPending){ histPending = false; histDepth = d; scheduleSync(); return; }
  const was = histDepth;
  histDepth = d;
  if(d < was) handleBack(true);
  scheduleSync();
});
['pointerdown', 'keydown'].forEach(ev => addEventListener(ev, () => setTimeout(syncHistory, 0), true));

function updateScrollLock(){
  const lock = !!(openSheetId || editorCtx || openMenuEntry || $('dialog-wrap').classList.contains('open'));
  document.documentElement.classList.toggle('scroll-locked', lock);
}

/* adjustResize pushes the fixed nav bar above the keyboard, so hide it while typing */
const isTextInput = el => !!el && (el.tagName === 'TEXTAREA' ||
  (el.tagName === 'INPUT' && !/^(checkbox|radio|range|button|submit|file|color)$/i.test(el.type)));
const vpHeight = () => (window.visualViewport ? visualViewport.height : innerHeight);
let vpBase = vpHeight(), kbPendingUntil = 0;
function updateKeyboard(){
  const h = vpHeight(), focused = isTextInput(document.activeElement);
  if(!focused) vpBase = Math.max(vpBase, h);
  const open = focused && (vpBase - h > 120 || Date.now() < kbPendingUntil);
  document.body.classList.toggle('kb-open', open);
}
document.addEventListener('focusin', e => {
  if(!isTextInput(e.target)) return;
  kbPendingUntil = Date.now() + 700;
  updateKeyboard();
  setTimeout(updateKeyboard, 750);
});
document.addEventListener('focusout', () => setTimeout(updateKeyboard, 60));
(window.visualViewport || window).addEventListener('resize', updateKeyboard);
addEventListener('orientationchange', () => { vpBase = 0; setTimeout(updateKeyboard, 300); });

/* ── Bottom sheet: смахивание вниз за drag handle ───────────────────────── */
function sheetScrimFollow(sheet, dy){
  const sc = $('sheet-scrim');
  if(!sc) return;
  const p = Math.max(0, Math.min(1, 1 - dy / Math.max(1, sheet.offsetHeight)));
  sc.style.transition = 'none';
  sc.style.opacity = p;
}
function sheetScrimRelease(){
  const sc = $('sheet-scrim');
  if(!sc) return;
  sc.style.transition = sc.style.opacity = '';
}
function initSheetDrag(sheet){
  const zone = sheet.querySelector('.sheet-drag');
  if(!zone) return;
  let y0 = null, dy = 0, dragged = false;
  zone.addEventListener('pointerdown', e => {
    y0 = e.clientY; dy = 0; dragged = false;
    sheet.style.transition = 'none';
    zone.setPointerCapture(e.pointerId);
  });
  zone.addEventListener('pointermove', e => {
    if(y0 == null) return;
    dy = Math.max(0, e.clientY - y0);
    if(dy > 4) dragged = true;
    sheet.style.transform = 'translateY(' + dy + 'px)';
    sheetScrimFollow(sheet, dy);
  });
  const end = () => {
    if(y0 == null) return;
    y0 = null;
    sheet.style.transition = '';
    sheetScrimRelease();
    if(dy > Math.min(120, sheet.offsetHeight * .25)) requestAnimationFrame(() => closeSheet());
    else sheet.style.transform = '';
  };
  zone.addEventListener('pointerup', end);
  zone.addEventListener('pointercancel', end);
  zone.addEventListener('click', () => { if(dragged){ dragged = false; return; } closeSheet(); });
}
document.querySelectorAll('.sheet').forEach(initSheetDrag);

/* ── Лист со списком: смахивание вниз с любого места ───────────────────── */
function initSheetSwipe(sheet){
  const list = sheet.querySelector('.sheet-scroll');
  if(!list) return;
  let y0 = 0, lastY = 0, lastT = 0, v = 0, state = '', inList = false;
  sheet.addEventListener('touchstart', e => {
    state = '';
    if(e.touches.length !== 1 || e.target.closest('.sheet-drag')) return;
    if(e.target.closest('.wheel, input[type=range]')) return;
    y0 = lastY = e.touches[0].clientY; lastT = e.timeStamp; v = 0;
    inList = !!e.target.closest('.sheet-scroll');
    state = !inList || list.scrollTop <= 0 ? 'wait' : 'scroll';
  }, {passive: true});
  sheet.addEventListener('touchmove', e => {
    if(!state || state === 'scroll') return;
    const y = e.touches[0].clientY, dy = y - y0;
    if(state === 'wait'){
      if(dy < 0 || (inList && list.scrollTop > 0)){ state = 'scroll'; return; }
      if(e.cancelable) e.preventDefault();
      if(dy < 8) return;
      state = 'drag'; y0 = y; sheet.style.transition = 'none';
    }
    if(e.cancelable) e.preventDefault();
    if(e.timeStamp > lastT){ v = (y - lastY) / (e.timeStamp - lastT); lastY = y; lastT = e.timeStamp; }
    sheet.style.transform = 'translateY(' + Math.max(0, y - y0) + 'px)';
    sheetScrimFollow(sheet, Math.max(0, y - y0));
  }, {passive: false});
  const end = e => {
    if(state !== 'drag'){ state = ''; return; }
    state = '';
    if(e.cancelable) e.preventDefault();
    const dy = Math.max(0, lastY - y0);
    sheet.style.transition = '';
    sheetScrimRelease();
    if(e.type === 'touchend' && (dy > Math.min(120, sheet.offsetHeight * .25) || (v > .5 && dy > 24))) requestAnimationFrame(() => closeSheet());
    else sheet.style.transform = '';
  };
  sheet.addEventListener('touchend', end, {passive: false});
  sheet.addEventListener('touchcancel', end);
}
document.querySelectorAll('.sheet.list-sheet').forEach(initSheetSwipe);
