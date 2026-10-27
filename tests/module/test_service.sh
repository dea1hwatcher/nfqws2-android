#!/bin/sh
# Service lifecycle and firewall rule-set tests
#
# These are the slowest tests in the suite: every iptables call is a process
# spawn, and a full rule set is ~130 rules across two tables. They are kept in
# their own file so the fast suites can be run without them

HERE=$(cd "$(dirname "$0")" && pwd)
TESTS_DIR=$(cd "$HERE/.." && pwd)
REPO_DIR=$(cd "$TESTS_DIR/.." && pwd)
. "$TESTS_DIR/lib/harness.sh"

sandbox_init
load_common
conf_reset

# IPv6 off by default, switched on only in the section that tests it. With it on,
# every firewall_apply/firewall_stop in this file drives both tables, and the
# Windows that is the single largest cost in the whole suite. Only two assertions
# here look at ip6tables at all, and the section that enables it covers them
printf 'WATCHDOG=0\nIPV6_ENABLED=0\n' >> "$CONFFILE"

section "start: the daemon comes up and the arguments are assembled"

svc start
assert_rc 0 "$svc_rc" "start succeeds with the stub daemon"
assert_contains "$(cat "$MOCK_DIR/restore.log" 2>/dev/null)" 'iptables success' "the initial ruleset uses restore successfully, not just fallback"
assert_file "$CONFDIR/state/nfqws2.pid" "the pidfile is written"
assert_file "$CONFDIR/state/last.args" "the argument file is written"
assert_file "$CONFDIR/state/desired" "the desired-state marker is written"
assert_file "$CONFDIR/state/started_at" "the start timestamp is written"

args=$(cat "$CONFDIR/state/last.args")
assert_contains "$args" "--qnum=300" "the queue number reaches the daemon"
assert_contains "$args" "--user=root" "the run-as user reaches the daemon"
assert_contains "$args" "--debug=@$NFQWS_LOG" "the log path reaches the daemon"
assert_not_contains "$args" "/opt/etc/nfqws2" "no keenetic paths leak into the arguments"
assert_not_contains "$args" "MODE_" "MODE_ references are expanded before launch"

section "start: iptables chains"

assert_file "$MOCK_IPT_STORE/iptables/mangle/nfqws_post" "nfqws_post chain is created"
assert_file "$MOCK_IPT_STORE/iptables/mangle/nfqws_pre" "nfqws_pre chain is created"
# APP_MODE defaults to off, so app_rules() actively removes its chain
assert_no_file "$MOCK_IPT_STORE/iptables/mangle/nfqws_app" "no app chain while APP_MODE=off"
assert_file "$MOCK_IPT_STORE/iptables/nat/nfqws_nat" "nfqws_nat chain is created with NAT_FIX=1"

assert_contains "$(ipt_rules nfqws_post)" "-j NFQUEUE --queue-num 300" "outgoing traffic is queued"
assert_contains "$(ipt_rules nfqws_pre)" "-j NFQUEUE --queue-num 300" "incoming traffic is queued"
assert_contains "$(ipt_rules nfqws_pre)" "--tcp-flags syn,ack syn,ack" "SYN/ACK replies are queued"
assert_contains "$(ipt_rules nfqws_post)" "-m connbytes" "connbytes is used when the kernel has it"
assert_not_contains "$(ipt_rules nfqws_post)" "-j nfqws_qout" "no counter chain is used in connbytes mode"
assert_contains "$(ipt_rules nfqws_post)" "-o lo -j RETURN" "loopback is excluded"
assert_contains "$(ipt_rules nfqws_nat nat)" "-j MASQUERADE" "the NAT fix is installed"

post=$(ipt_count nfqws_post)
assert_ge "$post" 10 "the postrouting chain has a substantial rule set ($post rules)"

section "start: the limiter is recorded for the UI"

assert_eq "connbytes" "$(cat "$CONFDIR/state/limiter")" "the limiter state file says connbytes"

section "stop: everything is torn down"

svc stop
assert_rc 0 "$svc_rc" "stop succeeds"
assert_no_file "$CONFDIR/state/nfqws2.pid" "the pidfile is removed"
assert_no_file "$CONFDIR/state/desired" "the desired-state marker is removed"
assert_no_file "$MOCK_IPT_STORE/iptables/mangle/nfqws_post" "nfqws_post is deleted"
assert_no_file "$MOCK_IPT_STORE/iptables/mangle/nfqws_pre" "nfqws_pre is deleted"
assert_no_file "$MOCK_IPT_STORE/iptables/mangle/nfqws_app" "nfqws_app is deleted"
assert_no_file "$MOCK_IPT_STORE/iptables/nat/nfqws_nat" "nfqws_nat is deleted"

section "start: a daemon that dies at once is reported with the log tail"

# Neither refusal branch in start() was covered before, and the two of them share
# that used to be copy-pasted into both. This drives the first branch, where the
# daemon exits non-zero
#
# The service has to be down for it: start() returns 0 without doing anything if
# it is already up, and the section above is where it gets stopped
#
# The status is asserted as well as the log. service.sh used to end with `exit 0`,
# passes that status along, which made a failed start indistinguishable from a
# good one for anything that checks it
: > "$SERVICE_LOG"
MOCK_NFQWS_FAIL=3
export MOCK_NFQWS_FAIL
svc start
assert_rc 1 "$svc_rc" "start reports failure through its exit status"
assert_contains "$(cat "$SERVICE_LOG")" "exited with code 3" "the exit code reaches the log"
assert_contains "$(cat "$SERVICE_LOG")" "Last log lines:" "the log tail is announced"
assert_contains "$(cat "$SERVICE_LOG")" "refusing to start" "and the tail itself is included"
unset MOCK_NFQWS_FAIL
assert_no_file "$CONFDIR/state/nfqws2.pid" "no pidfile is left behind"

section "start: preflight dry-run rejection"
: > "$SERVICE_LOG"
MOCK_NFQWS_DRY_RUN_FAIL=2
export MOCK_NFQWS_DRY_RUN_FAIL
svc start
assert_rc 1 "$svc_rc" "start reports failure when dry-run rejects parameters"
assert_contains "$(cat "$SERVICE_LOG")" "--dry-run" "the dry-run failure is announced in service.log"
assert_no_file "$CONFDIR/state/nfqws2.pid" "no pidfile on dry-run failure"
unset MOCK_NFQWS_DRY_RUN_FAIL

# turn everything red
svc status
assert_rc 0 "$svc_rc" "status still reports success"

section "connmark_out: a kernel without connbytes gets counter chains"

conf_reset
printf 'WATCHDOG=0\nBLOCK_QUIC=1\nIPV6_ENABLED=0\nAPP_MODE=include\n' >> "$CONFFILE"
printf 'com.termux\n' > "$CONFDIR/apps.list"
MOCK_IPT_FEATURES="multiport owner NFQUEUE"
export MOCK_IPT_FEATURES
ipt_reset

svc firewall_apply
assert_rc 0 "$svc_rc" "firewall_apply succeeds without connbytes"

assert_eq "connmark_out" "$(cat "$CONFDIR/state/limiter")" "the limiter state file says connmark_out"
assert_file "$MOCK_IPT_STORE/iptables/mangle/nfqws_qout" "the outgoing counter chain exists"
assert_file "$MOCK_IPT_STORE/iptables/mangle/nfqws_qin" "the incoming counter chain exists"
assert_contains "$(ipt_rules nfqws_post)" "-j nfqws_qout" "outgoing traffic goes through the counter chain"
assert_file "$MOCK_IPT_STORE/iptables/mangle/nfqws_app" "an app chain appears once APP_MODE is set"
assert_contains "$(ipt_rules nfqws_app)" "--uid-owner 10201" "the resolved UID is matched by owner"
assert_contains "$(ipt_rules nfqws_app)" "--set-xmark 0x10000000/0x10000000" "include mode marks matching traffic"
assert_contains "$(ipt_rules nfqws_post)" "! --mark 0x10000000/0x10000000 -j RETURN" "unmarked traffic is skipped in include mode"
assert_contains "$(ipt_rules nfqws_pre)" "-j nfqws_qin" "incoming traffic goes through the counter chain"

# The counter chain walks PKT_LIMIT_OUT down to zero and then queues
qout=$(ipt_rules nfqws_qout)
assert_contains "$qout" "--set-xmark" "the counter chain increments the connmark counter"
assert_contains "$qout" "-j NFQUEUE --queue-num 300" "the counter chain ends in NFQUEUE"
assert_contains "$qout" "/0x0f000000" "the outgoing counter uses its own mark bits"
assert_eq "15" "$(printf '%s\n' "$qout" | grep -c -- '--set-xmark')" "PKT_LIMIT_OUT=15 yields 15 counter steps"
qin=$(ipt_rules nfqws_qin)
assert_contains "$qin" "/0x000f0000" "the incoming counter uses disjoint mark bits"

section "connmark_out: per-strategy packet limits are honoured"

printf 'NFQWS2_TCP_PKT_OUT=8\n' >> "$CONFFILE"
svc firewall_apply >/dev/null 2>&1
assert_rc 0 "$svc_rc" "firewall_apply accepts a per-strategy limit"
qout=$(ipt_rules nfqws_qout)
assert_eq "8" "$(printf '%s\n' "$qout" | grep -c -- '--set-xmark')" "the strategy's TCP limit lowers the counter steps"

section "connmark_out: BLOCK_QUIC drops UDP/443"

assert_contains "$(ipt_rules nfqws_post)" "-p udp --dport 443 -j DROP" "QUIC is blocked in the post chain"

section "IPv6 disabled"

assert_no_file "$MOCK_IPT_STORE/ip6tables/mangle/nfqws_post" "no ip6tables chain is created"

section "firewall_ok"

reload_conf
firewall_ok
assert_rc 0 $? "firewall_ok sees the installed rules"

svc firewall_stop >/dev/null 2>&1
firewall_ok
assert_rc 1 $? "firewall_ok reports missing rules after firewall_stop"

section "IPv6 enabled builds both tables"

conf_reset
printf 'WATCHDOG=0\nIPV6_ENABLED=1\n' >> "$CONFFILE"
MOCK_IPT_FEATURES="connbytes multiport owner NFQUEUE"
export MOCK_IPT_FEATURES
ipt_reset

svc firewall_apply
assert_rc 0 "$svc_rc" "both firewall families apply successfully"
assert_file "$MOCK_IPT_STORE/iptables/mangle/nfqws_post" "the IPv4 chain exists"
assert_file "$MOCK_IPT_STORE/ip6tables/mangle/nfqws_post" "the IPv6 chain exists"
reload_conf
firewall_ok
assert_rc 0 $? "firewall_ok checks both installed families"
ctl doctor
assert_contains "$ctl_out" "$(printf 'ok\tipv6_rules\t')" "doctor reports healthy IPv6 rules"

ip6tables -w -t mangle -D PREROUTING -j nfqws_pre
firewall_ok
assert_rc 1 $? "a missing IPv6 incoming hook is detected"
IPV6_ENABLED=0
firewall_ok
assert_rc 0 $? "disabled IPv6 is not required for firewall health"
IPV6_ENABLED=1
svc firewall_apply
ip6tables -w -t mangle -F nfqws_post
firewall_ok
assert_rc 1 $? "an empty IPv6 outgoing chain is detected"
svc firewall_stop >/dev/null 2>&1

section "a broken ip6tables half is reported, not silent"

: > "$SERVICE_LOG"
MOCK_IP6_FAIL=1
export MOCK_IP6_FAIL
svc firewall_apply
assert_rc 1 "$svc_rc" "firewall_apply rejects an incomplete dual-stack ruleset"
assert_contains "$(cat "$SERVICE_LOG")" "IPv6 traffic is not intercepted" "the v6 failure is logged"
ctl doctor
assert_contains "$ctl_out" "$(printf 'fail\tipv6_rules\t')" "doctor reports the missing v6 rules as a failure"
svc start
assert_rc 1 "$svc_rc" "service start rejects missing IPv6 protection"
assert_no_file "$PIDFILE" "the daemon is rolled back after IPv6 failure"
assert_no_file "$DESIRED_FILE" "failed IPv6 start leaves no desired-state marker"
unset MOCK_IP6_FAIL
svc firewall_stop >/dev/null 2>&1

section "firewall_start reports a failure in either half"

# firewall_start() runs the IPv4 and IPv6 halves in sequence and used to return the
# status of the last one. firewall_ip6tables() returns 0 unconditionally when
# IPV6_ENABLED=0, so an IPv4 failure was reported as success
#
# The pin matters twice over: the section above turns IPv6 on, and with it every
printf 'IPV6_ENABLED=0\n' >> "$CONFFILE"
MOCK_IPT_FAIL=1
export MOCK_IPT_FAIL
svc firewall_apply
assert_rc 1 "$svc_rc" "firewall_apply fails when the rules cannot be installed"
unset MOCK_IPT_FAIL

section "start: a firewall that does not install is a failed start"

# start() ignored firewall_start() entirely, so a kernel where the rules did not
# install gave a running daemon and a desired-state marker with nothing
# rolled back now, so the failure does not leave a half-applied state either
: > "$SERVICE_LOG"
MOCK_IPT_FAIL=1
export MOCK_IPT_FAIL
svc start
assert_rc 1 "$svc_rc" "start fails when the rules cannot be installed"
assert_contains "$(cat "$SERVICE_LOG")" "failed to apply" "and says why"
assert_no_file "$CONFDIR/state/desired" "the service is not marked as desired"
assert_no_file "$CONFDIR/state/nfqws2.pid" "and the daemon is rolled back"
unset MOCK_IPT_FAIL

section "watchdog and netwatch helpers"

# Both are started through one shared helper now, and the helper's return value
# carries meaning: 0 means "I just started it", 1 means "nothing to do". That sign
# is what keeps ensure_watchdog starting netwatch only at the moment it starts the
# watchdog. A refactor of a load-bearing spawn is exactly where a silent change
# would hide, so the decisions are pinned here
# The detached helper creates its PID file asynchronously; wait to avoid a race
wait_for_file() { # <file> [seconds]
  _i=0
  while [ "$_i" -lt "${2:-5}" ]; do
    [ -f "$1" ] && return 0
    sleep 1
    _i=$((_i + 1))
  done
  return 1
}

printf 'IPV6_ENABLED=0\nWATCHDOG=0\n' >> "$CONFFILE"
svc stop >/dev/null 2>&1
svc start >/dev/null 2>&1
assert_no_file "$WD_PIDFILE" "with WATCHDOG=0 no watchdog is spawned"
assert_no_file "$WN_PIDFILE" "and no netwatch either"

# start() returns early when the service is already up, so the helpers are only
# reached from a genuinely stopped state
svc stop >/dev/null 2>&1
printf 'WATCHDOG=1\n' >> "$CONFFILE"
svc start >/dev/null 2>&1
wait_for_file "$WD_PIDFILE" 8
assert_file "$WD_PIDFILE" "with WATCHDOG=1 the watchdog is spawned"
# The sandbox has no `ip`, so the netwatch precondition fails and it must stay down
assert_no_file "$WN_PIDFILE" "netwatch stays down while ip is missing"

# Kill the daemon but leave the watchdog alive: the next start must reuse the
# running watchdog rather than spawn a second one. That guard is only reachable
wd=$(cat "$WD_PIDFILE" 2>/dev/null)
kill "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null
svc start >/dev/null 2>&1
assert_eq "$wd" "$(cat "$WD_PIDFILE" 2>/dev/null)" "a running watchdog is not spawned twice"

kill "$wd" 2>/dev/null

section "boot-completed.sh lifecycle hook"

assert_file "$MODDIR/boot-completed.sh" "boot-completed.sh exists in sandbox"
svc stop >/dev/null 2>&1

# When AUTOSTART=1 and service is down, boot-completed hook revives it
printf 'AUTOSTART=1\n' >> "$CONFFILE"
sh "$MODDIR/boot-completed.sh" >/dev/null 2>&1
assert_file "$PIDFILE" "boot-completed hook starts service when AUTOSTART=1"

# When already running, running boot-completed hook maintains service state
sh "$MODDIR/boot-completed.sh" >/dev/null 2>&1
assert_file "$PIDFILE" "boot-completed hook maintains running service"

svc stop >/dev/null 2>&1
[ -f "$WD_PIDFILE" ] && kill "$(cat "$WD_PIDFILE" 2>/dev/null)" 2>/dev/null

section "protect_process"

protect_process $$
assert_rc 0 $? "protect_process succeeds on valid pid"
protect_process ""
assert_rc 0 $? "protect_process handles empty pid gracefully"
protect_process "99999999"
assert_rc 0 $? "protect_process handles non-existent pid gracefully"

section "topology_fingerprint and working snapshots"

fp1=$(topology_fingerprint "$CONFFILE")
assert_contains "$fp1" "80,443" "fingerprint captures TCP ports"
save_working_snapshot "$CONFFILE"
assert_file "$CONFDIR/state/snapshot_working/nfqws2.conf" "snapshot saved nfqws2.conf"

section "zero-downtime daemon replace"

svc start >/dev/null 2>&1
assert_file "$PIDFILE" "service is running before replace"
old_pid=$(cat "$PIDFILE")

svc replace
assert_rc 0 "$svc_rc" "replace succeeds"
new_pid=$(cat "$PIDFILE")
assert_file "$PIDFILE" "pidfile exists after replace"
if [ "$old_pid" != "$new_pid" ]; then
  _ok "replace switched daemon PID"
else
  _fail "replace did not switch PID"
fi
assert_file "$MOCK_IPT_STORE/iptables/mangle/nfqws_post" "mangle rules are preserved across replace"

section "rollback engine"

echo "GARBAGE_CONFIG_TEST=1" > "$CONFFILE"
svc rollback
assert_rc 0 "$svc_rc" "rollback succeeds"
assert_not_contains "$(cat "$CONFFILE")" "GARBAGE_CONFIG_TEST" "rollback restored working config"
assert_file "$CONFDIR/state/last_rollback.json" "last_rollback.json is written"

svc stop >/dev/null 2>&1
[ -f "$WD_PIDFILE" ] && kill "$(cat "$WD_PIDFILE" 2>/dev/null)" 2>/dev/null

section "atomic firewall helpers and desync mark unmarking"
printf 'WATCHDOG=0\n' >> "$CONFFILE"

svc start >/dev/null 2>&1
assert_file "$PIDFILE" "service is running for firewall helpers check"
post_rules=$(ipt_rules POSTROUTING)
assert_contains "$post_rules" "MARK --set-xmark 0x0/0x40000000" "POSTROUTING contains desync mark cleaner"

post_chain=$(ipt_rules nfqws_post)
assert_contains "$post_chain" "-m mark --mark 0x40000000/0x40000000 -j RETURN" "nfqws_post avoids requeuing desync packets"

wflag=$(ipt_wait_flag iptables)
assert_rc 0 $? "ipt_wait_flag returns 0"

ipt_exec iptables -t mangle -C POSTROUTING -j nfqws_post 2>/dev/null
assert_rc 0 $? "ipt_exec can probe existing rule"

svc stop >/dev/null 2>&1

ipt_snapshot() {
  (cd "$MOCK_IPT_STORE" && find . -type f | sort | while IFS= read -r f; do echo "== $f"; cat "$f"; done)
}

section "QUIC to Meta is rejected at once"
conf_reset
load_conf >/dev/null 2>&1
ipt_reset
firewall_start >/dev/null 2>&1
snap=$(ipt_snapshot)
assert_contains "$snap" "-p udp --dport 443 -d 157.240.0.0/16,31.13.24.0/21," "on by default: QUIC to Meta gets an ICMP reject"
assert_contains "$snap" "2a03:2880::/32 -j REJECT --reject-with icmp6-port-unreachable" "and over IPv6"
assert_eq "1" "$(grep -c nfqws_mquic "$MOCK_IPT_STORE/iptables/filter/OUTPUT" 2>/dev/null)" "for the phone's own traffic"
assert_eq "1" "$(grep -c nfqws_mquic "$MOCK_IPT_STORE/iptables/filter/FORWARD" 2>/dev/null)" "and for hotspot clients"
firewall_stop >/dev/null 2>&1
assert_not_contains "$(ipt_snapshot)" "nfqws_mquic" "stopping removes the rules"
printf 'META_QUIC_REJECT=0\n' >> "$CONFFILE"
load_conf >/dev/null 2>&1
ipt_reset
firewall_start >/dev/null 2>&1
assert_not_contains "$(ipt_snapshot)" "nfqws_mquic" "off: no reject rules"
firewall_stop >/dev/null 2>&1
conf_reset
load_conf >/dev/null 2>&1

section "VPN pause: active interface suspends the bypass"
NFQWS_SYSNET="$SANDBOX/sysnet"; export NFQWS_SYSNET
mkdir -p "$NFQWS_SYSNET"
svc stop >/dev/null 2>&1
[ -f "$WD_PIDFILE" ] && kill "$(cat "$WD_PIDFILE" 2>/dev/null)" 2>/dev/null
printf 'VPN_PAUSE=1\nWATCHDOG=0\n' >> "$CONFFILE"
svc start >/dev/null 2>&1
assert_file "$PIDFILE" "without a VPN the bypass runs"
mkdir -p "$NFQWS_SYSNET/tun0"; printf '0x1091\n' > "$NFQWS_SYSNET/tun0/flags"
svc home_check >/dev/null 2>&1
assert_no_file "$PIDFILE" "a VPN coming up pauses the bypass"
assert_eq "@vpn" "$(cat "$HOME_PAUSED_FILE" 2>/dev/null)" "and the pause is marked as VPN"
svc start >/dev/null 2>&1
assert_file "$PIDFILE" "a manual start overrides the VPN pause"
assert_eq "@vpn" "$(cat "$HOME_OVERRIDE_FILE" 2>/dev/null)" "until the VPN goes away"
svc home_check >/dev/null 2>&1
assert_file "$PIDFILE" "the override holds while the VPN is on"
printf '0x1090\n' > "$NFQWS_SYSNET/tun0/flags"
svc home_check >/dev/null 2>&1
assert_no_file "$HOME_OVERRIDE_FILE" "a VPN going down clears the override"
printf '0x1091\n' > "$NFQWS_SYSNET/tun0/flags"
svc home_check >/dev/null 2>&1
assert_no_file "$PIDFILE" "the next VPN pauses again"
rm -rf "$NFQWS_SYSNET/tun0"
svc home_check >/dev/null 2>&1
assert_file "$PIDFILE" "the VPN going away resumes the bypass"
assert_no_file "$HOME_PAUSED_FILE" "and clears the pause"
svc stop >/dev/null 2>&1
conf_reset
unset NFQWS_SYSNET

harness_finish
