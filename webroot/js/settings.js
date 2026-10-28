/* nfqws2 WebUI - settings, home Wi-Fi, backup */

function settingsRow(o){
  if(o.sw){
    return '<label class="list-item' + (o.sub ? ' two-line' : '') + ' clickable state">' +
      '<span class="li-icon">' + icon(o.icon, 's24') + '</span>' +
      '<span class="li-text"><span class="li-primary">' + esc(t(o.title)) + '</span>' +
        (o.sub ? '<span class="li-secondary">' + esc(o.sub) + '</span>' : '') + '</span>' +
      '<span class="li-trail"><input type="checkbox" class="switch" role="switch" aria-label="' + esc(t(o.title)) + '"' +
        (o.checked ? ' checked' : '') + (o.id ? ' id="' + esc(o.id) + '"' : '') +
        ' onchange="' + o.on + '"></span>' +
    '</label>';
  }
  return '<div class="list-item' + (o.sub ? ' two-line' : '') + (o.on ? ' clickable state' : '') + '"' +
    (o.long ? ' data-long="' + o.long + '"' : '') +
    (o.on ? ' role="button" tabindex="0"' + (o.menu ? ' aria-haspopup="menu"' : '') + ' onclick="' + o.on + '"' : '') + '>' +
    '<span class="li-icon">' + icon(o.icon, 's24') + '</span>' +
    '<span class="li-text"><span class="li-primary">' + esc(t(o.title)) + '</span>' +
      (o.sub ? '<span class="li-secondary">' + esc(o.sub) + '</span>' : '') + '</span>' +
    (o.value ? '<span class="li-trail li-value">' + esc(o.value) + '</span>' : '') +
    (o.chevron ? '<span class="li-trail">' + icon('chevron-right', 's24') + '</span>' : '') +
  '</div>';
}
function renderSettings(){
  const homeN = S.home_wifi == 1 ? t('Включено') : t('Выключено');
  const groups = [
    ['Работа', [
      {icon: 'home', title: 'Домашняя Wi‑Fi', sub: t('Пауза обхода в домашних сетях') + ' · ' + homeN, on: "navigate('wifi')", chevron: true},
      {icon: 'refresh', title: 'Стратегии по сетям', sub: t('Запоминать стратегию отдельно для каждой сети'), sw: true, checked: S.net_strategy == 1, on: 'toggleNetStrategy(this.checked)'},
      {icon: 'shield', title: 'Пауза при VPN', sub: t('Пауза обхода при включённом VPN'), sw: true, checked: S.vpn_pause == 1, on: 'toggleVpnPause(this.checked)'}
    ]],
    ['Инструменты', [
      {icon: 'auto', title: 'Умный режим', sub: S.smart == 1 ? t('Включён · сам подбирает обход для каждого сайта и сети') : t('Сам подбирает обход для каждого сайта и сети'), on: "navigate('smart')", chevron: true},
      {icon: 'apps', title: 'Фильтр приложений', sub: t('Обход только для выбранных приложений или для всех, кроме них'), on: "navigate('apps')", chevron: true},
      {icon: 'status', title: 'nfqws2 Helper', sub: t('Плитка быстрых настроек и уведомление о состоянии'), on: 'openHelperApp()', chevron: true},
      {icon: 'test', title: 'Проверка доступности', sub: t('Открывает адреса из probe_hosts.list через обход'), on: "navigate('test')", chevron: true},
      {icon: 'medical', title: 'Диагностика', sub: t('Ядро, правила iptables и аргументы запуска'), on: "navigate('diag')", chevron: true}
    ]],
    ['Резервная копия', [
      {icon: 'download', title: 'Создать копию', sub: t('Конфиг, списки, стратегии и оформление — в архив .tar'), on: 'createBackup()'},
      {icon: 'upload', title: 'Восстановить из копии', sub: t('Выбрать архив .tar или из списка'), on: 'openBackupSheet()'}
    ]],
    ['Оформление', [
      {icon: 'palette', title: 'Тема оформления', sub: t('Светлая, тёмная, AMOLED и цвет акцента'), on: 'openMonetModal()'},
      {icon: 'tune', title: 'Капсула навигации', sub: t('Плавающая нижняя панель со скруглением'), sw: true, checked: isNavCapsule(), id: 'capsule-toggle-settings', on: 'toggleNavCapsule(this.checked); renderSettings()'},
      {icon: 'motion', title: 'Отключение анимаций', sw: true, checked: isAnimationsDisabled(), id: 'animations-toggle', on: 'toggleAnimations(this.checked); renderSettings()'},
      {icon: 'apps', title: 'Ярлык на рабочий стол', sub: t('Добавить на главный экран телефона'), on: 'addDesktopShortcut()'},
      {icon: 'translate', title: 'Язык', sub: LANG === 'en' ? 'English' : 'Русский', on: 'pickLanguage(this)', menu: true, long: 'lang'}
    ]],
    ['О модуле', [
      {icon: 'info', title: 'nfqws2 for Android', sub: t('Версия {0}', S.version || '—'), on: 'openWhatsNew()', chevron: true, long: 'ver'}
    ]]
  ];
  let devHtml = '';
  if(devMode){
    devHtml = '<div class="stack" id="dev-block"><h2 class="subhead">' + esc(t('Для разработчиков')) + '</h2><div class="list" id="dev-sws">' + renderDevRows(S) + '</div></div>';
  }
  setHTML('settings-body', groups.map(([title, rows]) =>
    '<div class="stack"><h2 class="subhead">' + esc(t(title)) + '</h2><div class="list">' + rows.map(settingsRow).join('') + '</div></div>').join('') +
    devHtml, false);
}
const GITHUB_URL = 'https://github.com/Dea1hwa1cher/nfqws2-android';

/* Долгое нажатие на строки настроек: быстрые действия для тех, кто знает */
const SETTINGS_LONG = {
  // версия — список изменений (раньше — отдельный пункт «Что нового»)
  ver: () => openWhatsNew(),
  // язык — сразу на другой из двух
  lang: () => {
    setLanguage(LANG === 'en' ? 'ru' : 'en');
    toast(t('Язык переключён: {0}', LANG === 'en' ? 'English' : 'Русский'));
  }
};
if(typeof onLongPress === 'function') onLongPress($('settings-body'), '[data-long]', el => { const f = SETTINGS_LONG[el.dataset.long]; if(f) f(); });
const HELPER_PACKAGE = 'org.nfqws2.helper';
const HELPER_RELEASE_URL = 'https://github.com/duhenduhen/nfqws2-helper/releases/tag/1.0';

let deferredInstallPrompt = null;
if(typeof window !== 'undefined'){
  window.addEventListener('beforeinstallprompt', e => {
    e.preventDefault();
    deferredInstallPrompt = e;
  });
}

function addDesktopShortcut(){
  if(deferredInstallPrompt){
    deferredInstallPrompt.prompt();
    deferredInstallPrompt.userChoice.then(choiceResult => {
      if(choiceResult && choiceResult.outcome === 'accepted'){
        toast(t('Ярлык добавлен на рабочий стол'));
      }
      deferredInstallPrompt = null;
    });
    return;
  }
  mdDialog({
    title: t('Ярлык на рабочий стол'),
    text: t('KernelSU: в списке модулей удерживайте кнопку WebUI на карточке nfqws2 и выберите «Создать ярлык».\nMMRL и KsuWebUI: «Создать ярлык» в меню модуля.\nИконка ярлыка подставится из модуля сама.'),
    iconName: 'apps',
    ok: t('Понятно'),
    cancel: false
  });
}

/* Links open in the system app: navigating inside the WebView loses the module page */
async function openUrl(url){
  const r = await sh('am start -a android.intent.action.VIEW -d ' + q(url) + ' >/dev/null 2>&1', 8000);
  if(r.code) try { window.open(url, '_blank'); } catch(e) {}
}
async function openHelperApp(){
  const installed = await sh('pm path ' + q(HELPER_PACKAGE) + ' >/dev/null 2>&1', 8000);
  if(!installed.code){
    const r = await sh('am start -a android.settings.QS_TILE_SETTINGS >/dev/null 2>&1', 8000);
    if(!r.code) return;
  }
  await openUrl(HELPER_RELEASE_URL);
}
function pickLanguage(anchor){
  openMenu(anchor, [['ru', 'Русский'], ['en', 'English']].map(([k, label]) => ({
    label, icon: k === LANG ? 'check' : '', onClick: () => setLanguage(k)
  })));
}
function setLanguage(l){
  if(l === LANG) return;
  LANG = l;
  store.set('nfq_lang', l);
  rerenderAll();
}
/* Language switch without reload: data-t for static nodes, re-render for the rest */
function rerenderAll(){
  translateStatic();
  renderAppBar(currentPage, false);
  renderStatus();
  renderStrategyRow();
  renderMode(); renderListFiles();
  renderLogChips();
  drawThemeUI();
  if(currentPage === 'settings') renderSettings();
  if(currentPage === 'apps'){ renderAppModes(); drawPk(false); }
  if(currentPage === 'wifi') renderWifi();
  if(currentPage === 'test') testInit();
  if(currentPage === 'diag') diagInit();
  if(currentPage === 'logs') loadLog();
  if(currentPage === 'config'){ loadImports(); checkConfModified(); }
}

/* Home Wi-Fi */
let homeList = [], currentSsid = '';
async function wifiInit(){
  renderWifi();
  const [r1, r2] = await Promise.all([ctlx(['get-list', 'home']), ctlx(['wifi-ssid'])]);
  homeList = (r1.code ? '' : r1.out).split('\n').map(s => s.replace(/\r$/, '')).filter(s => s.trim() && s.trim()[0] !== '#');
  currentSsid = r2.code ? '' : r2.out.replace(/\n+$/, '');
  await stat(true);
  renderWifi();
}
function renderWifi(){
  const on = S.home_wifi == 1;
  $('wifi-toggle').checked = on;
  $('wifi-main').classList.toggle('on', on);
  $('wifi-body').classList.toggle('is-disabled', !on);
  $('wifi-body').inert = !on;
  setHTML('wifi-suggest', on && currentSsid && !homeList.includes(currentSsid)
    ? '<div class="suggest">' + icon('wifi', 's24') +
        '<span class="grow">' + esc(t('Сейчас телефон подключён к «{0}». Добавить эту сеть в домашние?', currentSsid)) + '</span>' +
        '<button class="btn tonal sm state" onclick="addHome(' + jsArg(currentSsid) + ')">' + esc(t('Добавить')) + '</button></div>'
    : '', true);
  setHTML('wifi-list', homeList.length ? homeList.map(s =>
    '<div class="list-item">' +
      '<span class="li-icon plain">' + icon('wifi', 's24') + '</span>' +
      '<span class="li-text"><span class="li-primary truncate">' + esc(s) + '</span>' +
        (s === currentSsid ? '<span class="li-secondary">' + esc(t('Подключено сейчас')) + '</span>' : '') + '</span>' +
      '<button class="icon-btn sm state" aria-label="' + esc(t('Убрать сеть {0}', s)) + '" onclick="removeHome(' + jsArg(s) + ')">' +
        icon('trash', 's20') + '</button>' +
    '</div>').join('')
    : '<div class="empty"><span class="empty-icon">' + icon('home', 's24') + '</span><span>' +
      esc(t('Домашних сетей пока нет. Подключитесь к своей Wi‑Fi — модуль сам предложит её добавить.')) + '</span></div>', false);
}
async function saveHomeList(list){
  const r = await withBusy(['save-list-b64', 'home', b64(list.join('\n') + (list.length ? '\n' : ''))], 30000);
  if(r.code){ toast(errText(r, 'Не удалось сохранить')); return false; }
  homeList = list;
  return true;
}
async function addHome(ssid){
  ssid = String(ssid || '');
  if(!ssid || homeList.includes(ssid)) return;
  if(await saveHomeList(homeList.concat([ssid]))){
    toast(t('«{0}» добавлена в домашние сети', ssid));
    await stat(true);
    renderWifi();
  }
}
async function removeHome(ssid){
  if(await saveHomeList(homeList.filter(s => s !== ssid))){
    toast(t('«{0}» убрана из домашних сетей', ssid));
    await stat(true);
    renderWifi();
  }
}
async function addHomeManual(){
  const v = await mdPrompt(t('Добавить сеть'), t('Имя сети (SSID) в точности как в настройках Wi‑Fi.'), currentSsid && !homeList.includes(currentSsid) ? currentSsid : '', 'SSID',
    {ok: t('Добавить')});
  if(v) addHome(v);
}
async function setHomeWifi(on){
  const r = await withBusy(['set', 'HOME_WIFI', on ? '1' : '0'], 40000);
  if(r.code){ toast(errText(r, 'Не удалось сохранить')); $('wifi-toggle').checked = !on; return; }
  await stat(true);
  renderWifi();
  // Offer the current network right after the feature is turned on
  if(on && currentSsid && !homeList.includes(currentSsid)){
    const ok = await mdConfirm(t('Это домашняя сеть?'),
      t('Сейчас телефон подключён к «{0}». Добавить её в домашние — тогда в ней обход будет вставать на паузу.', currentSsid),
      {ok: t('Добавить'), cancel: t('Не сейчас'), iconName: 'home'});
    if(ok) addHome(currentSsid);
  }
}

/* Backup */
const UI_KEYS = ['m3_seed', 'm3_mode', 'm3_amoled', 'm3_containers', 'm3_monochrome', 'm3_nav_capsule', 'm3_no_animations', 'm3_animations', 'nfq_lang', 'nfq_dev'];
async function createBackup(){
  const targetDir = await promptSaveDir('Сохранить копию');
  if(!targetDir) return;
  const ui = {};
  UI_KEYS.forEach(k => { const v = store.get(k); if(v != null) ui[k] = v; });
  const r = await withBusy(['backup-create', b64(JSON.stringify(ui))], 60000);
  if(r.code){ toast(errText(r, 'Не удалось создать копию')); return; }
  const parts = r.out.trim().split('\n')[0].split('\t');
  const filename = parts[0] || ('nfqws2-backup-' + Date.now() + '.tar');
  const filePath = parts[1] || '';
  const b64Data = parts[2] || '';
  if(b64Data){
    const blob = b64toBlob(b64Data, 'application/x-tar');
    await exportBlobFile(blob, filename, 'application/x-tar', filePath, targetDir);
  } else {
    toast(t('Копия сохранена: {0}', filename));
  }
}
async function openBackupSheet(){
  setHTML('backup-list', '<div class="list-item"><span class="spinner"></span><span class="li-text"><span class="li-secondary">' +
    esc(t('Поиск копий…')) + '</span></span></div>', false);
  openSheet('backup-sheet');
  const r = await ctlx(['backup-list']);
  const rows = (r.code ? '' : r.out).split('\n').filter(Boolean).map(l => l.split('\t'));
  setHTML('backup-list', rows.length ? rows.map(([name, size]) => {
    const m = name.match(/(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})/);
    const when = m ? m[3] + '.' + m[2] + '.' + m[1] + ' ' + m[4] + ':' + m[5] : name;
    return '<div class="list-item two-line clickable state" role="button" tabindex="0" onclick="restoreBackup(' + jsArg(name) + ')">' +
      '<span class="li-icon">' + icon('upload', 's24') + '</span>' +
      '<span class="li-text"><span class="li-primary">' + esc(when) + '</span>' +
        '<span class="li-secondary li-mono truncate">' + esc(name) + ' · ' + Math.max(1, Math.round((+size || 0) / 1024)) + ' KB</span></span>' +
    '</div>';
  }).join('') : '<div class="empty"><span class="empty-icon">' + icon('download', 's24') + '</span><span>' +
    esc(t('В памяти устройства нет копий nfqws2-backup-*.tar. Выберите файл вручную.')) + '</span></div>');
}
function applyRestoredUi(raw){
  const line = (raw || '').trim().split('\n')[0];
  if(line){
    try {
      const ui = JSON.parse(unb64(line));
      UI_KEYS.forEach(k => { if(ui[k] != null) store.set(k, String(ui[k])); });
      LANG = store.get('nfq_lang') === 'en' ? 'en' : 'ru';
      devMode = store.get('nfq_dev') === '1';
      currentMode = store.get('m3_mode') || 'auto';
      const sd = (store.get('m3_seed') || '').toLowerCase();
      if(/^#[0-9a-f]{6}$/.test(sd)) currentSeed = sd;
      applyTheme();
    } catch(e) {}
  }
  stat();
  initStrategySelector();
  rerenderAll();
}
async function restoreBackupFromFile(file){
  if(!file) return;
  if($('backupFile')) $('backupFile').value = '';
  if(!await mdConfirm(t('Восстановить копию?'),
    t('Конфиг, пользовательские списки, стратегии и оформление будут заменены содержимым «{0}».', file.name),
    {ok: t('Восстановить'), danger: true})) return;
  closeSheet();
  try {
    const b64Data = await blobToB64(file);
    const r = await withBusy(['backup-restore-b64', b64Data], 90000);
    if(r.code){ toast(errText(r, 'Не удалось восстановить копию')); return; }
    applyRestoredUi(r.out);
    toast(t('Копия восстановлена'));
  } catch(e){
    toast(t('Ошибка чтения файла: {0}', (e && e.message) || String(e)));
  }
}
async function restoreBackup(name){
  if(!await mdConfirm(t('Восстановить копию?'), t('Конфиг, пользовательские списки, стратегии и оформление будут заменены содержимым «{0}».', name),
    {ok: t('Восстановить'), danger: true})) return;
  closeSheet();
  const r = await withBusy(['backup-restore', name], 90000);
  if(r.code){ toast(errText(r, 'Не удалось восстановить копию')); return; }
  applyRestoredUi(r.out);
  toast(t('Копия восстановлена'));
}

async function toggleNetStrategy(checked){
  const on = typeof checked === 'boolean' ? checked : (S.net_strategy != 1);
  const r = await withBusy(['set', 'NET_STRATEGY', on ? '1' : '0'], 40000);
  if(r.code) toast(errText(r, 'Не удалось переключить привязку стратегий'));
  else { S.net_strategy = on ? 1 : 0; renderSettings(); stat(); }
}

async function toggleVpnPause(checked){
  const on = typeof checked === 'boolean' ? checked : (S.vpn_pause != 1);
  const r = await withBusy(['set', 'VPN_PAUSE', on ? '1' : '0'], 40000);
  if(r.code) toast(errText(r, 'Не удалось переключить паузу при VPN'));
  else { S.vpn_pause = on ? 1 : 0; renderSettings(); stat(); }
}

/* Strategy Testing (Benchmark) */
let benchRunning = false;
let benchCancelled = false;
let benchResults = {};
let benchTotalStrats = 0;
let benchBestStrat = null;

function updateBenchButtons(running){
  const el = $('bench-btn');
  if(!el) return;
  el.disabled = false;
  if(running){
    el.classList.add('danger');
    el.innerHTML = icon('stop', 's18') + '<span>' + esc(t('Остановить')) + '</span>';
  } else {
    el.classList.remove('danger');
    el.innerHTML = icon('play', 's18') + '<span>' + esc(t('Запустить тестирование')) + '</span>';
  }
}

function updateBenchButtonsStopping(){
  const el = $('bench-btn');
  if(!el) return;
  el.disabled = true;
  el.innerHTML = '<span class="spinner"></span><span>' + esc(t('Остановка…')) + '</span>';
}

function renderBenchRow(idx, name, ok, total, avg_ms, top_fail, isRunning, yt_ok, dc_ok){
  const stratTitle = typeof strategyName === 'function' ? strategyName(name) : name;
  if(isRunning){
    return '<div class="list-item two-line" id="benchrow' + idx + '">' +
      '<span class="status info"><span class="spinner" style="width:14px;height:14px;"></span></span>' +
      '<span class="li-text">' +
        '<span class="li-primary truncate">' + esc(stratTitle) + ' <span class="muted li-mono">(' + esc(name) + ')</span></span>' +
        '<span class="li-secondary">' + esc(t('Тестирование соединений…')) + '</span>' +
      '</span>' +
      '<span class="li-trail li-value">…</span>' +
    '</div>';
  }
  const isAllOk = total > 0 && ok === total;
  const isPartOk = ok > 0;
  const stClass = isAllOk ? 'ok' : (isPartOk ? 'warn' : 'bad');
  const icName = isAllOk ? 'check' : (isPartOk ? 'warn' : 'close');
  let sub = '';
  if(total === 0){
    sub = t('Не запустилась');
  } else {
    sub = t('Успешно: {0}/{1}', ok, total);
    if(ok > 0) sub += ` · ${avg_ms} ` + t('мс');
    if(top_fail && top_fail !== '-'){
      const reasonsDict = typeof PROBE_REASON !== 'undefined' ? PROBE_REASON : {};
      const failReason = t(reasonsDict[top_fail] || top_fail);
      sub += ` · ${failReason}`;
    }
  }

  let svcBadges = '';
  if(total > 0 && (yt_ok !== undefined || dc_ok !== undefined)){
    const ytPill = yt_ok > 0
      ? '<span class="pill ok" style="padding:1px 6px; font-size:11px;">YT ✓</span>'
      : '<span class="pill tonal" style="padding:1px 6px; font-size:11px;">YT ✗</span>';
    const dcPill = dc_ok > 0
      ? '<span class="pill ok" style="padding:1px 6px; font-size:11px;">DC ✓</span>'
      : '<span class="pill tonal" style="padding:1px 6px; font-size:11px;">DC ✗</span>';
    svcBadges = ' <span style="display:inline-flex; gap:4px; margin-left:6px; vertical-align:middle;">' + ytPill + dcPill + '</span>';
  }

  const pct = total > 0 ? Math.round((ok / total) * 100) + '%' : '0%';
  return '<div class="list-item two-line" id="benchrow' + idx + '">' +
    '<span class="status ' + stClass + '">' + icon(icName, 's16') + '</span>' +
    '<span class="li-text">' +
      '<span class="li-primary truncate">' + esc(stratTitle) + ' <span class="muted li-mono">(' + esc(name) + ')</span>' + svcBadges + '</span>' +
      '<span class="li-secondary">' + esc(sub) + '</span>' +
    '</span>' +
    '<span class="li-trail ' + (isAllOk || isPartOk ? 'li-value' : 't-label-medium bad') + '">' + esc(pct) + '</span>' +
  '</div>';
}

function renderBenchBest(name, ok, total, avg_ms, best_yt, best_dc){
  const el = $('bench-best');
  if(!el) return;
  if(!name || ok <= 0){
    el.hidden = false;
    el.innerHTML = banner('danger', 'error', '<b>' + esc(t('Ни одна стратегия не сработала')) + '</b><br>' +
      esc(t('Все протестированные стратегии потерпели неудачу на контрольном наборе сайтов.')));
    return;
  }
  el.hidden = false;
  const stratTitle = typeof strategyName === 'function' ? strategyName(name) : name;
  const cur = (typeof currentStrategy !== 'undefined' && currentStrategy) ? currentStrategy : 'default';
  const isCurrent = cur === name;

  const countBadge = t('{0}/{1} хостов ({2} мс)', ok, total, avg_ms);
  const descText = t('Стратегия «{0}» показала максимальную проходимость и скорость на контрольных ресурсах.', stratTitle);

  let extraButtons = '';
  if(best_yt && best_yt !== '-' && best_yt !== name){
    const ytTitle = typeof strategyName === 'function' ? strategyName(best_yt) : best_yt;
    const isYtCurrent = cur === best_yt;
    extraButtons += '<button class="btn with-icon state ' + (isYtCurrent ? 'tonal' : '') + '" onclick="applyBenchStrategy(' + jsArg(best_yt) + ')"' + (isYtCurrent ? ' disabled' : '') + '>' +
      icon(isYtCurrent ? 'check' : 'tune', 's18') +
      '<span>' + (isYtCurrent ? esc(t('YouTube: «{0}» активна', ytTitle)) : esc(t('YouTube Focus: «{0}»', ytTitle))) + '</span>' +
    '</button>';
  }
  if(best_dc && best_dc !== '-' && best_dc !== name && best_dc !== best_yt){
    const dcTitle = typeof strategyName === 'function' ? strategyName(best_dc) : best_dc;
    const isDcCurrent = cur === best_dc;
    extraButtons += '<button class="btn with-icon state ' + (isDcCurrent ? 'tonal' : '') + '" onclick="applyBenchStrategy(' + jsArg(best_dc) + ')"' + (isDcCurrent ? ' disabled' : '') + '>' +
      icon(isDcCurrent ? 'check' : 'tune', 's18') +
      '<span>' + (isDcCurrent ? esc(t('Discord: «{0}» активна', dcTitle)) : esc(t('Discord Focus: «{0}»', dcTitle))) + '</span>' +
    '</button>';
  }

  el.innerHTML = '<div class="subhead-row" style="margin-top:0;">' +
    '<span class="subhead plain">' + esc(t('Лучшая стратегия по результатам прохода')) + '</span>' +
    '<span class="badge number tonal">' + esc(countBadge) + '</span>' +
  '</div>' +
  '<div class="t-body-medium">' +
    esc(descText) +
  '</div>' +
  '<div class="row" style="margin-top:12px; gap:8px; flex-wrap:wrap;">' +
    '<button class="btn with-icon state ' + (isCurrent ? 'tonal' : '') + '" onclick="applyBenchStrategy(' + jsArg(name) + ')"' + (isCurrent ? ' disabled' : '') + '>' +
      icon(isCurrent ? 'check' : 'tune', 's18') +
      '<span>' + (isCurrent ? esc(t('Стратегия «{0}» уже действует', stratTitle)) : esc(t('Применить «{0}»', stratTitle))) + '</span>' +
    '</button>' +
    extraButtons +
  '</div>';
}

function wilsonScore(ok, total) {
  if (!total || total <= 0) return 0;
  const z = 1.96;
  const n = total;
  const p = ok / n;
  const z2 = z * z;
  return (p + z2 / (2 * n) - z * Math.sqrt((p * (1 - p) + z2 / (4 * n)) / n)) / (1 + z2 / n);
}

function sortBenchList(){
  const listEl = $('bench-list');
  if(!listEl) return;
  const sorted = Object.values(benchResults).sort((a, b) => {
    const sA = wilsonScore(a.ok, a.total);
    const sB = wilsonScore(b.ok, b.total);
    return (sB - sA) || (b.ok - a.ok) || (a.avg_ms - b.avg_ms);
  });
  listEl.innerHTML = sorted.map(it => renderBenchRow(it.idx, it.name, it.ok, it.total, it.avg_ms, it.top_fail, false, it.yt_ok, it.dc_ok)).join('');
}

function resetBenchResults(){
  const listEl = $('bench-list');
  if(listEl){ listEl.innerHTML = ''; listEl._html = ''; }
  benchResults = {};
  benchTotalStrats = 0;
  benchBestStrat = null;
  const badge = $('bench-badge');
  if(badge){ badge.hidden = true; badge.textContent = ''; }
  const best = $('bench-best');
  if(best){ best.hidden = true; best.innerHTML = ''; }
}

async function stopBench(){
  if(!benchRunning) return;
  benchCancelled = true;
  updateBenchButtonsStopping();
  await ctlx(['probe-cancel']);
  toast(t('Проверка остановлена'));
}

async function runBench(){
  if(benchRunning){
    await stopBench();
    return;
  }

  benchRunning = true;
  benchCancelled = false;
  resetBenchResults();

  updateBenchButtons(true);

  const onLine = l => {
    if(benchCancelled) return;
    const p = l.split('\t');
    if(p[0] === 'BENCH_START') {
      benchTotalStrats = +p[1] || 0;
      const badge = $('bench-badge');
      if(badge){
        badge.hidden = false;
        badge.className = 'pill tonal';
        badge.textContent = t('Проверка 0/{0}', benchTotalStrats);
      }
    } else if(p[0] === 'BENCH_RUN') {
      const idx = p[1], strat = p[2], total = p[3];
      const badge = $('bench-badge');
      if(badge){
        badge.hidden = false;
        badge.className = 'pill tonal';
        badge.textContent = t('Тест {0}/{1}: {2}', +idx + 1, total, typeof strategyName === 'function' ? strategyName(strat) : strat);
      }
      const existing = $('benchrow' + idx);
      const rowHtml = renderBenchRow(idx, strat, null, null, null, null, true);
      if(existing) existing.outerHTML = rowHtml;
      else if($('bench-list')) $('bench-list').insertAdjacentHTML('beforeend', rowHtml);
    } else if(p[0] === 'BENCH_RES') {
      const idx = p[1], strat = p[2], ok = +p[3] || 0, total = +p[4] || 0, avg_ms = +p[5] || 0, top_fail = p[6] || '-';
      const yt_ok = p[7] !== undefined ? +p[7] : undefined;
      const dc_ok = p[8] !== undefined ? +p[8] : undefined;
      benchResults[strat] = { idx, name: strat, ok, total, avg_ms, top_fail, yt_ok, dc_ok };
      const existing = $('benchrow' + idx);
      const rowHtml = renderBenchRow(idx, strat, ok, total, avg_ms, top_fail, false, yt_ok, dc_ok);
      if(existing) existing.outerHTML = rowHtml;
      else if($('bench-list')) $('bench-list').insertAdjacentHTML('beforeend', rowHtml);
    } else if(p[0] === 'BENCH_BEST') {
      const strat = p[1], ok = +p[2] || 0, total = +p[3] || 0, avg_ms = +p[4] || 0;
      const best_yt = p[5] && p[5] !== '-' ? p[5] : null;
      const best_dc = p[6] && p[6] !== '-' ? p[6] : null;
      benchBestStrat = { name: strat, ok, total, avg_ms, best_yt, best_dc };
      sortBenchList();
      renderBenchBest(strat, ok, total, avg_ms, best_yt, best_dc);
      const badge = $('bench-badge');
      if(badge){
        badge.hidden = false;
        badge.className = 'pill tonal';
        badge.textContent = t('Завершено ({0} стратегий)', benchTotalStrats);
      }
    }
  };

  try {
    await ctlx(['bench-strategies'], 300000, onLine);
  } finally {
    benchRunning = false;
    if(benchCancelled){
      const badge = $('bench-badge');
      if(badge){
        badge.className = 'pill tonal';
        badge.textContent = t('Проверка остановлена');
      }
      document.querySelectorAll('#bench-list .list-item').forEach(el => {
        if(el.querySelector('.spinner')){
          const liSec = el.querySelector('.li-secondary');
          if(liSec) liSec.textContent = t('Прервано');
          const liTrail = el.querySelector('.li-trail');
          if(liTrail) liTrail.textContent = '—';
          const st = el.querySelector('.status');
          if(st){
            st.className = 'status warn';
            st.innerHTML = icon('close', 's16');
          }
        }
      });
    }
    updateBenchButtons(false);
  }
}

async function applyBenchStrategy(name){
  if(typeof applyStrategy === 'function'){
    await applyStrategy(name);
    if(benchBestStrat){
      renderBenchBest(benchBestStrat.name, benchBestStrat.ok, benchBestStrat.total, benchBestStrat.avg_ms);
    }
  }
}

function copyBenchReport(){
  const title = t('Автоподбор стратегий');
  let rep = '### ' + title + ' (nfqws2-android)\n\n';
  if(benchBestStrat){
    const bestTitle = typeof strategyName === 'function' ? strategyName(benchBestStrat.name) : benchBestStrat.name;
    rep += `*Победитель:* ${bestTitle} (${benchBestStrat.name}) — ${benchBestStrat.ok}/${benchBestStrat.total}, ${benchBestStrat.avg_ms} мс\n\n`;
  }
  const sorted = Object.values(benchResults).sort((a, b) => b.ok - a.ok || a.avg_ms - b.avg_ms);
  if(!sorted.length){
    toast(t('Нет результатов для отчёта'));
    return;
  }
  for(const it of sorted){
    const title = typeof strategyName === 'function' ? strategyName(it.name) : it.name;
    const reasonsDict = typeof PROBE_REASON !== 'undefined' ? PROBE_REASON : {};
    rep += `- ${title} (${it.name}): ${it.ok}/${it.total} (${it.avg_ms} мс)` + (it.top_fail && it.top_fail !== '-' ? ` [${t(reasonsDict[it.top_fail] || it.top_fail)}]` : '') + '\n';
  }
  copyText(rep, t('Отчёт скопирован в буфер обмена'), t('Не удалось скопировать: выделите текст вручную'));
}

/* ══ Что нового ══════════════════════════════════════════════════════════
   После обновления модуля, при первом открытии WebUI, — лист с изменениями
   этой версии из changelog.md модуля. Версия, для которой лист уже
   показывали, хранится в nfq_seen_ver; при первой установке не показываем. */
async function checkWhatsNew(){
  const v = S.version;
  if(!v) return;
  const seen = store.get('nfq_seen_ver');
  if(seen === v) return;
  store.set('nfq_seen_ver', v);
  if(seen && !openSheetId && !editorCtx) await openWhatsNew(true);
}
/* Раздел changelog.md для версии: заголовок «### … vX.Y.Z:» — без суффиксов
   вроде -ci.abc1234; нет такого — первый раздел. */
function whatsNewSection(md, version){
  const base = (version || '').replace(/^(v?\d+(?:\.\d+)*).*$/, '$1');
  const parts = md.split(/^### /m).slice(1).map(p => {
    const nl = p.indexOf('\n');
    return {head: p.slice(0, nl < 0 ? p.length : nl).trim(), body: nl < 0 ? '' : p.slice(nl + 1)};
  });
  const esc2 = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return parts.find(p => base && new RegExp('\\b' + esc2(base) + '\\b').test(p.head)) || parts[0] || null;
}
function mdInline(s){
  return esc(s).replace(/\*\*([^*]+)\*\*/g, '<b>$1</b>').replace(/`([^`]+)`/g, '<code>$1</code>');
}
async function openWhatsNew(auto){
  const r = await ctlx(['changelog']);
  const sec = !r.code && whatsNewSection(r.out || '', S.version);
  if(!sec){ if(!auto) toast(errText(r, 'Список изменений недоступен')); return; }
  const items = sec.body.split('\n').map(l => l.trim()).filter(l => /^[-*] /.test(l)).map(l => l.slice(2));
  $('whatsnew-title').textContent = t('Что нового в {0}', (S.version || '').replace(/-.*$/, ''));
  setHTML('whatsnew-body', items.length
    ? '<ul>' + items.map(i => '<li>' + mdInline(i) + '</li>').join('') + '</ul>'
    : '<p>' + mdInline(sec.body.trim()) + '</p>', false);
  openSheet('whatsnew-sheet');
}

