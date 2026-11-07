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
assert_contains "$(ipt_rules nfqws_nat nat)" "-m connmark --mark 0x80000000/0x80000000 -j MASQUERADE" "the NAT fix matches the saved connmark, not the packet mark that mangle clears first"

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
assert_contains "$(ipt_rules nfqws_pre)" "! --mark 0x10000000/0x10000000 -j RETURN" "unmarked incoming traffic is skipped in prerouting in include mode"
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

section "app filter: multiple apps and profiles generate separate comma-free rules"

printf 'com.termux\ncom.example.browser\n' > "$CONFDIR/apps.list"
svc firewall_apply >/dev/null 2>&1
assert_rc 0 "$svc_rc" "firewall_apply succeeds with multiple apps"
app_chain=$(ipt_rules nfqws_app)
assert_contains "$app_chain" "--uid-owner 10123" "first app UID is matched individually"
assert_contains "$app_chain" "--uid-owner 10201" "second app UID is matched individually"
assert_not_contains "$app_chain" "," "no comma-separated UIDs in owner rules (xt_owner restriction)"

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

section "working snapshots"

save_working_snapshot "$CONFFILE"
assert_file "$CONFDIR/state/snapshot_working/nfqws2.conf" "snapshot saved nfqws2.conf"

section "restart stops the daemon before starting the new one"

svc start >/dev/null 2>&1
assert_file "$PIDFILE" "service is running before replace"
old_pid=$(cat "$PIDFILE")

: > "$SERVICE_LOG"
MOCK_NFQWS_EBUSY=1
export MOCK_NFQWS_EBUSY
svc replace
assert_rc 0 "$svc_rc" "replace succeeds with the queue reported busy"
new_pid=$(cat "$PIDFILE" 2>/dev/null)
assert_file "$PIDFILE" "pidfile exists after replace"
if [ "$old_pid" != "$new_pid" ]; then
  _ok "replace switched daemon PID"
else
  _fail "replace did not switch PID"
fi
log_text=$(cat "$SERVICE_LOG")
assert_contains "$log_text" "stopping first" "the log explains why the daemon is stopped first"
assert_not_contains "$log_text" "Zero-Downtime" "the zero-downtime claim is gone"
assert_file "$MOCK_IPT_STORE/iptables/mangle/nfqws_post" "mangle rules are rebuilt after replace"
unset MOCK_NFQWS_EBUSY

section "invalid parameters keep the running daemon"

: > "$SERVICE_LOG"
old_pid=$(cat "$PIDFILE")
MOCK_NFQWS_DRY_RUN_FAIL=2
export MOCK_NFQWS_DRY_RUN_FAIL
svc replace
assert_rc 1 "$svc_rc" "replace refuses to stop on an invalid config"
assert_eq "$old_pid" "$(cat "$PIDFILE")" "the running daemon is kept"
kill -0 "$old_pid" 2>/dev/null
assert_rc 0 $? "and it is still alive"
unset MOCK_NFQWS_DRY_RUN_FAIL

section "a failed restart falls back to the working snapshot"

svc start >/dev/null 2>&1
assert_file "$PIDFILE" "running before the failing restart"
: > "$SERVICE_LOG"
MOCK_NFQWS_FAIL=3
export MOCK_NFQWS_FAIL
svc replace
assert_rc 1 "$svc_rc" "restart reports failure"
assert_contains "$(cat "$SERVICE_LOG")" "restoring the last working snapshot" \
  "and tries to come back on the previous configuration"
unset MOCK_NFQWS_FAIL

section "hotspot rules follow the setting"

svc start >/dev/null 2>&1
ctl set ENABLE_HOTSPOT 1
assert_contains "$(ipt_rules FORWARD)" "-j nfqws_fwd" "enabling the hotspot adds the FORWARD jump"
ctl set ENABLE_HOTSPOT 0
assert_not_contains "$(ipt_rules FORWARD)" "nfqws_fwd" "disabling it removes the jump and the chain"
svc stop >/dev/null 2>&1
ctl set ENABLE_HOTSPOT 1
assert_eq "" "$(ipt_rules POSTROUTING)" "a stopped service gets no firewall rules from a setting"
ctl set ENABLE_HOTSPOT 0

section "a restart whose configuration passes no traffic is rolled back"

# Background helpers (a watchdog auto-restart) can hold the service lock between
# the sections; drop them so the restart under test is not refused.
for _p in "$WD_PIDFILE" "$WN_PIDFILE" "$WL_PIDFILE" "$SK_PIDFILE"; do
  if [ -f "$_p" ]; then kill "$(cat "$_p" 2>/dev/null)" 2>/dev/null; rm -f "$_p"; fi
done
rm -rf "$CONFDIR/state/service.lock"

# the old configuration passed traffic (first probe), the new one never does
printf 'example.net\nexample.org\n' > "$LISTS_DIR/probe_hosts.list"
cat > "$MOCKBIN/curl" <<'X'
#!/bin/sh
n=$(cat "$MOCK_DIR/curl_calls" 2>/dev/null || echo 0)
n=$((n + 1)); printf '%s\n' "$n" > "$MOCK_DIR/curl_calls"
[ "$n" -le 1 ] && exit 0
exit 22
X
chmod 0755 "$MOCKBIN/curl"
rm -f "$MOCK_DIR/curl_calls"
svc start >/dev/null 2>&1
# config B differs from the config the snapshot holds: the rollback has to bring
# A back, and the failing start must not have overwritten the snapshot with B
sed -i 's/^TCP_PORTS=.*/TCP_PORTS="9"/' "$CONFFILE"
: > "$SERVICE_LOG"
svc replace
assert_rc 1 "$svc_rc" "a restart that breaks traffic fails"
assert_contains "$(cat "$SERVICE_LOG")" "passes no traffic" "and says the new configuration passes no traffic"
assert_contains "$(cat "$SERVICE_LOG")" "restored from working snapshot" "the working snapshot is restored"
assert_eq "80,443,1984,2053,2083,2087,2096,5222,8443" \
  "$(grep '^TCP_PORTS=' "$CONFFILE" | head -1 | sed 's/^TCP_PORTS=//; s/"//g')" \
  "the rollback restores the pre-replace settings, not the ones that just failed"
assert_eq "0" "$(grep -c 'TCP_PORTS="9"' "$SNAPSHOT_DIR/nfqws2.conf" 2>/dev/null || true)" \
  "the configuration that passed no traffic never became the working snapshot"
assert_file "$PIDFILE" "and the service runs on the old configuration"
assert_file "$CONFDIR/state/last_rollback.json" "the rollback is recorded"
rm -f "$MOCKBIN/curl" "$MOCK_DIR/curl_calls"

section "a restart that keeps working traffic alone does not roll back"

printf 'example.net\n' > "$LISTS_DIR/probe_hosts.list"
cat > "$MOCKBIN/curl" <<'X'
#!/bin/sh
exit 0
X
chmod 0755 "$MOCKBIN/curl"
old_pid=$(cat "$PIDFILE" 2>/dev/null)
: > "$SERVICE_LOG"
svc replace
assert_rc 0 "$svc_rc" "a healthy restart succeeds"
assert_not_contains "$(cat "$SERVICE_LOG")" "passes no traffic" "and no rollback is mentioned"
if [ "$(cat "$PIDFILE" 2>/dev/null)" != "$old_pid" ]; then _ok "the daemon was switched"
else _fail "the daemon was not switched"; fi
rm -f "$MOCKBIN/curl"

section "the watchdog restart streak survives a restart"

(
  awk '/^watchdog_fail_count\(\)/,/^}/' "$MODDIR/service.sh" > "$SANDBOX/wd.sh"
  awk '/^watchdog_fail_set\(\)/,/^}/' "$MODDIR/service.sh" >> "$SANDBOX/wd.sh"
  . "$SANDBOX/wd.sh"
  printf '3 %s\n' "$(date +%s)" > "$STATE_DIR/watchdog_fails"
  assert_eq "3" "$(watchdog_fail_count)" "the streak is read back from the file"
  printf '7 %s\n' "$(( $(date +%s) - 7200 ))" > "$STATE_DIR/watchdog_fails"
  assert_eq "0" "$(watchdog_fail_count)" "a streak older than an hour counts as a fresh problem"
  watchdog_fail_set 5
  assert_eq "5" "$(awk '{print $1}' "$STATE_DIR/watchdog_fails")" "and the streak is written back"
  rm -f "$STATE_DIR/watchdog_fails"
)

section "stopping puts the kernel settings back"
mkdir -p "$STATE_DIR"
printf 'net.core.rmem_max 111111\n' > "$STATE_DIR/sysctls"
svc stop >/dev/null 2>&1
assert_no_file "$STATE_DIR/sysctls" "stop clears the sysctl snapshot taken at start"

section "the service lock is not stolen"
svc start >/dev/null 2>&1
svc stop >/dev/null 2>&1
mkdir "$CONFDIR/state/service.lock"
: > "$SERVICE_LOG"
svc start
assert_rc 1 "$svc_rc" "a second start is refused while the lock is held"
assert_contains "$(cat "$SERVICE_LOG")" "another start/replace holds" "and says why"
if [ -d "$CONFDIR/state/service.lock" ]; then _ok "the foreign lock directory survives"
else _fail "the foreign lock directory was removed"; fi
assert_no_file "$PIDFILE" "and no daemon was started"
rmdir "$CONFDIR/state/service.lock"

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
assert_contains "$post_rules" "-j CONNMARK --set-xmark 0x80000000/0x80000000" "POSTROUTING saves the desync mark for nat before clearing it"

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

section "a firewall re-apply without a stop keeps POSTROUTING single"

conf_reset
load_conf >/dev/null 2>&1
ipt_reset
# На телефоне правила копились именно здесь: прямой путь _firewall_start вставляет
# -I POSTROUTING 2/3, а защищён от повтора только restore-путь с проверкой -C.
# iptables-restore убираем, чтобы firewall_start пошёл прямым путём, как на ядрах
# без него.
mv "$MOCKBIN/iptables-restore" "$SANDBOX/iptables-restore.off"
mv "$MOCKBIN/ip6tables-restore" "$SANDBOX/ip6tables-restore.off"
firewall_start >/dev/null 2>&1
firewall_start >/dev/null 2>&1
post="$MOCK_IPT_STORE/iptables/mangle/POSTROUTING"
assert_eq "1" "$(grep -c -- '-j nfqws_post' "$post" 2>/dev/null)" "the outgoing jump is applied once"
assert_eq "1" "$(grep -c 'CONNMARK --set-xmark 0x80000000' "$post" 2>/dev/null)" "the NAT_FIX save rule is not stacked"
assert_eq "1" "$(grep -c 'MARK --set-xmark 0x0/0x40000000' "$post" 2>/dev/null)" "neither is the unmark rule"
assert_eq "1" "$(grep -c -- '-j nfqws_pre' "$MOCK_IPT_STORE/iptables/mangle/PREROUTING" 2>/dev/null)" "and PREROUTING keeps a single jump"
firewall_stop >/dev/null 2>&1
mv "$SANDBOX/iptables-restore.off" "$MOCKBIN/iptables-restore"
mv "$SANDBOX/ip6tables-restore.off" "$MOCKBIN/ip6tables-restore"

section "stopping the service clears what a killed bench left behind"

conf_reset
load_conf >/dev/null 2>&1
ipt_reset
iptables -w -t mangle -N nfqws_bench_out >/dev/null 2>&1
iptables -w -t mangle -N nfqws_bench_in >/dev/null 2>&1
iptables -w -t mangle -I POSTROUTING 1 -j nfqws_bench_out >/dev/null 2>&1
iptables -w -t mangle -I PREROUTING 1 -j nfqws_bench_in >/dev/null 2>&1
sh "$MODDIR/bin/nfqws2" --daemon --pidfile="$STATE_DIR/bench_slot.0.pid" >/dev/null 2>&1
slotpid=$(cat "$STATE_DIR/bench_slot.0.pid" 2>/dev/null)
assert_match "$slotpid" '^[0-9]+$' "a slot instance is left running"
kill -0 "$slotpid" 2>/dev/null
assert_rc 0 "$?" "and its process lives before the stop"
svc stop
assert_not_contains "$(ipt_rules POSTROUTING)" "nfqws_bench_out" "stop takes the bench jump out of POSTROUTING"
assert_not_contains "$(ipt_rules PREROUTING)" "nfqws_bench_in" "and the incoming one out of PREROUTING"
assert_eq "" "$(iptables -w -t mangle -S nfqws_bench_out 2>/dev/null)" "the bench chain itself is deleted"
assert_no_file "$STATE_DIR/bench_slot.0.pid" "the slot pidfile is gone"
kill -0 "$slotpid" 2>/dev/null
assert_rc 1 "$?" "and the slot daemon is stopped rather than orphaned on the queue"

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

# ── network scenarios: loss and return of the connection ────────────────────
section "network scenarios: the connection drops and comes back"
: > "$MOCK_DIR/ipmon"; echo rmnet_data1 > "$MOCK_DIR/route"
cat > "$MOCKBIN/ip" <<EOF
#!/bin/sh
case "\$1 \$2" in
  "monitor "*) exec tail -n 0 -f "$MOCK_DIR/ipmon" ;;
  "route get") d=\$(cat "$MOCK_DIR/route" 2>/dev/null); [ -n "\$d" ] || { echo "RTNETLINK answers: Network is unreachable" >&2; exit 2; }
    echo "1.1.1.1 via 10.0.0.1 dev \$d src 10.0.0.2 uid 0" ;;
esac
exit 0
EOF
chmod 0755 "$MOCKBIN/ip"
MOCK_OPERATOR=25001; MOCK_OPERATOR_NAME=MTS; NW_RECHECK="1 2 4"; export MOCK_OPERATOR MOCK_OPERATOR_NAME NW_RECHECK
rm -f "$STATE_DIR/smart_net" "$STATE_DIR/smart_net_last" "$CONFDIR/smart/nets.tsv"
svc stop >/dev/null 2>&1
printf 'WATCHDOG=1\n' >> "$CONFFILE"
svc start >/dev/null 2>&1
wait_for_file "$WN_PIDFILE" 8
net_is() { # <expected net> <seconds>
  local i=0; while [ "$i" -lt $(( $2 * 4 )) ]; do [ "$(cat "$STATE_DIR/smart_net" 2>/dev/null)" = "$1" ] && return 0; sleep 0.25; i=$((i + 1)); done; return 1
}
ev() { echo "2: rmnet_data1: <UP> state $1" >> "$MOCK_DIR/ipmon"; }
net_is mobile-25001 6
assert_rc 0 $? "online at start: the mobile network is known"
# 1. Connection drops
: > "$MOCK_DIR/route"; ev DOWN
net_is offline 6
assert_rc 0 $? "the connection drops: no network"
assert_eq "mobile-25001" "$(cat "$STATE_DIR/smart_net_last")" "the last real network is remembered"
assert_not_contains "$(cat "$CONFDIR/smart/nets.tsv" 2>/dev/null)" "offline" "«no connection» is never a network of its own"
# 2. Connection returns
: > "$IDLE_FILE"
ev UP; sleep 2; echo rmnet_data1 > "$MOCK_DIR/route"
net_is mobile-25001 8
assert_rc 0 $? "the route shows up after the only event: the recheck sees the network back"
assert_contains "$(cat "$SERVICE_LOG")" "netwatch: connection returned" "and says so"
# 3. Flapping
for st in DOWN UP DOWN UP; do
  if [ "$st" = DOWN ]; then : > "$MOCK_DIR/route"; else echo rmnet_data1 > "$MOCK_DIR/route"; fi
  ev "$st"; sleep 0.3
done
net_is mobile-25001 8
assert_rc 0 $? "a flapping connection ends on the network it ended on"
# 4. Mobile -> Wi-Fi -> offline -> Wi-Fi
NFQWS_SYSNET="$SANDBOX/sysnet2"; export NFQWS_SYSNET
mkdir -p "$NFQWS_SYSNET/wlan0"; echo up > "$NFQWS_SYSNET/wlan0/operstate"
echo wlan0 > "$MOCK_DIR/route"; ev UP
net_is wifi 10
assert_rc 0 $? "switching to Wi-Fi switches the network"
: > "$MOCK_DIR/route"; echo down > "$NFQWS_SYSNET/wlan0/operstate"; ev DOWN
net_is offline 10
assert_rc 0 $? "Wi-Fi gone with no mobile: no network"
echo up > "$NFQWS_SYSNET/wlan0/operstate"; ev UP; sleep 0.5; echo wlan0 > "$MOCK_DIR/route"
net_is wifi 10
assert_rc 0 $? "Wi-Fi back after its event: the recheck finds it"
assert_eq "wifi" "$(cat "$STATE_DIR/smart_net_last")" "and it becomes the last real network"
# 5. Smart status without connection
: > "$MOCK_DIR/route"; ev DOWN; net_is offline 10
ctl_out=$(sh "$MODDIR/bin/nfqws2-ctl" smart-status 2>&1)
assert_contains "$ctl_out" '"offline":1' "the screen knows there is no connection"
assert_contains "$ctl_out" '"view":"wifi"' "and shows the last real network, not an empty «no connection» profile"
assert_contains "$ctl_out" '"id":"wifi","label":"Wi‑Fi"' "that network is listed"
assert_match "$ctl_out" '"id":"wifi"[^}]*"current":1' "as the current one"
unset NFQWS_SYSNET NW_RECHECK
kill "$(cat "$WN_PIDFILE" 2>/dev/null)" "$(cat "$WD_PIDFILE" 2>/dev/null)" 2>/dev/null
svc stop >/dev/null 2>&1
rm -f "$MOCKBIN/ip" "$WN_PIDFILE" "$WD_PIDFILE" "$MOCK_DIR/route"

section "a lost nfqws2 of ours is stopped before a start"
# Honor, MagicOS 11: служба потеряла свой nfqws2 (PID-файл сброшен), а он
# держал очередь NFQUEUE — каждый новый запуск падал с «nfq_create_queue():
# Operation not permitted». Свой — по --pidfile модуля, чужой не трогаем
svc stop >/dev/null 2>&1
# pidof Android (toybox) находит и скрипты, pidof procps — только с -x
pidof_real=$(command -v pidof 2>/dev/null)
if [ -n "$pidof_real" ]; then
  printf '#!/bin/sh\nexec %s -x "$@"\n' "$pidof_real" > "$MOCKBIN/pidof"
else
  cat > "$MOCKBIN/pidof" <<'EOF'
#!/bin/sh
for c in /proc/[0-9]*/cmdline; do
  [ -f "$c" ] || continue
  p=${c#/proc/}
  p=${p%/cmdline}
  [ "$p" = "$$" ] && continue
  if grep -qF "$1" "$c" 2>/dev/null; then
    printf '%s ' "$p"
  fi
done
echo
EOF
fi
chmod 0755 "$MOCKBIN/pidof"
mkdir -p "$SANDBOX/orph" "$SANDBOX/orph2"
printf '#!/bin/sh\nwhile :; do sleep 1; done\n' > "$SANDBOX/orph/nfqws2"; cp "$SANDBOX/orph/nfqws2" "$SANDBOX/orph2/nfqws2"
chmod 0755 "$SANDBOX/orph/nfqws2" "$SANDBOX/orph2/nfqws2"
"$SANDBOX/orph/nfqws2" --daemon --pidfile="$PIDFILE" --qnum=300 >/dev/null 2>&1 &
op=$!
"$SANDBOX/orph2/nfqws2" --daemon --pidfile=/data/adb/other/nfqws2.pid >/dev/null 2>&1 &
fp=$!
sleep 0.3
rm -f "$PIDFILE"; : > "$SERVICE_LOG"
svc start
assert_rc 0 "$svc_rc" "the start goes through"
kill -0 "$op" 2>/dev/null; assert_rc 1 $? "our lost daemon holding the queue is stopped first"
assert_contains "$(cat "$SERVICE_LOG")" "Найден потерянный nfqws2 (PID $op)" "and the log says so"
kill -0 "$fp" 2>/dev/null; assert_rc 0 $? "another module's nfqws2 is left alone"
kill -9 "$fp" "$op" 2>/dev/null; wait "$fp" "$op" 2>/dev/null
rm -f "$MOCKBIN/pidof"
svc stop >/dev/null 2>&1

section "boot again without a kernel reboot (Android restart)"
# Мягкая перезагрузка (LSPosed/Vector) запускает service.sh заново, а процессы
# модуля живы: тот же boot_id — сначала остановить прежнее, а не терять его
cp "$CONFFILE" "$SANDBOX/conf.keep"
printf 'AUTOSTART=0\nWATCHDOG=0\n' >> "$CONFFILE"
if [ -r /proc/sys/kernel/random/boot_id ]; then
  svc start >/dev/null 2>&1
  old=$(cat "$PIDFILE" 2>/dev/null)
  sleep 300 & wd=$!; echo "$wd" > "$WD_PIDFILE"
  cat /proc/sys/kernel/random/boot_id > "$CONFDIR/state/boot_id"
  : > "$SERVICE_LOG"
  svc boot
  assert_contains "$(cat "$SERVICE_LOG")" "Повторная загрузка Android без перезагрузки ядра" "the same kernel boot is recognised"
  kill -0 "$old" 2>/dev/null; assert_rc 1 $? "the old daemon is stopped, not lost"
  kill -0 "$wd" 2>/dev/null; assert_rc 1 $? "and the old watchdog too (no second one beside the new)"
  wait "$wd" 2>/dev/null
  echo other > "$CONFDIR/state/boot_id"; : > "$SERVICE_LOG"
  svc boot
  assert_not_contains "$(cat "$SERVICE_LOG")" "Повторная загрузка Android" "a real reboot (new boot_id) is a normal boot"
  assert_eq "$(cat /proc/sys/kernel/random/boot_id)" "$(cat "$CONFDIR/state/boot_id")" "the boot is remembered"
fi
cp "$SANDBOX/conf.keep" "$CONFFILE"
svc stop >/dev/null 2>&1

harness_finish
