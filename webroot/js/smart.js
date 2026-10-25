/* nfqws2 WebUI · smart.js — умный режим: выученное по сетям и обучение
   Скрипты подключаются из index.html обычными <script> по порядку и делят одну
   глобальную область: функции и let/const одного файла видны в остальных. */

/* ══ УМНЫЙ РЕЖИМ ═════════════════════════════════════════════════════════
   Стратегия smart сама подбирает вариант обхода для каждого сайта и помнит
   его отдельно для каждой сети. Здесь — состояние, выученное, обучение и сброс. */
let SMS = null, smartTimer = null, smartView = null;
const isSmartMode = () => (typeof currentStrategy !== 'undefined' ? currentStrategy === 'smart' : (SMS && SMS.active == 1));

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
      esc(t('Умный режим сейчас не выбран. Он сам подберёт обход для каждого сайта из блоков авторских стратегий и альтов Flowseal и запомнит его для каждой сети.')) + '</span>' +
      '<button class="btn tonal sm state" onclick="smartEnable()">' + esc(t('Включить')) + '</button></div>');
  }

  // Состояние в текущей / выбранной сети
  const netText = m.offline == 1 ? t('Нет связи — перебор на паузе') : cur ? smartNetLabel(cur) : t('Сеть ещё не определена');
  parts.push('<div class="list">' +
    settingsRow({icon: m.offline == 1 ? 'warn' : (cur && /^mobile/.test(cur.id) ? 'globe' : 'wifi'),
      title: 'Сеть', sub: netText + (nets.length > 1 ? ' · ' + t('нажмите для выбора сети') : ''),
      on: nets.length > 1 ? 'smartPickNet(this)' : null, chevron: nets.length > 1}) +
    settingsRow({icon: 'auto', title: 'Выучено в этой сети',
      sub: cur ? plural(cur.sites, t('сайт'), t('сайта'), t('сайтов')) : t('пока ничего'),
      on: "smartSites('all')", chevron: true}) +
    (cur && (cur.ok || cur.err) ? settingsRow({icon: 'status', title: 'Соединения',
      sub: t('Удачных {0} · с ошибками {1} — свежие весят больше', cur.ok, cur.err)}) : '') +
  '</div>');

  // Обучение
  const bg = m.bg || {}, ls = smartLearnState(m);
  parts.push('<h2 class="subhead">' + esc(t('Обучение')) + '</h2>' +
    '<div class="helper">' + esc(t('Умный режим учится сам, по ходу работы. Фоновое обучение раз в две минуты открывает один сайт из списка популярных и ваших — так он заранее знает обход для каждого вида соединений.')) + '</div>' +
    '<div class="list">' +
      settingsRow({icon: 'auto', title: 'Фоновое обучение',
        sub: bg.n ? t('Открыто сайтов: {0}, из них удачно {1}', bg.n, bg.ok || 0) + (bg.last ? ' · ' + bg.last : '') : t('Раз в две минуты, пока работает умный режим'),
        sw: true, checked: m.learn == 1, on: 'smartLearnToggle(this.checked)'}) +
      (m.learn == 1 ? settingsRow({icon: ls.on ? 'check' : 'pause', title: ls.on ? t('Идёт') : ls.value, sub: ls.sub}) : '') +
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
      '<div class="helper">' + esc(t('На текущем варианте у них ошибок больше, чем удач. Умный режим уже подбирает им другой: при следующей ошибке вариант сменится, а застрявшие соединения он обрывает сам, чтобы приложение переподключилось.')) + '</div>' +
      '<div class="list">' + probs.slice().sort((a, b) => b.err - a.err).slice(0, 10).map(p =>
        settingsRow({icon: 'warn', title: p.host, sub: (p.name || '#' + p.n) + ' · ' + t('удачных {0} · с ошибками {1}', p.ok, p.err)})).join('') + '</div>');
  }

  // Ни один вариант не помог — дело не в блокировке
  const nodpi = m.nodpi || [];
  if(nodpi.length){
    parts.push('<h2 class="subhead">' + esc(t('Не похоже на блокировку')) + '</h2>' +
      '<div class="helper">' + esc(t('Эти сайты не открылись ни на одном варианте: дело не в DPI — сервер недоступен, мешает прокси или само приложение. Умный режим 6 часов их не трогает: не перебирает варианты и не обрывает соединения.')) + '</div>' +
      '<div class="list">' + nodpi.slice(0, 10).map(h => settingsRow({icon: 'info', title: h})).join('') + '</div>');
  }

  // Резервная копия и перенос
  parts.push('<h2 class="subhead">' + esc(t('Резервная копия выученного')) + '</h2>' +
    '<div class="list">' +
      settingsRow({icon: 'share', title: 'Поделиться обучением', sub: t('Файл с выученным в этой сети (.tsv)'), on: 'smartExport()'}) +
      settingsRow({icon: 'upload', title: 'Загрузить обучение', sub: t('Добавить выученное из файла (.tsv) в текущую сеть'), on: "$('smart-imp').click()"}) +
    '</div>');

  // Сети: выученное хранится отдельно для каждой
  parts.push('<h2 class="subhead">' + esc(t('Сети')) + '</h2>' +
    '<div class="helper">' + esc(t('Для каждой сети — своё выученное. Новая сеть начинает с копии выученного в прежней и дальше меняется сама; при возвращении в сеть ничего не перебирается заново.')) + '</div>' +
    (nets.length ? '<div class="list">' + nets.map(n =>
      '<div class="list-item two-line">' +
        '<span class="li-icon plain">' + icon(/^mobile/.test(n.id) ? 'globe' : 'wifi', 's24') + '</span>' +
        '<span class="li-text"><span class="li-primary truncate">' + esc(smartNetLabel(n)) + '</span>' +
          '<span class="li-secondary">' + esc(plural(n.sites, t('сайт'), t('сайта'), t('сайтов')) + (n.current == 1 ? ' · ' + t('сейчас') : '')) + '</span></span>' +
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
  smartSheet(t('Выученные сайты'), '<div class="helper">' + esc(t('Загрузка…')) + '</div>');
  const list = await smartSitesList(grp);
  smartSheet(t('Выученные сайты'), '<div class="helper">' + esc(t('Сайт и вариант, на котором он сейчас работает. Первые 300 — по числу удачных соединений.')) + '</div>' + smartSiteRows(list));
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
  await exportBlobFile(p[2] ? b64toBlob(p[2], 'text/tab-separated-values') : null, p[0], 'text/tab-separated-values', p[1], SAVE_DIR_DEFAULT);
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
