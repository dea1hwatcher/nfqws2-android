/* nfqws2 WebUI - app filter */

const APP_MODES = [
  ['off', 'Выключен', 'Обрабатывается трафик всех приложений'],
  ['include', 'Только выбранные', 'Трафик остальных приложений идёт напрямую'],
  ['exclude', 'Все, кроме выбранных', 'Выбранные приложения идут напрямую']
];
async function appsInit(){
  renderAppModes();
  if(pkgs.length){
    drawPk();
    // Фоновая проверка: если на устройстве изменились пакеты, обновляем без спиннера
    ctlx(['list-apps']).then(r => {
      if(!r.code && r.out){
        const raw = r.out.trim();
        if(raw.startsWith('[')){
          try {
            const next = JSON.parse(raw);
            if(JSON.stringify(next) !== JSON.stringify(pkgs)){
              pkgs = next;
              drawPk(false);
            }
          } catch(_){}
        }
      }
    });
  } else {
    loadPk();
  }
  await stat(true);
  renderAppModes();
}
function renderAppModes(){
  const cur = S.app_mode || 'off';
  setHTML('amode-list', APP_MODES.map(([v, label, hint]) =>
    '<label class="list-item two-line clickable state' + (v === cur ? ' selected' : '') + '">' +
      '<input type="radio" class="radio" name="amode" value="' + v + '"' + (v === cur ? ' checked' : '') +
        ' onchange="setAppMode(this.value)">' +
      '<span class="li-text"><span class="li-primary">' + esc(t(label)) + '</span><span class="li-secondary">' + esc(t(hint)) + '</span></span>' +
    '</label>').join(''), false);
  const n = (S.counts || {}).apps || 0;
  $('apps-info').textContent = cur === 'off'
    ? t('Фильтр выключен. Выбрано приложений: {0}.', n)
    : t('Фильтр включён. Выбрано приложений: {0}.', n) + (S.app_uids > 0 ? ' ' + t('UID найдено: {0}.', S.app_uids) : '');
}
async function setAppMode(v){
  const r = await withBusy(['set', 'APP_MODE', v], 30000);
  toast(r.code ? errText(r, 'Не удалось сменить режим') : t('Режим фильтра сохранён'));
  await stat();
  renderAppModes();
}
async function loadPk(force){
  clearTimeout(pkTimer); // cancel the deferred repaint from the previous input
  $('pk').innerHTML = '<div class="list-item"><span class="spinner"></span>' +
    '<span class="li-text"><span class="li-secondary">' + esc(t('Загрузка списка приложений…')) + '</span></span></div>';
  $('pk')._html = null;
  const r = force ? await ctlx(['list-apps', 'refresh'], 30000) : await ctlx(['list-apps'], 30000);
  if(r.code){
    if(!pkgs.length) pkgs = [];
    toast(errText(r, 'Не удалось получить список приложений'));
  } else {
    const raw = (r.out || '').trim();
    if(raw.startsWith('[')){
      try {
        pkgs = JSON.parse(raw);
      } catch(_){
        if(!pkgs.length) pkgs = raw.split('\n').map(s => s.trim()).filter(Boolean);
      }
    } else {
      const rawLines = raw.split('\n').map(s => s.trim()).filter(Boolean);
      if(pkgs.length && typeof pkgs[0] === 'object'){
        const known = new Map(pkgs.map(it => [it.pkg, it]));
        pkgs = rawLines.map(p => known.get(p) || p);
      } else {
        pkgs = rawLines;
      }
    }
  }
  await drawPk(true);
}
/* Cached: drawPk() is the search oninput handler and without the cache every keystroke spawned a
      shell. Invalidated after manual edits in the editor */
let appsCache = null;
let appTypeFilter = 'all';

function isAppSystem(item){
  if(typeof item === 'object' && item && typeof item.system === 'boolean') return item.system;
  if(typeof item === 'object' && item && item.system != null) return item.system === true || item.system === 1 || item.system === 'true';
  const p = typeof item === 'string' ? item : (item && item.pkg ? item.pkg : '');
  return p.startsWith('com.android.') || p.startsWith('android') || p.startsWith('com.google.android.packageinstaller') || p.startsWith('com.google.android.gms');
}

function isAppWork(item){
  if(typeof item !== 'object' || !item) return false;
  return !!item.isWork || (item.userId != null && Number(item.userId) > 0);
}

function appKey(item){
  if(typeof item === 'string') return item;
  const uid = (item && item.userId != null) ? Number(item.userId) : 0;
  return uid > 0 ? (uid + ':' + item.pkg) : (item ? item.pkg : '');
}

function isAppSelected(s, item){
  if(!s) return false;
  const p = typeof item === 'string' ? item : (item && item.pkg ? item.pkg : '');
  if(!p) return false;
  if(s.has(p)) return true;
  const uid = (typeof item === 'object' && item && item.userId != null) ? Number(item.userId) : 0;
  if(uid > 0 && s.has(uid + ':' + p)) return true;
  if(uid === 0 && s.has('0:' + p)) return true;
  return false;
}

function setAppTypeFilter(type){
  appTypeFilter = type;
  const wrap = $('pk-filter-chips');
  if(wrap){
    wrap.querySelectorAll('.chip').forEach(c => {
      const on = c.getAttribute('data-type') === type;
      c.classList.toggle('selected', on);
      c.setAttribute('aria-pressed', on ? 'true' : 'false');
    });
  }
  drawPk(false);
}

async function getAppsList(){
  if(appsCache) return appsCache;
  const r = await ctlx(['get-list', 'apps']);
  appsCache = new Set((r.code ? '' : r.out).split('\n').map(s => s.trim()).filter(s => s && s[0] !== '#'));
  return appsCache;
}
/* Debounced: up to 120 rows are rebuilt per keystroke and innerHTML is the expensive part */
let pkTimer = null;
function pkSearchInput(){
  clearTimeout(pkTimer);
  pkTimer = setTimeout(() => drawPk(false), 180);
}
async function drawPk(animate){
  const f = $('pf').value.trim().toLowerCase();
  const s = await getAppsList();
  const hasWork = pkgs.some(isAppWork);
  const workChip = $('pk-chip-work');
  if(workChip) workChip.style.display = hasWork ? '' : 'none';

  const shown = pkgs.filter(item => {
    const p = typeof item === 'string' ? item : (item.pkg || '');
    const n = typeof item === 'string' ? item : (item.name || item.pkg || '');
    const matchSearch = !f || p.toLowerCase().includes(f) || n.toLowerCase().includes(f);
    if(!matchSearch) return false;
    if(appTypeFilter === 'all') return true;
    if(appTypeFilter === 'selected') return isAppSelected(s, item);
    const isSys = isAppSystem(item);
    if(appTypeFilter === 'system') return isSys;
    if(appTypeFilter === 'user') return !isSys;
    if(appTypeFilter === 'work') return isAppWork(item);
    return true;
  });
  shown.sort((a, b) => {
    const sa = isAppSelected(s, a) ? 1 : 0;
    const sb = isAppSelected(s, b) ? 1 : 0;
    if(sa !== sb) return sb - sa;
    const na = typeof a === 'string' ? a : (a.name || a.pkg || '');
    const nb = typeof b === 'string' ? b : (b.name || b.pkg || '');
    const c = na.localeCompare(nb, undefined, { sensitivity: 'base' });
    if(c !== 0) return c;
    const ua = (typeof a === 'object' && a && a.userId != null) ? Number(a.userId) : 0;
    const ub = (typeof b === 'object' && b && b.userId != null) ? Number(b.userId) : 0;
    return ua - ub;
  });
  $('pk-count').textContent = t('Найдено {0} из {1}, выбрано {2}', shown.length, pkgs.length, s.size) +
    (shown.length > 120 ? '. ' + t('Показаны первые 120, уточните поиск') : '');
  const slice = shown.slice(0, 120);
  setHTML('pk', slice.map((item, idx) => {
    const p = typeof item === 'string' ? item : item.pkg;
    const name = typeof item === 'string' ? item : (item.name || item.pkg);
    const icon = typeof item === 'object' && item && item.icon ? item.icon : '';
    const isSys = isAppSystem(item);
    const isWork = isAppWork(item);
    const uName = (typeof item === 'object' && item && item.userName) ? item.userName : '';
    const sysBadge = isSys ? ' · ' + esc(t('Системное')) : '';
    const workBadge = isWork ? ' · 💼 ' + esc(uName || t('Рабочий профиль')) : '';
    const sel = isAppSelected(s, item);
    const key = appKey(item);
    let selCls = '';
    if(sel){
      const prev = idx > 0 && isAppSelected(s, slice[idx - 1]);
      const next = idx < slice.length - 1 && isAppSelected(s, slice[idx + 1]);
      if(!prev && !next) selCls = ' sel-single';
      else if(!prev && next) selCls = ' sel-first';
      else if(prev && next) selCls = ' sel-mid';
      else selCls = ' sel-last';
    }
    const iconHtml = icon
      ? '<img class="app-ico" src="' + esc(icon) + '" alt="" loading="lazy">'
      : '<span class="app-ico-fallback"><svg class="icon s24" aria-hidden="true"><use href="#i-apps"/></svg></span>';
    return '<label class="list-item two-line clickable state' + (sel ? ' selected' + selCls : '') + '">' +
      '<span class="li-icon plain app-ico-cell">' + iconHtml + '</span>' +
      '<span class="li-text">' +
        '<span class="li-primary">' + esc(name) + '</span>' +
        '<span class="li-secondary li-mono">' + esc(p) + sysBadge + workBadge + '</span>' +
      '</span>' +
      '<span class="li-trail">' +
        '<input type="checkbox" class="checkbox" data-key="' + esc(key) + '" data-pkg="' + esc(p) + '"' + (sel ? ' checked' : '') + '>' +
      '</span>' +
    '</label>';
  }).join('') ||
    '<div class="list-item"><span class="li-text"><span class="li-secondary">' + esc(t('Ничего не найдено')) + '</span></span></div>', !!animate);
  $('pk').querySelectorAll('input[data-key]').forEach(cb => {
    cb.onchange = () => togglePkgKey(cb.getAttribute('data-key'), cb.getAttribute('data-pkg'), cb.checked);
  });
}
async function togglePkgKey(key, p, want){
  const s = await getAppsList();
  if(want){
    s.add(key);
  } else {
    s.delete(key);
    if(s.has(p)){
      s.delete(p);
      pkgs.forEach(other => {
        if(typeof other === 'object' && other && other.pkg === p){
          const k = appKey(other);
          if(k !== key) s.add(k);
        }
      });
    }
    if(key.startsWith('0:')) s.delete(p);
    if(key === p) s.delete('0:' + p);
  }
  const r = await withBusy(['save-list-b64', 'apps', b64([...s].join('\n'))], 30000);
  if(r.code) toast(errText(r, 'Не удалось сохранить'), {label: t('Повторить'), fn: () => togglePkgKey(key, p, want)});
  else toast((want ? t('Добавлено: {0}', key) : t('Убрано: {0}', key)));
  await drawPk(false);
  await stat(true);
  renderAppModes();
}
function togglePkg(p, want){
  return togglePkgKey(p, p, want);
}
