/* nfqws2 WebUI - status screen and strategy selection */

/* Uptime */
let uptTimer = null;
function fmtUptime(sec){
  sec = Math.max(0, Math.floor(Number(sec) || 0));
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  const s = sec % 60;
  const p = n => String(n).padStart(2, '0');
  return p(h) + ':' + p(m) + ':' + p(s);
}
let uptAnchor = null;   // {ms: uptime_ms, t: performance.now() anchor}
function uptElapsedMs(){ return uptAnchor ? uptAnchor.ms + (performance.now() - uptAnchor.t) : 0; }
function stopUptTimer(){
  if(uptTimer){ clearTimeout(uptTimer); uptTimer = null; }
  uptAnchor = null;
  $('upt').textContent = '—';
}
function uptTick(){
  if(!uptAnchor) return;
  const ms = uptElapsedMs();
  $('upt').textContent = fmtUptime(ms / 1000);
  uptTimer = setTimeout(uptTick, 1000 - (ms % 1000) + 10);
}
function startUptTimer(ms){
  ms = Math.max(0, ms);
  if(uptAnchor && Math.abs(uptElapsedMs() - ms) < 2000) return;
  uptAnchor = {ms, t: performance.now()};
  if(uptTimer) clearTimeout(uptTimer);
  uptTick();
}

/* Strategies carry no descriptions: what works depends on provider and region. Grouped by origin */
let strategies = [{name: 'default', kind: 'builtin', mod: false}], currentStrategy = 'default', pendingStrategy = 'default';
const STRATEGY_GROUPS = [
  ['base', 'Базовая'], ['alt', 'Flowseal · ALT'], ['fake', 'Flowseal · FAKE TLS AUTO'],
  ['simple', 'Flowseal · SIMPLE FAKE'], ['turkey', 'Турция'], ['authors', 'Авторские'], ['user', 'Пользовательские']
];
function strategyGroup(s){
  if(s.kind === 'import' || s.kind === 'user') return 'user';
  if(s.name === 'default') return 'base';
  if(/^alt\d*(_|$)/i.test(s.name)) return 'alt';
  if(/^fake_tls_auto/i.test(s.name)) return 'fake';
  if(/^simple_fake/i.test(s.name)) return 'simple';
  if(/^tr_/i.test(s.name)) return 'turkey';
  return 'authors';
}
const groupTitle = g => t((STRATEGY_GROUPS.find(x => x[0] === g) || ['', ''])[1]);
const strategyName = s => s === 'default' ? t('По умолчанию') : s === 'smart' ? t('Умный режим') : String(s).replace(/^imp:/, '');
const findStrategy = n => strategies.find(s => s.name === n);

async function loadStrategies(){
  const r = await ctlx(['list-strategies']);
  const list = r.code ? [] : r.out.split('\n').filter(Boolean).map(l => {
    const p = l.split('\t');
    return {name: p[0], kind: p[1] || 'builtin', mod: p[2] === '1'};
  });
  strategies = [{name: 'default', kind: 'builtin', mod: false}].concat(list.filter(s => s.name !== 'default'));
}
async function initStrategySelector(){
  const r2 = await ctlx(['get-strategy']);
  currentStrategy = (!r2.code && r2.out.trim()) || 'default';
  await loadStrategies();
  renderStrategyRow();
}
function renderStrategyRow(){
  const s = findStrategy(currentStrategy) || {name: currentStrategy, kind: /^imp:/.test(currentStrategy) ? 'import' : 'builtin'};
  $('strategy-current').textContent = strategyName(currentStrategy);
  $('strategy-group').textContent = groupTitle(strategyGroup(s)) + (s.mod ? ' · ' + t('изменена') : '');
}
function strategyItem(s){
  const sel = s.name === pendingStrategy;
  return '<label class="list-item clickable state' + (sel ? ' selected' : '') + '">' +
    '<input type="radio" class="radio" name="strategy" value="' + esc(s.name) + '"' + (sel ? ' checked' : '') + '>' +
    '<span class="li-text"><span class="li-primary truncate">' + esc(strategyName(s.name)) + '</span>' +
      (s.mod || s.kind === 'import' || s.name === currentStrategy ? '<span class="li-tags">' +
        (s.name === currentStrategy ? '<span class="pill">' + esc(t('Текущая')) + '</span>' : '') +
        (s.mod ? '<span class="pill tonal">' + esc(t('Изменена')) + '</span>' : '') +
        (s.kind === 'import' ? '<span class="pill tonal">' + esc(t('Импорт')) + '</span>' : '') + '</span>' : '') +
    '</span>' +
    '<span class="li-trail li-actions">' +
      (s.mod ? '<button type="button" class="icon-btn sm state" data-act="reset" data-s="' + esc(s.name) + '"' +
        ' aria-label="' + esc(t('Сбросить «{0}» к исходнику', strategyName(s.name))) + '" title="' + esc(t('Сбросить к исходнику')) + '">' +
        icon('restart', 's20') + '</button>' : '') +
      (s.name !== 'default' ? '<button type="button" class="icon-btn sm state" data-act="edit" data-s="' + esc(s.name) + '"' +
        ' aria-label="' + esc(t('Редактировать «{0}»', strategyName(s.name))) + '" title="' + esc(t('Редактировать')) + '">' +
        icon('edit', 's20') + '</button>' : '') +
    '</span></label>';
}
function renderStrategyList(animate){
  const cmp = (a, b) => a.name.localeCompare(b.name, undefined, {numeric: true, sensitivity: 'base'});
  const html = STRATEGY_GROUPS.map(([g]) => {
    const items = strategies.filter(s => strategyGroup(s) === g).sort(cmp);
    if(!items.length) return '';
    return '<div class="sheet-group" role="presentation">' + esc(groupTitle(g)) + '</div>' +
      '<div class="list">' + items.map(strategyItem).join('') + '</div>';
  }).join('');
  const box = $('strategy-list');
  box.innerHTML = html;
  if(animate){ box.classList.remove('appear'); void box.offsetWidth; box.classList.add('appear'); }
  box.querySelectorAll('input.radio').forEach(r => {
    r.onchange = () => {
      pendingStrategy = r.value;
      box.querySelectorAll('.list-item').forEach(li => li.classList.toggle('selected', li.querySelector('input').value === pendingStrategy));
    };
  });
  box.querySelectorAll('button[data-act]').forEach(b => {
    b.onclick = e => {
      e.preventDefault(); e.stopPropagation();
      if(b.dataset.act === 'edit') editStrategy(b.dataset.s);
      else resetStrategy(b.dataset.s);
    };
  });
}
async function openStrategySheet(){
  pendingStrategy = currentStrategy;
  renderStrategyList(false);
  $('strategy-apply').innerHTML = icon('check', 's18') + esc(S.running ? t('Применить и перезапустить') : t('Применить'));
  openSheet('strategy-sheet');
  const list = $('strategy-list'), sel = list.querySelector('.selected');
  if(sel) list.scrollTop = sel.offsetTop - list.offsetTop - (list.clientHeight - sel.offsetHeight) / 2;
  await loadStrategies();
  if(openSheetId === 'strategy-sheet'){
    const top = list.scrollTop;
    renderStrategyList(false);
    list.scrollTop = top;
  }
}
async function applySelectedStrategy(){
  const val = pendingStrategy;
  closeSheet();
  await applyStrategy(val);
}
async function applyStrategy(val){
  const r = await withBusy(['set-strategy', val]);
  if(r.code){ toast(errText(r, 'Не удалось применить стратегию')); return; }
  currentStrategy = val;
  renderStrategyRow();
  if(S.running) await act('restart');
  else { toast(t('Стратегия «{0}» применится при следующем запуске', strategyName(val))); stat(); }
  if(val === 'smart' && currentPage !== 'smart') smartOffer();
}
function editStrategy(name){
  openEditorWith({target: 'strategy', key: name, title: strategyName(name) + '.conf', lang: 'conf', b64: true,
    hint: t('Правка сохраняется отдельно от встроенной стратегии: исходник можно вернуть кнопкой сброса.'),
    load: ['strategy-get-b64', name]});
}
async function resetStrategy(name){
  if(!await mdConfirm(t('Сбросить «{0}»?', strategyName(name)),
    t('Ваши правки стратегии будут удалены, вернётся версия из релиза.'), {ok: t('Сбросить'), danger: true})) return;
  const r = await withBusy(['strategy-reset', name]);
  if(r.code){ toast(errText(r, 'Не удалось сбросить')); return; }
  await loadStrategies();
  renderStrategyRow();
  if(openSheetId === 'strategy-sheet') renderStrategyList(true);
  toast(t('Стратегия «{0}» сброшена', strategyName(name)),
    name === currentStrategy ? {label: t('Применить'), fn: () => applyStrategy(name)} : null);
}

let currentStratTab = 'presets';
let currentCatalogCategory = 'tcp_tls';

function switchStratTab(tab){
  currentStratTab = tab;
  const isPresets = tab === 'presets';
  const tabPre = $('strat-tab-presets'), tabCat = $('strat-tab-catalogs');
  if(tabPre) tabPre.classList.toggle('on', isPresets);
  if(tabCat) tabCat.classList.toggle('on', !isPresets);
  const vPre = $('strat-presets-view'), vCat = $('strat-catalogs-view');
  if(vPre) vPre.hidden = !isPresets;
  if(vCat) vCat.hidden = isPresets;
  if(!isPresets){
    loadCatalogCategory(currentCatalogCategory);
  }
}

async function selectCatalogCategory(cat){
  currentCatalogCategory = cat;
  document.querySelectorAll('#cat-chips .chip').forEach(ch => {
    const sel = ch.dataset.cat === cat;
    ch.classList.toggle('selected', sel);
    ch.setAttribute('aria-pressed', sel ? 'true' : 'false');
  });
  await loadCatalogCategory(cat);
}

async function loadCatalogCategory(cat){
  const box = $('catalog-list');
  if(!box) return;
  box.innerHTML = '<div class="list-item"><span class="spinner"></span><span class="li-text"><span class="li-secondary">' + esc(t('Загрузка каталога…')) + '</span></span></div>';
  const r = await ctlx(['get-catalog', cat]);
  if(r.code !== 0 || !r.out){
    box.innerHTML = '<div class="empty"><span class="empty-title">' + esc(t('Каталог пуст')) + '</span></div>';
    return;
  }
  const lines = r.out.trim().split('\n').filter(Boolean);
  box.innerHTML = lines.map(line => {
    const tabIdx = line.indexOf('\t');
    const idx = tabIdx !== -1 ? line.slice(0, tabIdx) : '';
    const text = tabIdx !== -1 ? line.slice(tabIdx + 1) : line;
    return '<div class="list-item two-line" style="align-items:flex-start;padding:10px 16px;">' +
      '<span class="li-text" style="gap:4px;">' +
        '<span class="li-primary t-label-large">#' + esc(idx) + '</span>' +
        '<div class="li-mono" style="font-size:11px;line-height:1.4;word-break:break-all;color:var(--md-sys-color-on-surface-variant);">' + esc(text) + '</div>' +
      '</span>' +
      '<span class="li-trail" style="align-self:center;">' +
        '<button class="btn sm tonal with-icon state" onclick="applyCatalogModule(' + jsArg(cat) + ', ' + jsArg(idx) + ')">' +
          icon('check', 's16') + '<span>' + esc(t('Подменить')) + '</span>' +
        '</button>' +
      '</span>' +
    '</div>';
  }).join('');
}

async function applyCatalogModule(cat, idx){
  if(!await mdConfirm(t('Подменить модуль в пресете?'), t('Выбранный десинхронизатор заменит блок {0} в nfqws2.conf. Прежний конфиг сохранится в архив.', cat), t('Подменить'))) return;
  const r = await withBusy(['catalog-apply-module', cat, String(idx)]);
  if(r.code === 0){
    toast(t('Модуль успешно подменён в действующем пресете'));
    closeSheet();
    stat(true);
  } else {
    toast(errText(r, 'Не удалось подменить модуль'));
  }
}

async function rollbackStrategy(){
  if(!await mdConfirm(t('Откатить к предыдущей рабочей конфигурации?'), t('Откат восстановит настройки из рабочего снимка и перезапустит службу.'), t('Откатить'))) return;
  const r = await withBusy(['rollback']);
  if(r.code === 0){
    toast(t('Конфигурация успешно откатана'));
    closeSheet();
    await stat(true);
    await loadStrategies();
  } else {
    toast(t('Не удалось выполнить откат'));
  }
}

async function openReplacedSheet(){
  openSheet('replaced-sheet');
  const box = $('replaced-list');
  if(!box) return;
  box.innerHTML = '<div class="list-item"><span class="spinner"></span><span class="li-text"><span class="li-secondary">' + esc(t('Загрузка архива…')) + '</span></span></div>';
  const r = await ctlx(['list-replaced-strategies']);
  if(r.code !== 0 || !r.out || !r.out.trim()){
    box.innerHTML = '<div class="empty"><span class="empty-title">' + esc(t('Архив пуст')) + '</span></div>';
    return;
  }
  const lines = r.out.trim().split('\n').filter(Boolean);
  box.innerHTML = lines.map(line => {
    const parts = line.split('\t');
    const name = parts[0] || '';
    const dt = parts[1] || '—';
    const sz = parts[2] || '';
    return '<div class="list-item two-line">' +
      '<span class="li-icon plain">' + icon('file', 's24') + '</span>' +
      '<span class="li-text">' +
        '<span class="li-primary truncate">' + esc(name) + '</span>' +
        '<span class="li-secondary">' + esc(dt) + (sz ? ' · ' + esc(sz) + ' B' : '') + '</span>' +
      '</span>' +
      '<span class="li-trail">' +
        '<button class="btn sm tonal with-icon state" onclick="restoreReplacedStrategy(' + jsArg(name) + ')">' +
          icon('restart', 's16') + '<span>' + esc(t('Восстановить')) + '</span>' +
        '</button>' +
      '</span>' +
    '</div>';
  }).join('');
}

async function restoreReplacedStrategy(name){
  if(!await mdConfirm(t('Восстановить пресет «{0}»?', name), t('Текущая конфигурация будет заменена.'), t('Восстановить'))) return;
  const r = await withBusy(['restore-replaced-strategy', name]);
  if(r.code === 0){
    toast(t('Пресет восстановлен'));
    closeSheet();
    stat(true);
  } else {
    toast(errText(r, 'Не удалось восстановить'));
  }
}

async function openStealthSheet(){
  openSheet('stealth-sheet');
  const box = $('stealth-sheet-body');
  if(!box) return;
  const st = (S && S.stealth) || { mode: 'none', detail: '' };
  const mode = st.mode || 'none';
  const detail = st.detail || '';

  let modeTitle = t('Базовый (без сокрытия)');
  let modeDesc = t('Модуль смонтирован в штатном режиме. Точки монтирования видны приложениям с проверками рут-доступа.');

  if(mode === 'susfs'){
    modeTitle = 'SuSFS ' + (detail ? '(' + detail + ')' : '');
    modeDesc = t('Ядро с поддержкой SuSFS автоматически скрывает каталог модуля (/data/adb/modules/nfqws2-android), размонтирует обёртки /system/bin и подменяет метаданные kstat для изолированных приложений.');
  } else if(mode === 'ksud'){
    modeTitle = 'KernelSU (ksud kernel umount)';
    modeDesc = t('Ядро KernelSU 22106+ через ksud выполняет автоматическое размонтирование /system/bin и каталогов модуля из пространств имён изолированных приложений.');
  } else if(mode === 'denylist'){
    modeTitle = 'Denylist ' + (detail ? '(' + detail + ')' : '');
    modeDesc = t('Обнаружен активный обработчик списка Denylist ({0}), выполняющий скрытие модулей из процессов с проверкой рут-доступа.', detail || t('перехватчик'));
  }

  const layers = [
    {
      name: t('SELinux Context Matching'),
      desc: t('Клонирование контекста /system/bin/sh на бинарные обёртки модуля'),
      active: true
    },
    {
      name: t('Root CLI Path Independence'),
      desc: t('Безопасные символические ссылки в tmpfs (/data/adb/ksu/bin, /sbin) для сохранения доступа root'),
      active: true
    },
    {
      name: (mode === 'susfs') ? t('SuSFS Path & Mount Spoofing') : (mode === 'ksud' ? t('Kernel Namespace Umount') : t('Zygisk Denylist Handler')),
      desc: (mode === 'susfs') ? t('Скрытие путей модуля и подмена kstat от обнаружения банками и Native Detector') :
            (mode === 'ksud' ? t('Изоляция монтирований ядра от непривилегированных процессов') :
            (mode === 'denylist' ? t('Перехват монтирований для приложений из списка запрета') :
            t('Автоматическое сокрытие точек монтирования недоступно в текущем ядре'))),
      active: (mode !== 'none')
    }
  ];

  let h = '';
  h += '<div class="stealth-mode-card">';
  h += (mode !== 'none')
    ? '<div class="stealth-mode-badge ok">'
    : '<div class="stealth-mode-badge neutral">';
  h += '  <svg aria-hidden="true" class="icon s16"><use href="#i-shield"/></svg>';
  h += '  <span>' + esc(modeTitle) + '</span>';
  h += '</div>';
  h += '<div style="font-size:var(--ts-body-medium);line-height:var(--lh-body-medium);color:var(--md-sys-color-on-surface);">' + esc(modeDesc) + '</div>';
  h += '</div>';

  h += '<div class="stealth-section-title">' + esc(t('Активные уровни защиты')) + '</div>';
  for(const l of layers){
    h += '<div class="stealth-layer-item">';
    h += '  <div class="stealth-layer-icon" style="' + (l.active ? '' : 'color:var(--md-sys-color-outline);') + '">';
    h += '    <svg aria-hidden="true" class="icon s20"><use href="#' + (l.active ? 'i-check' : 'i-close') + '"/></svg>';
    h += '  </div>';
    h += '  <div class="stealth-layer-content">';
    h += '    <div class="stealth-layer-name">' + esc(l.name) + '</div>';
    h += '    <div class="stealth-layer-desc">' + esc(l.desc) + '</div>';
    h += '  </div>';
    h += '</div>';
  }

  h += '<div class="stealth-section-title">' + esc(t('Режимы сокрытия Bindhosts')) + '</div>';
  h += '<div style="font-size:var(--ts-body-small);color:var(--md-sys-color-on-surface-variant);line-height:var(--lh-body-small);display:flex;flex-direction:column;gap:6px;">';
  h += '  <div><strong>Mode 1 (SuSFS):</strong> ' + esc(t('Максимальный уровень: защита на уровне ядра против Momo, банков и Play Integrity.')) + '</div>';
  h += '  <div><strong>Mode 10 (KernelSU):</strong> ' + esc(t('Встроенная изоляция KernelSU 22106+ без сторонних патчей ядра.')) + '</div>';
  h += '  <div><strong>Mode 2 (Denylist):</strong> ' + esc(t('Пользовательский перехватчик Denylist для Magisk/KernelSU/APatch.')) + '</div>';
  h += '</div>';

  box.innerHTML = h;
}

async function reapplyStealth(){
  const r = await withBusy(['stealth']);
  if(r.code === 0){
    toast(t('Скрытие успешно применено'));
    await stat(true);
    if(openSheetId === 'stealth-sheet') openStealthSheet();
  } else {
    toast(errText(r, 'Не удалось применить скрытие'));
  }
}

/* Status */

/* Toggle rows stay single-line; service switches live in the developer block */
const SW = [
  ['AUTOSTART', 'Автозапуск при загрузке', 'autostart'],
  ['IPV6_ENABLED', 'Обрабатывать IPv6', 'ipv6'],
  ['BLOCK_QUIC', 'Блокировать QUIC', 'block_quic'],
  ['ENABLE_HOTSPOT', 'Точка доступа с nfqws2', 'enable_hotspot']
];
const DEV_SW = [
  ['WATCHDOG', 'Watchdog', 'watchdog'],
  ['META_QUIC_REJECT', 'Отказ QUIC для Instagram', 'meta_quic'],
  ['CALLS_BYPASS', 'Обход звонков (не тестировалось)', 'calls_bypass'],
  ['TCP_MSS_CLAMP', 'Занижать TCP MSS (536)', 'tcp_mss_clamp'],
  ['WL_PAUSE', 'Отключать при белых списках', 'wl_pause'],
  ['WAKELOCK', 'Wakelock', 'wakelock_on']
];
const LIMITS = [
  ['PKT_LIMIT_OUT', 'Исходящие пакеты', 'pkt_limit_out'],
  ['PKT_LIMIT_IN', 'Входящие пакеты', 'pkt_limit_in']
];

function banner(kind, ic, text){
  return '<div class="banner' + (kind ? ' ' + kind : '') + '">' + icon(ic) +
    '<span class="grow">' + esc(text) + '</span></div>';
}

let svcBusy = '';
function renderHeroActions(){
  const run = !!S.running, bt = $('bt'), rs = $('bt-restart');
  const busyLabel = {start: t('Запуск…'), stop: t('Остановка…'), restart: t('Перезапуск…'), 'home-pause': t('Пауза…')}[svcBusy];
  bt.disabled = !!svcBusy;
  bt.classList.toggle('with-icon', !!svcBusy);
  bt.innerHTML = busyLabel
    ? '<span class="spinner"></span><span>' + esc(busyLabel) + '</span>'
    : '<span>' + esc(run ? t('Остановить') : t('Запустить')) + '</span>';
  rs.hidden = !run || !!svcBusy;
  const pBtn = $('bt-pause');
  if(pBtn) pBtn.hidden = !run || !!svcBusy || !S.home_override;
}

function switchRow(k, label, on){
  const sid = 'sw-' + k.toLowerCase().replace(/_/g, '-');
  return '<label class="list-item clickable state">' +
    '<span class="li-text"><span class="li-primary">' + esc(t(label)) + '</span></span>' +
    '<span class="li-trail"><input type="checkbox" id="' + sid + '" class="switch" role="switch" aria-label="' + esc(t(label)) + '"' +
      (on ? ' checked' : '') + ' onchange="setp(' + jsArg(k) + ', this.checked ? 1 : 0)"></span>' +
  '</label>';
}
function renderDevRows(j){
  j = j || {};
  const lim = LIMITS.map(([k, label, jk]) =>
    '<div class="list-item clickable state" role="button" tabindex="0" aria-haspopup="dialog"' +
      // the value is read in editLimit() at click time: the incremental render
      // refreshes the row text, and a value baked into onclick would go stale
      ' onclick="editLimit(' + jsArg(k) + ', ' + jsArg(t(label)) + ', ' + jsArg(jk) + ')">' +
      '<span class="li-text"><span class="li-primary">' + esc(t(label)) + '</span></span>' +
      '<span class="li-trail">' +
        '<span class="li-value">' + esc(j[jk] != null ? j[jk] : '—') + '</span>' + icon('chevron-right', 's24') +
      '</span>' +
    '</div>');
  return DEV_SW.map(([k, label, jk]) => switchRow(k, label, j[jk] == 1)).concat(lim).join('');
}
function renderParams(j, force){
  j = j || {};
  const swContainer = $('sws');
  if(swContainer){
    const firstSw = $('sw-' + SW[0][0].toLowerCase().replace(/_/g, '-'));
    if(!force && firstSw && swContainer.children && swContainer.children.length === SW.length){
      for(const [k, label, jk] of SW){
        const el = $('sw-' + k.toLowerCase().replace(/_/g, '-'));
        if(el){
          const on = (j[jk] == 1);
          if(el.checked !== on) el.checked = on;
        }
      }
    } else {
      setHTML('sws', SW.map(([k, label, jk]) => switchRow(k, label, j[jk] == 1)).join(''), false);
    }
  }

  if($('dev-sws') && devMode){
    const devContainer = $('dev-sws');
    const firstDevSw = $('sw-' + DEV_SW[0][0].toLowerCase().replace(/_/g, '-'));
    if(!force && firstDevSw && devContainer.children && devContainer.children.length === (DEV_SW.length + LIMITS.length)){
      for(const [k, label, jk] of DEV_SW){
        const el = $('sw-' + k.toLowerCase().replace(/_/g, '-'));
        if(el){
          const on = (j[jk] == 1);
          if(el.checked !== on) el.checked = on;
        }
      }
      const vals = devContainer.querySelectorAll('.li-value');
      if(vals && vals.length === LIMITS.length){
        LIMITS.forEach(([k, label, jk], idx) => {
          const v = j[jk] != null ? j[jk] : '—';
          if(vals[idx].textContent !== String(v)) vals[idx].textContent = v;
        });
      }
    } else {
      setHTML('dev-sws', renderDevRows(j), false);
    }
  }
  if($('dev-block')) $('dev-block').hidden = !devMode;
}

/* Paint from the last known status so the screen is never blank */
function renderStatus(force){
  const j = S;
  if(!j || j.running == null){
    if($('stealth-mode')) $('stealth-mode').textContent = t('Скрытие: —');
    if($('stealth-pill')) $('stealth-pill').classList.remove('active');
    renderHeroActions(); renderParams({}, force); return;
  }
  const paused = !j.running && !!j.paused;
  if(j.strategy) currentStrategy = j.strategy;
  $('hero-status').className = 'hero' + (j.running ? ' running' : (paused ? ' paused' : ''));
  $('st').textContent = j.running ? t('Служба работает') : (paused ? t('Пауза') : t('Служба остановлена'));
  const limiter = j.limiter;
  $('sub').textContent = paused
    ? (j.paused === '@vpn' || j.paused === 'vpn'
        ? t('Активен VPN. Обход возобновится при отключении VPN.')
        : t('Домашняя Wi‑Fi «{0}». Обход возобновится, когда телефон уйдёт из этой сети.', j.paused))
    : '';
  $('queue-num').textContent = j.running ? (j.queue || '—') : '—';
  const qd = $('qdrop-num');
  qd.textContent = j.running ? (j.qdrop || 0) : '—';
  qd.classList.toggle('bad', j.running && j.qdrop > 0);
  if(j.running) startUptTimer(j.uptime_ms != null ? j.uptime_ms : (j.uptime || 0) * 1000); else stopUptTimer();
  renderHeroActions();
  renderParams(j, force);
  $('dbg').checked = (j.log_level == 1);

  const rbBtn = $('btn-rollback');
  if(rbBtn) rbBtn.hidden = !(j.has_rollback == 1);

  const st = (j && j.stealth) || { mode: 'none', detail: '' };
  const smode = st.mode || 'none';
  const pill = $('stealth-pill');
  const lbl = $('stealth-mode');
  if(pill && lbl){
    const isAct = (smode !== 'none');
    pill.classList.toggle('active', isAct);
    let title = t('Базовый');
    if(smode === 'susfs') title = 'SuSFS';
    else if(smode === 'ksud') title = 'KernelSU';
    else if(smode === 'denylist') title = st.detail ? 'Denylist (' + st.detail + ')' : 'Denylist';
    lbl.textContent = t('Скрытие: {0}', title);
  }

  let w = '';
  if(j.qdrop > 0) w += banner('danger', 'warn', t('Ядро сбросило {0} пакетов: nfqws2 не успевает обрабатывать очередь {1}.', j.qdrop, j.queue));
  if(j.log_level == 1) w += banner('', 'info', t('Включён подробный журнал отладки: обработка заметно медленнее.'));
  setHTML('warn', w, false);
}

let statPending = null;
async function stat(quiet){
  if(statPending) return statPending;
  statPending = (async () => {
    if(!quiet) busy(true);
    const raw = await ctl(['json-status']);
    if(!quiet) busy(false);
    let j = null, a = raw.indexOf('{'), b = raw.lastIndexOf('}');
    if(a >= 0 && b > a){ try { j = JSON.parse(raw.slice(a, b + 1)); } catch(e) {} }
    if(!j){
      if(quiet) return;
      $('hero-status').className = 'hero offline';
      $('st').textContent = t('Нет связи с модулем');
      $('sub').textContent = t('Проверьте root-доступ и наличие {0}', CTL);
      if($('stealth-mode')) $('stealth-mode').textContent = t('Скрытие: —');
      if($('stealth-pill')) $('stealth-pill').classList.remove('active');
      $('queue-num').textContent = '—';
      $('qdrop-num').textContent = '—';
      stopUptTimer();
      renderHeroActions();
      setHTML('warn', banner('danger', 'error', 'json-status: ' + (raw.trim() || t('(пустой ответ)')).slice(0, 200)), false);
      return;
    }
    S = j;
    renderStatus();
    if(currentPage === 'lists'){ renderMode(); renderListFiles(); }
  })();
  try { return await statPending; } finally { statPending = null; }
}

/* Quiet auto-refresh while the screen is visible, skipped while busy */
const POLL_PAGES = {control: 1, lists: 1};
const statusPollTimer = setInterval(() => {
  if(document.visibilityState !== 'visible' || !POLL_PAGES[currentPage]) return;
  if(busyCount || svcBusy || editorCtx || openSheetId) return;
  stat(true);
}, 5000);
document.addEventListener('visibilitychange', () => {
  if(document.visibilityState === 'visible' && POLL_PAGES[currentPage]) stat(true);
});

async function setp(k, v){
  const r = await withBusy(['set', k, String(v)]);
  const needRestart = !r.code && S.running && /перезапуск/i.test(r.out);
  toast(r.code ? errText(r, 'Не удалось сохранить') : (needRestart ? t('Применится после перезапуска службы') : t('Сохранено')),
    needRestart ? {label: t('Перезапустить'), fn: restartSvc} : null);
  stat();
}
async function editLimit(key, title, jk){
  const cur = (S && S[jk] != null) ? +S[jk] : 15;
  const v = await mdPrompt(title, t('Целое число от 1 до 15.'), String(cur), t('Пакетов на соединение'), {type: 'number', inputmode: 'numeric'});
  if(v == null || v === '') return;
  const n = parseInt(v, 10);
  if(!(n >= 1 && n <= 15)){ toast(t('Нужно целое число от 1 до 15')); return; }
  if(n !== cur) setp(key, n);
}
async function act(a){
  svcBusy = a;
  if(a === 'stop') stopUptTimer();
  renderHeroActions();
  const r = await withBusy([a], 40000);
  svcBusy = '';
  const ok = {start: 'Служба запущена', stop: 'Служба остановлена', restart: 'Служба перезапущена',
    'home-pause': 'Обход на паузе в домашнем Wi‑Fi'}[a];
  toast(r.code ? errText(r, 'Команда не выполнена') : t(ok));
  await stat();
}
function toggle(){ act(S.running ? 'stop' : 'start'); }
function restartSvc(){ act('restart'); }
function pauseHome(){ act('home-pause'); }
