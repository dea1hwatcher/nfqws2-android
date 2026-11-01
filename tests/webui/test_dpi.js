#!/usr/bin/env node
/**
 * test_dpi.js — Unit tests for ported DPI Detector logic:
 * - Error classification (TLS RST, TLS Alert, Spoof, MITM, Drop, Timeout, ISP Redir)
 * - Row HTML renderers (TCP16, DNS)
 * - Strategy auto-selection logic & heuristic decision engine
 * - Report generator formatting
 */
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const REPO = path.resolve(__dirname, '..', '..');
const TEST_JS = path.join(REPO, 'webroot', 'js', 'test.js');
const SETTINGS_JS = path.join(REPO, 'webroot', 'js', 'settings.js');

let pass = 0;
const failures = [];
let section = '';

function sect(name) { section = name; process.stdout.write(`\n== ${name}\n`); }
function ok(msg) { pass++; process.stdout.write(`   ok   ${msg}\n`); }
function fail(msg) { failures.push(`[${section}] ${msg}`); process.stdout.write(`   FAIL ${msg}\n`); }
function eq(expected, actual, msg) {
  if (expected === actual) ok(msg);
  else fail(`${msg} -- expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}
function truthy(cond, msg) { cond ? ok(msg) : fail(msg); }

// Setup sandbox environment simulating WebUI globals
const sandbox = {
  console,
  t: (s, ...args) => {
    let r = s;
    for (let i = 0; i < args.length; i++) r = r.split('{' + i + '}').join(args[i]);
    return r;
  },
  esc: str => String(str).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'),
  icon: (name, sz) => `<svg class="${sz}"><use href="#i-${name}"/></svg>`,
  banner: (t, kind, msg) => `<div class="banner ${kind}">${msg}</div>`,
  stat: async () => {},
  setHTML: (id, html) => {},
  ctlx: async () => ({ code: 0, out: '' }),
  toast: () => {},
  copyText: (text) => { if (sandbox.navigator.clipboard && sandbox.navigator.clipboard.writeText) sandbox.navigator.clipboard.writeText(text); },
  S: { running: true, paused: false },
  currentStrategy: 'default',
  strategyName: s => s,
  jsArg: v => JSON.stringify(String(v == null ? '' : v)),
  onLongPress: () => {},
  document: {
    querySelectorAll: () => [],
    createElement: () => ({ select: () => {}, appendChild: () => {} }),
    body: { appendChild: () => {}, removeChild: () => {} }
  },
  navigator: {},
  $: id => (sandbox._els = sandbox._els || {}, sandbox._els[id] = sandbox._els[id] || { textContent: '', innerHTML: '', hidden: false, disabled: false, dataset: {}, classList: { toggle: () => {}, add: () => {}, remove: () => {} }, insertAdjacentHTML: () => {} })
};

vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(TEST_JS, 'utf8'), sandbox);
vm.runInContext(fs.readFileSync(SETTINGS_JS, 'utf8'), sandbox);

// ── 1. Error classification dictionary ─────────────────────────────────────
sect('DPI error classification');
const probeReason = vm.runInContext('PROBE_REASON', sandbox);
truthy(typeof probeReason === 'object', 'PROBE_REASON dictionary is exported');
eq('TLS RST (сброс ClientHello)', probeReason.tls_rst, 'tls_rst maps to ClientHello reset');
eq('TLS Alert (SNI блок)', probeReason.tls_alert, 'tls_alert maps to SNI block');
eq('Тихий сброс (Drop)', probeReason.drop, 'drop maps to silent TSPU drop');
eq('Заглушка провайдера (RKN)', probeReason.isp_redir, 'isp_redir maps to RKN block page');
eq('WebSocket Gateway заблокирован (ТСПУ)', probeReason.ws_blocked, 'ws_blocked maps to Discord WebSocket block');
eq('Подмена сертификата (MITM)', probeReason.tls_mitm, 'tls_mitm maps to MITM');
eq('Сертификат УЦ Минцифры (RU CA)', probeReason.ru_ca, 'ru_ca maps to Russian Trusted CA');
eq('Некорректный ответ HTTP', probeReason.not_http, 'not_http maps to non-HTTP response');
eq('Блокировка протокола TLS', probeReason.tls_block, 'tls_block maps to TLS protocol block');
eq('Несовместимость параметров TLS', probeReason.peer_incompat, 'peer_incompat maps to peer incompatibility');
eq('Подмена ответа (Spoof)', probeReason.tls_spoof, 'tls_spoof maps to response spoof');
eq('Ошибка DNS', probeReason.dns_fail, 'dns_fail maps to DNS failure');

// ── 2. Row renderers ───────────────────────────────────────────────────────
sect('row HTML renderers');
const tcpClean = sandbox.renderTcp16Row(0, 'Cloudflare', '172.67.70.222', 443, 'clean', '42ms');
truthy(tcpClean.includes('status ok') && tcpClean.includes('42ms'), 'TCP16 clean row renders with status ok');

const tcpDetected = sandbox.renderTcp16Row(1, 'Hetzner', '91.98.156.82', 443, 'detected', '16KB');
truthy(tcpDetected.includes('status bad') && tcpDetected.includes('16KB'), 'TCP16 detected row renders with status bad');

const dnsRow = sandbox.renderDnsRow(0, 'Google', '8.8.8.8', 'ok', 'ok', 'no', 'OK');
truthy(dnsRow.includes('status ok') && dnsRow.includes('UDP: OK'), 'DNS clean row renders with status ok');

const dnsHijacked = sandbox.renderDnsRow(1, 'ISP DNS', '192.168.1.1', 'ok', 'none', 'yes', 'Заглушка');
truthy(dnsHijacked.includes('status bad') && dnsHijacked.includes('ПЕРЕХВАТ'), 'DNS hijacked row renders with status bad');

const benchRowRunning = sandbox.renderBenchRow(0, 'fake_tls_auto', null, null, null, null, true);
truthy(benchRowRunning.includes('status info') && benchRowRunning.includes('spinner'), 'Bench running row renders with spinner');

const benchRowOk = sandbox.renderBenchRow(1, 'fake_tls_auto', 30, 30, 45, '-', false);
truthy(benchRowOk.includes('status ok') && benchRowOk.includes('100%') && benchRowOk.includes('45 мс'), 'Bench 100% row renders with status ok and 100%');

const benchRowFail = sandbox.renderBenchRow(2, 'default', 0, 30, 0, 'tls_rst', false);
truthy(benchRowFail.includes('status bad') && benchRowFail.includes('0%') && benchRowFail.includes('TLS RST'), 'Bench failed row renders with status bad and reason');

const benchRowSvc = sandbox.renderBenchRow(3, 'fake_tls_auto', 20, 30, 40, '-', false, 1, 0);
truthy(benchRowSvc.includes('YT ✓') && benchRowSvc.includes('DC ✗'), 'Bench row displays YouTube and Discord status pills');

sandbox.renderBenchBest('fake_tls_auto', 25, 30, 45, 'alt4', 'fake_tls_auto');
const bestEl = sandbox.$('bench-best');
truthy(bestEl.innerHTML.includes('YouTube Focus') && bestEl.innerHTML.includes('alt4'), 'Bench best renders dedicated YouTube focus button when different');

// ── Wilson score strategy ranking ─────────────────────────────────────────
sect('Wilson score strategy ranking');
truthy(typeof sandbox.wilsonScore === 'function', 'wilsonScore helper is exported');
eq(0, sandbox.wilsonScore(0, 0), 'wilsonScore returns 0 on zero total');
const scoreLuckySingle = sandbox.wilsonScore(1, 1);
const scoreSolidBatch = sandbox.wilsonScore(29, 30);
truthy(scoreSolidBatch > scoreLuckySingle, 'Wilson score prioritizes high sample size (29/30) over 1/1 fluke');
truthy(scoreLuckySingle > 0.15 && scoreLuckySingle < 0.35, '1/1 Wilson score lower bound is discounted (~0.20)');
truthy(scoreSolidBatch > 0.75 && scoreSolidBatch < 0.95, '29/30 Wilson score lower bound is solid (~0.83)');

// ── 3. Strategy auto-selection logic ───────────────────────────────────────
sect('strategy auto-selection logic');

// 3.1: Clean run -> retains default or current
const recClean = sandbox.analyzeProbeResults(
  { 0: { host: 'google.com', list: [{ ok: true, ms: 20 }, { ok: true, ms: 22 }, { ok: true, ms: 21 }] } },
  { 0: { provider: 'Cloudflare', status: 'clean', detail: '32KB' } },
  { 0: { name: 'Google', udp: 'ok', doh: 'ok', hijacked: 'no' } }
);
truthy(recClean.isClean === true, 'clean run sets isClean flag');
eq('default', recClean.strategy, 'clean run recommends default strategy');

// 3.2: TCP 16KB + SNI block -> recommends fake_tls_auto_alt2
const recTcpAlert = sandbox.analyzeProbeResults(
  { 0: { host: 'rutracker.org', list: [{ ok: false, reason: 'tls_alert' }] } },
  { 0: { provider: 'Hetzner', status: 'detected', detail: '16KB' } },
  { 0: { name: 'Cloudflare', udp: 'ok', doh: 'ok', hijacked: 'no' } }
);
eq('fake_tls_auto_alt2', recTcpAlert.strategy, 'TCP16 + TLS Alert recommends fake_tls_auto_alt2');

// 3.3: Pure TCP 16KB -> recommends alt4_mod
const recTcpOnly = sandbox.analyzeProbeResults(
  { 0: { host: 'cdn.example.com', list: [{ ok: true, ms: 30 }] } },
  { 0: { provider: 'Hetzner', status: 'detected', detail: '16KB' } },
  {}
);
eq('alt4_mod', recTcpOnly.strategy, 'pure TCP16 filter recommends alt4_mod');

// 3.4: Pure SNI block (TLS Alert) -> recommends fake_tls_auto
const recSniOnly = sandbox.analyzeProbeResults(
  { 0: { host: 'discord.com', list: [{ ok: false, reason: 'tls_alert' }] } },
  {},
  {}
);
eq('fake_tls_auto', recSniOnly.strategy, 'pure TLS Alert recommends fake_tls_auto');

// 3.5: TLS RST active reset -> recommends fake_tls_auto
const recRst = sandbox.analyzeProbeResults(
  { 0: { host: 'youtube.com', list: [{ ok: false, reason: 'tls_rst' }] } },
  {},
  {}
);
eq('fake_tls_auto', recRst.strategy, 'TLS RST recommends fake_tls_auto');

// 3.6: Silent drop / timeout -> recommends alt11
const recDrop = sandbox.analyzeProbeResults(
  { 0: { host: 'medium.com', list: [{ ok: false, reason: 'drop' }] } },
  {},
  {}
);
eq('alt11', recDrop.strategy, 'silent drop recommends alt11');

// 3.7: DNS hijacking warning
const recDnsHijack = sandbox.analyzeProbeResults(
  { 0: { host: 'clean.site', list: [{ ok: true, ms: 10 }] } },
  {},
  { 0: { name: 'ISP', udp: 'ok', doh: 'none', hijacked: 'yes', detail: 'Заглушка' } }
);
truthy(recDnsHijack.dnsWarning.length > 0, 'hijacked DNS emits dnsWarning');

// 3.8: Tab selection
sandbox.selectTestTab('ru');
eq('ru', vm.runInContext('currentTestTab', sandbox), 'selectTestTab switches to ru tab');

// ── net-info ──────────────────────────────────────────────────────────────
sect('net-info parsing');
const net = vm.runInContext(`parseNetInfo('NET\\t5.18.158.84\\tRU\\tZ-Telecom\\tAS41733 Z-Telecom\\twlan0\\t192.168.1.1\\t8.8.8.8,1.1.1.1\\trunning\\talt13\\n')`, sandbox);
eq('5.18.158.84', net.ip, 'the IP is read from the NET line');
eq('Z-Telecom', net.isp, 'the provider is read');
eq('8.8.8.8,1.1.1.1', net.dns, 'DNS servers are read');
eq('running', net.status, 'the service state is read');
eq('alt13', net.strategy, 'the strategy is read');
const netEmpty = vm.runInContext(`parseNetInfo('NET\\t—\\t—\\t—\\t—\\twlan0\\t—\\t—\\tstopped\\t—')`, sandbox);
eq(undefined, netEmpty.ip, 'a dash means no value');
eq('stopped', netEmpty.status, 'known fields survive next to dashes');
eq(0, Object.keys(vm.runInContext(`parseNetInfo('')`, sandbox)).length, 'an empty answer gives an empty object');
// The line comes from cmd_net_info in nfqws2-ctl: one %s per NET_FIELDS entry.
const ctlSrc = fs.readFileSync(path.join(REPO, 'bin', 'nfqws2-ctl'), 'utf8');
const fmt = /printf 'NET((?:\\t%s)+)\\n'/.exec(ctlSrc);
truthy(!!fmt, 'nfqws2-ctl prints the NET line');
eq(vm.runInContext('NET_FIELDS.length', sandbox), fmt ? fmt[1].split('%s').length - 1 : -1,
  'the WebUI reads as many fields as nfqws2-ctl prints');

// ── 4. Report generation ───────────────────────────────────────────────────
sect('report formatting');
vm.runInContext(`
netInfoData = {
  ip: '5.18.158.84',
  loc: 'RU',
  isp: 'Z-Telecom',
  asn: 'AS41733',
  status: 'running',
  strategy: 'fake_tls_auto',
  dns: '8.8.8.8'
};
webResults = {
  0: { host: 'youtube.com', list: [{ ok: true, ms: 30 }, { ok: true, ms: 32 }] }
};
tcp16Results = {
  0: { provider: 'Hetzner', ip: '91.98.156.82', status: 'detected', detail: '16KB' }
};
dnsResults = {
  0: { name: 'Cloudflare', ip: '1.1.1.1', udp: 'ok', doh: 'ok', hijacked: 'no', detail: 'OK' }
};
benchResults = {
  default: { idx: 0, name: 'default', ok: 5, total: 30, avg_ms: 120, top_fail: 'tls_rst' },
  fake_tls_auto: { idx: 1, name: 'fake_tls_auto', ok: 30, total: 30, avg_ms: 42, top_fail: '-' }
};
benchBestStrat = { name: 'fake_tls_auto', ok: 30, total: 30, avg_ms: 42 };
`, sandbox);

let copiedText = '';
sandbox.navigator.clipboard = {
  writeText: txt => { copiedText = txt; }
};
sandbox.copyTestReport();

truthy(copiedText.includes('### DPI Detector (nfqws2-android)'), 'report header is present');
truthy(copiedText.includes('5.18.158.84') && copiedText.includes('Z-Telecom'), 'network info is present in report');
truthy(copiedText.includes('youtube.com'), 'web test is present in report');
truthy(copiedText.includes('DETECTED @ 16KB'), 'TCP16 test is present in report');
truthy(!copiedText.includes('Telegram датацентры'), 'Telegram section is removed from DPI report');
truthy(copiedText.includes('Рекомендованная стратегия'), 'strategy recommendation is present in report');

let copiedBench = '';
sandbox.navigator.clipboard = {
  writeText: async txt => { copiedBench = txt; }
};
sandbox.copyBenchReport();
truthy(copiedBench.includes('Автоподбор стратегий'), 'bench header is present in bench report');
truthy(copiedBench.includes('fake_tls_auto (fake_tls_auto) — 30/30, 42 мс'), 'winning strategy is reported in bench report');

// ── 5. QUIC & CDN indicators ──────────────────────────────────────────────
sect('QUIC & CDN indicator rendering');

vm.runInContext(`
quicStatusResult = {
  'youtube.com': { verdict: 'blocked', desc: 'QUIC (HTTP/3) глушится провайдером' }
};
tlsDiffResult = {
  'youtube.com': { verdict: 'tls13_blocked', desc: 'TLS 1.3 заблокирован ТСПУ, TLS 1.2 доступен' }
};
discoveredGoogleVideoCdn = 'rr1---sn-h0jelne7.googlevideo.com';
var quicElHtml = '';
var quicElHidden = true;
$ = id => {
  if (id === 'test-quic-status') {
    return {
      set innerHTML(h) { quicElHtml = h; },
      get innerHTML() { return quicElHtml; },
      set hidden(val) { quicElHidden = val; },
      get hidden() { return quicElHidden; }
    };
  }
  return { textContent: '', innerHTML: '', hidden: false, disabled: false, insertAdjacentHTML: () => {} };
};
renderQuicIndicator();
`, sandbox);

const qHtml = sandbox.quicElHtml;
truthy(!sandbox.quicElHidden, 'QUIC indicator is visible when results exist');
truthy(qHtml.includes('QUIC глушится ТСПУ'), 'QUIC badge shows blocked status');
truthy(qHtml.includes('rr1---sn-h0jelne7.googlevideo.com'), 'discovered GoogleVideo CDN is rendered');
truthy(qHtml.includes('TLS 1.3 заблокирован'), 'TLS diff summary is rendered');

copiedText = '';
sandbox.navigator.clipboard.writeText = txt => { copiedText = txt; };
sandbox.copyTestReport();
truthy(copiedText.includes('QUIC и региональные CDN'), 'QUIC & CDN section present in test report');
truthy(copiedText.includes('rr1---sn-h0jelne7.googlevideo.com'), 'GoogleVideo CDN present in test report');

// ── 6. Summary ─────────────────────────────────────────────────────────────
console.log(`\n----------------------------------------\nPASS  ${pass} checks`);
if (failures.length) {
  console.error(`FAIL  ${failures.length} check(s) failed`);
  process.exit(1);
}
process.exit(0);
