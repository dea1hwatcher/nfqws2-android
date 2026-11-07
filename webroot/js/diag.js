/* nfqws2 WebUI - diagnostics */

let diagRam = '';
let argsRaw = '';

function formatRamEn(str){
  if(!str) return '';
  return str
    .replace(/МБ/gi, 'MB')
    .replace(/КБ/gi, 'KB')
    .replace(/пик/gi, 'peak')
    .replace(/байт/gi, 'bytes');
}

function renderArgs(){
  if(!$('args')) return;
  const ramEn = formatRamEn(diagRam);
  const header = (S && S.running && S.pid)
    ? 'PID ' + S.pid + (ramEn ? ' · RAM: ' + ramEn : '') + '\n\n'
    : '';
  $('args').textContent = header + (argsRaw || t('Служба ещё не запускалась'));
}

function diagInit(){ diagRam = ''; argsRaw = ''; doctor(); loadArgs(); }
async function doctor(){
  setHTML('doc', '<div class="list-item"><span class="spinner"></span>' +
    '<span class="li-text"><span class="li-secondary">' + esc(t('Проверка ядра и правил…')) + '</span></span></div>', false);
  const r = await ctlx(['doctor'], 30000);
  if(!r.code && r.out){
    const match = r.out.split('\n').map(l => l.split('\t')).find(([_, n]) => n === 'ОЗУ' || n === 'RAM');
    diagRam = match && match[2] ? match[2] : '';
    renderArgs();
  }
  setHTML('doc', statusRows(r.code ? '' : r.out) || '<div class="list-item"><span class="li-text"><span class="li-secondary">' +
    esc(r.code ? errText(r, 'Проверка не удалась') : t('Нет данных')) + '</span></span></div>');
}
async function loadArgs(){
  $('args').textContent = t('Загрузка…');
  const r = await ctlx(['get-logs', 'args', '5']);
  argsRaw = (r.code ? errText(r, 'Нет данных') : r.out).trim();
  renderArgs();
}
async function copyArgs(){
  await copyText($('args').textContent, t('Аргументы скопированы'), t('Не удалось скопировать: выделите текст вручную'));
}
