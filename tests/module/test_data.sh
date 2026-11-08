#!/bin/sh
# Data-integrity tests: the shipped configs, lists, blobs and metadata must stay
# mutually consistent. These need no sandbox and no Android tools — they only
# read the repository, so they are cheap and run first.

HERE=$(cd "$(dirname "$0")" && pwd)
TESTS_DIR=$(cd "$HERE/.." && pwd)
REPO_DIR=$(cd "$TESTS_DIR/.." && pwd)
. "$TESTS_DIR/lib/harness.sh"

# ── shell syntax ──────────────────────────────────────────────────────────────
section "shell syntax"

SCRIPTS="action.sh boot-completed.sh customize.sh post-fs-data.sh service.sh uninstall.sh bin/nfqws2-ctl system/bin/nfqws2-ctl system/bin/zapret2-start system/bin/zapret2-stop system/bin/zapret2-restart system/bin/zapret2-status system/bin/zapret2-rollback system/bin/zapret2-bench lib/common.sh"
for f in $SCRIPTS; do
  sh -n "$REPO_DIR/$f" 2>/dev/null
  assert_rc 0 $? "$f parses under sh"
done
for f in $SCRIPTS; do
  dash -n "$REPO_DIR/$f" 2>/dev/null
  assert_rc 0 $? "$f parses under dash"
done

# ── lua syntax ────────────────────────────────────────────────────────────────
section "lua syntax"

lua_files=$(cd "$REPO_DIR" && ls lua/*.lua 2>/dev/null)
lua_count=0
for f in $lua_files; do
  lua_count=$((lua_count + 1))
done
assert_ge "$lua_count" 21 "all 21+ lua modules are present ($lua_count found)"

if command -v luac >/dev/null 2>&1; then
  for f in "$REPO_DIR"/lua/*.lua; do
    luac -p "$f" >/dev/null 2>&1
    assert_rc 0 $? "${f##*/} parses under luac"
  done
else
  _ok "luac not available on host, skipping luac -p (runs in CI)"
fi

section "line endings"

# Android's sh reads a CRLF script as garbage ("\r: not found" on every line).
# The check covers every shipped text file, not just the scripts: an editor on
# Windows will happily save index.html or a config as CRLF too, and the repo
# pins LF.
TEXT_FILES="$SCRIPTS module.prop LICENSE README.md webroot/index.html webroot/config.json"
TEXT_FILES="$TEXT_FILES $(cd "$REPO_DIR" && ls lists/*.list defaults/lists/*.list defaults/*.conf \
                                            strategies/*.conf lua/*.lua strategy-catalogs/*.list 2>/dev/null)"

# Both checks run in one pass over the whole set, not one process per file. That
# is not a micro-optimisation: on Windows/Git Bash a single process spawn costs
# about 0.3 s, and the per-file loops here (72 files x up to five commands each)
# were spending over a minute on their own.
files=""; nonempty=""
for f in $TEXT_FILES; do
  p="$REPO_DIR/$f"
  [ -f "$p" ] || continue
  files="$files $p"
  [ -s "$p" ] && nonempty="$nonempty $p"
done
nfiles=$(printf '%s' "$files" | wc -w | tr -d ' ')

# Counting CRs with od, not grep or awk. Both of those open files in text mode
# here, and the CR is gone before the pattern is applied — that is how this check
# passed for as long as it did without ever looking at a real CR (T1 in the
# 2026-10-05 review). od reads binary. Verified against a file that really has
# CRLF. One `cat | od | grep` covers every file; the per-file pass runs only when
# something was found, and that is when naming the offenders matters.
crlf=""
if [ "$(cat $files | od -An -c | grep -c '\\r')" != "0" ]; then
  for f in $files; do
    [ "$(od -An -c "$f" | grep -c '\\r')" = "0" ] || crlf="$crlf ${f#"$REPO_DIR/"}"
  done
fi
assert_eq "" "$(printf '%s' "$crlf" | sed 's/^ *//')" \
  "every text file is LF-only ($nfiles files checked)"

# POSIX text files end with a newline. Without one, anything appended to the file
# lands on the last line: `echo x >> conf` would produce `LOG_LEVEL=0x`. 26 of
# the shipped files were missing it — every strategy but two, and config.json.
#
# `tail -c 1` over several files prints its own `==> name <==` headers, so one
# call covers the set: a non-empty line right after a header means that file does
# not end with a newline. Empty files are skipped — they have no last byte.
no_final_nl=$(tail -c 1 $nonempty 2>/dev/null | awk '
  /^==> /{ f=$2; next }
  { if (f != "" && length($0) > 0) print f; f="" }' \
  | sed "s#$REPO_DIR/##g" | tr '\n' ' ')
assert_eq "" "$(printf '%s' "$no_final_nl" | sed 's/^ *//; s/ *$//')" \
  "every text file ends with a newline ($nfiles files checked)"

# ── module.prop ───────────────────────────────────────────────────────────────
section "module.prop"

PROP="$REPO_DIR/module.prop"
for key in id name version versionCode author description; do
  assert_match "$(cat "$PROP")" "^$key=" "module.prop declares $key"
done
assert_match "$(sed -n 's/^version=//p' "$PROP")" '^v[0-9]+\.[0-9]+\.[0-9]+$' "version looks like vX.Y.Z"
assert_match "$(sed -n 's/^versionCode=//p' "$PROP")" '^[0-9]+$' "versionCode is numeric"
assert_eq "$(sed -n 's/^id=//p' "$PROP")" "nfqws2-android" "id matches the module directory name"

# ── configs ───────────────────────────────────────────────────────────────────
section "shipped configs"

assert_file "$REPO_DIR/defaults/nfqws2.conf" "defaults/nfqws2.conf exists"

for f in "$REPO_DIR"/defaults/nfqws2.conf "$REPO_DIR"/strategies/*.conf; do
  b="${f##*/}"
  out=$(awk '/`/ { print "backtick" } /\$\(/ { print "cmdsubst" }' "$f")
  if [ -z "$out" ]; then _ok "$b has no backticks or command substitution"
  else _fail "$b contains forbidden syntax: $out"; fi
done

# ── shipped presets stay runnable ─────────────────────────────────────────────
section "shipped presets stay runnable"

# fake without a blob raises 'blob' arg required, which aborts the whole Lua
# chain for that packet: such an instance never desynchronises anything
bad_fake=$(grep -hv '^[[:space:]]*#' "$REPO_DIR/defaults/nfqws2.conf" "$REPO_DIR"/strategies/*.conf |
  grep -o -- '--lua-desync=fake:[^ ]*' | grep -v 'blob=' || true)
assert_eq "" "$bad_fake" "every fake instance names a blob"

# fool=<name> is looked up with _G[], so an unknown name throws in apply_fooling
fool_list=$(grep -hov -- 'fool=[A-Za-z0-9_]*' "$REPO_DIR/defaults/nfqws2.conf" "$REPO_DIR"/strategies/*.conf |
  sed 's/^fool=//' | sort -u)
fn_list=$(grep -ho '^function [A-Za-z0-9_]*' "$REPO_DIR"/lua/*.lua | sed 's/^function //' | sort -u)
missing_fool=$(printf '%s\n' "$fool_list" | while IFS= read -r n; do
  [ -n "$n" ] || continue
  printf '%s\n' "$fn_list" | grep -qx "$n" || printf '%s ' "$n"
done)
assert_eq "" "$missing_fool" "every fool= names a defined Lua function"

# Helpers that insert bytes in front of the request change the payload length
# without moving the socket's sequence numbers, so a keep-alive stream
# desynchronises once the server acknowledges the inserted bytes.
shifting=$(grep -hE -- 'http_(garbage_prefix|pipeline_fake|pipeline_fake_v2|header_shuffle|methodeol_safe|multi_crlf|mixed_prefix|xpadding|simple_bypass|fake_continuation|fake_xhost|inject_safe_header|oob_prefix|space_prefix|lf_prefix|tab_prefix|absolute_url)' \
  "$REPO_DIR"/strategy-catalogs/*.list 2>/dev/null || true)
assert_eq "" "$shifting" "the catalog ships no payload-shifting HTTP helpers"

assert_no_file "$REPO_DIR/lua/silent-drop-detector.lua" \
  "the never-loaded silent-drop detector is gone"

# ── strategy references ───────────────────────────────────────────────────────
section "strategy references resolve"

# One grep over every file rather than a grep+sed+sort per file: -H makes it print
# the file name itself. The per-file version spent about 170 process spawns here,
# which is a minute of wall clock on Windows for what is a handful of matches.
missing_blobs=0
missing_lists=0
seen_b=""
for r in $(grep -Ho '\$BLOBS_DIR/[A-Za-z0-9_.-]*' \
             "$REPO_DIR"/defaults/nfqws2.conf "$REPO_DIR"/strategies/*.conf 2>/dev/null); do
  f=${r%%:*}; b=${r#*:}; b=${b#\$BLOBS_DIR/}
  case " $seen_b " in *" $b "*) continue ;; esac
  seen_b="$seen_b $b"
  [ -f "$REPO_DIR/blobs/$b" ] && continue
  missing_blobs=$((missing_blobs + 1))
  _fail "${f##*/} references missing blob $b"
done

seen_l=""
for r in $(grep -Ho '\$LISTS_DIR/[A-Za-z0-9_.-]*' \
             "$REPO_DIR"/defaults/nfqws2.conf "$REPO_DIR"/strategies/*.conf 2>/dev/null); do
  f=${r%%:*}; l=${r#*:}; l=${l#\$LISTS_DIR/}
  case " $seen_l " in *" $l "*) continue ;; esac
  seen_l="$seen_l $l"
  [ -f "$REPO_DIR/lists/$l" ] || [ -f "$REPO_DIR/defaults/lists/$l" ] || {
    missing_lists=$((missing_lists + 1))
    _fail "${f##*/} references missing list $l"
  }
done
[ "$missing_blobs" = 0 ] && _ok "every referenced blob exists directly in blobs/"
[ "$missing_lists" = 0 ] && _ok "every referenced list exists"

# ── rewriting keenetic paths has one definition ────────────────────────────────
section "keenetic path rewriting"

# The rewrite rule used to be copy-pasted three times (norm_args, set_strategy,
# render_import_merged) and drifted by quoting: two copies expanded the
# variables, one wrote the reference. Keep it to one place.
assert_eq "1" "$(grep -c '^rewrite_keenetic_paths()' "$REPO_DIR/lib/common.sh")" \
  "rewrite_keenetic_paths is defined exactly once"
assert_eq "0" "$(grep -c 'opt/etc/nfqws2' "$REPO_DIR/bin/nfqws2-ctl")" \
  "the ctl has no private copy of the rewrite rule"
assert_ge "$(grep -c 'rewrite_keenetic_paths' "$REPO_DIR/lib/common.sh")" 1 \
  "the library calls the shared function"
assert_eq "refs" "$(grep -o 'rewrite_keenetic_paths refs' "$REPO_DIR/lib/common.sh" | sed 's/.* //')" \
  "the config preview asks for the reference form explicitly"
assert_contains "$(cat "$REPO_DIR/lib/common.sh")" \
  's#/opt/etc/nfqws2/lua#$LUA_DIR#g' "the lua rule still precedes the generic /opt/etc/nfqws2 rule"

# Paths and directories belong to lib/common.sh; the ctl sources it and must not
# restate the same values (they used to drift silently when one side changed).
for v in STRATEGIES_DIR USER_STRATEGIES_DIR; do
  assert_eq "1" "$(grep -c "^$v=" "$REPO_DIR/lib/common.sh")" "$v is defined in lib/common.sh"
  assert_eq "0" "$(grep -c "^$v=" "$REPO_DIR/bin/nfqws2-ctl")" "the ctl does not redeclare $v"
done

# ── config keys are actually read ─────────────────────────────────────────────
section "config keys are read"

# A key nothing reads is a lie in the config file: it looks like a setting and
# changes nothing. SAFE_START and CONFIG_VERSION both sat in all 28 configs that
# way — no version of the code ever read either (`git log -S <key> -- lib bin
# service.sh` is empty for both) — so both were removed. This keeps the next one
# from appearing.
#
# A key counts as read if the code expands it *or* a config does: strategies
# compose their own helpers, e.g. MartinBacker builds $ARGS_BLOCK16 and uses it
# twice in the same file, and defaults/nfqws2.conf composes $MODE_AUTO.
cfg_files=$(ls "$REPO_DIR"/defaults/nfqws2.conf "$REPO_DIR"/strategies/*.conf 2>/dev/null)
cfg_keys=$(grep -hoE '^[A-Z_][A-Z0-9_]*=' $cfg_files 2>/dev/null | tr -d '=' | sort -u)
unread=""
for k in $cfg_keys; do
  if ! grep -qE "\\\$$k\\b|\\\$\{$k[:=}]" \
        "$REPO_DIR/lib/common.sh" "$REPO_DIR/bin/nfqws2-ctl" "$REPO_DIR/service.sh" \
        $cfg_files 2>/dev/null; then
    unread="$unread $k"
  fi
done
assert_eq "" "$(printf '%s' "$unread" | sed 's/^ *//')" \
  "every config key is read somewhere ($(printf '%s' "$cfg_keys" | wc -w | tr -d ' ') keys checked)"

# ── the wake lock name is pinned to the module id ─────────────────────────────
section "wake lock name matches the module id"

# Acquiring, releasing and the doctor's check all write and read one string in
# /sys/power/wake_lock. If they ever disagree the lock is never released, and a
# named wake lock in the kernel is not tied to a process: the phone would not
# sleep until reboot. So the name is module.prop's id, and nothing else.
mod_id=$(sed -n 's/^id=//p' "$REPO_DIR/module.prop")
assert_eq "nfqws2-android" "$mod_id" "module.prop declares the expected id"
assert_eq "2" "$(grep -c "\"$mod_id\"" "$REPO_DIR/lib/common.sh")" \
  "acquire_wakelock and release_wakelock both use the module id"
assert_eq "1" "$(grep -c "\"$mod_id\"" "$REPO_DIR/bin/nfqws2-ctl")" \
  "the doctor checks the same name"
assert_eq "1" "$(grep -c "echo $mod_id " "$REPO_DIR/uninstall.sh")" \
  "uninstall releases the same name"

# The legacy lock name must never come back: nothing would release it.
assert_eq "0" "$(grep -rl "nfqws2-magisk" "$REPO_DIR/bin" "$REPO_DIR/lib" "$REPO_DIR/service.sh" "$REPO_DIR/uninstall.sh" "$REPO_DIR/webroot" 2>/dev/null | wc -l | tr -d ' ')" \
  "nothing refers to the legacy name"

# ── uninstall.sh ──────────────────────────────────────────────────────────────
section "uninstall"

# uninstall.sh is deliberately not executed by the suite: it calls kill, and the
# harness stubs iptables/rm/nfqws2 but not kill, so a real pid in the sandbox
# pidfile would take down a real process. These are static checks instead.
#
# `kill "$(cat pidfile)"` becomes `kill ""` when the file is gone — the error is
# suppressed, but the intent is invisible. The pid has to be read and checked.
assert_eq "0" "$(grep -c 'kill "\$(cat' "$REPO_DIR/uninstall.sh")" \
  "uninstall does not kill a pid it has not checked"
assert_contains "$(cat "$REPO_DIR/uninstall.sh")" '[ -n "$wpid" ]' \
  "uninstall checks the watchdog pid before killing it"
assert_contains "$(cat "$REPO_DIR/uninstall.sh")" 'rm -rf /data/adb/nfqws2/state' \
  "uninstall still clears the state directory"

# ── no A && B || C in the library ─────────────────────────────────────────────
section "conditional chains"

# `A && B || C` runs C when B fails, which is almost never what was meant: the
# two sites that had it would have created an empty user_extra.list instead of a
# copy, and rotated a log instead of truncating it. In bin/nfqws2-ctl the same
# shape is the doctor's `row ok … || row fail …` idiom, where the middle command
# is a printf that cannot fail, so the check covers the library only.
# Comments are skipped: the fixes document the pattern they removed, quoting it.
assert_eq "0" "$(grep -v '^[[:space:]]*#' "$REPO_DIR/lib/common.sh" | grep -c '&& .*|| ')" \
  "lib/common.sh has no A && B || C chains outside comments"

# ── the two lists of lists differ only by auto ────────────────────────────────
section "install and reset cover the same lists, minus auto"

# customize.sh seeds all six at install time; reset-lists restores five and
# deliberately leaves auto.list alone, because that one is learned and clearing
# it would throw away what nfqws2 taught itself. The difference is the point, so
# it is pinned here — a name added to one list and forgotten in the other would
# otherwise go unnoticed, and the two live in different files that share no code
# (customize.sh does not source lib/common.sh).
# Two things this has to survive. [^;]* rather than .*: the reset branch ends with
# `; done`, and a greedy .* stops at the `; do` inside it, swallowing the loop
# body. And the newline: the branch is a multi-line block now, so the ctl is
# flattened first — a line-based sed would simply find nothing and the guard would
# report every name as missing.
install_list=$(ls "$REPO_DIR/defaults/lists" 2>/dev/null | sed 's/\.list$//')
reset_list=$(tr '\n' ' ' < "$REPO_DIR/bin/nfqws2-ctl" \
             | sed -n 's/.*reset-lists) *for f in \([^;]*\); do.*/\1/p')

# Exact tokens, not substrings: "ipset" is a prefix of "ipset_exclude".
list_has() { printf '%s\n' "$1" | tr ' ' '\n' | grep -qx "$2"; }
if list_has "$install_list" auto; then _ok "install seeds auto.list"; else _fail "install does not seed auto.list"; fi
if list_has "$reset_list" auto; then _fail "reset-lists touches the learned list"; else _ok "reset-lists leaves auto.list alone"; fi
for n in $install_list; do
  [ "$n" = "auto" ] && continue
  if list_has "$reset_list" "$n"; then _ok "reset-lists restores $n"; else _fail "reset-lists misses $n"; fi
done
for n in $reset_list; do
  if list_has "$install_list" "$n"; then _ok "install seeds $n"; else _fail "install misses $n"; fi
done

# ── lists vs defaults/lists ───────────────────────────────────────────────────
section "lists/ and defaults/lists/ agree"

# These two copies drifted apart once already (commit af8101b): customize.sh
# installs from lists/, while reset-lists restores from defaults/lists/, so a
# stale copy in either place makes "fresh install" and "reset lists" produce
# different results — silently re-adding entries one of them had dropped.
list_lines() { grep -cv -e '^[[:space:]]*$' -e '^[[:space:]]*#' "$1" 2>/dev/null || echo 0; }

for f in "$REPO_DIR"/defaults/lists/*.list; do
  b="${f##*/}"
  if [ ! -f "$REPO_DIR/lists/$b" ]; then
    _fail "lists/$b is missing while defaults/lists/$b exists"
    continue
  fi
  if cmp -s "$f" "$REPO_DIR/lists/$b"; then
    _ok "lists/$b matches defaults/lists/$b"
  else
    _fail "lists/$b differs from defaults/lists/$b ($(list_lines "$REPO_DIR/lists/$b") vs $(list_lines "$f") entries)"
  fi
done

section "lists are sane"

# The CR check that used to sit here is gone: it was the same broken grep as
# above, and the line-endings section already covers every list. What is left is
# the part that is specific to lists — ipset entries are "1.2.3.0/24" style and
# exclude lists may carry comments, so an entry with inner whitespace is the
# thing to catch.
malformed=""
for f in "$REPO_DIR"/lists/*.list; do
  b="${f##*/}"
  bad=$(grep -nE '^[^#]*[[:space:]]+[^[:space:]]' "$f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*$' | head -1)
  [ -n "$bad" ] && malformed="$malformed lists/$b"
done
assert_eq "" "$(printf '%s' "$malformed" | sed 's/^ *//')" "every list entry is a bare token"

# ── installer ─────────────────────────────────────────────────────────────────
section "installer covers the shipped binaries"

# binaries/ is built by CI, not committed; the files themselves are checked
# when present, the customize.sh ABI mapping always. customize.sh maps the
# manager-provided $ARCH (Magisk/KernelSU/APatch API), so run its real case
# block against each value instead of grepping for patterns.
abi_case=$(sed -n '/^case "$ARCH" in/,/^esac/p' "$REPO_DIR/customize.sh")
[ -n "$abi_case" ] || abi_case='echo BAD'
for pair in "arm64 android-arm64" "arm android-arm" "x86_64 android-x86_64" "x86 android-x86"; do
  set -- $pair
  got=$(BIN=; ARCH=$1; eval "$abi_case"; printf '%s' "${BIN:-none}")
  assert_eq "$2" "$got" "customize.sh maps ARCH $1 to $2"
done
got=$(BIN=; ARCH=mips; eval "$abi_case" >/dev/null 2>&1; printf '%s' "${BIN:-unset}")
assert_eq "unset" "$got" "customize.sh rejects an unknown ARCH"
for b in android-arm android-arm64 android-x86 android-x86_64; do
  [ -d "$REPO_DIR/binaries" ] && assert_file "$REPO_DIR/binaries/$b/nfqws2" "binaries/$b/nfqws2 exists"
done

section "installer wires up the runtime"

assert_contains "$(cat "$REPO_DIR/customize.sh")" 'cp -f "$MODPATH/binaries/$BIN/nfqws2" "$MODPATH/bin/nfqws2"' \
  "customize.sh installs the picked binary as bin/nfqws2"
for f in user exclude ipset ipset_exclude auto probe_hosts; do
  assert_contains "$(cat "$REPO_DIR/customize.sh")" "$f" "customize.sh seeds $f.list"
done

# These two steps fail loudly instead of letting the install report success on a
# device where /data/adb is not writable. The rest of the installer is
# self-healing — load_conf recreates a missing config and the lists — but nothing
# recreates a directory it cannot write to.
assert_contains "$(cat "$REPO_DIR/customize.sh")" \
  'mkdir -p "$CONF/lists" "$CONF/state" "$CONF/logs" "$CONF/imports" "$CONF/strategies"' \
  "customize.sh creates the config tree"
# Flattened first: the continuation sits on the next line, and grep matches within
# a line. Same trap as the reset-lists guard above.
installer_flat=$(tr '\n' ' ' < "$REPO_DIR/customize.sh" | tr -s ' ')
assert_match "$installer_flat" \
  'mkdir -p "\$CONF/lists".*\|\| abort' \
  "and aborts when the config tree cannot be created"
# `.*` rather than a literal separator: flattening the file leaves the backslash of
# the line continuation in place, so the two are not adjacent.
assert_match "$installer_flat" \
  'cp -f "\$MODPATH/defaults/nfqws2.conf" "\$CONF/nfqws2.conf".*\|\| abort' \
  "and aborts when the config cannot be written"

section "service entry points the WebUI relies on"

for cmd in start autostart stop restart reload status firewall_apply firewall_stop ensure_watchdog; do
  assert_contains "$(cat "$REPO_DIR/service.sh")" "$cmd)" "service.sh handles $cmd"
done

harness_finish
