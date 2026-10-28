/* nfqws2 WebUI - DPI detector and availability check */

const PROBE_REASON = {
  dns: 'DNS не отвечает',
  dns_fail: 'Ошибка DNS',
  reset: 'Соединение сброшено',
  tls_rst: 'TLS RST (сброс ClientHello)',
  tls_alert: 'TLS Alert (SNI блок)',
  tls_spoof: 'Подмена ответа (Spoof)',
  tls_mitm: 'Подмена сертификата (MITM)',
  drop: 'Тихий сброс (Drop)',
  timeout: 'Нет ответа (Timeout)',
  isp_redir: 'Заглушка провайдера (RKN)',
  ws_blocked: 'WebSocket Gateway заблокирован (ТСПУ)',
  refused: 'Соединение отклонено',
  tls: 'Ошибка TLS',
  quic_unsupported: 'QUIC не поддерживается',
  other: 'Ошибка'
};

const PROTO_NAMES = {
  1: 'HTTP',
  2: 'TLS 1.2',
  3: 'TLS 1.3',
  4: 'QUIC'
};

let testRunning = false;
let testCancelled = false;
let webViewAbortCtrl = null;
let currentTestTab = 'all';
let netInfoData = null;
let webResults = {};
let tcp16Results = {};
let dnsResults = {};
let lastRecommendation = null;
let quicStatusResult = null;
let tlsDiffResult = null;
let discoveredGoogleVideoCdn = null;
let testDomainTimer = null;
let testLastCheckedDomain = '';

function cleanDomainInput(val){
  return (val || '').trim().toLowerCase()
    .replace(/^[a-z]+:\/\//, '')
    .replace(/\/.*$/, '')
    .replace(/:[0-9]+$/, '')
    .replace(/^www\./, '');
}

function clearTestDomain(){
  const input = $('test-domain');
  if(input) input.value = '';
  const clearBtn = $('test-domain-clear');
  if(clearBtn) clearBtn.hidden = true;
  const status = $('test-domain-status');
  if(status){ status.textContent = ''; status.className = 'helper'; }
  const action = $('test-domain-action');
  if(action){ action.hidden = true; action.innerHTML = ''; }
  testLastCheckedDomain = '';
  if(testDomainTimer) clearTimeout(testDomainTimer);
}

function onTestDomainInput(val){
  const clearBtn = $('test-domain-clear');
  if(clearBtn) clearBtn.hidden = !val;

  if(testDomainTimer) clearTimeout(testDomainTimer);
  const status = $('test-domain-status');
  const action = $('test-domain-action');

  const domain = cleanDomainInput(val);
  if(!domain){
    if(status){ status.textContent = ''; status.className = 'helper'; }
    if(action){ action.hidden = true; action.innerHTML = ''; }
    testLastCheckedDomain = '';
    return;
  }

  testDomainTimer = setTimeout(() => {
    checkTestDomain(domain);
  }, 300);
}

async function checkTestDomain(domain){
  if(!domain) return;
  testLastCheckedDomain = domain;
  const status = $('test-domain-status');
  const action = $('test-domain-action');

  if(!/^[a-z0-9.-]+\.[a-z]{2,}$/.test(domain)){
    if(status){
      status.className = 'helper err';
      status.textContent = t('Некорректный домен');
    }
    if(action){ action.hidden = true; action.innerHTML = ''; }
    return;
  }

  if(status){
    status.className = 'helper';
    status.textContent = t('Проверка списков…');
  }

  try {
    const res = await ctl(['check-domain', domain]);
    const line = (res || '').trim().split('\n')[0] || '';
    const parts = line.split('\t');

    if(parts[0] === 'FOUND'){
      const lists = (parts[2] || '').split(',').filter(Boolean);
      if(status){
        status.className = 'helper';
        status.textContent = t('Домен найден в списках:');
      }
      if(action){
        action.hidden = false;
        let pillsHtml = '';
        for(const listName of lists){
          const isExclude = listName === 'exclude';
          const label = listName + '.list' + (isExclude ? ' (' + t('исключён из обхода') + ')' : '');
          pillsHtml += '<span class="pill tonal">' + esc(label) + '</span>';
        }
        action.innerHTML = pillsHtml;
      }
    } else if(parts[0] === 'NOT_FOUND'){
      if(status){
        status.className = 'helper';
        status.textContent = t('Отсутствует в списках');
      }
      if(action){
        action.hidden = false;
        action.innerHTML = '<button type="button" class="btn text with-icon state" onclick="addTestDomainToUser(' + jsArg(domain) + ')">' +
          icon('add', 's18') +
          '<span>' + esc(t('Добавить в user.list')) + '</span>' +
        '</button>';
      }
    } else {
      if(status){
        status.className = 'helper err';
        status.textContent = t('Некорректный домен');
      }
      if(action){ action.hidden = true; action.innerHTML = ''; }
    }
  } catch(e){
    if(status){
      status.className = 'helper err';
      status.textContent = t('Ошибка проверки домена');
    }
    if(action){ action.hidden = true; action.innerHTML = ''; }
  }
}

async function addTestDomainToUser(domain){
  if(!domain) return;
  try {
    await withBusy(['add-domain', domain]);
    toast(t('Домен добавлен в user.list'));
    await checkTestDomain(domain);
  } catch(e){
    toast(t('Не удалось добавить домен'));
  }
}

function testInit(){
  updateTestDesc();
  stat(true).then(renderTestWarn);
  renderTestWarn();
  refreshNetInfo();
}

function updateTestDesc(){
  const d = $('test-desc');
  if(!d) return;
  if(currentTestTab === 'web'){
    d.textContent = t('Каждый адрес из probe_hosts.list проверяется по 4 протоколам (HTTP, TLS 1.2, TLS 1.3, QUIC). Анализируются активные сбросы (TLS RST), инжекции TLS Alert, тихий дроп и блокировки UDP/QUIC.');
  } else if(currentTestTab === 'tcp16'){
    d.textContent = t('Тестирование соединений к зарубежным CDN и хостингам (Cloudflare, Hetzner, DO, OVH) с нарастающим объёмом данных до 32 КБ для выявления фильтра TCP 16-20KB.');
  } else if(currentTestTab === 'dns'){
    d.textContent = t('Проверка резолверов по UDP:53 и DoH для обнаружения перехвата портов провайдером и подмены IP адресов на заглушки РКН.');
  } else if(currentTestTab === 'domain'){
    d.textContent = t('Проверка списков, IP-адреса и доступности конкретного домена через nfqws2.');
  } else {
    d.textContent = t('Комплексный анализ цензуры DPI: проверка доступности сайтов (HTTP/TLS/QUIC), детекция блокировок TCP 16-20KB и перехват DNS.');
  }
}

function selectTestTab(tab){
  currentTestTab = tab;
  document.querySelectorAll('#test-tabs .seg').forEach(btn => {
    btn.classList.toggle('on', btn.dataset.tab === tab);
  });
  const showWeb = tab === 'all' || tab === 'web';
  const showTcp = tab === 'all' || tab === 'tcp16';
  const showDns = tab === 'all' || tab === 'dns';
  const dom = tab === 'domain';
  ['tb', 'test-warn', 'test-recommendation', 'test-empty', 'test-quic-status'].forEach(id => {
    const el = $(id);
    if(!el) return;
    if(dom){ if(!el.hidden) el.dataset.domHidden = '1'; el.hidden = true; }
    else if(el.dataset.domHidden){ delete el.dataset.domHidden; el.hidden = false; }
  });
  if($('test-sec-domain')) $('test-sec-domain').hidden = !dom;
  if(dom){
    if($('test-sec-web')) $('test-sec-web').hidden = true;
    if($('test-sec-tcp16')) $('test-sec-tcp16').hidden = true;
    if($('test-sec-dns')) $('test-sec-dns').hidden = true;
    updateTestDesc();
    return;
  }

  if($('test-sec-web')) $('test-sec-web').hidden = !showWeb;
  if($('test-sec-tcp16')) $('test-sec-tcp16').hidden = !showTcp;
  if($('test-sec-dns')) $('test-sec-dns').hidden = !showDns;

  updateTestDesc();
}

/* net-info returns one TAB-separated line: NET ip loc isp asn iface gw dns status strategy; unknown is "-" */
const NET_FIELDS = ['ip', 'loc', 'isp', 'asn', 'iface', 'gw', 'dns', 'status', 'strategy'];
function parseNetInfo(out){
  const data = {};
  const line = (out || '').split('\n').find(l => l.startsWith('NET\t'));
  if(!line) return data;
  const p = line.split('\t');
  NET_FIELDS.forEach((k, i) => {
    const v = (p[i + 1] || '').trim();
    if(v && v !== '—') data[k] = v;
  });
  return data;
}

async function refreshNetInfo(){
  const ipEl = $('net-ip'), ispEl = $('net-isp'), badgeEl = $('net-badge');
  if(!ipEl || !ispEl) return;
  ispEl.textContent = t('Загрузка сети…');
  const r = await ctlx(['net-info'], 8000);
  if(r.code && !r.out){
    ispEl.textContent = t('Сетевые данные недоступны');
    return;
  }
  const data = parseNetInfo(r.out);
  netInfoData = data;
  ipEl.textContent = data.ip ? `${data.ip} (${data.loc || '?'})` : t('Локальная сеть');
  const ispText = [data.isp, data.asn, data.dns ? `DNS: ${data.dns}` : ''].filter(Boolean).join(' · ');
  ispEl.textContent = ispText || t('Информация о провайдере отсутствует');

  if(badgeEl){
    const active = data.status === 'running';
    badgeEl.innerHTML = `<span class="status ${active ? 'ok' : 'info'}">${icon(active ? 'shield' : 'wifi', 's16')}</span>`;
  }
}

function renderTestWarn(){
  let w = '';
  if(S.running === false) w += banner('', 'info', S.paused
    ? (S.paused === 'vpn'
        ? t('Служба на паузе из-за активного VPN: проверяется прямое соединение, без обхода.')
        : t('Служба на паузе в домашней Wi‑Fi: проверяется прямое соединение, без обхода.'))
    : t('Служба остановлена: проверяется прямое соединение, без обхода.'));
  setHTML('test-warn', w, false);
}

function testRow(i, h){
  return '<div class="list-item two-line" id="trow' + i + '">' +
    '<span class="status info" id="ti' + i + '"><span class="spinner" style="width:14px;height:14px;"></span></span>' +
    '<span class="li-text"><span class="li-primary li-mono truncate">' + esc(h) + '</span>' +
      '<span class="li-secondary" id="ts' + i + '">' + esc(t('Проверка…')) + '</span></span>' +
    '<span class="li-trail li-value" id="tr' + i + '">…</span>' +
  '</div>';
}

function finishTestRow(i, res){
  const active = res.filter(x => !x.skip);
  const ok = active.filter(x => x.ok), n = active.length;
  const badge = $('ti' + i);
  if(!badge) return;
  badge.className = 'status ' + (ok.length === n && n > 0 ? 'ok' : (ok.length ? 'warn' : 'bad'));
  badge.innerHTML = icon(ok.length === n && n > 0 ? 'check' : (ok.length ? 'warn' : 'close'), 's16');
  const tr = $('tr' + i);
  if(tr) tr.textContent = ok.length + '/' + n;

  const failedProtos = res.filter(x => !x.ok && !x.skip).map(x => {
    const pName = PROTO_NAMES[x.proto];
    const rName = t(PROBE_REASON[x.reason] || PROBE_REASON.other);
    return pName ? `${pName}: ${rName}` : rName;
  });
  const reasons = [...new Set(failedProtos)];

  const ts = $('ts' + i);
  if(ts) {
    const avg = ok.length ? t('{0} мс в среднем', Math.round(ok.reduce((a, x) => a + x.ms, 0) / ok.length)) : '';
    let details = avg + (avg && reasons.length ? ' · ' : '') + reasons.join(', ');
    const h = webResults[i] && webResults[i].host;
    if(h && (h.includes('googlevideo') || h.includes('youtube')) && discoveredGoogleVideoCdn){
      details += (details ? ' · ' : '') + 'CDN: ' + discoveredGoogleVideoCdn;
    }
    ts.textContent = details;
  }
}

function renderTcp16Row(i, provider, ip, port, status, detail){
  const isClean = status === 'clean';
  const isDetected = status === 'detected';
  const stClass = isClean ? 'ok' : (isDetected ? 'bad' : 'info');
  const icName = isClean ? 'check' : (isDetected ? 'warn' : 'close');
  const trailText = isClean ? `${detail || 'OK'}` : (isDetected ? `БЛОК @ ${detail}` : t('Недоступен'));
  return '<div class="list-item two-line" id="tcprow' + i + '">' +
    '<span class="status ' + stClass + '">' + icon(icName, 's16') + '</span>' +
    '<span class="li-text">' +
      '<span class="li-primary truncate">' + esc(provider.replace(/_/g, ' ')) + ' <span class="muted li-mono">(' + esc(ip) + ')</span></span>' +
      '<span class="li-secondary">' + esc(isClean ? t('Чисто, передача данных стабильна') : (isDetected ? t('Обрыв сессии ТСПУ после {0}', detail) : t('Хост недоступен'))) + '</span>' +
    '</span>' +
    '<span class="li-trail ' + (isDetected ? 't-label-medium bad' : 'li-value') + '">' + esc(trailText) + '</span>' +
  '</div>';
}

function renderDnsRow(i, name, ip, udp, doh, hijacked, detail){
  const isHijacked = hijacked === 'yes';
  const isUdpOk = udp === 'ok';
  const stClass = isHijacked ? 'bad' : (isUdpOk ? 'ok' : 'warn');
  const icName = isHijacked ? 'warn' : (isUdpOk ? 'check' : 'close');
  let sub = `UDP: ${isUdpOk ? 'OK' : t('Блок')}`;
  if(doh && doh !== 'none') sub += ` · DoH: ${doh === 'ok' ? 'OK' : t('Блок')}`;
  if(isHijacked) sub += ` · ${detail}`;
  const trail = isHijacked ? t('ПЕРЕХВАТ') : (isUdpOk ? 'OK' : t('СБОЙ'));
  return '<div class="list-item two-line" id="dnsrow' + i + '">' +
    '<span class="status ' + stClass + '">' + icon(icName, 's16') + '</span>' +
    '<span class="li-text">' +
      '<span class="li-primary truncate">' + esc(name.replace(/_/g, ' ')) + ' <span class="muted li-mono">(' + esc(ip) + ')</span></span>' +
      '<span class="li-secondary">' + esc(sub) + '</span>' +
    '</span>' +
    '<span class="li-trail ' + (isHijacked ? 't-label-medium bad' : 'li-value') + '">' + esc(trail) + '</span>' +
  '</div>';
}

function startBenchFromRec(){
  navigate('settings');
  setTimeout(() => {
    const el = $('bench-block');
    if(el) el.scrollIntoView({ behavior: 'smooth' });
    if(typeof runBench === 'function') runBench();
  }, 150);
}

function resetTestResults(){
  ['tr', 'test-tcp16-list', 'test-dns-list'].forEach(id => {
    const el = $(id);
    if(el){ el.innerHTML = ''; el._html = ''; }
  });
  webResults = {}; tcp16Results = {}; dnsResults = {}; lastRecommendation = null;
  quicStatusResult = null; tlsDiffResult = null; discoveredGoogleVideoCdn = null;
  const recEl = $('test-recommendation');
  if(recEl){ recEl.hidden = true; recEl.innerHTML = ''; }
  const quicEl = $('test-quic-status');
  if(quicEl){ quicEl.hidden = true; quicEl.innerHTML = ''; }
}

async function stopTest(){
  if(!testRunning) return;
  testCancelled = true;
  if(webViewAbortCtrl){
    try { webViewAbortCtrl.abort(); } catch(_){}
  }
  const tb = $('tb');
  if(tb){
    tb.disabled = true;
    tb.innerHTML = '<span class="spinner"></span><span>' + esc(t('Остановка…')) + '</span>';
  }
  await ctlx(['probe-cancel']);
  toast(t('Проверка остановлена'));
}

async function loadGoogleVideoCdn(){
  try {
    const r = await ctlx(['googlevideo-discovery']);
    if(r.code === 0 && r.out){
      const m = r.out.match(/GOOGLEVIDEO_CDN\t([^\r\n]+)/);
      if(m && m[1] && m[1] !== '—'){
        discoveredGoogleVideoCdn = m[1].trim();
        Object.keys(webResults).forEach(idx => {
          const item = webResults[idx];
          if(item && item.host && (item.host.includes('googlevideo') || item.host.includes('youtube'))){
            const ts = $('ts' + idx);
            if(ts && ts.textContent && !ts.textContent.includes('CDN:')){
              ts.textContent += (ts.textContent ? ' · ' : '') + 'CDN: ' + discoveredGoogleVideoCdn;
            }
          }
        });
        renderQuicIndicator();
      }
    }
  } catch(_){}
}

async function runTest(){
  if(testRunning){
    await stopTest();
    return;
  }

  let targetDomain = '';
  const domainInput = $('test-domain');
  if(domainInput && domainInput.value.trim()){
    targetDomain = cleanDomainInput(domainInput.value);
    if(!/^[a-z0-9.-]+\.[a-z]{2,}$/.test(targetDomain)){
      toast(t('Некорректный домен'));
      domainInput.focus();
      return;
    }
  }

  testRunning = true;
  testCancelled = false;
  webViewAbortCtrl = new AbortController();

  const tb = $('tb');
  if(tb){
    tb.disabled = false;
    tb.classList.add('danger');
    tb.innerHTML = icon('stop', 's18') + '<span>' + esc(t('Остановить')) + '</span>';
  }
  if($('test-empty')) $('test-empty').hidden = true;

  resetTestResults();

  await stat(true);
  renderTestWarn();
  await refreshNetInfo();
  loadGoogleVideoCdn();

  const hosts = [];
  let tool = '';

  const onLine = l => {
    if(testCancelled) return;
    const p = l.split('\t');
    if(p[0] === 'tool') {
      tool = p[1];
    } else if(p[0] === 'H') {
      hosts[+p[1]] = p[2];
      webResults[p[1]] = {host: p[2], list: []};
      $('tr').insertAdjacentHTML('beforeend', testRow(p[1], p[2]));
    } else if(p[0] === 'R' && webResults[p[1]]) {
      const v = (p[3] || '').split(' ');
      const proto = +p[2] || (webResults[p[1]].list.length + 1);
      const isOk = v[0] === 'ok';
      const isSkip = v[0] === 'skip';
      const resItem = isOk
        ? { ok: true, ms: +v[1] || 0, proto }
        : (isSkip
            ? { ok: false, skip: true, reason: v[1] || 'skip', proto }
            : { ok: false, reason: v[1] || 'other', proto });
      webResults[p[1]].list.push(resItem);
      const active = webResults[p[1]].list.filter(x => !x.skip);
      const rowEl = $('tr' + p[1]);
      if(rowEl) rowEl.textContent = active.filter(x => x.ok).length + '/' + active.length;
      if(webResults[p[1]].list.length === 4) finishTestRow(p[1], webResults[p[1]].list);
    } else if(p[0] === 'T16') {
      const idx = p[1], provider = p[2], ip = p[3], port = p[4], st = p[5], detail = p[6];
      tcp16Results[idx] = {provider, ip, port, status: st, detail};
      const existing = $('tcprow' + idx);
      const rowHtml = renderTcp16Row(idx, provider, ip, port, st, detail);
      if(existing) existing.outerHTML = rowHtml;
      else if($('test-tcp16-list')) $('test-tcp16-list').insertAdjacentHTML('beforeend', rowHtml);
    } else if(p[0] === 'DNS') {
      const idx = p[1], name = p[2], ip = p[3], udp = p[4], doh = p[5], hijacked = p[6], detail = p[7];
      dnsResults[idx] = {name, ip, udp, doh, hijacked, detail};
      const existing = $('dnsrow' + idx);
      const rowHtml = renderDnsRow(idx, name, ip, udp, doh, hijacked, detail);
      if(existing) existing.outerHTML = rowHtml;
      else if($('test-dns-list')) $('test-dns-list').insertAdjacentHTML('beforeend', rowHtml);
    } else if(p[0] === 'QUIC_STATUS') {
      const idx = p[1], host = p[2], verdict = p[3], desc = p[4];
      quicStatusResult = quicStatusResult || {};
      quicStatusResult[host] = { verdict, desc };
      renderQuicIndicator();
    } else if(p[0] === 'TLS_DIFF') {
      const idx = p[1], host = p[2], verdict = p[3], desc = p[4];
      tlsDiffResult = tlsDiffResult || {};
      tlsDiffResult[host] = { verdict, desc };
      renderQuicIndicator();
    }
  };

  try {
    const args = ['probe-dpi', currentTestTab];
    if(targetDomain) args.push(targetDomain);
    const r = await ctlx(args, 180000, onLine);
    if(!testCancelled){
      if(tool === 'none' || (r.code && !hosts.length && (currentTestTab === 'web' || targetDomain))) {
        await runTestWebView(targetDomain);
      } else {
        Object.keys(webResults).forEach(i => {
          if(webResults[i].list.length < 4) {
            finishTestRow(i, webResults[i].list.length ? webResults[i].list : [{ok: false, reason: 'timeout'}]);
          }
        });
      }
    }
  } finally {
    testRunning = false;
    if(testCancelled){
      document.querySelectorAll('#tr .list-item, #test-tcp16-list .list-item, #test-dns-list .list-item').forEach(el => {
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
    if(tb){
      tb.classList.remove('danger');
      tb.disabled = false;
      tb.innerHTML = icon('play', 's18') + '<span>' + esc(t('Проверить снова')) + '</span>';
    }
    if(!testCancelled){
      renderRecommendation();
    }
  }
}

/* Fallback: fetch from the WebView */
async function probeFetch(u, signal){
  const t0 = performance.now();
  try {
    await fetch('https://' + u + (u.includes('?') ? '&' : '?') + '_=' + Date.now() + Math.random(),
      {mode: 'no-cors', cache: 'no-store', credentials: 'omit', signal});
    return {ok: true, ms: performance.now() - t0};
  } catch(e) {
    return {ok: false, reason: signal && signal.aborted ? 'timeout' : 'reset'};
  }
}

async function runTestWebView(targetDomain){
  setHTML('test-warn', $('test-warn').innerHTML + banner('', 'warn',
    t('На устройстве нет curl или busybox wget с TLS — проверка идёт через WebView и показывает лишь приблизительную картину.')), false);
  let hosts;
  if(targetDomain){
    hosts = [targetDomain];
  } else {
    const r = await ctlx(['get-list', 'probe_hosts']);
    hosts = (r.code ? '' : r.out).split('\n').map(s => s.trim()).filter(s => s && s[0] !== '#');
  }
  setHTML('tr', hosts.map((h, i) => testRow(i, h)).join(''), false);
  if(!hosts.length){
    if($('test-empty')) $('test-empty').hidden = false;
    if($('test-empty-title')) $('test-empty-title').textContent = t('probe_hosts.list пуст');
    return;
  }
  for(let i = 0; i < hosts.length; i++){
    if(testCancelled) break;
    const h = hosts[i];
    const out = [];
    for(let k = 0; k < 3; k++){
      if(testCancelled) break;
      const subCtrl = new AbortController();
      const onParentAbort = () => subCtrl.abort();
      if(webViewAbortCtrl) webViewAbortCtrl.signal.addEventListener('abort', onParentAbort);
      const tm = setTimeout(() => subCtrl.abort(), 6000);
      try {
        out.push(await probeFetch(h, subCtrl.signal));
      } finally {
        clearTimeout(tm);
        if(webViewAbortCtrl) webViewAbortCtrl.signal.removeEventListener('abort', onParentAbort);
      }
    }
    finishTestRow(i, out);
  }
}

/* Result analysis and strategy recommendation */
function analyzeProbeResults(webRes, tcp16Res, dnsRes){
  const webKeys = Object.keys(webRes || {});
  const tcpKeys = Object.keys(tcp16Res || {});
  const dnsKeys = Object.keys(dnsRes || {});

  if(!webKeys.length && !tcpKeys.length && !dnsKeys.length) return null;

  let totalWeb = webKeys.length;
  let okWeb = 0;
  let rstCount = 0;
  let alertCount = 0;
  let dropCount = 0;
  let otherFailWeb = 0;

  webKeys.forEach(k => {
    const list = (webRes[k].list || []).filter(x => !x.skip);
    const oks = list.filter(x => x.ok);
    if(oks.length >= 2 || (list.length > 0 && oks.length === list.length)) {
      okWeb++;
    } else {
      const reasons = list.filter(x => !x.ok).map(x => x.reason);
      if(reasons.some(r => r === 'tls_alert')) alertCount++;
      else if(reasons.some(r => r === 'tls_rst' || r === 'reset')) rstCount++;
      else if(reasons.some(r => r === 'drop' || r === 'timeout')) dropCount++;
      else otherFailWeb++;
    }
  });

  let tcp16Detected = 0;
  let tcp16Clean = 0;
  tcpKeys.forEach(k => {
    const st = tcp16Res[k].status;
    if(st === 'detected') tcp16Detected++;
    else if(st === 'clean') tcp16Clean++;
  });

  let dnsHijacked = 0;
  let dnsUdpBlocked = 0;
  dnsKeys.forEach(k => {
    if(dnsRes[k].hijacked === 'yes') dnsHijacked++;
    if(dnsRes[k].udp === 'fail') dnsUdpBlocked++;
  });

  const failWeb = totalWeb - okWeb;
  const isClean = (failWeb === 0 && tcp16Detected === 0);

  let strategy = 'fake_tls_auto';
  let altStrategies = ['alt4_mod', 'alt11'];
  let summaryTitle = '';
  let reason = '';

  if(isClean){
    const cur = (typeof currentStrategy !== 'undefined' && currentStrategy) ? currentStrategy : 'default';
    strategy = cur;
    altStrategies = cur === 'default' ? ['fake_tls_auto', 'alt4_mod'] : ['default', 'fake_tls_auto'];
    summaryTitle = t('Блокировок не обнаружено');
    reason = t('Все проверенные сайты и соединения к CDN работают стабильно без вмешательства DPI.');
  } else if(tcp16Detected > 0){
    if(alertCount > 0 || rstCount > 0){
      strategy = 'fake_tls_auto_alt2';
      altStrategies = ['fake_tls_auto_alt3', 'alt4_mod'];
      summaryTitle = t('Обнаружены TCP 16-20KB и фильтрация TLS');
      reason = t('DPI разрывает сессии после 16-20 КБ данных и блокирует ClientHello. Рекомендуется стратегия со сплитом пакетов и маскировкой перекрытиями (multisplit + seqovl).');
    } else {
      strategy = 'alt4_mod';
      altStrategies = ['alt4', 'fake_tls_auto_alt2'];
      summaryTitle = t('Обнаружен фильтр TCP 16-20KB');
      reason = t('Соединения к зарубежным CDN (Cloudflare/Hetzner) обрываются после 16-20 КБ данных. Рекомендуется сегментация TCP пакетов.');
    }
  } else if(alertCount > 0){
    strategy = 'fake_tls_auto';
    altStrategies = ['fake_tls_auto_alt', 'simple_fake_alt2'];
    summaryTitle = t('Обнаружена блокировка по SNI (TLS Alert)');
    reason = t('DPI перехватывает имя хоста в ClientHello и посылает TLS Alert. Рекомендуется стратегия с поддельным SNI и рандомизацией.');
  } else if(rstCount > 0){
    strategy = 'fake_tls_auto';
    altStrategies = ['simple_fake_alt2', 'alt8'];
    summaryTitle = t('Обнаружен активный сброс (TLS RST)');
    reason = t('DPI инжектирует пакеты TCP RST при попытке установить защищенное соединение. Рекомендуется отправка фейкового ClientHello со сдвигом окна.');
  } else if(dropCount > 0){
    strategy = 'alt11';
    altStrategies = ['alt12', 'exp'];
    summaryTitle = t('Обнаружен тихий сброс (Drop / Timeout)');
    reason = t('DPI молча отбрасывает пакеты без ответа. Рекомендуется стратегия с повышенным числом повторов (repeats=8) и модификацией TCP Timestamps.');
  } else {
    strategy = 'eduncey';
    altStrategies = ['hardcorp74', 'fake_tls_auto'];
    summaryTitle = t('Смешанный профиль цензуры');
    reason = t('Обнаружен нестандартный профиль блокировок. Рекомендуется адаптивная стратегия с циклическим самоподбором методов (circular).');
  }

  let dnsWarning = '';
  if(dnsHijacked > 0 || dnsUdpBlocked > 0){
    dnsWarning = t('Внимание: обнаружен перехват или подмена DNS провайдером. Рекомендуется включить «Частный DNS» (DoH) в настройках системы.');
  }

  return {
    strategy,
    altStrategies,
    title: summaryTitle,
    reason,
    dnsWarning,
    isClean,
    stats: { totalWeb, okWeb, failWeb, tcp16Detected, tcp16Clean, dnsHijacked }
  };
}

function renderRecommendation(){
  const el = $('test-recommendation');
  if(!el) return;
  const rec = analyzeProbeResults(webResults, tcp16Results, dnsResults);
  lastRecommendation = rec;
  if(!rec){
    el.hidden = true;
    el.innerHTML = '';
    return;
  }
  el.hidden = false;

  const cur = (typeof currentStrategy !== 'undefined' && currentStrategy) ? currentStrategy : 'default';
  const isCurrent = cur === rec.strategy;
  const stratTitle = typeof strategyName === 'function' ? strategyName(rec.strategy) : rec.strategy;

  let html = '<div class="subhead-row" style="margin-top:0;">' +
    '<span class="subhead plain">' + esc(t('Автоподбор стратегии')) + '</span>' +
    '<span class="pill tonal badge">' + esc(rec.title) + '</span>' +
  '</div>' +
  '<div class="t-body-medium">' + esc(rec.reason) + '</div>';

  if(rec.dnsWarning){
    html += '<div class="helper err" style="margin-top:8px;">' + icon('warn', 's16') + ' ' + esc(rec.dnsWarning) + '</div>';
  }

  html += '<div class="row" style="margin-top:12px; flex-wrap:wrap; gap:8px;">' +
    '<button class="btn with-icon state ' + (isCurrent ? 'tonal' : '') + '" onclick="applyRecommendedStrategy(' + jsArg(rec.strategy) + ')"' + (isCurrent ? ' disabled' : '') + '>' +
      icon(isCurrent ? 'check' : 'tune', 's18') +
      '<span>' + (isCurrent ? esc(t('Стратегия «{0}» уже действует', stratTitle)) : esc(t('Применить «{0}»', stratTitle))) + '</span>' +
    '</button>';

  if(rec.altStrategies && rec.altStrategies.length > 0){
    rec.altStrategies.forEach(altName => {
      const isAltCur = cur === altName;
      const altTitle = typeof strategyName === 'function' ? strategyName(altName) : altName;
      html += '<button class="btn tonal sm state" onclick="applyRecommendedStrategy(' + jsArg(altName) + ')"' + (isAltCur ? ' disabled' : '') + '>' +
        '<span>' + esc(isAltCur ? altTitle + ' (' + t('действует') + ')' : altTitle) + '</span>' +
      '</button>';
    });
  }

  html += '<button class="btn text sm with-icon state" onclick="startBenchFromRec()">' +
    icon('tune', 's16') +
    '<span>' + esc(t('Полный автоподбор по всем стратегиям')) + '</span>' +
  '</button>';

  html += '</div>';

  el.innerHTML = html;
}

async function applyRecommendedStrategy(name){
  if(typeof applyStrategy === 'function'){
    await applyStrategy(name);
    renderRecommendation();
    if(typeof renderBenchBest === 'function' && typeof benchBestStrat !== 'undefined' && benchBestStrat){
      renderBenchBest(benchBestStrat.name, benchBestStrat.ok, benchBestStrat.total, benchBestStrat.avg_ms);
    }
  }
}

function renderQuicIndicator(){
  const el = $('test-quic-status');
  if(!el) return;
  const quicKeys = Object.keys(quicStatusResult || {});
  const tlsKeys = Object.keys(tlsDiffResult || {});
  if(!quicKeys.length && !tlsKeys.length && !discoveredGoogleVideoCdn){
    el.hidden = true;
    el.innerHTML = '';
    return;
  }
  el.hidden = false;

  let hasBlockedQuic = false;
  let hasOkQuic = false;
  quicKeys.forEach(k => {
    if(quicStatusResult[k].verdict === 'blocked') hasBlockedQuic = true;
    if(quicStatusResult[k].verdict === 'ok') hasOkQuic = true;
  });

  let tlsDiffSummary = '';
  tlsKeys.forEach(k => {
    const v = tlsDiffResult[k].verdict;
    if(v === 'tls13_blocked' || v === 'tls12_blocked' || v === 'both_blocked'){
      tlsDiffSummary = t(tlsDiffResult[k].desc);
    }
  });

  const quicBadgeClass = hasBlockedQuic ? 'bad' : (hasOkQuic ? 'ok' : 'info');
  const quicBadgeText = hasBlockedQuic
    ? t('QUIC глушится ТСПУ')
    : (hasOkQuic ? t('QUIC доступен') : t('QUIC проверяется'));

  let descText = '';
  if(hasBlockedQuic){
    descText = t('DPI отбрасывает UDP/QUIC (HTTP/3) пакеты. Рекомендуется активировать «Блокировать QUIC» в настройках модуля для принудительного отката браузера на TCP TLS.');
  } else if(hasOkQuic){
    descText = t('Протокол QUIC (HTTP/3) работает без искажений со стороны ТСПУ.');
  }

  let html = '<div class="subhead-row" style="margin-top:0;">' +
    '<span class="subhead plain">' + esc(t('Диагностика QUIC & TLS')) + '</span>' +
    '<span class="pill tonal badge ' + quicBadgeClass + '">' + esc(quicBadgeText) + '</span>' +
  '</div>';

  if(descText){
    html += '<div class="t-body-medium">' + esc(descText) + '</div>';
  }

  if(tlsDiffSummary){
    html += '<div class="helper err" style="margin-top:8px;">' + icon('warn', 's16') + ' ' + esc(tlsDiffSummary) + '</div>';
  }

  if(discoveredGoogleVideoCdn){
    html += '<div class="helper" style="margin-top:8px;">' + icon('play', 's16') + ' ' + esc(t('Региональный CDN YouTube / GoogleVideo: {0}', discoveredGoogleVideoCdn)) + '</div>';
  }

  el.innerHTML = html;
}

function copyTestReport(){
  let rep = '### DPI Detector (nfqws2-android)\n\n';
  if(netInfoData){
    rep += `**Сеть:** IP: ${netInfoData.ip || '—'} (${netInfoData.loc || '—'}), Провайдер: ${netInfoData.isp || '—'} (${netInfoData.asn || '—'})\n`;
    rep += `**Обход:** ${netInfoData.status === 'running' ? 'Активен' : 'Остановлен'}, Стратегия: ${netInfoData.strategy || '—'}, DNS: ${netInfoData.dns || '—'}\n\n`;
  }
  const rec = lastRecommendation || analyzeProbeResults(webResults, tcp16Results, dnsResults);
  if(rec){
    rep += `#### Анализ и автоподбор стратегии:\n`;
    rep += `- Вердикт: ${rec.title}\n`;
    rep += `- Рекомендованная стратегия: ${rec.strategy}\n`;
    rep += `- Обоснование: ${rec.reason}\n`;
    if(rec.dnsWarning) rep += `- DNS: ${rec.dnsWarning}\n`;
    rep += '\n';
  }
  if(Object.keys(webResults).length > 0){
    rep += '#### Сайты и сервисы:\n';
    for(const k of Object.keys(webResults)){
      const item = webResults[k];
      const ok = item.list.filter(x => x.ok);
      const fails = [...new Set(item.list.filter(x => !x.ok).map(x => PROBE_REASON[x.reason] || x.reason))];
      rep += `- ${item.host}: ${ok.length}/${item.list.length}` + (ok.length ? ` (${Math.round(ok.reduce((a,x)=>a+x.ms,0)/ok.length)} мс)` : '') + (fails.length ? ` [${fails.join(', ')}]` : '') + '\n';
    }
    rep += '\n';
  }
  if(Object.keys(tcp16Results).length > 0){
    rep += '#### TCP 16-20KB блокировка (CDN и хостинги):\n';
    for(const k of Object.keys(tcp16Results)){
      const it = tcp16Results[k];
      rep += `- ${it.provider} (${it.ip}): ${it.status === 'clean' ? 'CLEAN (' + it.detail + ')' : (it.status === 'detected' ? 'DETECTED @ ' + it.detail : 'UNREACHABLE')}\n`;
    }
    rep += '\n';
  }
  if(Object.keys(dnsResults).length > 0){
    rep += '#### DNS и перехват:\n';
    for(const k of Object.keys(dnsResults)){
      const it = dnsResults[k];
      rep += `- ${it.name} (${it.ip}): UDP=${it.udp}, DoH=${it.doh}, Перехват=${it.hijacked === 'yes' ? 'ДА (' + it.detail + ')' : 'НЕТ'}\n`;
    }
    rep += '\n';
  }
  if(discoveredGoogleVideoCdn || (quicStatusResult && Object.keys(quicStatusResult).length > 0) || (tlsDiffResult && Object.keys(tlsDiffResult).length > 0)){
    rep += '#### QUIC и региональные CDN:\n';
    if(discoveredGoogleVideoCdn){
      rep += `- YouTube / GoogleVideo CDN: ${discoveredGoogleVideoCdn}\n`;
    }
    if(quicStatusResult){
      for(const h of Object.keys(quicStatusResult)){
        rep += `- QUIC ${h}: ${quicStatusResult[h].verdict} (${quicStatusResult[h].desc})\n`;
      }
    }
    if(tlsDiffResult){
      for(const h of Object.keys(tlsDiffResult)){
        rep += `- TLS Diff ${h}: ${tlsDiffResult[h].verdict} (${tlsDiffResult[h].desc})\n`;
      }
    }
    rep += '\n';
  }

  copyText(rep, t('Отчёт скопирован в буфер обмена'), t('Не удалось скопировать: выделите текст вручную'));
}

/* ══ Проверка одного домена ══════════════════════════════════════════════
   domain-check отвечает строками MODE / LIST / IP / R (попытки) / done; итог
   складываем здесь: исключён ли домен, попадает ли под обход, открывается ли. */
const DC_ROLE = {
  host: 'список обхода', auto: 'автообучение', exclude: 'исключения',
  ipset: 'IP-список обхода', 'ipset-exclude': 'IP-исключения', idle: 'не подключён к текущей стратегии'
};
let dcRunning = false;
async function runDomainCheck(){
  const q = $('dc-q').value.trim();
  if(!q || dcRunning) return;
  dcRunning = true;
  $('dc-go').disabled = true;
  $('dc-q').blur();
  const st = {mode: '', lists: [], ip: '', tries: [], keep: ''};
  const paint = done => setHTML('dc-res', dcRender(q, st, done), false);
  paint(false);
  const r = await ctlx(['domain-check', q], 60000, line => {
    const p = line.split('\t');
    if(p[0] === 'MODE') st.mode = p[1];
    else if(p[0] === 'LIST') st.lists.push({file: p[1], role: p[2], entry: p[3]});
    else if(p[0] === 'IP') st.ip = p[1];
    else if(p[0] === 'R'){ const [ok, v] = (p[2] || '').split(' '); st.tries.push({ok: ok === 'ok', v}); }
    else if(p[0] === 'K') st.keep = p[1];
    else return;
    paint(false);
  });
  dcRunning = false;
  $('dc-go').disabled = false;
  if(r.code){ setHTML('dc-res', banner('danger', 'error', errText(r, 'Не удалось проверить домен')), false); return; }
  paint(true);
}
function dcVerdict(st){
  const has = role => st.lists.some(l => l.role === role);
  if(has('exclude') || has('ipset-exclude')) return ['warn', 'warn', t('В исключениях: обход к этому домену не применяется')];
  if(has('host') || has('auto') || has('ipset')) return ['ok', 'check', t('Под обходом')];
  if(st.mode === 'all') return ['ok', 'check', t('Под обходом: режим «все сайты, кроме исключений»')];
  return ['warn', 'info', t('Не под обходом: домена нет в списках, которые использует текущая стратегия')];
}
function dcRender(q, st, done){
  const out = [];
  if(st.mode){
    const [kind, ic, text] = dcVerdict(st);
    out.push(banner(kind === 'ok' ? '' : 'warn', ic, text));
    if(!S.running) out.push(banner('', 'info', t('Служба остановлена — сейчас обход не работает ни для каких доменов.')));
  }
  const rows = [];
  if(st.mode) rows.push(dcRow('list', t('Списки'), st.lists.length
    ? st.lists.map(l => l.file + ' — ' + l.entry + ' (' + t(DC_ROLE[l.role] || l.role) + ')').join('\n')
    : t('Ни в одном списке')));
  if(st.ip) rows.push(dcRow('globe', t('IP-адрес'), st.ip));
  const n = st.tries.length, ok = st.tries.filter(x => x.ok);
  if(n || !done){
    let sub;
    if(!n) sub = t('Проверяю…');
    else if(ok.length) sub = t('Открылся {0} из {1}, ~{2} мс', ok.length, n, Math.round(ok.reduce((a, x) => a + (+x.v || 0), 0) / ok.length));
    else sub = t('Не открылся: {0}', [...new Set(st.tries.map(x => t(PROBE_REASON[x.v] || PROBE_REASON.other)))].join(', '));
    rows.push(dcRow('test', t('Доступность через обход'), sub, n && !done ? '' : (n ? (ok.length === n ? 'ok' : ok.length ? 'warn' : 'bad') : '')));
  } else if(done) rows.push(dcRow('test', t('Доступность через обход'), t('Нет curl или wget — открыть сайт с устройства нечем')));
  // второй запрос по тому же соединению: так ходят приложения и браузер
  if(st.keep === 'ok') rows.push(dcRow('refresh', t('Повторный запрос'), t('Проходит по тому же соединению'), 'ok'));
  else if(st.keep === 'stall') rows.push(dcRow('refresh', t('Повторный запрос'),
    t('Зависает: первый запрос отвечает, следующий по тому же соединению — нет. Соединение замораживается после первого обмена — приложения покажут ошибку со второго запроса'), 'bad'));
  else if(n === 3 && ok.length && !done) rows.push(dcRow('refresh', t('Повторный запрос'), t('Проверяю…')));
  if(rows.length) out.push('<div class="list">' + rows.join('') + '</div>');
  if(done && st.mode){
    const acts = [];
    if(!st.lists.some(l => l.role === 'host'))
      acts.push('<button class="btn tonal with-icon state" onclick="dcAddUser(' + jsArg(q) + ')">' + icon('add', 's18') + '<span>' + esc(t('Добавить в user.list')) + '</span></button>');
    if(st.lists.length)
      acts.push('<button class="btn text state" aria-haspopup="menu" onclick="dcPickList(this)">' + esc(t('Открыть список')) + '</button>');
    dcLast = st;
    if(acts.length) out.push('<div class="row">' + acts.join('') + '</div>');
  }
  return out.join('');
}
function dcRow(ic, title, sub, status){
  const sic = {ok: 'check', warn: 'warn', bad: 'error'}[status];
  const st = sic ? '<span class="status ' + status + '">' + icon(sic, 's16') + '</span>' : '';
  return '<div class="list-item two-line">' +
    '<span class="li-icon plain">' + icon(ic, 's24') + '</span>' +
    '<span class="li-text"><span class="li-primary">' + esc(title) + '</span>' +
      '<span class="li-secondary selectable-pre">' + esc(sub) + '</span></span>' + st + '</div>';
}
async function dcAddUser(q){
  const r = await withBusy(['add-domain', q]);
  if(r.code){ toast(errText(r, 'Не удалось добавить')); return; }
  // ответ ctl — по-русски («Добавлено: x»); в интерфейсе — своя строка
  toast(t('Добавлено: {0}', (r.out || '').trim().split(': ').pop() || q));
  runDomainCheck();
}
/* Открыть список, где нашёлся домен, сразу с поиском этой записи. Списков
   несколько — выбор из меню. Ждём именно тот редактор, который открыли: если
   открыть не удалось и пользователь открыл другой список, поиск туда не лезет. */
let dcLast = null;
function dcPickList(anchor){
  const lists = dcLast ? dcLast.lists : [];
  if(lists.length === 1) return dcOpenList(lists[0].file, lists[0].entry);
  openMenu(anchor, lists.map(l => ({label: l.file, sub: l.entry, icon: 'list', onClick: () => dcOpenList(l.file, l.entry)})));
}
async function dcOpenList(file, entry){
  openSlideEditor('list', file.replace(/\.list$/, ''));
  const o = editorCtx;
  if(!o) return;
  for(let i = 0; i < 300 && editorCtx === o && o.original === undefined; i++) await new Promise(r => setTimeout(r, 100));
  if(editorCtx !== o || o.original === undefined) return;
  openEditorSearch();
  const inp = $('editor-search-input');
  if(inp){
    inp.value = entry;
    onEditorSearchInput();
  }
}
