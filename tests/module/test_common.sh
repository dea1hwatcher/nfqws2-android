#!/bin/sh
# Unit tests for the pure logic in lib/common.sh.
# Everything here runs without touching a device: no iptables, no /data/adb.

HERE=$(cd "$(dirname "$0")" && pwd)
TESTS_DIR=$(cd "$HERE/.." && pwd)
REPO_DIR=$(cd "$TESTS_DIR/.." && pwd)
. "$TESTS_DIR/lib/harness.sh"

sandbox_init
trap sandbox_cleanup INT TERM
load_common
conf_reset
load_conf

# ── norm_args ─────────────────────────────────────────────────────────────────
section "norm_args: comment stripping and whitespace"

out=$(norm_args '--foo   --bar
   # this is a comment
   --baz')
assert_eq "--foo --bar --baz" "$out" "drops comment lines and collapses whitespace"

out=$(norm_args 'a\\b')
assert_eq "ab" "$out" "strips backslashes"

out=$(norm_args '   leading and trailing   ')
assert_eq "leading and trailing" "$out" "trims the edges"

section "norm_args: path rewriting"

out=$(norm_args '--lua-init=@/opt/etc/nfqws2/lua/zapret-lib.lua')
assert_eq "--lua-init=@$LUA_DIR/zapret-lib.lua" "$out" "lua path -> \$LUA_DIR"

out=$(norm_args '--blob=x:/opt/etc/nfqws2/blobs/stun.bin')
assert_eq "--blob=x:$BLOBS_DIR/stun.bin" "$out" "blobs path -> \$BLOBS_DIR"

out=$(norm_args '--hostlist=/opt/etc/nfqws2/lists/user.list')
assert_eq "--hostlist=$LISTS_DIR/user.list" "$out" "lists path -> \$LISTS_DIR"

out=$(norm_args '--debug=@/opt/var/log/nfqws2.log')
assert_eq "--debug=@$LOG_DIR/nfqws2.log" "$out" "log path -> \$LOG_DIR"

# The generic /opt/etc/nfqws2 rule must not swallow the specific ones above.
out=$(norm_args '/opt/etc/nfqws2/lua/a.lua /opt/etc/nfqws2/lists/b.list /opt/etc/nfqws2/c.conf')
assert_eq "$LUA_DIR/a.lua $LISTS_DIR/b.list $CONFDIR/c.conf" "$out" \
  "specific paths win over the generic /opt/etc/nfqws2 rule"

# ── list_count ────────────────────────────────────────────────────────────────
section "list_count"

printf 'a.com\n\n# comment\n  \nb.com\n' > "$LISTS_DIR/user.list"
assert_eq "2" "$(list_count "$LISTS_DIR/user.list")" "counts only real entries"

assert_eq "0" "$(list_count "$LISTS_DIR/does-not-exist.list")" "missing file counts as 0"

: > "$LISTS_DIR/user.list"
assert_eq "0" "$(list_count "$LISTS_DIR/user.list")" "empty file counts as 0"

section "list_counts agrees with list_count"

# json-status counts all its lists with one grep; the numbers must stay exactly
# what list_count gives file by file, including for missing and edge-case files.
printf 'a.com\r\n\r\n# c\r\nb.com' > "$LISTS_DIR/user.list"
printf 'x\n\t\n  # y\nz\n' > "$LISTS_DIR/exclude.list"
printf 'one\n' > "$LISTS_DIR/user.list.bak"
: > "$LISTS_DIR/auto.list"
mkdir -p "$LISTS_DIR/dir.list"
set --
want=""
for f in user exclude auto user.list.bak dir does-not-exist user; do
  case "$f" in *.bak) p="$LISTS_DIR/$f" ;; *) p="$LISTS_DIR/$f.list" ;; esac
  set -- "$@" "$p"
  want="$want${want:+ }$(list_count "$p")"
done
assert_eq "$want" "$(list_counts "$@")" "one number per file, in argument order"
assert_eq "2" "$(list_counts "$LISTS_DIR/exclude.list")" "a single file works too"
rmdir "$LISTS_DIR/dir.list"; rm -f "$LISTS_DIR/user.list.bak"
set --

section "current_mode"

cp "$CONFFILE" "$CONFFILE.keep"
printf 'A=1\nNFQWS_EXTRA_ARGS="$MODE_LIST"\nNFQWS_EXTRA_ARGS="$MODE_ALL"\n' > "$CONFFILE"
assert_eq "list" "$(current_mode)" "the first NFQWS_EXTRA_ARGS line wins"
printf 'NFQWS_EXTRA_ARGS="--x"\n' > "$CONFFILE"
assert_eq "" "$(current_mode)" "no mode, no output"
mv -f "$CONFFILE.keep" "$CONFFILE"

# ── port_list_without ─────────────────────────────────────────────────────────
section "port_list_without"

assert_eq "80,1984" "$(port_list_without '80,443,1984' 443)" "removes a middle port"
assert_eq "443,1984" "$(port_list_without '80,443,1984' 80)" "removes the first port"
assert_eq "80,443" "$(port_list_without '80,443,1984' 1984)" "removes the last port"
assert_eq "80,443" "$(port_list_without '80,443' 5222)" "unknown port changes nothing"
assert_eq "80" "$(port_list_without '80,443' 443)" "single port can disappear"

# ── validate_conf ─────────────────────────────────────────────────────────────
section "validate_conf"

printf 'A=1\nB="x"\n' > "$CONFFILE"
validate_conf "$CONFFILE"; assert_rc 0 $? "plain config passes"

printf 'A=1\nB=`id`\n' > "$CONFFILE"
validate_conf "$CONFFILE" >/dev/null 2>&1; assert_rc 1 $? "backtick is rejected"

printf 'A=1\nB=$(id)\n' > "$CONFFILE"
validate_conf "$CONFFILE" >/dev/null 2>&1; assert_rc 1 $? "command substitution is rejected"

out=$(validate_conf "$CONFFILE" 2>&1)
assert_contains "$out" "line 2" "the offending line number is reported"

# ── dry_run_check and validate_conf_file ──────────────────────────────────────
section "dry_run_check and validate_conf_file"

conf_reset
validate_conf_file "$CONFFILE"
assert_rc 0 $? "valid conf file passes validate_conf_file"

printf 'NFQWS_BASE_ARGS="--new"\n' > "$CONFFILE"
validate_conf_file "$CONFFILE" >/dev/null 2>&1
assert_rc 1 $? "config with --new in base args is rejected by validate_conf_file"

conf_reset
MOCK_NFQWS_DRY_RUN_FAIL=1
export MOCK_NFQWS_DRY_RUN_FAIL
validate_conf_file "$CONFFILE" >/dev/null 2>&1
assert_rc 1 $? "validate_conf_file fails when nfqws2 dry-run rejects parameters"
unset MOCK_NFQWS_DRY_RUN_FAIL

# ── import_safe_name ──────────────────────────────────────────────────────────
section "import_safe_name"

assert_eq "keenetic" "$(import_safe_name 'keenetic')" "plain name survives"
assert_eq "etcpasswd" "$(import_safe_name '/etc/passwd')" "slashes are stripped"
assert_eq "мой конфиг" "$(import_safe_name 'мой конфиг')" "cyrillic survives, only edges are trimmed"
assert_eq "ab" "$(import_safe_name '..ab')" "leading dots are trimmed"

q="'"
raw="a/b\\c\`d\$e\"f${q}g"
assert_eq "abcdefg" "$(import_safe_name "$raw")" "shell metacharacters are removed"

long=$(printf 'x%.0s' $(seq 1 400))
assert_eq "200" "$(printf '%s' "$(import_safe_name "$long")" | wc -c | tr -d ' ')" "name is capped at 200 chars"

# ── is_keenetic_config ────────────────────────────────────────────────────────
section "is_keenetic_config"

printf 'NFQWS_ARGS="x"\n' > "$SANDBOX/one.conf"
is_keenetic_config "$SANDBOX/one.conf"; assert_rc 1 $? "a single key is not enough"

printf 'NFQWS_ARGS="x"\nISP_INTERFACE="eth0"\n' > "$SANDBOX/two.conf"
is_keenetic_config "$SANDBOX/two.conf"; assert_rc 0 $? "two keys are accepted"

printf '# just a comment\nfoo=bar\n' > "$SANDBOX/none.conf"
is_keenetic_config "$SANDBOX/none.conf"; assert_rc 1 $? "unrelated file is rejected"

# ── is_running ────────────────────────────────────────────────────────────────
section "is_running"

rm -f "$PIDFILE"
is_running; assert_rc 1 $? "no pidfile means not running"

echo "" > "$PIDFILE"
is_running; assert_rc 1 $? "empty pidfile means not running"

echo "0" > "$PIDFILE"
is_running; assert_rc 1 $? "pid 0 is rejected"

echo "notapid" > "$PIDFILE"
is_running; assert_rc 1 $? "non-numeric pid is rejected"

echo "999999" > "$PIDFILE"
is_running; assert_rc 1 $? "dead pid is rejected"

echo "$$" > "$PIDFILE"
is_running; assert_rc 0 $? "live pid is accepted"

# ── app_uid_count ─────────────────────────────────────────────────────────────
section "app_uid_count"

rm -f "$APP_UIDS_FILE"
assert_eq "0" "$(app_uid_count)" "missing uid file counts as 0"

printf '10123,10188,10201\n' > "$APP_UIDS_FILE"
assert_eq "3" "$(app_uid_count)" "counts comma-separated uids"

printf '10123,,abc,10201\n' > "$APP_UIDS_FILE"
assert_eq "2" "$(app_uid_count)" "ignores empty and non-numeric fields"

# ── resolve_app_uids ──────────────────────────────────────────────────────────
section "resolve_app_uids"

printf '# packages\ncom.example.browser\ncom.termux\nmissing.app\n' > "$CONFDIR/apps.list"
out=$(resolve_app_uids)
assert_eq "10123,10201" "$out" "resolves only packages present on the device, sorted"

printf 'com.termux\n' > "$CONFDIR/apps.list"
assert_eq "10201" "$(resolve_app_uids)" "single package resolves"

: > "$CONFDIR/apps.list"
assert_eq "" "$(resolve_app_uids)" "empty apps.list resolves to nothing"

# Multi-user / Shelter profile support
export MOCK_USERS="0 10"
printf 'com.termux\n' > "$CONFDIR/apps.list"
assert_eq "10201,1010201" "$(resolve_app_uids)" "unprefixed package resolves across all active profiles"

printf '10:com.termux\n' > "$CONFDIR/apps.list"
assert_eq "1010201" "$(resolve_app_uids)" "prefixed package (10:pkg) resolves only for user 10 (Shelter)"

printf '0:com.termux\n' > "$CONFDIR/apps.list"
assert_eq "10201" "$(resolve_app_uids)" "prefixed package (0:pkg) resolves only for user 0"

printf '10:com.termux\ncom.example.browser\n' > "$CONFDIR/apps.list"
assert_eq "10123,1010123,1010201" "$(resolve_app_uids)" "mix of global and profile-specific packages resolves correctly"
unset MOCK_USERS

# ── _startup_args ─────────────────────────────────────────────────────────────
section "_startup_args"

conf_reset
printf 'ipset.example.com\n' > "$LISTS_DIR/ipset.list"
reload_conf
args=$(_startup_args)
assert_contains "$args" "--user=root" "passes the configured user"
assert_contains "$args" "--qnum=300" "passes the queue number"
assert_contains "$args" "--debug=@$NFQWS_LOG" "LOG_LEVEL=0 logs to nfqws2.log"
assert_not_contains "$args" "--bind-fix4" "no bind-fix without ISP_INTERFACE"
assert_contains "$args" "--ipset=$LISTS_DIR/ipset.list" "ipset block appears when ipset.list is populated"

: > "$LISTS_DIR/ipset.list"
reload_conf
args=$(_startup_args)
assert_not_contains "$args" "--ipset" "ipset block disappears when ipset.list is empty"

printf 'BLOCK_QUIC=1\n' >> "$CONFFILE"
reload_conf
args=$(_startup_args)
assert_not_contains "$args" "--filter-udp=443" "QUIC block drops the quic desync"

conf_reset
printf 'LOG_LEVEL=1\n' >> "$CONFFILE"
reload_conf
args=$(_startup_args)
assert_contains "$args" "--debug=@$LOG_DIR/nfqws2-debug.log" "LOG_LEVEL=1 logs to the debug file"

conf_reset
printf 'ISP_INTERFACE="wlan0 rmnet0"\n' >> "$CONFFILE"
reload_conf
args=$(_startup_args)
assert_contains "$args" "--bind-fix4" "multiple ISP interfaces enable bind-fix4"
assert_contains "$args" "--bind-fix6" "bind-fix6 follows when IPv6 is on"

conf_reset
printf 'ISP_INTERFACE="wlan0 rmnet0"\nIPV6_ENABLED=0\n' >> "$CONFFILE"
reload_conf
args=$(_startup_args)
assert_contains "$args" "--bind-fix4" "bind-fix4 still applies"
assert_not_contains "$args" "--bind-fix6" "bind-fix6 is skipped with IPv6 disabled"

section "_startup_args: call bypass"
conf_reset
reload_conf
args=$(_startup_args)
assert_not_contains "$args" "calls_stun" "off by default"
printf 'CALLS_BYPASS=1\n' >> "$CONFFILE"
reload_conf
args=$(_startup_args)
assert_contains "$args" "--blob=calls_stun:@$BLOBS_DIR/stun.bin" "on: the STUN blob is loaded"
assert_contains "$args" "--filter-udp=590-1400,3478-3482 --filter-l7=stun" "STUN on call ports is faked"
assert_contains "$args" "157.240.0.0/16" "the Meta networks are filled in"
assert_contains "$args" "149.154.160.0/20" "and the Telegram ones"
assert_contains "$args" "2001:67c:4e8::/48" "IPv6 included"
assert_not_contains "$args" "@META@" "no placeholder is left"
assert_contains "$args" "--hostlist-domains=whatsapp.net" "the WhatsApp TLS channel has its profile"
assert_not_contains "$args" "#" "without the comments of its file"
pre=${args%%--filter-udp=590-1400*}
assert_not_contains "$pre" "--new" "before every strategy profile"

section "port_list_add"
assert_eq "443,5349,19294:19344,49152:65535,590:1400,3478:3482" \
  "$(port_list_add 443,590:600,1400,3478:3481,5349,19294:19344,49152:65535 590:1400 3478:3482)" \
  "ranges absorb the ports they cover, so multiport keeps under 15"
assert_eq "80,443,5222" "$(port_list_add 80,443,5222 5222)" "a port already there stays once"

# ── render_import_merged ──────────────────────────────────────────────────────
section "render_import_merged"

conf_reset
printf 'PKT_LIMIT_OUT=15\n' >> "$CONFFILE"
reload_conf
cat > "$SANDBOX/imp.conf" <<'IMP'
ISP_INTERFACE="eth0"
USER="keenetic"
POLICY_NAME="p1"
LOG_DEBUG_PATH="/opt/var/log/nfqws2.log"
NFQWS_BASE_ARGS="--lua-init=@/opt/etc/nfqws2/lua/zapret-lib.lua"
PKT_LIMIT_OUT=3
IMP
out=$(render_import_merged "$SANDBOX/imp.conf")
assert_not_contains "$out" 'ISP_INTERFACE=' "device-specific ISP_INTERFACE is dropped"
assert_not_contains "$out" 'USER="keenetic"' "keentic USER is dropped"
assert_not_contains "$out" 'POLICY_NAME=' "POLICY_NAME is dropped"
assert_not_contains "$out" 'LOG_DEBUG_PATH=' "LOG_DEBUG_PATH is dropped"
# The preview is what ends up in nfqws2.conf, which the module sources after
# lib/common.sh has defined these variables — so the reference form is correct
# here, unlike in norm_args() where the real path must reach the binary.
assert_contains "$out" '@$LUA_DIR/zapret-lib.lua' "lua path becomes a \$LUA_DIR reference"
assert_not_contains "$out" '/opt/etc/nfqws2' "no /opt paths survive"
assert_contains "$out" 'AUTOSTART=' "keys the import lacks are filled in from the device conf"
assert_eq "1" "$(printf '%s\n' "$out" | grep -c '^PKT_LIMIT_OUT=')" \
  "keys the import defines are not duplicated in the appended section"

# ── rotate_file ───────────────────────────────────────────────────────────────
section "rotate_file"

big="$SANDBOX/big.log"
awk 'BEGIN{for(i=0;i<200;i++) print "0123456789"}' > "$big"
before=$(wc -c < "$big" | tr -d ' ')
rotate_file "$big" 500
after=$(wc -c < "$big" | tr -d ' ')
assert_ge "$before" 2000 "the fixture really is over the limit"
if [ "$after" -lt "$before" ]; then _ok "oversized file is truncated"; else _fail "oversized file was not truncated"; fi
if [ "$after" -le 500 ]; then _ok "result fits the limit"; else _fail "result is still $after bytes"; fi

small="$SANDBOX/small.log"
printf 'tiny\n' > "$small"
rotate_file "$small" 500
assert_eq "tiny" "$(cat "$small")" "small file is left alone"

# ── sync_lists_and_blobs ──────────────────────────────────────────────────────
section "sync_lists_and_blobs: restoring a missing list"

# A list deleted from the config directory comes back from the module's copy;
# an existing one, edited by the user, is never overwritten.
rm -f "$LISTS_DIR/exclude.list"
printf 'mine\n' > "$LISTS_DIR/youtube.list"
sync_lists_and_blobs >/dev/null 2>&1
assert_file "$LISTS_DIR/exclude.list" "missing list file is recreated"
assert_eq "$(cat "$MODDIR/lists/exclude.list")" "$(cat "$LISTS_DIR/exclude.list" 2>/dev/null)" \
  "a missing list is copied from the module"
assert_eq "mine" "$(cat "$LISTS_DIR/youtube.list")" "an existing list is left alone"

rm -rf "$LISTS_DIR"
sync_lists_and_blobs >/dev/null 2>&1
assert_file "$LISTS_DIR/user.list" "a removed lists directory is recreated and filled"

# ── setup_cli_symlinks ────────────────────────────────────────────────────────
section "setup_cli_symlinks"

setup_cli_symlinks
assert_rc 0 $? "setup_cli_symlinks succeeds silently when APatch/KSU paths are absent"

# ── Phase 3 features ──────────────────────────────────────────────────────────
section "get_strategy_packet_limits"

test_strat="$SANDBOX/test_limits.conf"
cat << 'EOF' > "$test_strat"
# NFQWS2_TCP_PKT_OUT=24
# NFQWS2_TCP_PKT_IN=11
# NFQWS2_UDP_PKT_OUT=32
# NFQWS2_UDP_PKT_IN=16
EOF
assert_eq "24 11 32 16" "$(get_strategy_packet_limits "$test_strat")" "reads per-strategy packet limits"
: > "$test_strat"
assert_eq "$PKT_LIMIT_OUT $PKT_LIMIT_IN $PKT_LIMIT_OUT $PKT_LIMIT_IN" "$(get_strategy_packet_limits "$test_strat")" "falls back to global limits"

section "collect_capture_ports"

sample_args="--filter-tcp=443,80,1984,8443 --filter-udp=443,590-600,1400"
assert_eq "80,443,1984,8443" "$(collect_capture_ports tcp "$sample_args")" "extracts sorted TCP ports"
assert_eq "443,590:600,1400" "$(collect_capture_ports udp "$sample_args")" "extracts and normalizes UDP ports"

section "validate_strategy_blob_references"

assert_rc 0 "$(validate_strategy_blob_references "$MODDIR/defaults/nfqws2.conf" >/dev/null 2>&1; echo $?)" "default config blob references are valid"
bad_conf="$SANDBOX/bad_blob.conf"
echo 'NFQWS_BASE_ARGS="--blob=test:@$BLOBS_DIR/nonexistent_blob_xyz.bin"' > "$bad_conf"
assert_rc 1 "$(validate_strategy_blob_references "$bad_conf" >/dev/null 2>&1; echo $?)" "detects missing blob reference"

section "heal_blob self-healing"
test_heal_blob="$SANDBOX/blobs_test/zero_256.bin"
rm -f "$test_heal_blob"
assert_rc 0 "$(heal_blob "$test_heal_blob" >/dev/null 2>&1; echo $?)" "heal_blob restores zero_256.bin"
assert_file "$test_heal_blob" "healed zero_256.bin file exists"
assert_eq "256" "$(wc -c < "$test_heal_blob" | tr -d ' ')" "healed zero_256.bin is 256 bytes"

test_bad_blob="$SANDBOX/blobs_test/unknown_invalid_blob.bin"
assert_rc 1 "$(heal_blob "$test_bad_blob" >/dev/null 2>&1; echo $?)" "heal_blob returns 1 for non-standard blob"

section "generate_strategy_receipt and verify_strategy_receipt"

r1=$(generate_strategy_receipt "$MODDIR/defaults/nfqws2.conf")
assert_match "$r1" '^[0-9a-f]{64}$' "generates 64-char sha256 receipt"
save_strategy_receipt "$MODDIR/defaults/nfqws2.conf"
assert_file "$RECEIPT_FILE" "receipt file is created"
if verify_strategy_receipt "$MODDIR/defaults/nfqws2.conf"; then
  _ok "verify_strategy_receipt verifies matching receipt"
else
  _fail "verify_strategy_receipt failed on matching receipt"
fi

section "verify_strategy_receipt detects lua script modification"

receipt_conf="$SANDBOX/receipt_lua.conf"
lua_test="$SANDBOX/test_receipt.lua"
echo 'local x = 1' > "$lua_test"
echo "NFQWS_BASE_ARGS=\"--lua-init=@$lua_test\"" > "$receipt_conf"
save_strategy_receipt "$receipt_conf"
assert_file "$RECEIPT_FILE" "receipt file created"
if verify_strategy_receipt "$receipt_conf"; then
  _ok "verify_strategy_receipt passes before lua modification"
else
  _fail "verify_strategy_receipt failed before lua modification"
fi
echo 'local x = 2 -- modified' > "$lua_test"
if verify_strategy_receipt "$receipt_conf"; then
  _fail "verify_strategy_receipt should fail after lua modification"
else
  _ok "verify_strategy_receipt detects modified lua script"
fi

section "resolve_googlevideo_cdn"

# 1. Test fallback when no network and no cache
rm -f "$GOOGLEVIDEO_CACHE_FILE" "$LISTS_DIR/googlevideo.list"
res1=$(resolve_googlevideo_cdn force)
assert_contains "$res1" "googlevideo.com" "resolves fallback googlevideo domain"
assert_file "$GOOGLEVIDEO_CACHE_FILE" "creates googlevideo cache file"

# 2. Test reading from cache
printf 'rr2---sn-custom-cache.googlevideo.com\n' > "$GOOGLEVIDEO_CACHE_FILE"
res2=$(resolve_googlevideo_cdn)
assert_eq "rr2---sn-custom-cache.googlevideo.com" "$res2" "reads from cache when present"

# 3. Test list fallback
rm -f "$GOOGLEVIDEO_CACHE_FILE"
printf 'rr3---sn-from-list.googlevideo.com\n' > "$LISTS_DIR/googlevideo.list"
res3=$(resolve_googlevideo_cdn force)
assert_eq "rr3---sn-from-list.googlevideo.com" "$res3" "falls back to googlevideo.list"
rm -f "$LISTS_DIR/googlevideo.list" "$GOOGLEVIDEO_CACHE_FILE"

section "batch generation does not mutate installed chains"
iptables -w -t mangle -N nfqws_batch
iptables -w -t mangle -A nfqws_batch -j RETURN
FW_PROBE_CMD=iptables
FW_BATCH_BUF=""
_fw_batch_cmd -w -t mangle -N nfqws_batch
_fw_batch_cmd -w -t mangle -F nfqws_batch
_fw_batch_cmd -w -t mangle -A nfqws_batch -j NFQUEUE --queue-num 300 --queue-bypass
_fw_batch_cmd -w -t mangle -I FORWARD 1 -j nfqws_batch
assert_eq '-j RETURN' "$(ipt_rules nfqws_batch)" "building a batch leaves the live chain intact"
assert_not_contains "$(ipt_rules FORWARD)" 'nfqws_batch' "building a batch does not attach a live hook"
assert_contains "$FW_BATCH_BUF" 'mangle|-A nfqws_batch -j NFQUEUE' "NFQUEUE rule is buffered"
FW_PROBE_CMD=""
FW_BATCH_BUF=""

section "restore mock commits or rolls back a table"
restore_input="$SANDBOX/restore.input"
printf '*mangle\n:nfqws_batch - [0:0]\n-A nfqws_batch -j NFQUEUE --queue-num 300 --queue-bypass\nCOMMIT\n' > "$restore_input"
MOCK_IPT_FEATURES=owner iptables-restore --noflush < "$restore_input" >/dev/null 2>&1
assert_rc 1 $? "an unsupported rule rejects the restore transaction"
assert_eq '-j RETURN' "$(ipt_rules nfqws_batch)" "a failed restore preserves the old rules"
iptables -w -t mangle -N unrelated_test
iptables -w -t mangle -A unrelated_test -j RETURN
iptables-restore --noflush < "$restore_input"
assert_rc 0 $? "a supported restore transaction commits"
assert_contains "$(ipt_rules nfqws_batch)" 'NFQUEUE' "restored chain contains the new rule"
assert_not_contains "$(ipt_rules nfqws_batch)" '-j RETURN' "a declared chain replaces its old rules"
assert_eq '-j RETURN' "$(ipt_rules unrelated_test)" "noflush preserves unrelated chains"
printf '*mangle\n-F nfqws_batch\n-X nfqws_batch\nCOMMIT\n' > "$restore_input"
iptables-restore --noflush < "$restore_input"
assert_rc 0 $? "batch teardown accepts flush and delete operations"
assert_no_file "$MOCK_IPT_STORE/iptables/mangle/nfqws_batch" "batch teardown removes its chain"
assert_eq '-j RETURN' "$(ipt_rules unrelated_test)" "batch teardown leaves unrelated rules intact"

section "update_description root manager state display"
prop_test="$SANDBOX/module.prop"
cat > "$prop_test" <<'EOF'
id=nfqws2-android
name=nfqws2 for Android
version=v2.0.3
versionCode=2030
author=deathwatcher
description=Initial Description
EOF

old_moddir="$MODDIR"
MODDIR="$SANDBOX"

# 1. ready state
update_description ready
assert_eq 'status: ready 🚀' "$(sed -n 's/^description=//p' "$prop_test")" "update_description ready writes ready emoji"

# 2. running state with default strategy
rm -f "$ACTIVE_FILE"
update_description running
assert_eq 'status: active ✅ | strategy: default 🎯 | mode: auto 🌐' "$(sed -n 's/^description=//p' "$prop_test")" "update_description running with default strategy"

# 3. running state with custom strategy
echo "alt4" > "$ACTIVE_FILE"
update_description running
assert_eq 'status: active ✅ | strategy: alt4 🎯 | mode: auto 🌐' "$(sed -n 's/^description=//p' "$prop_test")" "update_description running with alt4 strategy"

# 4. running state with smart mode (brain emoji)
echo "smart" > "$ACTIVE_FILE"
update_description running
assert_eq 'status: active ✅ | strategy: smart 🧠 | mode: auto 🌐' "$(sed -n 's/^description=//p' "$prop_test")" "update_description running with smart strategy shows brain emoji"

# 5. paused states
update_description paused "@vpn"
assert_eq 'status: paused ⏸️ | VPN 🛡️' "$(sed -n 's/^description=//p' "$prop_test")" "update_description paused @vpn"

update_description paused "@wl"
assert_eq 'status: paused ⏸️ | Whitelist ⚪' "$(sed -n 's/^description=//p' "$prop_test")" "update_description paused @wl"

update_description paused "CoffeeShop_5G"
assert_eq 'status: paused ⏸️ | Wi-Fi: CoffeeShop_5G 📶' "$(sed -n 's/^description=//p' "$prop_test")" "update_description paused with SSID"

# 6. failed state with sanitized reason
update_description failed "Error: iptables rules failed to apply."
assert_eq 'status: failed ❌ | iptables rules failed to apply.' "$(sed -n 's/^description=//p' "$prop_test")" "update_description failed strips Error prefix"

# 7. disabled state
update_description disabled
assert_eq 'status: disabled ❌' "$(sed -n 's/^description=//p' "$prop_test")" "update_description disabled"

# 8. stopped state
update_description stopped
assert_eq 'status: stopped ⛔' "$(sed -n 's/^description=//p' "$prop_test")" "update_description stopped"

# 9. flash wear protection (no disk write when description unchanged)
echo "marker" >> "$prop_test"
update_description stopped
assert_contains "$(cat "$prop_test")" "marker" "update_description skips rewriting when description matches"
sed -i '/marker/d' "$prop_test"

# 10. other fields in module.prop preserved
assert_eq 'nfqws2-android' "$(sed -n 's/^id=//p' "$prop_test")" "module.prop id is preserved"
assert_eq 'v2.0.3' "$(sed -n 's/^version=//p' "$prop_test")" "module.prop version is preserved"

MODDIR="$old_moddir"

harness_finish

