#!/bin/sh
# Strategy bench, with the emphasis on the parallel path: private nfqws2
# instances on their own queues, probes routed by local source port. Those
# routing rules sit in front of the live firewall, so what is left behind after
# the run matters as much as the numbers it prints.
#
# The curl stub is a tiny kernel: it resolves the probe's local port through the
# bench chain in the mock iptables store, exactly as mangle POSTROUTING would,
# and only the "good" queues answer. A strategy therefore wins only if its
# probes really reached its own instance — a slot that never got its rules, or
# whose daemon died, cannot score by accident.

HERE=$(cd "$(dirname "$0")" && pwd)
TESTS_DIR=$(cd "$HERE/.." && pwd)
REPO_DIR=$(cd "$TESTS_DIR/.." && pwd)
. "$TESTS_DIR/lib/harness.sh"

sandbox_init
load_common
conf_reset
printf 'WATCHDOG=0\n' >> "$CONFFILE"
# Живой конфиг с нестандартным NFQWS_EXTRA_ARGS: merge_user_keys переносит только
# стандартные $MODE_* ссылки, поэтому значение самой стратегии (см. sed ниже)
# доходит до подбора как есть — многострочным.
awk '/^NFQWS_EXTRA_ARGS=/ { print "NFQWS_EXTRA_ARGS=\"--hostlist=$LISTS_DIR/user.list\""; next } { print }' \
  "$CONFFILE" > "$CONFFILE.t" && mv "$CONFFILE.t" "$CONFFILE"
# the helper functions run in this shell too, and they read the same globals the
# ctl reads ($NFQUEUE_NUM, $IPV6_ENABLED) — sourcing common.sh alone leaves them unset
reload_conf

# default + alt + exp: two full rounds of two slots and a partial one, without
# spending minutes of stub probes on the other 27 strategies
for f in "$MODDIR/strategies/"*.conf; do
  case "${f##*/}" in alt.conf|exp.conf) ;; *) rm -f "$f" ;; esac
done
printf 'www.youtube.com\nx.com\n' > "$LISTS_DIR/probe_bench.list"

# Стратегия с многострочным NFQWS_EXTRA_ARGS: правка в WebUI даёт такие routinely,
# и подбор обязан измерять её, а не превращать живой nfqws2.conf в файл, который
# не читается из-за висящей кавычки.
sed -i 's#^NFQWS_EXTRA_ARGS=.*#NFQWS_EXTRA_ARGS="$MODE_LIST\n                 --dpi-desync=split2"#' "$MODDIR/strategies/exp.conf"

cat > "$MOCKBIN/curl" <<'X'
#!/bin/sh
if [ "${1:-}" = "--help" ]; then
  echo "  --local-port <num[-num]>  Local port range to use"
  echo "  --http3                   Use HTTP/3"
  exit 0
fi
# the capability probe is `--local-port … --version`: curl prints and exits
# before it would connect, and it is not a probe to record
for a in "$@"; do
  [ "$a" = "--version" ] && exit 0
done
lp=""; url=""; v4=0
while [ $# -gt 0 ]; do
  case "$1" in
    --local-port) lp="${2:-}"; shift ;;
    -4) v4=1 ;;
    http*) url="$1" ;;
  esac
  shift
done
port="${lp%%-*}"
q=""
store="$MOCK_IPT_STORE/iptables/mangle/nfqws_bench_out"
if [ -n "$port" ] && [ -f "$store" ]; then
  while IFS= read -r rule; do
    case "$rule" in
      *"--sport "*)
        r="${rule#*--sport }"; lo="${r%%:*}"; r="${r#*:}"; hi="${r%% *}"
        if [ "$port" -ge "$lo" ] 2>/dev/null && [ "$port" -le "$hi" ] 2>/dev/null; then
          q="${rule#*--queue-num }"; q="${q%% *}"
          break
        fi ;;
    esac
  done < "$store"
fi
# no bench rule matched: the probe goes through the live service, queue 300
[ -n "$q" ] || q=300
printf '%s\t%s\t%s\t%s\n' "$port" "$q" "$v4" "$url" >> "$MOCK_DIR/curl.calls"
if [ -n "${MOCK_BENCH_KILL_AT:-}" ]; then
  n=$(cat "$MOCK_DIR/curl.n" 2>/dev/null || echo 0)
  n=$((n + 1)); printf '%s\n' "$n" > "$MOCK_DIR/curl.n"
  if [ "$n" = "$MOCK_BENCH_KILL_AT" ]; then
    p=$(cat "$CONFDIR/state/probe.pid" 2>/dev/null)
    [ -n "$p" ] && kill -TERM "$p" 2>/dev/null
  fi
fi
case " ${MOCK_BENCH_GOOD_Q:-300} " in *" $q "*) exit 0 ;; esac
exit 7
X
chmod 0755 "$MOCKBIN/curl"

cat > "$MODDIR/bin/nfqws2" <<'X'
#!/bin/sh
case "${1:-}" in
  __stay) trap 'exit 0' TERM INT HUP; while :; do sleep 1; done ;;
esac
pidfile=""; qnum=""
for a in "$@"; do
  case "$a" in
    --dry-run) echo "command line parameters verified"; exit 0 ;;
    --pidfile=*) pidfile="${a#--pidfile=}" ;;
    --qnum=*) qnum="${a#--qnum=}" ;;
  esac
done
printf '%s\n' "$*" >> "$MOCK_DIR/nfqws2.calls"
if [ -n "${MOCK_BENCH_BUSY_Q:-}" ] && [ "$qnum" = "$MOCK_BENCH_BUSY_Q" ]; then
  echo "nfq_create_queue(): Device or resource busy"
  exit 1
fi
if [ -n "$pidfile" ]; then
  sh "$0" __stay &
  printf '%s\n' "$!" > "$pidfile"
fi
exit 0
X
chmod 0755 "$MODDIR/bin/nfqws2"

export MOCK_BENCH_GOOD_Q="300 302"

daemon300() { grep -- '--daemon' "$MOCK_DIR/nfqws2.calls" 2>/dev/null | grep -c -- '--qnum=300' || true; }
bench_reset_logs() { : > "$MOCK_DIR/curl.calls"; : > "$MOCK_DIR/nfqws2.calls"; }

# ── slot arithmetic ───────────────────────────────────────────────────────────
section "bench: slots and port range"

awk '/^BENCH_CHAIN_OUT=/{f=1} /^cmd_bench_strategies\(\)/{f=0} f' \
  "$MODDIR/bin/nfqws2-ctl" > "$SANDBOX/bench_helpers.sh"
. "$SANDBOX/bench_helpers.sh"

BENCH_SLOTS=9
assert_eq "4" "$(bench_slot_count)" "more slots than the cap is clamped to 4"
BENCH_SLOTS=0
assert_eq "0" "$(bench_slot_count)" "BENCH_SLOTS=0 asks for the serial path"
unset BENCH_SLOTS
assert_eq "0" "$(bench_slot_count 100000)" "under 128 MB free the extra instance is not worth it"
assert_eq "1" "$(bench_slot_count 300000)" "300 MB free still leaves room for one slot"
assert_eq "2" "$(bench_slot_count 400000)" "400 MB free: two slots after the 256 MB reserve"
assert_eq "4" "$(bench_slot_count 4000000)" "plenty of memory is capped at four"

mkdir -p "$MOCK_DIR/sys/net/ipv4" "$MOCK_DIR/net"
printf '32768 60999\n' > "$MOCK_DIR/sys/net/ipv4/ip_local_port_range"
PROC_SYS_ROOT="$MOCK_DIR/sys"; PROC_NET_ROOT="$MOCK_DIR/net"
assert_eq "61000" "$(bench_port_base 2)" "the range starts above the kernel's ephemeral ports"

# a socket inside the candidate range: 61000 = 0xEE48. The port field is hex and
# busybox awk has no strtonum, so this is also a test of the conversion itself.
printf '  sl local_address rem_address st\n   0: 0100007F:EE48 00000000:0000 0A\n' > "$MOCK_DIR/net/tcp"
assert_eq "32256" "$(bench_port_base 2)" "an occupied range falls back below the ephemeral ports"
printf '  sl local_address rem_address st\n   0: 0100007F:7E00 00000000:0000 0A\n' >> "$MOCK_DIR/net/tcp"
bench_port_base 2 >/dev/null 2>&1
assert_rc 1 "$?" "both candidates occupied: no parallel run"
printf '  sl local_address rem_address st\n   0: 0100007F:1F90 00000000:0000 0A\n' > "$MOCK_DIR/net/tcp"
assert_eq "61000" "$(bench_port_base 2)" "a socket outside the range (8080) does not block it"
rm -f "$MOCK_DIR/net/tcp"
unset PROC_SYS_ROOT PROC_NET_ROOT

BENCH_SLOTS=2
p=$(bench_parallel_possible curl "$MOCKBIN/curl")
assert_rc 0 "$?" "a curl with --local-port and two slots allows the parallel path"
assert_match "$p" '^2 [0-9]+$' "and reports the slot count together with the port base"
unset BENCH_SLOTS p

# IPv6 is hooked too, so a kernel that refuses ip6tables cannot give a honest
# measurement: the setup fails and takes the v4 chains it already made with it
MOCK_IP6_FAIL=1
export MOCK_IP6_FAIL
bench_chains_up >/dev/null 2>&1
assert_rc 1 "$?" "a failing ip6tables refuses the parallel setup"
bench_chains_down
assert_eq "" "$(find "$MOCK_IPT_STORE" -name 'nfqws_bench_*' -print 2>/dev/null)" "and the v4 chains are removed again"
unset MOCK_IP6_FAIL

# ── подстановка режима ────────────────────────────────────────────────────────
section "bench: MODE_ALL substitution keeps the config readable"

printf 'MODE_LIST="--hostlist=a.list"\nNFQWS_EXTRA_ARGS="$MODE_LIST\n                 --dpi-desync=split2"\nTCP_PORTS=443\n' > "$SANDBOX/ml.conf"
bench_set_mode_all "$SANDBOX/ml.conf" "$SANDBOX/ml.out"
assert_rc 0 "$?" "substitution on a multi-line value succeeds"
assert_eq "3" "$(grep -c . "$SANDBOX/ml.out")" "the continuation line goes with the value it belonged to"
assert_contains "$(cat "$SANDBOX/ml.out")" 'NFQWS_EXTRA_ARGS="$MODE_ALL"' "the mode is replaced"
assert_not_contains "$(cat "$SANDBOX/ml.out")" "dpi-desync" "nothing of the old value survives"
assert_contains "$(cat "$SANDBOX/ml.out")" "TCP_PORTS=443" "and the lines after it are untouched"
( . "$SANDBOX/ml.out" ) 2>/dev/null
assert_rc 0 "$?" "the result sources cleanly — the old sed left an unmatched quote here"

printf 'A=1\nNFQWS_EXTRA_ARGS="$MODE_AUTO"\nB=2\n' > "$SANDBOX/one.conf"
bench_set_mode_all "$SANDBOX/one.conf" "$SANDBOX/one.out"
# одинарные кавычки: $MODE_ALL должен записать сам конфиг, а не раскрывать
# переменную тестовой оболочки
expected_one='A=1
NFQWS_EXTRA_ARGS="$MODE_ALL"
B=2'
assert_eq "$expected_one" "$(cat "$SANDBOX/one.out")" "a single-line value is replaced in place"

# ── parallel run ──────────────────────────────────────────────────────────────
section "bench: parallel slots on their own queues"

bench_reset_logs
svc start
assert_rc 0 "$svc_rc" "the service is up before the bench"
cp -f "$CONFFILE" "$SANDBOX/conf.before"
svc_before=$(daemon300)

BENCH_SLOTS=2
export BENCH_SLOTS
ctl bench-strategies
assert_rc 0 "$ctl_rc" "the bench exits 0"
assert_contains "$ctl_out" "BENCH_MODE	parallel	2" "two slots were used"
assert_contains "$ctl_out" "BENCH_START	3" "all three strategies are announced"

# default lands on slot 0 (queue 301, refused), alt on slot 1 (queue 302, good)
assert_contains "$ctl_out" "BENCH_RES	0	default	0	2	0	refused	0	0" "a strategy that passes nothing is screened out on two probes"
assert_contains "$ctl_out" "BENCH_RES	1	alt	6	6" "the strategy whose probes reached its own queue scores all six"
assert_contains "$ctl_out" "BENCH_VERIFY	1	alt" "the winner is re-measured alone"
assert_contains "$ctl_out" "BENCH_BEST	alt	6	6" "and stays the winner after verification"
assert_match "$ctl_out" "BENCH_BEST	alt	6	6	[0-9]+	alt	-" "YouTube best is the winner; Discord best stays empty with no Discord success"
assert_not_contains "$ctl_out" "exp	0	0	0	failed_start" "the strategy with a multi-line mode value is measured, not dropped"

calls=$(cat "$MOCK_DIR/nfqws2.calls")
assert_contains "$calls" "--daemon --pidfile=$STATE_DIR/bench_slot.0.pid" "slot 0 got its own pidfile"
assert_contains "$calls" "--qnum=301" "slot 0 binds the queue after the service's one"
assert_contains "$calls" "--qnum=302" "slot 1 binds the next queue"
assert_not_contains "$calls" "--qnum=303" "no third instance with two slots"
assert_contains "$calls" "--debug=@$STATE_DIR/bench_slot.0.log" "slot 0 logs to its own file, not the service log"
assert_contains "$calls" "--hostlist-exclude=$LISTS_DIR/exclude.list" "the bench measures MODE_ALL, not the user's auto list"
assert_eq "0" "$(printf '%s\n' "$calls" | grep -c 'dpi-desync=split2')" "the leftover tail of a multi-line value never reaches the engine"

# the service is restarted once for the verification and once to restore the
# original config — never once per strategy
assert_eq "$((svc_before + 2))" "$(daemon300)" "the live daemon is not restarted per strategy"

# every probe was routed by local port, and the two slots never shared a range
ports=$(cut -f1,2 "$MOCK_DIR/curl.calls" | sort -u)
p301=$(printf '%s\n' "$ports" | awk -F'\t' '$2 == 301 { print $1; exit }')
p302=$(printf '%s\n' "$ports" | awk -F'\t' '$2 == 302 { print $1; exit }')
assert_match "$p301" '^[0-9]+$' "slot 0 probes carried a local port"
assert_match "$p302" '^[0-9]+$' "slot 1 probes carried a local port"
assert_eq "256" "$((p302 - p301))" "the two ranges are one slot width apart"
assert_eq "0" "$(cut -f2 "$MOCK_DIR/curl.calls" | grep -cv -e '^300$' -e '^301$' -e '^302$' || true)" "no probe reached an unrelated queue"

# ── what is left behind ───────────────────────────────────────────────────────
section "bench: nothing survives the run"

assert_no_file "$STATE_DIR/bench_slot.0.pid" "slot 0 pidfile is gone"
assert_no_file "$STATE_DIR/bench_slot.1.pid" "slot 1 pidfile is gone"
assert_no_file "$STATE_DIR/bench_slot.0.conf" "slot 0 config is gone"
assert_no_file "$STATE_DIR/bench_slot.0.log" "slot 0 log is gone"
assert_eq "" "$(find "$STATE_DIR" -name 'bench_*' -print 2>/dev/null)" "no bench scratch files at all"
assert_eq "" "$(find "$STATE_DIR" -name 'probe_bench_*' -print 2>/dev/null)" "no leftover probe host lists"

for C in iptables ip6tables; do
  assert_no_file "$MOCK_IPT_STORE/$C/mangle/nfqws_bench_out" "$C: the outgoing bench chain is deleted"
  assert_no_file "$MOCK_IPT_STORE/$C/mangle/nfqws_bench_in" "$C: the incoming bench chain is deleted"
  assert_not_contains "$(ipt_rules POSTROUTING mangle "$C")" "nfqws_bench_out" "$C: no jump to the bench chain remains"
  assert_not_contains "$(ipt_rules PREROUTING mangle "$C")" "nfqws_bench_in" "$C: no incoming jump remains"
done
assert_contains "$(ipt_rules POSTROUTING)" "-j nfqws_post" "the service's own jump is back in place"

ctl is-running
assert_rc 0 "$ctl_rc" "the service runs again after the bench"
assert_eq "$(cat "$SANDBOX/conf.before")" "$(cat "$CONFFILE")" "the original config is restored byte for byte"
assert_eq "default" "$(cat "$ACTIVE_FILE")" "and the original strategy name with it"

# ── a queue that is already taken ─────────────────────────────────────────────
section "bench: a slot whose queue is busy"

bench_reset_logs
svc_before=$(daemon300)
MOCK_BENCH_BUSY_Q=302
export MOCK_BENCH_BUSY_Q
ctl bench-strategies
assert_rc 0 "$ctl_rc" "the bench still exits 0"
assert_contains "$ctl_out" "BENCH_RES	1	alt	0	0	0	failed_start	0	0" "the busy slot is reported, not silently scored"
assert_eq "0" "$(cut -f2 "$MOCK_DIR/curl.calls" | grep -c '^302$' || true)" "no probe was routed to a slot that never started"
assert_eq "BENCH_RES	2	exp	0	2	0	refused	0	0" "$(printf '%s\n' "$ctl_out" | grep '^BENCH_RES	2	' || true)" "the next round still runs on the free slot"
assert_eq "$((svc_before + 1))" "$(daemon300)" "no winner to verify: only the restore restart"
assert_eq "" "$(find "$STATE_DIR" -name 'bench_slot.*' -print 2>/dev/null)" "the refused slot left no pidfile behind"
unset MOCK_BENCH_BUSY_Q

# ── interrupt ─────────────────────────────────────────────────────────────────
section "bench: interrupted mid-round"

bench_reset_logs
cp -f "$CONFFILE" "$SANDBOX/conf.before2"
MOCK_BENCH_KILL_AT=3
export MOCK_BENCH_KILL_AT
ctl bench-strategies
assert_rc 130 "$ctl_rc" "TERM ends the bench with 130"
unset MOCK_BENCH_KILL_AT
rm -f "$MOCK_DIR/curl.n"
assert_eq "" "$(find "$STATE_DIR" -name 'bench_slot.*' -print 2>/dev/null)" "the instances of the interrupted round are stopped"
for C in iptables ip6tables; do
  assert_no_file "$MOCK_IPT_STORE/$C/mangle/nfqws_bench_out" "$C: interrupted run leaves no outgoing chain"
  assert_not_contains "$(ipt_rules POSTROUTING mangle "$C")" "nfqws_bench_out" "$C: interrupted run leaves no jump"
done
assert_eq "$(cat "$SANDBOX/conf.before2")" "$(cat "$CONFFILE")" "the config is restored after the interrupt too"
ctl is-running
assert_rc 0 "$ctl_rc" "the service is back up after the interrupt"

# ── serial fallbacks ──────────────────────────────────────────────────────────
section "bench: serial path when parallel is not possible"

bench_reset_logs
BENCH_SLOTS=0
svc_before=$(daemon300)
ctl bench-strategies
assert_contains "$ctl_out" "BENCH_MODE	serial" "BENCH_SLOTS=0 forces the serial path"
assert_match "$ctl_out" 'BENCH_BEST	(alt|default|exp)	6	6' "the serial path still picks a winner"
assert_not_contains "$ctl_out" "BENCH_VERIFY" "no separate verification: every strategy already ran alone"
assert_eq "" "$(find "$MOCK_IPT_STORE" -name 'nfqws_bench_*' -print 2>/dev/null)" "the serial path creates no bench chains"
assert_eq "" "$(cut -f1 "$MOCK_DIR/curl.calls" | sort -u)" "serial probes need no local port"
assert_eq "$((svc_before + 4))" "$(daemon300)" "serial: one restart per strategy plus the restore"
assert_eq "3" "$(printf '%s\n' "$ctl_out" | grep -c '^BENCH_RUN')" "one BENCH_RUN per strategy"
assert_not_contains "$ctl_out" "exp	0	0	0	failed_start" "the serial path measures the multi-line strategy too, instead of writing a config it cannot load"

# curl without --local-port cannot pin a probe to a slot: the decision is made
# before anything is started, so it is checked here rather than by another full
# serial run (each of those costs three service restarts)
cat > "$MOCKBIN/curl" <<'X'
#!/bin/sh
case "$1" in
  --local-port) echo "curl: option --local-port: is unknown" >&2; exit 2 ;;
  --help) echo "  --http3   Use HTTP/3"; exit 0 ;;
esac
exit 0
X
chmod 0755 "$MOCKBIN/curl"
bench_curl_local_port "$MOCKBIN/curl"
assert_rc 1 "$?" "an old curl has no --local-port"
BENCH_SLOTS=2
bench_parallel_possible curl "$MOCKBIN/curl" >/dev/null 2>&1
assert_rc 1 "$?" "and the parallel path is refused for it"
assert_eq "" "$(find "$MOCK_IPT_STORE" -name 'nfqws_bench_*' -print 2>/dev/null)" "no bench chains were created"

harness_finish