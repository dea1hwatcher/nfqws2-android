/* nfqws2 WebUI · smart.js — умный режим: выученное по сетям и обучение
   Скрипты подключаются из index.html обычными <script> по порядку и делят одну
   глобальную область: функции и let/const одного файла видны в остальных. */

/* ══ УМНЫЙ РЕЖИМ ═════════════════════════════════════════════════════════
   Стратегия smart сама подбирает вариант обхода для каждого сайта и помнит
   его отдельно для каждой сети. Здесь — состояние, выученное, обучение и сброс. */
let SMS = null, smartTimer = null, smartView = null;
let smartBenchRunning = false, smartBenchCancelled = false;
// Every run gets a token: a cancelled run keeps streaming lines, and without it
// the old stream would write into the new run's rows and even cancel it.
let smartBenchRun = 0;
let smartBenchSlot = 'tls', smartBenchDomain = '';
let smartBenchResults = {}, smartBenchBest = null, smartBenchBadgeText = '';
const isSmartMode = () => (typeof S !== 'undefined' && S.smart == 1) || (typeof currentStrategy !== 'undefined' ? currentStrategy === 'smart' : (SMS && SMS.active == 1));

const SMART_GROUPS = [
  ['tls', 'Сайты (TLS)', ['tls', 'tls_cf', 'tls_16', 'tls_as']],
  ['google', 'Google и YouTube', ['google']],
  ['quic', 'QUIC', ['quic', 'quic_16']]
];

const SMART_SLOT_TITLE = {
  tls: 'Обычные сайты (TLS)',
  tls_cf: 'Сайты за Cloudflare',
  tls_16: 'Хостинги и CDN (обрыв на 16 КБ)',
  tls_as: 'Хостинги: Contabo, Frantech и другие',
  google: 'Google и YouTube',
  quic: 'QUIC',
  quic_16: 'QUIC на хостингах и CDN'
};

function smartLearnState(m){
  if(!m || m.learn != 1) return {value: t('Выкл.'), sub: t('только по ходу работы'), on: false};
  if(m.active != 1) return {value: t('Ждёт'), sub: t('начнётся в умном режиме'), on: false};
  if(m.paused == 1) return {value: t('Пауза'), sub: t('продолжится, когда служба возобновит работу'), on: false};
  if(m.running != 1) return {value: t('Пауза'), sub: t('служба остановлена — продолжится при запуске'), on: false};
  if(m.offline == 1) return {value: t('Ждёт сеть'), sub: t('нет связи — продолжится, когда сеть появится'), on: false};
  return {value: t('Идёт'), sub: t('открыто сайтов: {0}', (m.bg || {}).n || 0), on: true};
}

async function smartInit(){
  await smartLoad();
}

async function smartLoad(){
  if(smartBenchRunning) return;
  const r = await ctlx(smartView ? ['smart-status', smartView] : ['smart-status']);
  try { SMS = JSON.parse(r.out); } catch(e){ SMS = null; }
  // выбранной сети больше нет (забыли) — обратно на текущую
  if(SMS && smartView && !(SMS.nets || []).some(n => n.id === smartView)){ smartView = null; return smartLoad(); }
  renderSmart();
  clearTimeout(smartTimer);
  // пока экран открыт — раз в 20 секунд обновлять данные
  if(SMS && currentPage === 'smart') smartTimer = setTimeout(() => { if(currentPage === 'smart') smartLoad(); }, 20000);
}

const smartNetLabel = n => n.id === 'mobile' || /^mobile-/.test(n.id) ? t('Мобильная: {0}', n.label) : n.id === 'wifi' ? t('Wi‑Fi') : t('Wi‑Fi: {0}', n.label);

function renderSmart(){
  const m = SMS;
  if(!m){ setHTML('smart-body', banner('danger', 'error', t('Не удалось прочитать состояние умного режима')), false); return; }
  const nets = m.nets || [];
  const cur = nets.find(n => n.id === (smartView || m.view)) || nets.find(n => n.current == 1);
  const parts = [];

  // Подсказка, если умный режим не выбран основной стратегией
  if(m.active != 1){
    parts.push('<div class="suggest">' + icon('auto', 's24') + '<span class="grow">' +
      esc(t('Умный режим сейчас не выбран.')) + '</span>' +
      '<button class="btn tonal sm state" onclick="smartEnable()">' + esc(t('Включить')) + '</button></div>');
  }

  // Состояние в текущей / выбранной сети
  const netText = m.offline == 1 ? t('Нет связи — перебор на паузе') : cur ? smartNetLabel(cur) : t('Сеть ещё не определена');
  parts.push('<div class="list">' +
    settingsRow({icon: m.offline == 1 ? 'warn' : (cur && /^mobile/.test(cur.id) ? 'globe' : 'wifi'),
      title: 'Сеть', value: netText,
      on: nets.length > 1 ? 'smartPickNet(this)' : null, chevron: nets.length > 1}) +
    settingsRow({icon: 'auto', title: 'Выучено в этой сети',
      value: cur ? plural(cur.sites, t('сайт'), t('сайта'), t('сайтов')) : t('пока ничего'),
      on: "smartSites('all')", chevron: true}) +
    (cur && (cur.ok || cur.err) ? settingsRow({icon: 'status', title: 'Соединения',
      value: t('Удачных {0} · с ошибками {1}', cur.ok, cur.err)}) : '') +
  '</div>');

  // Калибровка вариантов умного режима
  const curSlot = SMART_BENCH_SLOTS.find(([sl]) => sl === smartBenchSlot) || SMART_BENCH_SLOTS[0];
  parts.push('<h2 class="subhead">' + esc(t('Калибровка вариантов')) + '</h2>' +
    '<div class="group" id="smart-bench-box">' +
      '<div class="row align-center wrap gap-sm">' +
        '<button class="chip dropdown state" id="smart-bench-slot-select" type="button" aria-haspopup="menu" aria-expanded="false" onclick="openSmartBenchSlotMenu(this)"' + (smartBenchRunning ? ' disabled' : '') + '>' +
          '<span id="smart-bench-slot-label">' + esc(t(curSlot[1])) + '</span>' +
          icon('caret', 's18') +
        '</button>' +
        '<div class="grow"></div>' +
        '<span class="pill tonal" id="smart-bench-badge"' + (smartBenchRunning || smartBenchBadgeText ? '' : ' hidden') + '>' + esc(smartBenchBadgeText || '') + '</span>' +
      '</div>' +
      '<div class="search-bar mt-sm">' +
        icon('globe', 's24') +
        '<input type="text" id="smart-bench-domain" placeholder="' + esc(t('Свой домен (опционально)')) + '" aria-label="' + esc(t('Свой домен (опционально)')) + '" data-ta="placeholder,aria-label" autocapitalize="off" autocorrect="off" spellcheck="false" enterkeyhint="go" value="' + esc(smartBenchDomain || '') + '" oninput="smartBenchDomain = this.value.trim()" onkeydown="if(event.key===\'Enter\')toggleSmartBench()" />' +
      '</div>' +
      '<div class="row mt-sm">' +
        '<button class="btn with-icon state' + (smartBenchRunning ? ' tonal' : '') + '" id="smart-bench-btn" onclick="toggleSmartBench()">' +
          icon(smartBenchRunning ? 'pause' : 'play', 's18') +
          '<span>' + esc(smartBenchRunning ? t('Остановить') : t('Тестировать')) + '</span>' +
        '</button>' +
      '</div>' +
      '<div id="smart-bench-best" class="mt-sm"' + (smartBenchBest ? '' : ' hidden') + '>' +
        (smartBenchBest ? renderSmartBenchBest(smartBenchBest) : '') +
      '</div>' +
      '<div class="list mt-sm" id="smart-bench-list">' +
        renderSmartBenchList() +
      '</div>' +
    '</div>');

  // Обучение
  const bg = m.bg || {}, ls = smartLearnState(m);
  parts.push('<h2 class="subhead">' + esc(t('Обучение')) + '</h2>' +
    '<div class="list">' +
      settingsRow({icon: 'auto', title: 'Фоновое обучение',
        sw: true, checked: m.learn == 1, on: 'smartLearnToggle(this.checked)'}) +
      (m.learn == 1 ? settingsRow({icon: ls.on ? 'check' : 'pause', title: 'Статус обучения',
        value: ls.on ? (bg.n ? t('Идёт ({0})', bg.n) : t('Идёт')) : ls.value}) : '') +
    '</div>');

  // Что работает в этой сети
  const top = m.top || {};
  const activeGroups = SMART_GROUPS.filter(([, , slots]) => slots.some(sl => (top[sl] || []).length));
  if(activeGroups.length){
    parts.push('<h2 class="subhead">' + esc(t('Что работает в этой сети')) + '</h2>');
    activeGroups.forEach(([, grpTitle, slots]) => {
      slots.filter(sl => (top[sl] || []).length).forEach(sl => {
        parts.push('<div class="list">' +
          '<div class="sheet-group" role="presentation">' + esc(t(SMART_SLOT_TITLE[sl] || grpTitle)) + '</div>' +
          top[sl].slice().sort((a, b) => b.sites - a.sites || b.ok - a.ok).slice(0, 5).map(v =>
            settingsRow({icon: v.err > v.ok ? 'warn' : 'check', title: v.name || ('#' + v.n),
              sub: t('Сайтов: {0} · удачных {1} · с ошибками {2}', v.sites, v.ok, v.err)})).join('') +
        '</div>');
      });
    });
  }

  // Сайты с ошибками: умный режим уже ищет им другой вариант
  const probs = m.problems || [];
  if(probs.length){
    parts.push('<h2 class="subhead">' + esc(t('Сайты с ошибками')) + '</h2>' +
      '<div class="list">' + probs.slice().sort((a, b) => b.err - a.err).slice(0, 10).map(p =>
        settingsRow({icon: 'warn', title: p.host, sub: (p.name || '#' + p.n) + ' · ' + t('удачных {0} · с ошибками {1}', p.ok, p.err)})).join('') + '</div>');
  }

  // Ни один вариант не помог — дело не в блокировке
  const nodpi = m.nodpi || [];
  if(nodpi.length){
    parts.push('<h2 class="subhead">' + esc(t('Не похоже на блокировку')) + '</h2>' +
      '<div class="list">' + nodpi.slice(0, 10).map(h => settingsRow({icon: 'info', title: h})).join('') + '</div>');
  }

  // Резервная копия и перенос
  parts.push('<h2 class="subhead">' + esc(t('Резервная копия выученного')) + '</h2>' +
    '<div class="list">' +
      settingsRow({icon: 'share', title: 'Поделиться обучением', on: 'smartExport()'}) +
      settingsRow({icon: 'upload', title: 'Загрузить обучение', on: "$('smart-imp').click()"}) +
    '</div>');

  // Сети: выученное хранится отдельно для каждой
  parts.push('<h2 class="subhead">' + esc(t('Сети')) + '</h2>' +
    (nets.length ? '<div class="list">' + nets.map(n =>
      '<div class="list-item">' +
        '<span class="li-icon plain">' + icon(/^mobile/.test(n.id) ? 'globe' : 'wifi', 's24') + '</span>' +
        '<span class="li-text"><span class="li-primary truncate">' + esc(smartNetLabel(n)) + '</span></span>' +
        '<span class="li-trail li-value">' + esc(plural(n.sites, t('сайт'), t('сайта'), t('сайтов')) + (n.current == 1 ? ' · ' + t('сейчас') : '')) + '</span>' +
        '<button class="icon-btn sm state" aria-label="' + esc(t('Забыть выученное в {0}', smartNetLabel(n))) + '" onclick="smartReset(' + jsArg(n.id) + ')">' +
          icon('trash', 's20') + '</button>' +
      '</div>').join('') + '</div>'
      : '<div class="empty"><span class="empty-icon">' + icon('wifi', 's24') + '</span><span>' + esc(t('Сетей пока нет: они появятся, когда умный режим начнёт работать.')) + '</span></div>') +
    (nets.length ? '<div class="row"><button class="btn text with-icon state danger" onclick="smartReset(\'all\')">' + icon('trash', 's18') + '<span>' + esc(t('Забыть всё выученное')) + '</span></button></div>' : ''));

  setHTML('smart-body', parts.join(''), false);
}

async function smartEnable(){
  await applyStrategy('smart');
  await smartLoad();
}

async function smartOffer(){
  if(currentPage === 'smart') smartLoad();
}

function smartPickNet(anchor){
  if(!SMS || !SMS.nets) return;
  openMenu(anchor, (SMS.nets || []).map(n => ({
    label: smartNetLabel(n), sub: plural(n.sites, t('сайт'), t('сайта'), t('сайтов')) + (n.current == 1 ? ' · ' + t('сейчас') : ''),
    icon: n.id === (smartView || SMS.view) ? 'check' : '',
    onClick: () => { smartView = n.current == 1 ? null : n.id; smartLoad(); }
  })));
}

let smartSheetKind = '';
function smartSheet(title, html, kind){
  smartSheetKind = kind || '';
  const tEl = $('smart-sheet-title');
  const bEl = $('smart-sheet-body');
  if(tEl) tEl.textContent = title;
  if(bEl){ bEl.innerHTML = html; bEl.scrollTop = 0; }
  if(openSheetId !== 'smart-sheet') openSheet('smart-sheet');
}

function smartSiteRows(list){
  if(!list || !list.length) return '<div class="empty"><span>' + esc(t('Пока пусто')) + '</span></div>';
  return '<div class="list">' + list.map(s =>
    settingsRow({icon: s.err > s.ok ? 'warn' : 'check', title: s.host,
      sub: (s.name || '#' + s.n) + ' · ' + t('удачных {0} · с ошибками {1}', s.ok, s.err)})).join('') + '</div>';
}

async function smartSitesList(grp){
  if(!SMS || !SMS.view) return [];
  const r = await ctlx(['smart-sites', smartView || SMS.view, grp]);
  try { return JSON.parse(r.out); } catch(e){ return []; }
}

async function smartSites(grp){
  if(!SMS) await smartLoad();
  if(!SMS) return;
  smartSheet(t('Выученные сайты'), '<div class="list-item"><span class="spinner"></span><span class="li-text"><span class="li-secondary">' + esc(t('Загрузка…')) + '</span></span></div>');
  const list = await smartSitesList(grp);
  smartSheet(t('Выученные сайты'), smartSiteRows(list));
}

async function smartLearnToggle(on){
  const r = await withBusy(['set', 'SMART_LEARN', on ? '1' : '0']);
  if(r.code){ toast(errText(r, 'Не удалось сохранить')); return; }
  if(SMS) SMS.learn = on ? 1 : 0;
  renderSmart();
  toast(on ? t('Фоновое обучение включено') : t('Фоновое обучение выключено'));
}

function plural(n, one, few, many){
  n = Number(n) || 0;
  const m10 = n % 10, m100 = n % 100;
  const w = (m10 === 1 && m100 !== 11) ? one : (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) ? few : many;
  return n + ' ' + w;
}

async function smartReset(id){
  const all = id === 'all';
  if(!await mdConfirm(all ? t('Забыть всё выученное?') : t('Забыть выученное в этой сети?'),
    t('Умный режим начнёт подбирать варианты заново. Служба перезапустится.'), {ok: t('Забыть'), danger: true})) return;
  const r = await withBusy(['smart-reset', id], 40000);
  toast(r.code ? errText(r, 'Не удалось сбросить') : t('Выученное забыто'));
  if(all || id === smartView) smartView = null;
  smartLoad();
}

async function smartExport(){
  if(!SMS) await smartLoad();
  const v = smartView || (SMS && SMS.view);
  if(!v){ toast(t('В этой сети ещё ничего не выучено')); return; }
  const r = await withBusy(window.ksu ? ['smart-export', v, 'path'] : ['smart-export', v]);
  const out = (r.out || '').trim();
  if(r.code || !out){ toast(errText(r, 'Не удалось сохранить')); return; }
  const p = out.split('\n')[0].split('\t');
  await exportBlobFile(p[2] ? b64toBlob(p[2], 'text/tab-separated-values') : null, p[0], 'text/tab-separated-values', p[1]);
}

async function smartImport(files){
  const f = files && files[0];
  const el = $('smart-imp');
  if(el) el.value = '';
  if(!f) return;
  if(!await mdConfirm(t('Загрузить обучение?'),
    t('Сайты из файла, которых здесь ещё нет, добавятся к выученному в текущей сети. Своё выученное останется. Служба перезапустится.'), {ok: t('Загрузить'), iconName: 'upload'})) return;
  const text = await f.text();
  const r = await withBusy(['smart-import-b64', b64(text)], 60000);
  if(r.code){ toast(errText(r, 'Не удалось загрузить')); return; }
  toast(t('Добавлено сайтов: {0}', (r.out || '0').trim()));
  smartView = null;
  smartLoad();
}

const SMART_BENCH_SLOTS = [
  ['tls', 'TLS (сайты)'],
  ['google', 'Google & YT'],
  ['quic', 'QUIC']
];

function openSmartBenchSlotMenu(anchor){
  if(smartBenchRunning) return;
  openMenu(anchor, SMART_BENCH_SLOTS.map(([sl, label]) => ({
    label: t(label),
    icon: sl === smartBenchSlot ? 'check' : '',
    onClick: () => smartBenchSetSlot(sl)
  })));
}

function smartBenchSetSlot(s){
  if(smartBenchRunning) return;
  smartBenchSlot = s;
  smartBenchResults = {};
  smartBenchBest = null;
  smartBenchBadgeText = '';
  renderSmart();
}

function renderSmartBenchRow(it, isRunning){
  const v = it.v, name = it.name || ('#' + v);
  if(isRunning){
    return '<div class="list-item two-line" id="smartrow' + v + '">' +
      '<span class="li-icon plain">' + icon('refresh', 's20') + '</span>' +
      '<span class="li-text"><span class="li-primary truncate">' + esc(name) + '</span>' +
      '<span class="li-secondary">' + esc(t('Тестирование...')) + '</span></span>' +
    '</div>';
  }
  const ok = it.ok || 0, total = it.total || 0, avg_ms = it.avg_ms || 0, top_fail = it.top_fail;
  const isOk = ok > 0;
  const subText = t('Успешно: {0}/{1} · {2} мс', ok, total, avg_ms) + (top_fail && top_fail !== '-' ? ' · ' + top_fail : '');
  return '<div class="list-item two-line" id="smartrow' + v + '">' +
    '<span class="li-icon plain">' + icon(isOk ? 'check' : 'warn', 's20') + '</span>' +
    '<span class="li-text"><span class="li-primary truncate">' + esc(name) + '</span>' +
    '<span class="li-secondary">' + esc(subText) + '</span></span>' +
    '<button class="btn tonal sm state" onclick="smartApplyVariant(' + jsArg(smartBenchSlot) + ', ' + jsArg(v) + ', ' + jsArg(name) + ')">' + esc(t('Применить')) + '</button>' +
  '</div>';
}

function renderSmartBenchBest(best){
  if(!best) return '';
  return '<div class="suggest mt-sm">' + icon('auto', 's24') +
    '<span class="grow"><strong>' + esc(t('Рекомендация: {0}', best.name)) + '</strong><br>' +
    esc(t('Успешно: {0}/{1} · {2} мс', best.ok, best.total, best.avg_ms)) + '</span>' +
    '<button class="btn sm state" onclick="smartApplyVariant(' + jsArg(best.slot || smartBenchSlot) + ', ' + jsArg(best.v) + ', ' + jsArg(best.name) + ')">' +
      esc(t('Сделать основным')) +
    '</button>' +
  '</div>';
}

function renderSmartBenchList(){
  const rows = Object.values(smartBenchResults);
  if(!rows.length) return '';
  return rows.sort((a, b) => b.ok - a.ok || a.avg_ms - b.avg_ms).map(it => renderSmartBenchRow(it, false)).join('');
}

async function toggleSmartBench(){
  if(smartBenchRunning){
    smartBenchCancelled = true;
    smartBenchRunning = false;
    smartBenchBadgeText = t('Остановлено');
    renderSmart();
    // a local flag alone leaves the ctl process probing and the uid-0 include
    // rule installed on the device, so stop the run there too
    await ctlx(['probe-cancel']);
    return;
  }
  const run = ++smartBenchRun;
  smartBenchRunning = true;
  smartBenchCancelled = false;
  smartBenchResults = {};
  smartBenchBest = null;
  smartBenchBadgeText = t('Запуск...');
  renderSmart();

  const domain = (smartBenchDomain || '').trim();
  const args = domain ? ['smart-bench', domain, smartBenchSlot] : ['smart-bench', '', smartBenchSlot];
  let sawBest = false;

  const onLine = line => {
    if(run !== smartBenchRun || smartBenchCancelled) return;
    const p = line.trim().split('\t');
    if(!p[0]) return;
    if(p[0] === 'SMART_BENCH_START'){
      const total = +p[1] || 0;
      smartBenchBadgeText = t('Проверка 0/{0}', total);
      const bEl = $('smart-bench-badge');
      if(bEl){ bEl.textContent = smartBenchBadgeText; bEl.hidden = false; }
    } else if(p[0] === 'SMART_BENCH_RUN'){
      const idx = +p[1] || 0, v = +p[2] || 0, name = p[3] || ('#' + v), total = +p[4] || 0;
      smartBenchBadgeText = t('Вариант {0}/{1}', idx + 1, total);
      const bEl = $('smart-bench-badge');
      if(bEl) bEl.textContent = smartBenchBadgeText;
      const listEl = $('smart-bench-list');
      if(listEl){
        const rowEl = $('smartrow' + v);
        const html = renderSmartBenchRow({v, name}, true);
        if(rowEl) rowEl.outerHTML = html;
        else listEl.insertAdjacentHTML('beforeend', html);
      }
    } else if(p[0] === 'SMART_BENCH_RES'){
      const v = +p[2] || 0, name = p[3] || ('#' + v), ok = +p[4] || 0, total = +p[5] || 0, avg_ms = +p[6] || 0, top_fail = p[7] || '-';
      smartBenchResults[v] = {v, name, ok, total, avg_ms, top_fail};
      const listEl = $('smart-bench-list');
      if(listEl){
        const rowEl = $('smartrow' + v);
        const html = renderSmartBenchRow(smartBenchResults[v], false);
        if(rowEl) rowEl.outerHTML = html;
        else listEl.insertAdjacentHTML('beforeend', html);
      }
    } else if(p[0] === 'SMART_BENCH_BEST'){
      sawBest = true;
      const slot = p[1], v = +p[2] || 0, name = p[3] || ('#' + v), ok = +p[4] || 0, total = +p[5] || 0, avg_ms = +p[6] || 0;
      if(v > 0 && ok > 0){
        smartBenchBest = {slot, v, name, ok, total, avg_ms};
        const bestEl = $('smart-bench-best');
        if(bestEl){
          bestEl.innerHTML = renderSmartBenchBest(smartBenchBest);
          bestEl.hidden = false;
        }
      }
    }
  };

  let r = {code: 1, out: '', err: ''};
  try {
    r = await ctlx(args, 180000, onLine);
  } catch(e){
    r = {code: 1, out: '', err: String((e && e.message) || e)};
  }
  if(run !== smartBenchRun) return; // a newer run owns the badge and the list
  smartBenchRunning = false;
  if(smartBenchCancelled){
    smartBenchBadgeText = t('Остановлено');
    renderSmart();
    return;
  }
  if(r.code || !sawBest){
    // the run failed, ran out of the client timeout or found no tool; the ctl
    // process may still be probing, so make sure it is stopped
    await ctlx(['probe-cancel']);
    smartBenchBadgeText = '';
    renderSmart();
    toast(errText(r, 'Тестирование не удалось'));
    return;
  }
  smartBenchBadgeText = t('Завершено');
  renderSmart();
}

async function smartApplyVariant(slot, v, name){
  const domain = (smartBenchDomain || '').trim();
  const args = domain ? ['smart-apply-variant', slot, String(v), domain] : ['smart-apply-variant', slot, String(v)];
  const r = await withBusy(args);
  if(r.code){ toast(errText(r, 'Не удалось применить')); return; }
  toast(t('Вариант #{0} закреплён ({1})', v, name || ''));
  smartView = null;
  await smartLoad();
}
