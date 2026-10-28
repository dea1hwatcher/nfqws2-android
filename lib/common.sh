#!/system/bin/sh
[ -n "$MODDIR" ] || { echo "MODDIR is not set" >&2; return 1 2>/dev/null || exit 1; }

: "${CONFDIR:=/data/adb/nfqws2}"
CONFFILE="$CONFDIR/nfqws2.conf"
LISTS_DIR="$CONFDIR/lists"
STATE_DIR="$CONFDIR/state"
LOG_DIR="$CONFDIR/logs"
STRATEGIES_DIR="$MODDIR/strategies"
USER_STRATEGIES_DIR="$CONFDIR/strategies"
IMPORTS_DIR="$CONFDIR/imports"

LUA_DIR="$MODDIR/lua"
BLOBS_DIR="$MODDIR/blobs"
NFQWS_BIN="$MODDIR/bin/nfqws2"

PIDFILE="$STATE_DIR/nfqws2.pid"
WD_PIDFILE="$STATE_DIR/watchdog.pid"
WN_PIDFILE="$STATE_DIR/netwatch.pid"
WL_PIDFILE="$STATE_DIR/wlwatch.pid"
WL_FILE="$STATE_DIR/whitelist"                  # carrier whitelisting active timestamp
DESIRED_FILE="$STATE_DIR/desired"
ARGS_FILE="$STATE_DIR/last.args"
APP_UIDS_FILE="$STATE_DIR/app_uids"
SERVICE_LOG="$LOG_DIR/service.log"
NFQWS_LOG="$LOG_DIR/nfqws2.log"
ACTIVE_FILE="$STATE_DIR/active_strategy"
LAST_STRATEGY_FILE="$STATE_DIR/last_strategy"   # last non-smart strategy
FIRST_STRATEGY=hardcorp74                       # default initial strategy

# Release-shipped lists; .pending = newer version kept aside due to user edits
LISTS_PENDING_DIR="$LISTS_DIR/.pending"

# Home Wi-Fi: bypass pauses on these networks (HOME_WIFI=1)
HOME_FILE="$CONFDIR/home_wifi.list"
HOME_PAUSED_FILE="$STATE_DIR/home_paused"      # paused by home network; holds SSID
HOME_OVERRIDE_FILE="$STATE_DIR/home_override"  # user re-enabled on this network
SMART_DIR="$CONFDIR/smart"                     # умный режим: выученное по сетям (<сеть>.tsv)
SMART_NET_FILE="$STATE_DIR/smart_net"          # id текущей сети для умного режима или offline
SMART_LEARN_FILE="$STATE_DIR/smart_learn"      # background learning state
SMART_LEARN_EVERY=120                          # seconds between learning attempts
SMART_TURBO_FILE="$STATE_DIR/smart_turbo"      # fast learning expiration
SMART_TURBO_EVERY=15
SK_PIDFILE="$STATE_DIR/smartkill.pid"          # обрыв застрявших соединений умного режима
SMART_KILL_FILE="$STATE_DIR/smart_kill"        # их пишет оркестратор: «4|6 адрес локальный-порт»

# VPN pause: bypass pauses while a VPN interface is active (VPN_PAUSE=1);
# the reason is recorded as @vpn inside HOME_PAUSED_FILE

MARK_EXCLUDE="0x20000000/0x20000000"
MARK_INCLUDE="0x10000000/0x10000000"
MARK_PROCESSED="0x40000000/0x40000000"

IPT_GROUP_POST="nfqws_post"
IPT_GROUP_PRE="nfqws_pre"
IPT_GROUP_NAT="nfqws_nat"
IPT_GROUP_QOUT="nfqws_qout"
IPT_GROUP_QIN="nfqws_qin" # like QOUT, for incoming when connbytes is missing
IPT_GROUP_APP="nfqws_app"
IPT_GROUP_FWD="nfqws_fwd"
IPT_GROUP_MQ="nfqws_mquic"     # filter: мгновенный отказ QUIC к Meta (META_QUIC_REJECT)

# Сети Meta (Instagram, Facebook, WhatsApp): AS32934
META_NET4="157.240.0.0/16 31.13.24.0/21 31.13.64.0/18 57.144.0.0/14 163.70.128.0/17 129.134.0.0/16 69.171.224.0/19 173.252.64.0/18 179.60.192.0/22 185.60.216.0/22 66.220.144.0/20 69.63.176.0/20 102.132.96.0/20 204.15.20.0/22 45.64.40.0/22"
META_NET6="2a03:2880::/32"

# Сети Telegram: CIDR диапазоны мессенджера для обхода звонков
TG_NET4="91.105.192.0/23 91.108.4.0/22 91.108.8.0/22 91.108.12.0/22 91.108.16.0/22 91.108.20.0/22 91.108.56.0/22 95.161.64.0/20 149.154.160.0/20 185.76.151.0/24"
TG_NET6="2001:67c:4e8::/48 2001:b28:f23c::/48 2001:b28:f23d::/48 2001:b28:f23f::/48 2a0a:f280::/32"

NET_STRATEGIES_DIR="$CONFDIR/net_strategies"
IPT_CAP_CACHE="$STATE_DIR/iptables-capabilities"
RECEIPT_FILE="$STATE_DIR/compiled.receipt"
LIST_COUNTS_CACHE="$STATE_DIR/list_counts.cache"
SNAPSHOT_DIR="$STATE_DIR/snapshot_working"
GOOGLEVIDEO_CACHE_FILE="$STATE_DIR/googlevideo_cdn.txt"
ORCHESTRA_MEMORY_FILE="$STATE_DIR/orchestra_memory.json"
TG_AFFINITY_FILE="$STATE_DIR/tg_affinity.json"

# xt_owner allows max 128 ranges per rule
APP_UID_MAX=128

CNT_OUT_MASK=0x0f000000
CNT_OUT_STEP=16777216
CNT_IN_MASK=0x000f0000   # bits 16-19, apart from out counter (24-27) and MARK_* (28-30)
CNT_IN_STEP=65536        # 1<<16

# dirs usually exist; builtin test avoids forking mkdir (sourced on every nfqws2-ctl call)
if [ ! -d "$LISTS_DIR" ] || [ ! -d "$STATE_DIR" ] || [ ! -d "$LOG_DIR" ] || [ ! -d "$USER_STRATEGIES_DIR" ] || [ ! -d "$NET_STRATEGIES_DIR" ]; then
  mkdir -p "$LISTS_DIR" "$STATE_DIR" "$LOG_DIR" "$USER_STRATEGIES_DIR" "$NET_STRATEGIES_DIR" 2>/dev/null
fi

set_defaults() {
  : "${ISP_INTERFACE:=}"
  : "${IFACE_EXCLUDE:=lo tun+ tap+ wg+ ppp+ ipsec+ ifb+ dummy+}"
  : "${IPV6_ENABLED:=1}"
  : "${TCP_PORTS:=80,443,1984,2053,2083,2087,2096,5222,8443}"
  : "${UDP_PORTS:=443,590:600,1400,3478:3481,5349,19294:19344,49152:65535}"
  : "${NFQUEUE_NUM:=300}"
  : "${NFQWS_USER:=root}"
  : "${LOG_LEVEL:=0}"
  : "${AUTOSTART:=1}"
  : "${WATCHDOG:=1}"
  : "${BLOCK_QUIC:=0}"
  : "${NAT_FIX:=1}"
  : "${APP_MODE:=off}"
  : "${LOG_MAX_KB:=512}"
  : "${PKT_LIMIT_OUT:=15}"
  : "${PKT_LIMIT_IN:=15}"
  : "${WAKELOCK:=0}"
  : "${HOME_WIFI:=0}"
  : "${ENABLE_HOTSPOT:=1}"
  : "${NET_STRATEGY:=0}"
  : "${VPN_PAUSE:=0}"
  : "${META_QUIC_REJECT:=1}"
  : "${CALLS_BYPASS:=0}"
  : "${TCP_MSS_CLAMP:=0}"
  : "${AUTO_PORTS:=0}"
  # opt-in: wlwatch probes the network periodically, and WL_PAUSE=1 keeps the
  # watchdog alive through watchers_wanted() even when WATCHDOG=0
  : "${WL_PAUSE:=0}"
  : "${SMART_LEARN:=1}"
}

log_msg() {
  local line="[$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)] $*"
  echo "$line"
  echo "$line" >> "$SERVICE_LOG" 2>/dev/null
  if command -v log >/dev/null 2>&1; then
    log -t nfqws "$*" 2>/dev/null
  fi
}

sync_lists_and_blobs() {
  # builtin dir check avoids a fork on every netwatch tick and nfqws2-ctl call
  [ -d "$LISTS_DIR" ] && [ -d "$LOG_DIR" ] && [ -d "$STATE_DIR" ] ||
    mkdir -p "$LISTS_DIR" "$CONFDIR" "$LOG_DIR" "$STATE_DIR" "$CONFDIR/strategy-catalogs" "$CONFDIR/strategies/replaced" 2>/dev/null

  for sdir in "$MODDIR/lists" "$MODDIR/defaults/lists"; do
    if [ -d "$sdir" ]; then
      for f in "$sdir"/*; do
        [ -f "$f" ] || continue
        local bname="${f##*/}"
        [ -f "$LISTS_DIR/$bname" ] || cp -f "$f" "$LISTS_DIR/$bname"
      done
    fi
  done

  if [ -d "$MODDIR/strategy-catalogs" ]; then
    mkdir -p "$CONFDIR/strategy-catalogs" 2>/dev/null
    for f in "$MODDIR/strategy-catalogs"/*; do
      [ -f "$f" ] || continue
      local bname="${f##*/}"
      [ -f "$CONFDIR/strategy-catalogs/$bname" ] || cp -f "$f" "$CONFDIR/strategy-catalogs/$bname"
    done
  fi
}

archive_replaced_preset() {
  local p="$1"
  [ -f "$p" ] || return 0
  local bname="${p##*/}"
  local ts
  ts=$(date '+%Y%m%d_%H%M%S' 2>/dev/null || echo "$$")
  local rep_dir="$CONFDIR/strategies/replaced"
  mkdir -p "$rep_dir" 2>/dev/null
  cp -f "$p" "$rep_dir/${bname%.conf}.$ts.conf" 2>/dev/null || true
}

catalog_file() { # <category>
  local cat="$1"
  case "$cat" in
    tcp_tls|tcp_http|udp_quic|udp_voice) ;;
    *) return 1 ;;
  esac
  if [ -f "$CONFDIR/strategy-catalogs/$cat.list" ]; then
    echo "$CONFDIR/strategy-catalogs/$cat.list"
  else
    if [ -f "$MODDIR/strategy-catalogs/$cat.list" ]; then
      echo "$MODDIR/strategy-catalogs/$cat.list"
    else
      return 1
    fi
  fi
}


rotate_file() {
  local f="$1" max="$2" sz
  [ -f "$f" ] || return 0
  sz=$(wc -c < "$f" 2>/dev/null)
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  [ "$sz" -gt "$max" ] || return 0
  tail -c $((max / 2)) "$f" > "$f.tmp" 2>/dev/null && cat "$f.tmp" > "$f" 2>/dev/null
  rm -f "$f.tmp"
}

rotate_logs() {
  local max=$(( ${LOG_MAX_KB:-512} * 1024 )) f
  for f in "$SERVICE_LOG" "$NFQWS_LOG" "$LOG_DIR/auto.log"; do rotate_file "$f" "$max"; done
  if [ "$1" = "start" ]; then
    f="$LOG_DIR/nfqws2-debug.log"
    # truncate when debug on, rotate when off; && ... || would rotate on failed truncate
    if [ "$LOG_LEVEL" = "1" ]; then
      : > "$f" 2>/dev/null
    else
      rotate_file "$f" "$max"
    fi
  fi
}

validate_conf() {
  awk '
    BEGIN { ok = 1 }
    /`/ { printf "line %d: backtick is forbidden\n", NR; ok = 0 }
    /\$\(/ { printf "line %d: $( is forbidden\n", NR; ok = 0 }
    END { exit ok ? 0 : 1 }
  ' "$1"
}

# Smart mode is a module strategy: its active configuration is kept in sync with the module.
# When a new layout is released (SMART_CONF_VER in strategies/smart.conf), the active configuration
# is rebuilt with user settings preserved (USER_KEYS). If the user created a custom copy in
# $USER_STRATEGIES_DIR/smart.conf, we do not touch it.
smart_conf_sync() {
  local want have tmp="$STATE_DIR/smart_sync.$$"
  [ "$(head -n 1 "$ACTIVE_FILE" 2>/dev/null | tr -d '\r\n')" = smart ] || return 0
  [ -f "$USER_STRATEGIES_DIR/smart.conf" ] && return 0
  want=$(SMART_CONF_VER=; . "$STRATEGIES_DIR/smart.conf" >/dev/null 2>&1; echo "$SMART_CONF_VER")
  have=$(SMART_CONF_VER=; . "$CONFFILE" >/dev/null 2>&1; echo "$SMART_CONF_VER")
  if [ -z "$want" ] || [ "$want" = "$have" ]; then return 0; fi
  if render_strategy smart > "$tmp.raw" 2>/dev/null && [ -s "$tmp.raw" ] &&
     merge_user_keys "$tmp.raw" "$CONFFILE" > "$tmp" && validate_conf "$tmp" >/dev/null 2>&1; then
    cp -f "$CONFFILE" "$CONFFILE.bak" 2>/dev/null
    mv -f "$tmp" "$CONFFILE" && chmod 0644 "$CONFFILE"
    log_msg "Smart mode: config updated (конфиг обновлён) to layout $want"
  fi
  rm -f "$tmp" "$tmp.raw"
}

load_conf() {
  sync_lists_and_blobs
  if [ ! -f "$CONFFILE" ]; then
    cp -f "$MODDIR/defaults/nfqws2.conf" "$CONFFILE" 2>/dev/null
  fi
  smart_conf_sync
  local err
  err=$(validate_conf "$CONFFILE" 2>&1) || {
    log_msg "Config $CONFFILE contains errors: $err"
    . "$MODDIR/defaults/nfqws2.conf"
    set_defaults
    return 1
  }
  . "$CONFFILE"
  set_defaults
  return 0
}

validate_args_conf() {
  local v var
  for var in NFQWS_BASE_ARGS NFQWS_ARGS NFQWS_ARGS_QUIC NFQWS_ARGS_UDP NFQWS_EXTRA_ARGS NFQWS_ARGS_IPSET; do
    eval "v=\$$var"
    case "$v" in
      *--new*) echo "--new cannot be used in $var. Use NFQWS_ARGS_CUSTOM"; return 1 ;;
    esac
  done
  return 0
}

is_running() {
  [ -f "$PIDFILE" ] || return 1
  local pid
  pid=$(cat "$PIDFILE" 2>/dev/null)
  case "$pid" in ''|0|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  return 0
}

# Список должен кончаться переводом строки: nfqws2 дописывает выученные домены
# в auto.list как «домен\n», и без перевода в конце новый домен склеивается с
# последней строкой («example1.comexample2.com»)
ensure_eol() {
  [ -s "$1" ] && [ -n "$(tail -c 1 "$1")" ] && printf '\n' >> "$1"
  return 0
}

list_line_count() {
  [ -f "$1" ] || { printf 0; return; }
  local n
  n=$(wc -l < "$1" 2>/dev/null | tr -d ' ')
  printf '%s' "${n:-0}"
}

list_count() {
  [ -f "$1" ] || { printf 0; return; }
  local c
  c=$(grep -cv -e '^[[:space:]]*$' -e '^[[:space:]]*#' "$1" 2>/dev/null)
  printf '%s' "${c:-0}"
}

# list_count for many files in one grep; counts space-separated, 0 if missing.
# Uses mtime+size signature cache to avoid redundant grep on 100k+ line lists.
list_counts() {
  local f out="" c r="" have="" sig cached_val cache_file="$LIST_COUNTS_CACHE"
  for f; do
    if [ -f "$f" ]; then
      sig=$(stat -c '%Y|%s' "$f" 2>/dev/null)
      cached_val=""
      if [ -n "$sig" ] && [ -f "$cache_file" ]; then
        cached_val=$(awk -F'|' -v f="$f" -v s="$sig" '$1 == f && ($2 "|" $3) == s { print $4; exit }' "$cache_file" 2>/dev/null)
      fi
      if [ -z "$cached_val" ]; then
        have="$have${have:+
}$f"
      fi
    fi
  done
  # trailing /dev/null makes grep print "name:count" even for a single file
  if [ -n "$have" ]; then
    out=$(IFS='
'; set -f; grep -cv -e '^[[:space:]]*$' -e '^[[:space:]]*#' $have /dev/null 2>/dev/null)
    out="
$out"
  fi
  for f; do
    c=0
    if [ -f "$f" ]; then
      sig=$(stat -c '%Y|%s' "$f" 2>/dev/null)
      cached_val=""
      if [ -n "$sig" ] && [ -f "$cache_file" ]; then
        cached_val=$(awk -F'|' -v f="$f" -v s="$sig" '$1 == f && ($2 "|" $3) == s { print $4; exit }' "$cache_file" 2>/dev/null)
      fi
      if [ -n "$cached_val" ]; then
        c="$cached_val"
      else
        case "$out" in *"
$f:"*) c="${out#*"
$f:"}"; c="${c%%[!0-9]*}" ;; esac
        c="${c:-0}"
        if [ -n "$sig" ]; then
          mkdir -p "$STATE_DIR" 2>/dev/null
          grep -v -F "$f|" "$cache_file" > "$cache_file.tmp" 2>/dev/null || true
          printf '%s|%s|%s\n' "$f" "$sig" "$c" >> "$cache_file.tmp"
          mv -f "$cache_file.tmp" "$cache_file" 2>/dev/null
        fi
      fi
    fi
    r="$r${r:+ }${c:-0}"
  done
  printf '%s' "$r"
}

# Rewrite keenetic paths to module dirs.
# Specific paths must be substituted before the generic /opt/etc/nfqws2.
# arg "refs": keep $LUA_DIR/... references (for stored config); no arg: expand.
rewrite_keenetic_paths() {
  if [ "$1" = "refs" ]; then
    sed -e 's#/opt/etc/nfqws2/lua#$LUA_DIR#g' \
        -e 's#/opt/etc/nfqws2/blobs#$BLOBS_DIR#g' \
        -e 's#/opt/etc/nfqws2/lists#$LISTS_DIR#g' \
        -e 's#/opt/etc/nfqws2#$CONFDIR#g' \
        -e 's#/opt/var/log#$LOG_DIR#g'
  else
    sed -e "s#/opt/etc/nfqws2/lua#$LUA_DIR#g" \
        -e "s#/opt/etc/nfqws2/blobs#$BLOBS_DIR#g" \
        -e "s#/opt/etc/nfqws2/lists#$LISTS_DIR#g" \
        -e "s#/opt/etc/nfqws2#$CONFDIR#g" \
        -e "s#/opt/var/log#$LOG_DIR#g"
  fi
}

norm_args() {
  printf '%s\n' "$1" \
    | sed -e 's/^[[:space:]]*#.*$//' -e 's/\\//g' \
    | awk '{ for (i=1; i<=NF; i++) printf "%s ", $i } END { print "" }' \
    | rewrite_keenetic_paths \
    | sed -e 's/  */ /g; s/^ //; s/ $//'
}

app_mode_active() {
  case "$APP_MODE" in include|exclude) return 0 ;; *) return 1 ;; esac
}

# apps.list package names -> comma-separated UIDs via pm (supports multi-user / Shelter)
resolve_app_uids() {
  local f="$CONFDIR/apps.list" PM=pm
  [ -f "$f" ] || return 0
  # WebUI/root shell may lack /system/bin in PATH
  command -v pm >/dev/null 2>&1 || PM=/system/bin/pm
  command -v "$PM" >/dev/null 2>&1 || return 0
  [ -s "$f" ] || return 0

  local users u out
  users=$("$PM" list users 2>/dev/null | awk -F'[{:]' '/UserInfo/ { print $2 }')
  [ -n "$users" ] || users=0

  for u in $users; do
    out=$("$PM" list packages -U --user "$u" 2>/dev/null)
    if [ -z "$out" ] && [ "$u" = "0" ]; then
      out=$("$PM" list packages -U 2>/dev/null)
    fi
    printf '%s\n' "$out" | awk -v u="$u" '
      $1 ~ /^package:/ {
        p = tolower(substr($1, 9)); uid = $2; sub(/^uid:/, "", uid)
        if (uid ~ /^[0-9]+$/) print u, p, uid
      }'
  done | awk '
    NR == FNR {
      sub(/\r$/, "")
      sub(/^[ \t]+/, "")
      sub(/[ \t]+$/, "")
      if ($0 != "" && $0 !~ /^#/) {
        val = tolower($0)
        if (val ~ /^[0-9]+:/) uw[val] = 1
        else w[val] = 1
      }
      next
    }
    NF >= 3 {
      u = $1; p = $2; uid = $3
      if ((p in w) || ((u ":" p) in uw)) print uid
    }' "$f" - | sort -n -u | awk '{ printf "%s%s", (NR > 1 ? "," : ""), $0 }'
}

app_features_ok() {
  has_ipt_feature "$1" -m owner --uid-owner 0 -j RETURN &&
  has_ipt_feature "$1" -m connmark --mark 0x1/0x1 -j RETURN &&
  has_ipt_feature "$1" -j CONNMARK --set-xmark 0x1/0x1
}

app_uid_count() {
  local n
  [ -f "$APP_UIDS_FILE" ] || { printf 0; return; }
  n=$(tr ',' '\n' < "$APP_UIDS_FILE" 2>/dev/null | grep -cE '^[0-9]+$')
  printf '%s' "${n:-0}"
}

# 0 = app filter applied, 1 = off/not applicable, 2 = error
app_rules() {
  local CMD="$1" REAL_CMD="${FW_PROBE_CMD:-$1}" uids n chunk chunks mark
  if ! app_mode_active; then
    if [ "$CMD" != "_fw_batch_cmd" ]; then
      $CMD -w -t mangle -F $IPT_GROUP_APP 2>/dev/null
      $CMD -w -t mangle -X $IPT_GROUP_APP 2>/dev/null
    fi
    rm -f "$APP_UIDS_FILE"
    return 1
  fi
  if ! app_features_ok "$REAL_CMD"; then
    [ "$REAL_CMD" = "iptables" ] && log_msg "No xt_owner/xt_CONNMARK — app filter is not applied"
    return 2
  fi
  uids=$(resolve_app_uids)
  n=$(printf '%s\n' "$uids" | tr ',' '\n' | grep -cE '^[0-9]+$')
  if [ "$REAL_CMD" = "iptables" ]; then
    printf '%s\n' "$uids" > "$APP_UIDS_FILE"
    n=$(app_uid_count)
  fi
  if [ "$n" = "0" ]; then
    log_msg "apps.list: no packages mapped to UIDs — app filter ($APP_MODE) is inactive"
    return 2
  fi

  # -m owner needs a socket, so UID matching runs in POSTROUTING; replies use the conn mark
  mark="$MARK_INCLUDE"
  [ "$APP_MODE" = "exclude" ] && mark="$MARK_EXCLUDE"
  $CMD -w -t mangle -N $IPT_GROUP_APP 2>/dev/null
  $CMD -w -t mangle -F $IPT_GROUP_APP
  # Not a `| while read` pipeline: in the batch path $CMD appends to
  # FW_BATCH_BUF, and a pipeline would run the loop in a subshell and lose
  # every --uid-owner rule on iptables-restore systems.
  chunks=$(printf '%s\n' "$uids" | tr ',' '\n' | grep -E '^[0-9]+$' | sort -n -u | awk -v mx="$APP_UID_MAX" '
      { b = int((NR - 1) / mx); a[b] = (b in a ? a[b] "," $0 : $0) }
      END { for (i = 0; i <= b; i++) if (i in a) print a[i] }')
  for chunk in $chunks; do
    $CMD -w -t mangle -A $IPT_GROUP_APP -m owner --uid-owner "$chunk" -j CONNMARK --set-xmark "$mark"
  done
  $CMD -w -t mangle -A $IPT_GROUP_POST -j $IPT_GROUP_APP
  if [ "$APP_MODE" = "exclude" ]; then
    $CMD -w -t mangle -A $IPT_GROUP_POST -m connmark --mark "$MARK_EXCLUDE" -j RETURN
    [ "$LIMITER" = "connbytes" ] && $CMD -w -t mangle -A $IPT_GROUP_PRE -m connmark --mark "$MARK_EXCLUDE" -j RETURN
  else
    $CMD -w -t mangle -A $IPT_GROUP_POST -m connmark ! --mark "$MARK_INCLUDE" -j RETURN
    [ "$LIMITER" = "connbytes" ] && $CMD -w -t mangle -A $IPT_GROUP_PRE -m connmark ! --mark "$MARK_INCLUDE" -j RETURN
  fi
  log_msg "App filter ($APP_MODE): $n UIDs"
  return 0
}

# Профиль звонков с подставленными сетями Meta и Telegram
calls_args() {
  local m t
  m=$(printf '%s' "$META_NET4 $META_NET6" | tr ' ' ',')
  t=$(printf '%s' "$TG_NET4 $TG_NET6" | tr ' ' ',')
  norm_args "$(sed -e "s#@META@#$m#g" -e "s#@TG@#$t#g" "$MODDIR/defaults/calls-bypass.conf")"
}

# Добавить порты или диапазоны (a:b) в список для iptables. То, что новый
# диапазон покрывает целиком, из списка уходит: multiport берёт не больше 15
# портов (диапазон — за два), и лишние записи переполнили бы правило.
port_list_add() { # <список> <порт|a:b>...
  local l="$1"; shift
  printf '%s\n' "$@" | awk -v l="$l" '
    function lo(x) { return x ~ /:/ ? substr(x, 1, index(x, ":") - 1) + 0 : x + 0 }
    function hi(x) { return x ~ /:/ ? substr(x, index(x, ":") + 1) + 0 : x + 0 }
    BEGIN { n = split(l, a, ",") }
    NF { add[++m] = $0 }
    END {
      out = ""
      for (i = 1; i <= n; i++) {
        if (a[i] == "") continue
        cov = 0
        for (j = 1; j <= m; j++) if (a[i] != add[j] && lo(a[i]) >= lo(add[j]) && hi(a[i]) <= hi(add[j])) cov = 1
        if (!cov) out = out (out == "" ? "" : ",") a[i]
      }
      for (j = 1; j <= m; j++) {
        dup = 0
        for (i = 1; i <= n; i++) if (lo(add[j]) >= lo(a[i]) && hi(add[j]) <= hi(a[i])) dup = 1
        if (!dup) out = out (out == "" ? "" : ",") add[j]
      }
      printf "%s", out
    }'
}

port_list_without() {
  printf ',%s,' "$1" | sed "s/,$2,/,/g; s/^,//; s/,\$//"
}

_startup_args() {
  local base tcp quic udp extra custom ipset
  base=$(norm_args "$NFQWS_BASE_ARGS")
  tcp=$(norm_args "$NFQWS_ARGS")
  quic=$(norm_args "$NFQWS_ARGS_QUIC")
  udp=$(norm_args "$NFQWS_ARGS_UDP")
  extra=$(norm_args "$NFQWS_EXTRA_ARGS")
  custom=$(norm_args "$NFQWS_ARGS_CUSTOM")
  ipset=""
  if [ -n "$NFQWS_ARGS_IPSET" ] && [ "$(list_count "$LISTS_DIR/ipset.list")" -gt 0 ]; then
    ipset=$(norm_args "$NFQWS_ARGS_IPSET")
  fi

  local args="--user=$NFQWS_USER --qnum=$NFQUEUE_NUM"

  if [ -n "$ISP_INTERFACE" ] && [ "$(echo $ISP_INTERFACE | wc -w)" -gt 1 ]; then
    args="$args --bind-fix4"
    [ "$IPV6_ENABLED" != "0" ] && args="$args --bind-fix6"
  fi

  if [ "$LOG_LEVEL" = "1" ]; then
    args="--debug=@$LOG_DIR/nfqws2-debug.log $args"
  else
    args="--debug=@$NFQWS_LOG $args"
  fi

  args="$args $base"
  # Обход звонков — ставится перед стратегией
  if [ "$CALLS_BYPASS" = "1" ] && [ -f "$MODDIR/defaults/calls-bypass.conf" ]; then
    args="$args --blob=calls_stun:@$BLOBS_DIR/stun.bin --blob=calls_tls:@$BLOBS_DIR/tls_clienthello.bin $(calls_args) --new"
  fi
  [ -n "$custom" ] && args="$args $custom --new"
  [ -n "$udp" ] && args="$args $udp --new"

  if [ -n "$quic" ] && [ "$BLOCK_QUIC" != "1" ]; then
    [ -n "$ipset" ] && args="$args $quic $ipset --ipset-ip=0.0.0.0 --new"
    args="$args $quic $extra --new"
  fi

  [ -n "$ipset" ] && args="$args $tcp $ipset --ipset-ip=0.0.0.0 --new"
  args="$args $tcp $extra"

  printf '%s' "$args" | tr -s ' '
}

dry_run_check() { # <args...>
  [ -x "$NFQWS_BIN" ] || return 0
  local out rc
  out=$(
    cd "$MODDIR/bin" 2>/dev/null || exit 1
    set -f
    if [ "$#" -eq 1 ]; then
      set -- $1
    fi
    "$NFQWS_BIN" --dry-run "$@" 2>&1
  )
  rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
    else
      echo "nfqws2: parameter error (code $rc)"
    fi
    return "$rc"
  fi
  return 0
}

validate_conf_file() { # <conf_file>
  local f="$1" err out rc
  [ -f "$f" ] || { echo "Файл не найден: $f"; return 1; }
  err=$(validate_conf "$f" 2>&1) || { echo "$err"; return 1; }
  err=$(validate_strategy_blob_references "$f" 2>&1) || { echo "$err"; return 1; }
  out=$(
    export CONFDIR MODDIR
    . "$f" >/dev/null 2>&1 || { echo "Ошибка синтаксиса в $f"; exit 1; }
    set_defaults
    err=$(validate_args_conf) || { echo "$err"; exit 1; }
    local args
    args=$(_startup_args)
    dry_run_check "$args" || exit 1
  )
  rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
    else
      echo "Ошибка валидации параметров nfqws2 (код $rc)"
    fi
    return "$rc"
  fi
  return 0
}

get_strategy_packet_limits() { # [conffile]
  local f="${1:-$CONFFILE}"
  local t_out="" t_in="" u_out="" u_in=""
  if [ -f "$f" ]; then
    t_out=$(grep -m1 -E '^[#[:space:]]*NFQWS2_TCP_PKT_OUT=' "$f" 2>/dev/null | sed 's/.*=//; s/[^0-9]//g')
    t_in=$(grep -m1 -E '^[#[:space:]]*NFQWS2_TCP_PKT_IN=' "$f" 2>/dev/null | sed 's/.*=//; s/[^0-9]//g')
    u_out=$(grep -m1 -E '^[#[:space:]]*NFQWS2_UDP_PKT_OUT=' "$f" 2>/dev/null | sed 's/.*=//; s/[^0-9]//g')
    u_in=$(grep -m1 -E '^[#[:space:]]*NFQWS2_UDP_PKT_IN=' "$f" 2>/dev/null | sed 's/.*=//; s/[^0-9]//g')
  fi
  printf '%s %s %s %s' "${t_out:-$PKT_LIMIT_OUT}" "${t_in:-$PKT_LIMIT_IN}" "${u_out:-$PKT_LIMIT_OUT}" "${u_in:-$PKT_LIMIT_IN}"
}

collect_capture_ports() { # <proto: tcp|udp> [args_string]
  local proto="${1:-tcp}" args="${2:-}"
  if [ -z "$args" ]; then
    args="$NFQWS_ARGS $NFQWS_ARGS_QUIC $NFQWS_ARGS_UDP $NFQWS_ARGS_CUSTOM"
  fi
  printf '%s\n' "$args" | awk -v proto="$proto" '
    BEGIN { pat = "--filter-" proto "=" }
    {
      s = $0
      while (match(s, /--filter-(tcp|udp)=[^ "\t]+/)) {
        tok = substr(s, RSTART, RLENGTH)
        s = substr(s, RSTART + RLENGTH)
        if (substr(tok, 1, length(pat)) == pat) {
          val = substr(tok, length(pat) + 1)
          n = split(val, arr, ",")
          for (i = 1; i <= n; i++) {
            p = arr[i]
            gsub(/-/, ":", p)
            if (p != "") {
              split(p, sp, ":")
              order[p] = sp[1] + 0
              seen[p] = 1
            }
          }
        }
      }
    }
    END {
      cnt = 0
      for (p in seen) items[++cnt] = p
      for (i = 1; i <= cnt; i++) {
        for (j = i + 1; j <= cnt; j++) {
          if (order[items[i]] > order[items[j]]) {
            tmp = items[i]; items[i] = items[j]; items[j] = tmp
          }
        }
      }
      res = ""
      for (i = 1; i <= cnt; i++) res = (res == "" ? items[i] : res "," items[i])
      print res
    }'
}

heal_blob() { # <blob_path> -> 0 if healed/exists, 1 if not healable
  local target="$1"
  [ -f "$target" ] && return 0
  local base="${target##*/}" dir="${target%/*}"
  [ -n "$dir" ] && mkdir -p "$dir" 2>/dev/null

  # 1. Try to restore from $MODDIR/blobs/ if target is in another directory
  if [ -n "$MODDIR" ] && [ -f "$MODDIR/blobs/$base" ]; then
    cp -f "$MODDIR/blobs/$base" "$target" 2>/dev/null && return 0
  fi

  # 2. Heal known standard zero blobs
  case "$base" in
    zero_256.bin)
      dd if=/dev/zero of="$target" bs=256 count=1 >/dev/null 2>&1 && return 0
      ;;
    zero_512.bin)
      dd if=/dev/zero of="$target" bs=512 count=1 >/dev/null 2>&1 && return 0
      ;;
    zero_1024.bin)
      dd if=/dev/zero of="$target" bs=1024 count=1 >/dev/null 2>&1 && return 0
      ;;
    quic_initial.bin|quic_initial_www_google_com.bin)
      if [ -f "$dir/quic_initial.bin" ]; then
        cp -f "$dir/quic_initial.bin" "$target" 2>/dev/null && return 0
      elif [ -f "$dir/quic_initial_www_google_com.bin" ]; then
        cp -f "$dir/quic_initial_www_google_com.bin" "$target" 2>/dev/null && return 0
      elif [ -n "$MODDIR" ] && [ -f "$MODDIR/blobs/quic_initial.bin" ]; then
        cp -f "$MODDIR/blobs/quic_initial.bin" "$target" 2>/dev/null && return 0
      elif [ -n "$MODDIR" ] && [ -f "$MODDIR/blobs/quic_initial_www_google_com.bin" ]; then
        cp -f "$MODDIR/blobs/quic_initial_www_google_com.bin" "$target" 2>/dev/null && return 0
      fi
      ;;
    tls_clienthello.bin|tls_clienthello_www_google_com.bin)
      if [ -f "$dir/tls_clienthello.bin" ]; then
        cp -f "$dir/tls_clienthello.bin" "$target" 2>/dev/null && return 0
      elif [ -f "$dir/tls_clienthello_www_google_com.bin" ]; then
        cp -f "$dir/tls_clienthello_www_google_com.bin" "$target" 2>/dev/null && return 0
      elif [ -n "$MODDIR" ] && [ -f "$MODDIR/blobs/tls_clienthello.bin" ]; then
        cp -f "$MODDIR/blobs/tls_clienthello.bin" "$target" 2>/dev/null && return 0
      elif [ -n "$MODDIR" ] && [ -f "$MODDIR/blobs/tls_clienthello_www_google_com.bin" ]; then
        cp -f "$MODDIR/blobs/tls_clienthello_www_google_com.bin" "$target" 2>/dev/null && return 0
      fi
      ;;
  esac
  return 1
}

validate_strategy_blob_references() { # <args_or_conffile>
  local content="$1" f p
  if [ -f "$content" ]; then
    content=$(cat "$content" 2>/dev/null)
  fi

  local missing=0
  for p in $(printf '%s\n' "$content" | awk '
    {
      s = $0
      if (s ~ /^[[:space:]]*#/) next
      while (match(s, /@[A-Za-z0-9_.\-\/$]+/)) {
        print substr(s, RSTART + 1, RLENGTH - 1)
        s = substr(s, RSTART + RLENGTH)
      }
    }' | sort -u); do
    case "$p" in META*|TG*) continue ;; esac
    f="$p"
    f=$(printf '%s\n' "$f" | sed \
        -e "s#\\\$LUA_DIR#$LUA_DIR#g" \
        -e "s#\\\$BLOBS_DIR#$BLOBS_DIR#g" \
        -e "s#\\\$CONFDIR#$CONFDIR#g" \
        -e "s#\\\$MODDIR#$MODDIR#g")
    case "$f" in
      */nfqws2-debug.log|*/nfqws2.log|*/auto.log) continue ;;
    esac
    if [ ! -f "$f" ]; then
      heal_blob "$f" 2>/dev/null || true
    fi
    if [ ! -f "$f" ]; then
      log_msg "Error: blob or script file not found: $f"
      missing=$((missing + 1))
    fi
  done
  [ "$missing" -eq 0 ] || return 1
  return 0
}

generate_strategy_receipt() { # [conffile]
  local conf="${1:-$CONFFILE}" f p file_list
  [ -f "$conf" ] || return 1
  file_list="$conf"
  for p in $(awk '
    {
      s = $0
      while (match(s, /@[A-Za-z0-9_.\-\/$]+/)) {
        print substr(s, RSTART + 1, RLENGTH - 1)
        s = substr(s, RSTART + RLENGTH)
      }
    }' "$conf" 2>/dev/null | sort -u); do
    f="$p"
    f=$(printf '%s\n' "$f" | sed \
        -e "s#\\\$LUA_DIR#$LUA_DIR#g" \
        -e "s#\\\$BLOBS_DIR#$BLOBS_DIR#g" \
        -e "s#\\\$CONFDIR#$CONFDIR#g" \
        -e "s#\\\$MODDIR#$MODDIR#g")
    case "$f" in
      */nfqws2-debug.log|*/nfqws2.log|*/auto.log) continue ;;
    esac
    [ -f "$f" ] && file_list="$file_list $f"
  done
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum $file_list 2>/dev/null | sha256sum 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

verify_strategy_receipt() { # [conffile]
  [ -f "$RECEIPT_FILE" ] || return 1
  local cur
  cur=$(generate_strategy_receipt "${1:-$CONFFILE}" 2>/dev/null) || return 1
  [ -n "$cur" ] && [ "$cur" = "$(cat "$RECEIPT_FILE" 2>/dev/null)" ]
}

save_strategy_receipt() { # [conffile]
  local r
  r=$(generate_strategy_receipt "${1:-$CONFFILE}" 2>/dev/null) || return 1
  [ -n "$r" ] && printf '%s\n' "$r" > "$RECEIPT_FILE"
}

topology_fingerprint() { # [conffile]
  local conf="${1:-$CONFFILE}"
  local tp="" up="" ap="" bq="" lim="" am="" qn="" lims=""
  if [ -f "$conf" ]; then
    tp=$(grep -m1 -E '^[[:space:]]*TCP_PORTS=' "$conf" 2>/dev/null | sed 's/.*=//; s/["'\'' ]//g')
    up=$(grep -m1 -E '^[[:space:]]*UDP_PORTS=' "$conf" 2>/dev/null | sed 's/.*=//; s/["'\'' ]//g')
    ap=$(grep -m1 -E '^[[:space:]]*AUTO_PORTS=' "$conf" 2>/dev/null | sed 's/.*=//; s/["'\'' ]//g')
    bq=$(grep -m1 -E '^[[:space:]]*BLOCK_QUIC=' "$conf" 2>/dev/null | sed 's/.*=//; s/["'\'' ]//g')
    lim=$(grep -m1 -E '^[[:space:]]*LIMITER=' "$conf" 2>/dev/null | sed 's/.*=//; s/["'\'' ]//g')
    am=$(grep -m1 -E '^[[:space:]]*APP_MODE=' "$conf" 2>/dev/null | sed 's/.*=//; s/["'\'' ]//g')
    qn=$(grep -m1 -E '^[[:space:]]*NFQUEUE_NUM=' "$conf" 2>/dev/null | sed 's/.*=//; s/["'\'' ]//g')
    lims=$(grep -E '^[#[:space:]]*NFQWS2_(TCP|UDP)_PKT_(OUT|IN)=' "$conf" 2>/dev/null | sort | tr '\n' ';')
  fi
  printf '%s|%s|%s|%s|%s|%s|%s|%s' "$tp" "$up" "${ap:-0}" "${bq:-0}" "$lim" "${am:-off}" "${qn:-300}" "$lims"
}

save_working_snapshot() { # [conffile]
  local conf="${1:-$CONFFILE}"
  mkdir -p "$SNAPSHOT_DIR" 2>/dev/null
  if [ -f "$conf" ]; then
    cp -f "$conf" "$SNAPSHOT_DIR/nfqws2.conf" 2>/dev/null || true
  fi
  if [ -f "$ACTIVE_FILE" ]; then
    cp -f "$ACTIVE_FILE" "$SNAPSHOT_DIR/active" 2>/dev/null || true
  fi
  if [ -f "$RECEIPT_FILE" ]; then
    cp -f "$RECEIPT_FILE" "$SNAPSHOT_DIR/compiled.receipt" 2>/dev/null || true
  fi
  date +%s > "$SNAPSHOT_DIR/saved_at" 2>/dev/null || true
}

rollback_to_snapshot() {
  if [ ! -f "$SNAPSHOT_DIR/nfqws2.conf" ]; then
    echo "Нет сохранённого рабочего снимка для отката" >&2
    return 1
  fi
  cp -f "$SNAPSHOT_DIR/nfqws2.conf" "$CONFFILE" 2>/dev/null || return 1
  if [ -f "$SNAPSHOT_DIR/active" ]; then
    cp -f "$SNAPSHOT_DIR/active" "$ACTIVE_FILE" 2>/dev/null || true
  fi
  if [ -f "$SNAPSHOT_DIR/compiled.receipt" ]; then
    cp -f "$SNAPSHOT_DIR/compiled.receipt" "$RECEIPT_FILE" 2>/dev/null || true
  fi
  rm -f "$STATE_DIR/rollback_armed" 2>/dev/null || true
  return 0
}

record_tcp16_detection() { # <provider> <ip> <detected_size>
  local provider="$1" ip="$2" sz="$3"
  [ -n "$ip" ] || return 0
  mkdir -p "$STATE_DIR" 2>/dev/null

  local o1 o2 prefix
  o1=$(printf '%s' "$ip" | cut -d. -f1)
  o2=$(printf '%s' "$ip" | cut -d. -f2)
  if [ -z "$o1" ] || [ -z "$o2" ]; then return 0; fi
  prefix="${o1}.${o2}.0.0/16"

  local asn=0 sni="300.ya.ru"
  case "$provider" in
    *Hetzner*) asn=24940; sni="300.ya.ru" ;;
    *Cloudflare*) asn=13335; sni="hcaptcha.com" ;;
    *CDN77*) asn=60068; sni="ad.adriver.ru" ;;
    *Akamai*) asn=20940; sni="300.ya.ru" ;;
    *AWS*) asn=16509; sni="hcaptcha.com" ;;
    *OVH*) asn=16276; sni="300.ya.ru" ;;
    *Fastly*) asn=54113; sni="release-assets.githubusercontent.com" ;;
    *Oracle*) asn=31898; sni="300.ya.ru" ;;
    *Google*) asn=15169; sni="ya.ru" ;;
    *) asn=99999; sni="ya.ru" ;;
  esac

  if [ -f "$LISTS_DIR/whitelist_sni.list" ]; then
    local custom_sni
    custom_sni=$(grep -v -E '^[[:space:]]*(#|$)' "$LISTS_DIR/whitelist_sni.list" 2>/dev/null | head -n1 | tr -d '\r')
    if [ -n "$custom_sni" ]; then
      sni="$custom_sni"
    fi
  fi

  # 1. ASN list: $STATE_DIR/tcp16_asn.txt
  if [ -f "$STATE_DIR/tcp16_asn.txt" ]; then
    grep -qx "$asn" "$STATE_DIR/tcp16_asn.txt" 2>/dev/null || echo "$asn" >> "$STATE_DIR/tcp16_asn.txt"
  else
    echo "$asn" > "$STATE_DIR/tcp16_asn.txt"
  fi

  # 2. Nets list: $STATE_DIR/tcp16_nets.txt
  local netline="$asn	$prefix"
  if [ -f "$STATE_DIR/tcp16_nets.txt" ]; then
    grep -qx "$netline" "$STATE_DIR/tcp16_nets.txt" 2>/dev/null || printf '%s\n' "$netline" >> "$STATE_DIR/tcp16_nets.txt"
  else
    printf '%s\n' "$netline" > "$STATE_DIR/tcp16_nets.txt"
  fi

  # 3. SNI list: $STATE_DIR/tcp16_sni.txt
  local sniline="$asn	$sni"
  if [ -f "$STATE_DIR/tcp16_sni.txt" ]; then
    grep -qx "$sniline" "$STATE_DIR/tcp16_sni.txt" 2>/dev/null || printf '%s\n' "$sniline" >> "$STATE_DIR/tcp16_sni.txt"
  else
    printf '%s\n' "$sniline" > "$STATE_DIR/tcp16_sni.txt"
  fi
}

resolve_googlevideo_cdn() { # [force]
  local force="${1:-}"
  mkdir -p "$STATE_DIR" 2>/dev/null
  if [ "$force" != "force" ]; then
    if [ -s "$GOOGLEVIDEO_CACHE_FILE" ]; then
      local cached
      cached=$(head -n1 "$GOOGLEVIDEO_CACHE_FILE" 2>/dev/null | tr -d '\r\n')
      if [ -n "$cached" ]; then
        printf '%s' "$cached"
        return 0
      fi
    fi
  fi

  local tool kind bin to="" resp="" cluster=""
  tool=$(probe_tool 2>/dev/null)
  kind="${tool%% *}"
  bin="${tool#* }"
  if command -v timeout >/dev/null 2>&1; then
    to="timeout 5"
  fi

  if [ "$kind" = "curl" ]; then
    resp=$($to "$bin" -s -m 4 "http://redirector.googlevideo.com/report_mapping?di=no" 2>/dev/null)
    if [ -z "$resp" ]; then
      resp=$($to "$bin" -s -m 4 "http://redirector.gvt1.com/report_mapping?di=no" 2>/dev/null)
    fi
  elif [ "$kind" = "wget" ]; then
    resp=$($to "$bin" -q -T 4 -O - "http://redirector.googlevideo.com/report_mapping?di=no" 2>/dev/null)
    if [ -z "$resp" ]; then
      resp=$($to "$bin" -q -T 4 -O - "http://redirector.gvt1.com/report_mapping?di=no" 2>/dev/null)
    fi
  fi

  if [ -n "$resp" ]; then
    cluster=$(printf '%s\n' "$resp" | awk -F'=>' '/=>/{gsub(/[ \r\t\n]/, "", $2); print $2; exit}')
    if [ -z "$cluster" ]; then
      cluster=$(printf '%s\n' "$resp" | awk -F':' '/:/{gsub(/[ \r\t\n]/, "", $1); print $1; exit}')
    fi
  fi

  if [ -z "$cluster" ]; then
    if [ "$kind" = "curl" ]; then
      local loc
      loc=$($to "$bin" -s -I -m 4 "http://redirector.googlevideo.com/videoplayback?id=0000000000000000" 2>/dev/null | grep -i '^location:' | tr -d '\r')
      if [ -n "$loc" ]; then
        cluster=$(printf '%s\n' "$loc" | sed -n 's#.*//\([^/]*\)\.googlevideo\.com/.*#\1#p')
      fi
    fi
  fi

  local domain=""
  if [ -n "$cluster" ]; then
    cluster=$(printf '%s' "$cluster" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-')
    case "$cluster" in
      rr*---sn-*) domain="${cluster}.googlevideo.com" ;;
      rr*) domain="${cluster}.googlevideo.com" ;;
      sn-*) domain="rr1---${cluster}.googlevideo.com" ;;
      *) domain="rr1---sn-${cluster}.googlevideo.com" ;;
    esac
  fi

  if [ -z "$domain" ]; then
    if [ -f "$LISTS_DIR/googlevideo.list" ]; then
      domain=$(grep -E '^rr[0-9]+---sn-[a-z0-9-]+\.googlevideo\.com' "$LISTS_DIR/googlevideo.list" 2>/dev/null | head -n1 | tr -d '\r\n')
    fi
  fi
  if [ -z "$domain" ]; then
    domain="rr1---sn-xguxaxjvh-n8me.googlevideo.com"
  fi

  printf '%s\n' "$domain" > "$GOOGLEVIDEO_CACHE_FILE" 2>/dev/null
  printf '%s' "$domain"
  return 0
}

orchestra_memory_init() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  if [ ! -f "$ORCHESTRA_MEMORY_FILE" ]; then
    printf '{\n  "max_entries": 3000,\n  "locked": {},\n  "blocked": {},\n  "hosts": {}\n}\n' > "$ORCHESTRA_MEMORY_FILE"
  fi
}

_orchestra_rewrite_strategy() { # <host> <idx> <locked|blocked> <value as list>
  local host="$1" idx="$2" section="$3" as_list="$4"
  if [ -z "$host" ] || [ -z "$idx" ]; then return 1; fi
  orchestra_memory_init
  command -v awk >/dev/null 2>&1 || return 0
  awk -v h="$host" -v idx="$idx" -v sec="$section" -v lst="$as_list" '
    BEGIN { in_s = 0 }
    {
      if ($0 ~ ("\"" sec "\": \{")) {
        print $0
        in_s = 1
        if (lst) printf "    \"%s\": [%s],\n", h, idx
        else printf "    \"%s\": %s,\n", h, idx
        next
      }
      if (in_s && $0 ~ /^[[:space:]]*\},?/) in_s = 0
      if (in_s && $0 ~ ("\"" h "\":")) next
      print
    }' "$ORCHESTRA_MEMORY_FILE" > "$ORCHESTRA_MEMORY_FILE.tmp"
  if [ -s "$ORCHESTRA_MEMORY_FILE.tmp" ]; then
    mv -f "$ORCHESTRA_MEMORY_FILE.tmp" "$ORCHESTRA_MEMORY_FILE"
  else
    rm -f "$ORCHESTRA_MEMORY_FILE.tmp"
  fi
  return 0
}
orchestra_lock_strategy()  { _orchestra_rewrite_strategy "$1" "$2" locked 0; }
orchestra_block_strategy() { _orchestra_rewrite_strategy "$1" "$2" blocked 1; }

_orchestra_drop_strategy() { # <host>
  local host="$1"
  [ -n "$host" ] || return 1
  orchestra_memory_init
  grep -v "\"$host\":" "$ORCHESTRA_MEMORY_FILE" > "$ORCHESTRA_MEMORY_FILE.tmp"
  if [ -s "$ORCHESTRA_MEMORY_FILE.tmp" ]; then
    mv -f "$ORCHESTRA_MEMORY_FILE.tmp" "$ORCHESTRA_MEMORY_FILE"
  else
    rm -f "$ORCHESTRA_MEMORY_FILE.tmp"
  fi
  return 0
}
orchestra_unlock_strategy()  { _orchestra_drop_strategy "$1"; }
orchestra_unblock_strategy() { _orchestra_drop_strategy "$1"; }

orchestra_status() {
  orchestra_memory_init
  local total locked blocked
  total=$(grep -c '"strategy":' "$ORCHESTRA_MEMORY_FILE" 2>/dev/null)
  if [ -z "$total" ]; then
    total=0
  fi
  locked=$(awk '/"locked": \{/{flag=1; next} flag && /\}/{flag=0} flag && /[a-zA-Z0-9]/{cnt++} END{print cnt+0}' "$ORCHESTRA_MEMORY_FILE" 2>/dev/null)
  if [ -z "$locked" ]; then
    locked=0
  fi
  blocked=$(awk '/"blocked": \{/{flag=1; next} flag && /\}/{flag=0} flag && /[a-zA-Z0-9]/{cnt++} END{print cnt+0}' "$ORCHESTRA_MEMORY_FILE" 2>/dev/null)
  if [ -z "$blocked" ]; then
    blocked=0
  fi
  printf 'ORCHESTRA\ttotal_hosts=%s\tlocked=%s\tblocked=%s\tmax_lru=3000\n' "$total" "$locked" "$blocked"
}



kernel_modules() {
  command -v modprobe >/dev/null 2>&1 || return 0
  modprobe -a -q nfnetlink_queue xt_multiport xt_connbytes xt_NFQUEUE xt_CONNMARK xt_connmark xt_owner nf_conntrack 2>/dev/null
  return 0
}

has_ipt_feature() {
  ipt_probe "$@" >/dev/null 2>&1
}

_ipt_cap_cache_get() { # <command> <probe key>
  [ -n "$MOCK_IPT_FEATURES" ] && return 1
  local kernel value
  kernel=$(uname -r 2>/dev/null) || return 1
  if [ -z "$kernel" ] || [ ! -f "$IPT_CAP_CACHE" ]; then return 1; fi
  value=$(while IFS='|' read -r k c p v; do
    [ "$k" = "$kernel" ] && [ "$c" = "$1" ] && [ "$p" = "$2" ] && {
      printf '%s' "$v"
      break
    }
  done < "$IPT_CAP_CACHE")
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

_ipt_cap_cache_put() { # <command> <probe key> <value>
  [ -n "$MOCK_IPT_FEATURES" ] && return 0
  local kernel tmp
  kernel=$(uname -r 2>/dev/null) || return 0
  [ -n "$kernel" ] || return 0
  mkdir -p "$STATE_DIR" 2>/dev/null
  tmp="$IPT_CAP_CACHE.tmp"
  if [ -f "$IPT_CAP_CACHE" ]; then
    while IFS='|' read -r k c p v; do
      [ "$k" = "$kernel" ] && [ "$c" = "$1" ] && [ "$p" = "$2" ] && continue
      printf '%s|%s|%s|%s\n' "$k" "$c" "$p" "$v"
    done < "$IPT_CAP_CACHE" > "$tmp"
  fi
  printf '%s|%s|%s|%s\n' "$kernel" "$1" "$2" "$3" >> "$tmp"
  mv -f "$tmp" "$IPT_CAP_CACHE"
}

ipt_probe() {
  local CMD="$1"; shift
  local err rc
  $CMD -w -t mangle -N nfqws_test >/dev/null 2>&1
  $CMD -w -t mangle -F nfqws_test >/dev/null 2>&1
  err=$($CMD -w -t mangle -A nfqws_test "$@" 2>&1); rc=$?
  $CMD -w -t mangle -F nfqws_test >/dev/null 2>&1
  $CMD -w -t mangle -X nfqws_test >/dev/null 2>&1
  [ "$rc" -eq 0 ] || printf '%s' "$err" | tail -n1
  return $rc
}

ipt_wait_flag() { # <cmd>
  local cmd="${1:-iptables}"
  if [ -n "$IPT_WAIT_CHECKED" ]; then
    printf '%s' "$IPT_WAIT_FLAG"
    return 0
  fi
  IPT_WAIT_CHECKED=1
  IPT_WAIT_FLAG=""
  if "$cmd" -w 1 -L -n >/dev/null 2>&1; then
    IPT_WAIT_FLAG="-w"
  elif "$cmd" -w -L -n >/dev/null 2>&1; then
    IPT_WAIT_FLAG="-w"
  fi
  printf '%s' "$IPT_WAIT_FLAG"
}

ipt_exec() { # <cmd> <args...>
  local cmd="$1"; shift
  if [ "$cmd" = "_fw_batch_cmd" ]; then
    _fw_batch_cmd "$@"
    return $?
  fi
  case "$1" in
    -w) shift ;;
  esac
  local wflag
  wflag=$(ipt_wait_flag "$cmd")
  local attempt=1 max_attempts=5 delay=0.1
  local err rc

  while [ "$attempt" -le "$max_attempts" ]; do
    if [ -n "$wflag" ]; then
      err=$("$cmd" "$wflag" "$@" 2>&1)
      rc=$?
    else
      err=$("$cmd" "$@" 2>&1)
      rc=$?
    fi

    if [ "$rc" -eq 0 ]; then
      return 0
    fi

    case "$err" in
      *xtables*|*lock*|*temporarily\ unavailable*)
        sleep "$delay"
        case "$attempt" in
          1) delay=0.15 ;;
          2) delay=0.20 ;;
          3) delay=0.25 ;;
          4) delay=0.30 ;;
        esac
        attempt=$((attempt + 1))
        continue
        ;;
    esac

    break
  done

  if [ -n "$err" ]; then
    printf '%s\n' "$err" >&2
  fi
  return "$rc"
}

ipt_restore_exec() { # <cmd: iptables|ip6tables> <rules_file>
  local cmd="$1" rules="$2"
  local restore_bin="${cmd}-restore"
  command -v "$restore_bin" >/dev/null 2>&1 || return 1

  local wait_arg=""
  if "$restore_bin" -w 1 < /dev/null >/dev/null 2>&1; then
    wait_arg="-w 5"
  elif "$restore_bin" -w < /dev/null >/dev/null 2>&1; then
    wait_arg="-w"
  fi

  local attempt=1 max_attempts=5 delay=0.1
  local err rc

  while [ "$attempt" -le "$max_attempts" ]; do
    if [ -n "$wait_arg" ]; then
      err=$("$restore_bin" $wait_arg --noflush < "$rules" 2>&1)
      rc=$?
    else
      err=$("$restore_bin" --noflush < "$rules" 2>&1)
      rc=$?
    fi

    if [ "$rc" -eq 0 ]; then
      return 0
    fi

    case "$err" in
      *xtables*|*lock*|*temporarily\ unavailable*)
        sleep "$delay"
        case "$attempt" in
          1) delay=0.15 ;;
          2) delay=0.20 ;;
          3) delay=0.25 ;;
          4) delay=0.30 ;;
        esac
        attempt=$((attempt + 1))
        continue
        ;;
    esac

    break
  done

  if [ -n "$err" ]; then
    printf '%s\n' "$err" >&2
  fi
  return "$rc"
}

detect_limiter() {
  local C="${1:-iptables}"
  local cached
  cached=$(_ipt_cap_cache_get "$C" limiter)
  [ -n "$cached" ] && { printf '%s\n' "$cached"; return 0; }
  if has_ipt_feature $C -m connbytes --connbytes-dir=original --connbytes-mode=packets --connbytes 1:15 -j RETURN; then
    cached=connbytes
  else
    cached=connmark_out
  fi
  _ipt_cap_cache_put "$C" limiter "$cached"
  printf '%s\n' "$cached"
}

has_multiport() {
  local C="$1" cached
  cached=$(_ipt_cap_cache_get "$C" multiport)
  case "$cached" in
    0) return 1 ;;
    1) return 0 ;;
  esac
  has_ipt_feature "$C" -p tcp -m multiport --dports 80,443 -j RETURN
  cached=$?
  if [ "$cached" -eq 0 ]; then
    _ipt_cap_cache_put "$C" multiport 1
  else
    _ipt_cap_cache_put "$C" multiport 0
  fi
  return "$cached"
}

_fw_counter_chain() {
  local CMD="$1" CH="$2" MASK="$3" STEP="$4" LIM="$5" k
  case "$LIM" in ''|*[!0-9]*) LIM=15 ;; esac
  [ "$LIM" -gt 15 ] && LIM=15
  [ "$LIM" -lt 1 ] && LIM=1
  $CMD -w -t mangle -N "$CH" 2>/dev/null
  $CMD -w -t mangle -F "$CH"
  $CMD -w -t mangle -A "$CH" -m connmark --mark $((LIM * STEP))/$MASK -j RETURN
  k=$((LIM - 1))
  while [ "$k" -ge 0 ]; do
    $CMD -w -t mangle -A "$CH" -m connmark --mark $((k * STEP))/$MASK -j CONNMARK --set-xmark $(((k + 1) * STEP))/$MASK
    k=$((k - 1))
  done
  $CMD -w -t mangle -A "$CH" -j NFQUEUE --queue-num $NFQUEUE_NUM --queue-bypass
}

_fw_add_rule() {
  # $1: CMD, $2: CHAIN, $3: IFSPEC (-o / -i), $4: proto (tcp/udp), $5: dir (dports/sports), $6: ports, $7: extra flags, $8: target
  local CMD="$1" CH="$2" IFSPEC="$3" PROTO="$4" DIR="$5" PORTS="$6" EXTRA="$7" TARGET="$8"
  [ -z "$PORTS" ] && return 0

  local applied=0
  if [ "$HAS_MULTIPORT" = "1" ]; then
    if $CMD -w -t mangle -A "$CH" $IFSPEC -p "$PROTO" -m multiport "--$DIR" "$PORTS" $EXTRA $TARGET 2>/dev/null; then
      applied=1
    fi
  fi

  if [ "$applied" = "0" ]; then
    local sdir p
    if [ "$DIR" = "dports" ]; then
      sdir="--dport"
    else
      sdir="--sport"
    fi
    for p in $(printf '%s' "$PORTS" | tr ',' ' '); do
      $CMD -w -t mangle -A "$CH" $IFSPEC -p "$PROTO" $sdir "$p" $EXTRA $TARGET 2>/dev/null
    done
  fi
}

_fw_batch_cmd() {
  local table=mangle original="$*"
  case "$original" in
    *nfqws_test*)
      # run via real command to reflect actual kernel
      "$FW_PROBE_CMD" $original; return $? ;;
  esac
  [ "$1" = "-w" ] && shift
  if [ "$1" = "-t" ]; then table="$2"; shift 2; fi
  case "$1" in
    -D) return 1 ;;
    -I)
      case "$2" in
        POSTROUTING|PREROUTING) return 0 ;;
        *)
          FW_BATCH_BUF="$FW_BATCH_BUF$table|$*
"
          return 0 ;;
      esac
      ;;
    -N|-F|-X|-A)
      FW_BATCH_BUF="$FW_BATCH_BUF$table|$*
"
      return 0 ;;
  esac
  return 1
}

_firewall_start_restore() {
  local CMD="$1" rules
  rules="${FW_RESTORE_DIR}/${CMD}.input"

  command -v "${CMD}-restore" >/dev/null 2>&1 || return 1
  FW_PROBE_CMD="$CMD"
  FW_BATCH_BUF=""
  # use existing builder to populate same rules
  if ! _firewall_start _fw_batch_cmd; then
    FW_PROBE_CMD=""
    FW_BATCH_BUF=""
    return 1
  fi
  FW_PROBE_CMD=""

  printf '%s' "$FW_BATCH_BUF" | awk '
    {
      i = index($0, "|"); t = substr($0, 1, i - 1); line = substr($0, i + 1)
      if (!(t in seen)) { order[++n] = t; seen[t] = 1 }
      if (line ~ /^-N /) {
        ch = substr(line, 4)
        buf[t] = buf[t] ":" ch " - [0:0]\n"
      } else {
        buf[t] = buf[t] line "\n"
      }
    }
    END {
      for (j = 1; j <= n; j++) {
        t = order[j]
        print "*" t
        printf "%s", buf[t]
        print "COMMIT"
      }
    }' > "$rules"
  FW_BATCH_BUF=""

  local rc
  ipt_restore_exec "$CMD" "$rules"
  rc=$?
  rm -f "$rules"

  if [ "$rc" -eq 0 ]; then
    ipt_exec "$CMD" -t mangle -C POSTROUTING -j "$IPT_GROUP_POST" 2>/dev/null || \
      ipt_exec "$CMD" -t mangle -I POSTROUTING 1 -j "$IPT_GROUP_POST"
    ipt_exec "$CMD" -t mangle -C PREROUTING -j "$IPT_GROUP_PRE" 2>/dev/null || \
      ipt_exec "$CMD" -t mangle -I PREROUTING 1 -j "$IPT_GROUP_PRE"
    ipt_exec "$CMD" -t mangle -C POSTROUTING -m mark --mark "$MARK_PROCESSED" -j MARK --set-xmark 0x0/0x40000000 2>/dev/null || \
      ipt_exec "$CMD" -t mangle -I POSTROUTING 2 -m mark --mark "$MARK_PROCESSED" -j MARK --set-xmark 0x0/0x40000000 2>/dev/null
    if [ "$CMD" = "iptables" ]; then
      if [ "$NAT_FIX" = "1" ]; then
        ipt_exec "$CMD" -t nat -C POSTROUTING -j "$IPT_GROUP_NAT" 2>/dev/null || \
          ipt_exec "$CMD" -t nat -I POSTROUTING 1 -j "$IPT_GROUP_NAT"
      fi
    fi
  fi
  return "$rc"
}

_fw_iface_rules() {
  local CMD="$1" REAL_CMD="${FW_PROBE_CMD:-$1}" OUT="$2" IN="$3"
  local UP="$IPT_UDP_EFF" TP="$IPT_TCP_PORTS"

  # don't requeue packets already processed by nfqws2
  $CMD -w -t mangle -A $IPT_GROUP_POST $OUT -m mark --mark $MARK_PROCESSED -j RETURN
  $CMD -w -t mangle -A $IPT_GROUP_PRE $IN -m mark --mark $MARK_PROCESSED -j RETURN

  # outgoing (POSTROUTING)
  [ -n "$UP" ] && _fw_add_rule "$CMD" $IPT_GROUP_POST "$OUT" udp dports "$UP" "" "$TARGET_OUT"
  [ -n "$TP" ] && _fw_add_rule "$CMD" $IPT_GROUP_POST "$OUT" tcp dports "$TP" "" "$TARGET_OUT"

  # FIN/RST go to nfqws for clean conntrack
  if [ -n "$TP" ]; then
    _fw_add_rule "$CMD" $IPT_GROUP_POST "$OUT" tcp dports "$TP" "--tcp-flags fin fin" "$JNFQ"
    _fw_add_rule "$CMD" $IPT_GROUP_POST "$OUT" tcp dports "$TP" "--tcp-flags rst rst" "$JNFQ"
  fi

  # TCP MSS Clamping to mitigate HTTP/2 mid-stream reassembly blocks (TSPU 2026)
  if [ -n "$TCP_MSS_CLAMP" ] && [ "$TCP_MSS_CLAMP" != "0" ]; then
    local mss_val="$TCP_MSS_CLAMP"
    [ "$mss_val" = "1" ] && mss_val=536
    if [ -n "$TP" ]; then
      _fw_add_rule "$CMD" $IPT_GROUP_POST "$OUT" tcp dports "$TP" "--tcp-flags syn,rst syn" "-j TCPMSS --set-mss $mss_val"
    fi
  fi

  # NAT fix for UDP
  if [ "$REAL_CMD" = "iptables" ] && [ "$NAT_FIX" = "1" ]; then
    $CMD -w -t nat -A $IPT_GROUP_NAT $OUT -p udp -m mark --mark $MARK_PROCESSED -j MASQUERADE
  fi

  # incoming (PREROUTING)
  if [ -n "$TP" ]; then
    _fw_add_rule "$CMD" $IPT_GROUP_PRE "$IN" tcp sports "$TP" "--tcp-flags syn,ack syn,ack" "$JNFQ"
    _fw_add_rule "$CMD" $IPT_GROUP_PRE "$IN" tcp sports "$TP" "--tcp-flags fin fin" "$JNFQ"
    _fw_add_rule "$CMD" $IPT_GROUP_PRE "$IN" tcp sports "$TP" "--tcp-flags rst rst" "$JNFQ"
  fi

  # Incoming data flow (connbytes or connmark_in)
  [ -n "$UP" ] && _fw_add_rule "$CMD" $IPT_GROUP_PRE "$IN" udp sports "$UP" "" "$TARGET_IN_UDP"
  [ -n "$TP" ] && _fw_add_rule "$CMD" $IPT_GROUP_PRE "$IN" tcp sports "$TP" "" "$TARGET_IN_TCP"
}

_firewall_start() {
  local CMD="$1" REAL_CMD="${FW_PROBE_CMD:-$1}" IF ex

  local strat_limits
  strat_limits=$(get_strategy_packet_limits "$CONFFILE")
  set -- $strat_limits
  TCP_PKT_OUT="${1:-$PKT_LIMIT_OUT}"
  TCP_PKT_IN="${2:-$PKT_LIMIT_IN}"
  UDP_PKT_OUT="${3:-$PKT_LIMIT_OUT}"
  UDP_PKT_IN="${4:-$PKT_LIMIT_IN}"

  if [ "${AUTO_PORTS:-0}" = "1" ] || [ "$TCP_PORTS" = "auto" ]; then
    local auto_tp
    auto_tp=$(collect_capture_ports tcp)
    IPT_TCP_PORTS="${auto_tp:-80,443}"
  else
    IPT_TCP_PORTS=$(printf '%s' "$TCP_PORTS" | tr '-' ':')
  fi

  if [ "${AUTO_PORTS:-0}" = "1" ] || [ "$UDP_PORTS" = "auto" ]; then
    local auto_up
    auto_up=$(collect_capture_ports udp)
    IPT_UDP_EFF="$auto_up"
  else
    IPT_UDP_EFF=$(printf '%s' "$UDP_PORTS" | tr '-' ':')
  fi
  [ "$BLOCK_QUIC" = "1" ] && IPT_UDP_EFF=$(port_list_without "$IPT_UDP_EFF" 443)
  if [ "$CALLS_BYPASS" = "1" ]; then
    IPT_UDP_EFF=$(port_list_add "$IPT_UDP_EFF" 590:1400 3478:3482)
    IPT_TCP_PORTS=$(port_list_add "$IPT_TCP_PORTS" 5222)
  fi

  LIMITER=$(detect_limiter "$REAL_CMD")
  [ "$REAL_CMD" = "iptables" ] && echo "$LIMITER" > "$STATE_DIR/limiter" 2>/dev/null

  JNFQ="-j NFQUEUE --queue-num $NFQUEUE_NUM --queue-bypass"
  case "$LIMITER" in
    connbytes)
      TARGET_OUT_TCP="-m connbytes --connbytes-dir=original --connbytes-mode=packets --connbytes 1:$TCP_PKT_OUT $JNFQ"
      TARGET_IN_TCP="-m connbytes --connbytes-dir=reply --connbytes-mode=packets --connbytes 1:$TCP_PKT_IN $JNFQ"
      TARGET_OUT_UDP="-m connbytes --connbytes-dir=original --connbytes-mode=packets --connbytes 1:$UDP_PKT_OUT $JNFQ"
      TARGET_IN_UDP="-m connbytes --connbytes-dir=reply --connbytes-mode=packets --connbytes 1:$UDP_PKT_IN $JNFQ"
      TARGET_OUT="$TARGET_OUT_TCP"
      TARGET_IN="$TARGET_IN_TCP"
      ;;
    connmark_out)
      TARGET_OUT_TCP="-j $IPT_GROUP_QOUT"
      TARGET_IN_TCP="-j $IPT_GROUP_QIN"
      TARGET_OUT_UDP="-j $IPT_GROUP_QOUT"
      TARGET_IN_UDP="-j $IPT_GROUP_QIN"
      TARGET_OUT="$TARGET_OUT_TCP"
      TARGET_IN="$TARGET_IN_TCP"
      ;;
  esac

  HAS_MULTIPORT=0
  has_multiport "$REAL_CMD" && HAS_MULTIPORT=1

  $CMD -w -t mangle -N $IPT_GROUP_POST 2>/dev/null
  $CMD -w -t mangle -F $IPT_GROUP_POST
  while $CMD -w -t mangle -D POSTROUTING -j $IPT_GROUP_POST 2>/dev/null; do :; done

  $CMD -w -t mangle -N $IPT_GROUP_PRE 2>/dev/null
  $CMD -w -t mangle -F $IPT_GROUP_PRE
  while $CMD -w -t mangle -D PREROUTING -j $IPT_GROUP_PRE 2>/dev/null; do :; done

  if [ "$LIMITER" = "connmark_out" ]; then
    # one counter chain serves TCP and UDP, and strategies tune the TCP limits:
    # follow them, falling back to the globals inside get_strategy_packet_limits
    _fw_counter_chain "$CMD" $IPT_GROUP_QOUT $CNT_OUT_MASK $CNT_OUT_STEP "$TCP_PKT_OUT"
    _fw_counter_chain "$CMD" $IPT_GROUP_QIN $CNT_IN_MASK $CNT_IN_STEP "$TCP_PKT_IN"
  fi

  if [ "$REAL_CMD" = "iptables" ] && [ "$NAT_FIX" = "1" ]; then
    $CMD -w -t nat -N $IPT_GROUP_NAT 2>/dev/null
    $CMD -w -t nat -F $IPT_GROUP_NAT
    while $CMD -w -t nat -D POSTROUTING -j $IPT_GROUP_NAT 2>/dev/null; do :; done
  fi

  if [ -z "$ISP_INTERFACE" ]; then
    for ex in $IFACE_EXCLUDE; do
      $CMD -w -t mangle -A $IPT_GROUP_POST -o "$ex" -j RETURN
      $CMD -w -t mangle -A $IPT_GROUP_PRE -i "$ex" -j RETURN
    done
  fi

  app_rules "$CMD"

  if [ "$BLOCK_QUIC" = "1" ]; then
    $CMD -w -t mangle -A $IPT_GROUP_POST -p udp --dport 443 -j DROP
  fi

  if [ -n "$ISP_INTERFACE" ]; then
    for IF in $ISP_INTERFACE; do
      _fw_iface_rules "$CMD" "-o $IF" "-i $IF"
    done
  else
    _fw_iface_rules "$CMD" "" ""
  fi

  $CMD -w -t mangle -I POSTROUTING 1 -j $IPT_GROUP_POST
  $CMD -w -t mangle -I PREROUTING 1 -j $IPT_GROUP_PRE
  $CMD -w -t mangle -I POSTROUTING 2 -m mark --mark $MARK_PROCESSED -j MARK --set-xmark 0x0/0x40000000 2>/dev/null || true
  if [ "$REAL_CMD" = "iptables" ] && [ "$NAT_FIX" = "1" ]; then
    $CMD -w -t nat -I POSTROUTING 1 -j $IPT_GROUP_NAT
  fi

  if [ "$ENABLE_HOTSPOT" = "1" ]; then
    $CMD -w -t mangle -N $IPT_GROUP_FWD 2>/dev/null
    $CMD -w -t mangle -F $IPT_GROUP_FWD
    while $CMD -w -t mangle -D FORWARD -j $IPT_GROUP_FWD 2>/dev/null; do :; done

    $CMD -w -t mangle -A $IPT_GROUP_FWD -m mark --mark $MARK_PROCESSED -j RETURN

    if [ "$BLOCK_QUIC" = "1" ]; then
      $CMD -w -t mangle -A $IPT_GROUP_FWD -p udp --dport 443 -j DROP
    fi

    local UP="$IPT_UDP_EFF" TP="$IPT_TCP_PORTS"
    [ -n "$UP" ] && _fw_add_rule "$CMD" $IPT_GROUP_FWD "" udp dports "$UP" "" "$TARGET_OUT_UDP"
    [ -n "$TP" ] && _fw_add_rule "$CMD" $IPT_GROUP_FWD "" tcp dports "$TP" "" "$TARGET_OUT_TCP"
    [ -n "$UP" ] && _fw_add_rule "$CMD" $IPT_GROUP_FWD "" udp sports "$UP" "" "$TARGET_IN_UDP"
    [ -n "$TP" ] && _fw_add_rule "$CMD" $IPT_GROUP_FWD "" tcp sports "$TP" "" "$TARGET_IN_TCP"

    $CMD -w -t mangle -I FORWARD 1 -j $IPT_GROUP_FWD
  fi
}


_firewall_stop_batch() { # <iptables|ip6tables>
  local CMD="$1" t chains in
  if ! command -v "$CMD-save" >/dev/null 2>&1 || ! command -v "$CMD-restore" >/dev/null 2>&1; then
    return 1
  fi
  for t in mangle nat; do
    if [ "$t" = mangle ]; then
      chains="$IPT_GROUP_POST $IPT_GROUP_PRE $IPT_GROUP_FWD $IPT_GROUP_QOUT $IPT_GROUP_QIN $IPT_GROUP_APP"
    else
      [ "$CMD" = iptables ] || continue
      chains="$IPT_GROUP_NAT"
    fi
    in=$("$CMD-save" -t "$t" 2>/dev/null) || return 1
    in=$(printf '%s\n' "$in" | awk -v t="$t" -v list=" $chains " '
      function ours(c) { return index(list, " " c " ") > 0 }
      /^:/ { c = substr($1, 2); if (ours(c)) own[++m] = c; next }
      /^-A / && !ours($2) {
        for (i = 3; i < NF; i++) if ($i == "-j" && ours($(i + 1))) { sub(/^-A /, "-D "); del[++n] = $0; break }
      }
      END {
        if (!n && !m) exit
        print "*" t
        for (i = 1; i <= n; i++) print del[i]
        for (i = 1; i <= m; i++) print "-F " own[i]
        for (i = 1; i <= m; i++) print "-X " own[i]
        print "COMMIT"
      }')
    [ -n "$in" ] || continue
    printf '%s\n' "$in" | "$CMD-restore" --noflush 2>/dev/null || return 1
  done
  return 0
}

_firewall_stop() {
  local CMD="$1"
  while $CMD -w -t mangle -D POSTROUTING -m mark --mark $MARK_PROCESSED -j MARK --set-xmark 0x0/0x40000000 2>/dev/null; do :; done
  _firewall_stop_batch "$CMD" && return 0
  while $CMD -w -t mangle -D POSTROUTING -j $IPT_GROUP_POST 2>/dev/null; do :; done
  while $CMD -w -t mangle -D PREROUTING -j $IPT_GROUP_PRE 2>/dev/null; do :; done
  while $CMD -w -t mangle -D FORWARD -j $IPT_GROUP_FWD 2>/dev/null; do :; done
  $CMD -w -t mangle -F $IPT_GROUP_POST 2>/dev/null; $CMD -w -t mangle -X $IPT_GROUP_POST 2>/dev/null
  $CMD -w -t mangle -F $IPT_GROUP_PRE 2>/dev/null;  $CMD -w -t mangle -X $IPT_GROUP_PRE 2>/dev/null
  $CMD -w -t mangle -F $IPT_GROUP_FWD 2>/dev/null;  $CMD -w -t mangle -X $IPT_GROUP_FWD 2>/dev/null
  $CMD -w -t mangle -F $IPT_GROUP_QOUT 2>/dev/null; $CMD -w -t mangle -X $IPT_GROUP_QOUT 2>/dev/null
  $CMD -w -t mangle -F $IPT_GROUP_QIN 2>/dev/null;  $CMD -w -t mangle -X $IPT_GROUP_QIN 2>/dev/null
  $CMD -w -t mangle -F $IPT_GROUP_APP 2>/dev/null; $CMD -w -t mangle -X $IPT_GROUP_APP 2>/dev/null
  if [ "$CMD" = "iptables" ]; then
    while $CMD -w -t nat -D POSTROUTING -j $IPT_GROUP_NAT 2>/dev/null; do :; done
    $CMD -w -t nat -F $IPT_GROUP_NAT 2>/dev/null; $CMD -w -t nat -X $IPT_GROUP_NAT 2>/dev/null
  fi
  return 0
}

# QUIC к Meta — сразу отказ (ICMP «порт недоступен»), а не молчаливая потеря.
# На мобильных сетях QUIC Instagram проходит обход, но потом встаёт посреди
# ролика, а к cdn.fbsbx.com (картинки и GIF) не проходит вовсе; на молчаливую
# потерю приложение ждёт таймаута. Получив отказ, оно сразу идёт по TCP — как
# за роутером, где провайдер QUIC к Meta не пропускает. Правила в таблице
# filter (REJECT в mangle нельзя), снимаются вместе с остальными.
_meta_quic_chain() { # <iptables|ip6tables> <сети> <reject-with>
  local C="$1" n
  command -v "$C" >/dev/null 2>&1 || return 0
  $C -w -t filter -N $IPT_GROUP_MQ 2>/dev/null || return 0
  n=$(printf '%s' "$2" | tr -s ' ' ',')
  $C -w -t filter -A $IPT_GROUP_MQ -p udp --dport 443 -d "$n" -j REJECT --reject-with "$3" 2>/dev/null || {
    log_msg "$C: no REJECT support — Meta QUIC reject is unavailable"
    $C -w -t filter -F $IPT_GROUP_MQ 2>/dev/null; $C -w -t filter -X $IPT_GROUP_MQ 2>/dev/null
    return 0
  }
  $C -w -t filter -I OUTPUT 1 -j $IPT_GROUP_MQ
  $C -w -t filter -I FORWARD 1 -j $IPT_GROUP_MQ 2>/dev/null
  return 0
}
meta_quic_stop() {
  local C
  for C in iptables ip6tables; do
    command -v "$C" >/dev/null 2>&1 || continue
    while $C -w -t filter -D OUTPUT -j $IPT_GROUP_MQ 2>/dev/null; do :; done
    while $C -w -t filter -D FORWARD -j $IPT_GROUP_MQ 2>/dev/null; do :; done
    $C -w -t filter -F $IPT_GROUP_MQ 2>/dev/null; $C -w -t filter -X $IPT_GROUP_MQ 2>/dev/null
  done
  return 0
}
meta_quic_start() {
  meta_quic_stop
  [ "$META_QUIC_REJECT" = "1" ] || return 0
  _meta_quic_chain iptables "$META_NET4" icmp-port-unreachable
  _meta_quic_chain ip6tables "$META_NET6" icmp6-port-unreachable
}

firewall_iptables()  { _firewall_start iptables; }
firewall_ip6tables() { [ "$IPV6_ENABLED" = "0" ] && return 0; _firewall_start ip6tables; }

firewall_iptables_restore()  { _firewall_start_restore iptables; }
firewall_ip6tables_restore() { [ "$IPV6_ENABLED" = "0" ] && return 0; _firewall_start_restore ip6tables; }

apply_tether_offload() {
  command -v settings >/dev/null 2>&1 || return 0
  if [ "$ENABLE_HOTSPOT" = "1" ]; then
    settings put global tether_offload_disabled 1 2>/dev/null || true
  else
    settings put global tether_offload_disabled 0 2>/dev/null || true
  fi
}

restore_tether_offload() {
  command -v settings >/dev/null 2>&1 || return 0
  settings put global tether_offload_disabled 0 2>/dev/null || true
}

# check both rc: firewall_ip6tables returns 0 when IPv6 is off, masking an iptables failure
firewall_start() {
  local rc=0
  sysctl -w net.netfilter.nf_conntrack_acct=1 >/dev/null 2>&1 ||
    { [ -w /proc/sys/net/netfilter/nf_conntrack_acct ] && echo 1 > /proc/sys/net/netfilter/nf_conntrack_acct 2>/dev/null; }
  FW_RESTORE_DIR="$STATE_DIR/firewall-restore"
  mkdir -p "$FW_RESTORE_DIR" 2>/dev/null
  if command -v iptables-restore >/dev/null 2>&1; then
    firewall_iptables_restore || { firewall_iptables || rc=1; }
  else
    firewall_iptables || rc=1
  fi
  if [ "$IPV6_ENABLED" = "0" ]; then
    :
  elif command -v ip6tables-restore >/dev/null 2>&1; then
    firewall_ip6tables_restore || { firewall_ip6tables || rc=1; }
  else
    firewall_ip6tables || rc=1
  fi
  if [ "$IPV6_ENABLED" = "1" ] && ! _firewall_family_ok ip6tables; then
    # logged on start, not on every watchdog re-apply; the doctor keeps showing it
    [ -f "$DESIRED_FILE" ] || log_msg "Error: ip6tables rules failed to apply — IPv6 traffic is not intercepted"
    rc=1
  fi
  meta_quic_start
  apply_tether_offload
  return $rc
}

_firewall_family_ok() {
  local CMD="$1"
  "$CMD" -w -t mangle -C POSTROUTING -j "$IPT_GROUP_POST" 2>/dev/null || return 1
  "$CMD" -w -t mangle -C PREROUTING -j "$IPT_GROUP_PRE" 2>/dev/null || return 1
  "$CMD" -w -t mangle -S "$IPT_GROUP_POST" 2>/dev/null | grep -qE -- 'NFQUEUE|nfqws_qout' || return 1
  "$CMD" -w -t mangle -S "$IPT_GROUP_PRE" 2>/dev/null | grep -qE -- 'NFQUEUE|nfqws_qin'
}

firewall_stop() {
  local rc=0
  _firewall_stop iptables || rc=1
  _firewall_stop ip6tables || rc=1
  meta_quic_stop
  restore_tether_offload
  return $rc
}

firewall_ok() {
  _firewall_family_ok iptables || return 1
  [ "$IPV6_ENABLED" = "0" ] || _firewall_family_ok ip6tables
}

# Some ROMs freeze the app cgroup the root process started in; move it to the
# root cgroup (v2), which is not frozen. Best-effort.
# -w first: dash reports a redirect open() error before 2>/dev/null applies.
protect_process() {   # $1 - PID; default: current process
  local p="${1:-$$}"
  [ -z "$p" ] && return 0
  [ -d "/proc/$p" ] || return 0
  if [ -w "/proc/$p/oom_score_adj" ] 2>/dev/null; then
    echo -1000 > "/proc/$p/oom_score_adj" 2>/dev/null
  elif [ -w "/proc/$p/oom_adj" ] 2>/dev/null; then
    echo -17 > "/proc/$p/oom_adj" 2>/dev/null
  fi
  if [ -w /sys/fs/cgroup/cgroup.procs ] 2>/dev/null; then
    echo "$p" > /sys/fs/cgroup/cgroup.procs 2>/dev/null
  fi
  if [ -w /dev/cpuset/cgroup.procs ] 2>/dev/null; then
    echo "$p" > /dev/cpuset/cgroup.procs 2>/dev/null
  fi
  if command -v renice >/dev/null 2>&1; then
    renice -n -20 -p "$p" >/dev/null 2>&1 || renice -20 "$p" >/dev/null 2>&1 || true
  fi
  return 0
}

# Partition wakelock blocks deep sleep while the service runs; costs battery, so
# opt-in only (WAKELOCK=1). The name must match the module.prop id exactly or the
# lock is never released (checked by test_data.sh).
acquire_wakelock() {
  [ "$WAKELOCK" = "1" ] || return 0
  [ -w /sys/power/wake_lock ] 2>/dev/null && echo "nfqws2-android" > /sys/power/wake_lock 2>/dev/null
  return 0
}
# release regardless of WAKELOCK: a stale lock is never freed otherwise
release_wakelock() {
  [ -w /sys/power/wake_unlock ] 2>/dev/null || return 0
  echo "nfqws2-android" > /sys/power/wake_unlock 2>/dev/null
  return 0
}

system_config() {
  sysctl -w net.netfilter.nf_conntrack_checksum=0 >/dev/null 2>&1
  sysctl -w net.netfilter.nf_conntrack_tcp_be_liberal=1 >/dev/null 2>&1
  sysctl -w net.ipv4.tcp_timestamps=1 >/dev/null 2>&1 || {
    [ -w /proc/sys/net/ipv4/tcp_timestamps ] && echo 1 > /proc/sys/net/ipv4/tcp_timestamps 2>/dev/null
  }
  sysctl -w net.core.rmem_max=8388608 >/dev/null 2>&1
  sysctl -w net.core.wmem_max=8388608 >/dev/null 2>&1
  sysctl -w net.core.rmem_default=2097152 >/dev/null 2>&1
  sysctl -w net.core.netdev_max_backlog=16384 >/dev/null 2>&1

  # Idle TCP connection lifetime in conntrack: do not shorten.
  # Previously set to 1200s (router value), but an Android phone is not a router:
  # Google push notifications (mtalk.google.com) heartbeat is up to 28 minutes.
  # A 20-minute timeout expired idle connections and caused bursty/delayed push notifications.
  # If previously shortened below 7200s, restore to kernel default (432000s).
  local cur_max cur_est
  cur_max=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null)
  cur_est=$(sysctl -n net.netfilter.nf_conntrack_tcp_timeout_established 2>/dev/null)
  if [ -n "$cur_est" ] && [ "$cur_est" -lt 7200 ] 2>/dev/null; then
    log_msg "conntrack: nf_conntrack_tcp_timeout_established was $cur_est, restoring 432000 (kernel default): short timeout breaks push notifications"
    sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=432000 >/dev/null 2>&1
  fi
  if [ -n "$cur_max" ] && [ "$cur_max" -lt 16384 ] 2>/dev/null; then
    log_msg "conntrack: nf_conntrack_max was $cur_max, raising to 16384 (reference router value)"
    sysctl -w net.netfilter.nf_conntrack_max=16384 >/dev/null 2>&1
  fi
  setup_cli_symlinks
  return 0
}

setup_cli_symlinks() {
  local p
  for p in /data/adb/ap/bin /data/adb/ksu/bin; do
    if [ -d "$p" ]; then
      ln -sf "$MODDIR/bin/nfqws2-ctl" "$p/nfqws2-ctl" 2>/dev/null
    fi
  done
  return 0
}

# ---------------------------------------------------------------- batch config import
# A keenetic config has at least 2 key variables.
is_keenetic_config() {
  local f="$1" n
  [ -f "$f" ] || return 1
  n=$(grep -cE '^[[:space:]]*(NFQWS_BASE_ARGS|NFQWS_ARGS|NFQWS_ARGS_QUIC|NFQWS_ARGS_UDP|NFQWS_EXTRA_ARGS|NFQWS_ARGS_IPSET|ISP_INTERFACE|TCP_PORTS)=' "$f" 2>/dev/null)
  [ "${n:-0}" -ge 2 ]
}

import_safe_name() {
  # strip only shell/path-dangerous bytes; they are single-byte ASCII, so
  # multibyte names (Cyrillic etc.) survive
  printf '%s' "$1" | tr -d '/\\`$"'"'" | tr -d '\n\r\t' | sed -e 's/^[[:space:].]*//' -e 's/[[:space:]]*$//' | cut -c1-200
}

list_imports() {
  local f
  for f in "$IMPORTS_DIR"/*.conf; do
    [ -f "$f" ] || continue
    basename "$f" .conf
  done | sort
}

# Keys defining the bypass itself; the rest are module settings, identical for
# all strategies and taken from the live config on switch (see USER_KEYS).
STRATEGY_KEYS="NFQWS_BASE_ARGS NFQWS_ARGS NFQWS_ARGS_QUIC NFQWS_ARGS_UDP NFQWS_ARGS_IPSET NFQWS_ARGS_CUSTOM"

# Unsupported long options in a file, one per line, checked against the binary
# (option names are strings in it); if the binary isn't nfqws2 (no "lua-desync"),
# nothing is stripped.
unsupported_opts() { # <file>
  local n
  if ! grep -qF lua-desync "$NFQWS_BIN" 2>/dev/null || ! grep -qF filter-tcp "$NFQWS_BIN" 2>/dev/null; then
    return 0
  fi
  grep -v '^[[:space:]]*#' "$1" 2>/dev/null | grep -oE -e '(^|[[:space:]"])--[A-Za-z0-9][A-Za-z0-9-]*' | sed 's/^.*--//' | sort -u |
  while IFS= read -r n; do
    ! grep -qF -e "$n" "$NFQWS_BIN" 2>/dev/null && echo "$n"
  done
}

# Remove listed --name[=value] options from a config, merging orphaned quotes and
# line continuations so the file looks as if the option was never there.
strip_opts() { # <space-separated names>  stdin -> stdout
  awk -v bad=" $1 " '
    function emit(l) { if (have) print prev; prev = l; have = 1 }
    {
      s = $0; out = ""; cut = 0
      while (match(s, /(^|[[:space:]"])--[A-Za-z0-9][A-Za-z0-9-]*(=[^[:space:]"]*)?/)) {
        tok = substr(s, RSTART, RLENGTH); lead = ""
        if (substr(tok, 1, 2) != "--") { lead = substr(tok, 1, 1); tok = substr(tok, 2) }
        name = substr(tok, 3); sub(/=.*/, "", name)
        pre = substr(s, 1, RSTART - 1); s = substr(s, RSTART + RLENGTH)
        if (index(bad, " " name " ")) {
          cut = 1
          # no space needed before the option if one follows it
          if (lead ~ /[[:space:]]/ && s ~ /^[[:space:]]/) lead = ""
          out = out pre lead
        } else out = out pre lead tok
      }
      out = out s
      if (!cut) {
        if (join) { sub(/^[[:space:]]+/, "", out); out = held out; join = 0 }
        emit(out); next
      }
      sub(/[[:space:]]+$/, "", out); sub(/[[:space:]]+"/, "\"", out)
      if (join) { sub(/^[[:space:]]+/, "", out); out = held out; join = 0 }
      if (out ~ /^[[:space:]]*$/) next
      if (out ~ /^[[:space:]]*"$/ && have) { prev = prev "\""; next }
      if (out ~ /="$/) { held = out; join = 1; next }
      emit(out)
    }
    END { if (join) emit(held); if (have) print prev }'
}

# Convert an imported keenetic config into strategy format: defaults/nfqws2.conf
# skeleton, only STRATEGY_KEYS and their own variables from the import, paths
# rewritten, unsupported options stripped. A missing key stays empty, not
# inherited. Idempotent.
normalize_import() { # <import file> -> stdout
  local src="$1" clean="$STATE_DIR/import_norm.$$"
  [ -f "$src" ] || return 1
  tr -d '\r' < "$src" | rewrite_keenetic_paths refs > "$clean"
  local bad
  bad=$(unsupported_opts "$clean" | tr '\n' ' ')
  if [ -n "$bad" ]; then strip_opts "$bad" < "$clean" > "$clean.s" && mv -f "$clean.s" "$clean"; fi
  awk -v skeys=" $STRATEGY_KEYS " -v tpl="$MODDIR/defaults/nfqws2.conf" '
    function quotes(str,   t) { t = str; return gsub(/"/, "", t) }
    function keyof(line) { return match(line, /^[A-Za-z_][A-Za-z0-9_]*=/) ? substr(line, 1, RLENGTH - 1) : "" }
    # read file into KEY=blocks (values may span lines)
    function load(file, blk, ord,   line, k, cur, inval, n) {
      n = 0; inval = 0; cur = ""
      while ((getline line < file) > 0) {
        if (inval) { blk[cur] = blk[cur] "\n" line; if (quotes(line) % 2 == 1) inval = 0; continue }
        k = keyof(line)
        if (k == "") { if (file == tpl) { ord[++n] = "\001" line } continue }
        cur = k; blk[k] = line; ord[++n] = k
        if (quotes(line) % 2 == 1) inval = 1
      }
      close(file)
      return n
    }
    BEGIN {
      ni = load(ARGV[1], imp, iord)
      nt = load(tpl, tblk, tord)
      for (i = 1; i <= nt; i++) if (substr(tord[i], 1, 1) != "\001") intpl[tord[i]] = 1
      skip["ISP_INTERFACE"]; skip["USER"]; skip["POLICY_NAME"]; skip["POLICY_EXCLUDE"]; skip["LOG_DEBUG_PATH"]
      first = 1
      for (i = 1; i <= nt; i++) {
        k = tord[i]
        if (substr(k, 1, 1) == "\001") { print substr(k, 2); continue }
        if (index(skeys, " " k " ")) {
          # own variables of the import must precede bypass keys using them
          if (first) {
            for (j = 1; j <= ni; j++) { e = iord[j]
              if (!(e in intpl) && !(e in skip) && !(e in done)) { print imp[e]; print ""; done[e] = 1 } }
            first = 0
          }
          print ((k in imp) ? imp[k] : k "=\"\"")
        } else {
          print tblk[k]
        }
      }
      exit
    }' "$clean"
  rm -f "$clean"
}

# Import preview for the editor: strategy + settings from the live config
render_import_merged() {
  local raw="$STATE_DIR/import_prev.$$"
  normalize_import "$1" > "$raw" || { rm -f "$raw"; return 1; }
  if [ -f "$CONFFILE" ]; then merge_user_keys "$raw" "$CONFFILE"; else cat "$raw"; fi
  rm -f "$raw"
}

# ---------------------------------------------------------------- service output language
# WebUI-shown content strings follow NFQWS_LANG; service logs stay Russian.
M() { if [ "$NFQWS_LANG" = "en" ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }

# ---------------------------------------------------------------- status in module.prop
# Managers (Magisk, KernelSU, APatch) show description in the module list,
# so write live state there following the bindhosts standard:
# status: <state> <emoji> | <key>: <value> <emoji> | ...
# Flash wear protection: skip disk writes if description line is already identical.
# cat > (not mv) keeps module.prop inode, owner and mode.
current_mode() {
  awk '/^NFQWS_EXTRA_ARGS=/ { if (match($0, /MODE_[A-Z]*/)) print tolower(substr($0, RSTART + 5, RLENGTH - 5)); exit }' "$CONFFILE" 2>/dev/null
}
update_description() { # running | stopped | paused <reason> | failed <msg> | disabled | ready
  local prop="$MODDIR/module.prop" d strat strat_icon mode tmp cur err
  if [ ! -f "$prop" ] || [ ! -w "$prop" ]; then return 0; fi
  case "$1" in
    running)
      strat=$(cat "$ACTIVE_FILE" 2>/dev/null); strat="${strat#imp:}"
      [ -n "$strat" ] || strat="default"
      if [ "$strat" = "smart" ] || smart_active 2>/dev/null; then
        strat_icon="🧠"
      else
        strat_icon="🎯"
      fi
      mode=$(current_mode)
      [ -n "$mode" ] || mode="auto"
      d="status: active ✅ | strategy: $strat $strat_icon | mode: $mode 🌐"
      ;;
    paused)
      case "$2" in
        @vpn|vpn|VPN) d="status: paused ⏸️ | VPN 🛡️" ;;
        @wl)          d="status: paused ⏸️ | Whitelist ⚪" ;;
        "")           d="status: paused ⏸️" ;;
        *)            d="status: paused ⏸️ | Wi-Fi: $2 📶" ;;
      esac
      ;;
    failed)
      err="${2:-startup error}"
      err=$(printf '%s' "$err" | tr '\\' '/' | tr '\n\r' ' ' | sed -e 's/^[Ee]rror: //' -e 's/^[Ee]rror //' -e 's/^[ ]*//' -e 's/[ ]*$//')
      err=$(printf '%s' "$err" | cut -c 1-50)
      d="status: failed ❌ | $err"
      ;;
    disabled)
      d="status: disabled ❌"
      ;;
    ready)
      d="status: ready 🚀"
      ;;
    stopped)
      d="status: stopped ⛔"
      ;;
    *)
      d="status: stopped ⛔"
      ;;
  esac

  # Flash wear protection: skip disk writes if description line is already identical
  cur=$(grep "^description=" "$prop" 2>/dev/null | tr -d '\r')
  d=$(printf '%s' "$d" | tr -d '\r\n')
  [ "$cur" = "description=$d" ] && return 0

  tmp="$STATE_DIR/module.prop.$$"
  [ -d "$STATE_DIR" ] || tmp="$prop.tmp.$$"
  awk -v d="$d" 'BEGIN { done = 0 } /^description=/ { print "description=" d; done = 1; next } { print }
    END { if (!done) print "description=" d }' "$prop" > "$tmp" 2>/dev/null && cat "$tmp" > "$prop"
  rm -f "$tmp"
  return 0
}

# ---------------------------------------------------------------- strategies
# Built-in strategies ship in the module; a user edit under the same name in
# $USER_STRATEGIES_DIR overrides it. Reset = delete that copy.
# Imported configs are selectable as "imp:<name>".
get_current_strategy() {
  local s
  s=$(head -n1 "$ACTIVE_FILE" 2>/dev/null | tr -d '\r\n')
  if [ -n "$s" ]; then
    printf '%s\n' "$s"
  else
    echo "default"
  fi
}
strategy_name_ok() {
  case "$1" in ''|*/*|*'`'*|*'$'*|*'"'*|*\'*|*'\'*|.*) return 1 ;; esac
  return 0
}
strategy_builtin_file() { [ -f "$STRATEGIES_DIR/$1.conf" ] && printf '%s' "$STRATEGIES_DIR/$1.conf"; }
strategy_file() { # effective strategy file: user edit first, else built-in
  case "$1" in
    imp:*) [ -f "$IMPORTS_DIR/${1#imp:}.conf" ] && printf '%s' "$IMPORTS_DIR/${1#imp:}.conf" ;;
    *) if [ -f "$USER_STRATEGIES_DIR/$1.conf" ]; then printf '%s' "$USER_STRATEGIES_DIR/$1.conf"
       else strategy_builtin_file "$1"; fi ;;
  esac
}
# 0: built-in strategy was edited and differs from the original
strategy_modified() {
  local b
  b=$(strategy_builtin_file "$1") || return 1
  [ -f "$USER_STRATEGIES_DIR/$1.conf" ] || return 1
  ! cmp -s "$b" "$USER_STRATEGIES_DIR/$1.conf"
}

# Strategy config as set-strategy writes it, before carrying over user settings.
render_strategy() {
  local f
  case "$1" in
    ''|default) cat "$MODDIR/defaults/nfqws2.conf" ;;
    imp:*) f=$(strategy_file "$1") || return 1; normalize_import "$f" ;;
    *) f=$(strategy_file "$1") || return 1
       rewrite_keenetic_paths < "$f" \
         | sed -e 's#^[[:space:]]*ISP_INTERFACE=.*#ISP_INTERFACE=""#' \
               -e 's#^[[:space:]]*USER=.*#NFQWS_USER=root#' ;;
  esac
}

# Module settings (same across strategies) are carried over whole from the live
# config on strategy change/reset. NFQWS_EXTRA_ARGS only for standard $MODE_* refs.
USER_KEYS="META_QUIC_REJECT CALLS_BYPASS TCP_MSS_CLAMP IPV6_ENABLED TCP_PORTS UDP_PORTS NFQUEUE_NUM PKT_LIMIT_OUT PKT_LIMIT_IN BLOCK_QUIC NAT_FIX APP_MODE AUTOSTART WATCHDOG NFQWS_USER LOG_LEVEL LOG_MAX_KB WAKELOCK HOME_WIFI ENABLE_HOTSPOT NET_STRATEGY VPN_PAUSE AUTO_PORTS WL_PAUSE SMART_LEARN NFQWS_EXTRA_ARGS"
merge_user_keys() { # <generated config> <settings source config>  -> stdout
  awk -v keys=" $USER_KEYS " -v src="$2" '
    function quotes(str,   t) { t = str; return gsub(/"/, "", t) }
    function keyof(line) { return match(line, /^[A-Za-z_][A-Za-z0-9_]*=/) ? substr(line, 1, RLENGTH - 1) : "" }
    BEGIN {
      while ((getline line < src) > 0) {
        k = keyof(line)
        if (k == "" || !index(keys, " " k " ") || quotes(line) % 2 == 1 || (k in keep)) continue
        if (k != "NFQWS_EXTRA_ARGS" || line ~ /^NFQWS_EXTRA_ARGS="?\$MODE_(LIST|AUTO|ALL)"?[ \t]*$/) keep[k] = line
      }
      close(src)
    }
    skip { if (quotes($0) % 2 == 1) skip = 0; next }
    {
      k = keyof($0)
      if (k != "" && (k in keep) && !(k in done)) {
        print keep[k]; done[k] = 1
        if (quotes($0) % 2 == 1) skip = 1
        next
      }
      print
    }
    END {
      hdr = 0
      for (k in keep) {
        if (!(k in done)) {
          if (!hdr) { print ""; print "# ---- Настройки Android"; hdr = 1 }
          print keep[k]
        }
      }
    }' "$1"
}

# ---------------------------------------------------------------- home Wi-Fi
# Current SSID, rc 1 if not on Wi-Fi. cmd wifi needs Android 11; dumpsys is the fallback.
current_ssid() {
  local out s
  out=$(cmd wifi status </dev/null 2>/dev/null)   # без stdin: cmd иначе может ждать ввода
  case "$out" in
    *"Wifi is "*)
      # cmd wifi отвечает — ему и верим: нет «connected to» значит не подключено.
      # Раньше тут откатывались к dumpsys wifi, а в нём лежит история недавних
      # состояний: сразу после ухода из дома первой находилась старая запись о
      # домашней сети, и пауза оставалась на мобильном интернете.
      s=$(printf '%s\n' "$out" | sed -n 's/^Wifi is connected to "\(.*\)"[[:space:]]*$/\1/p' | head -n1) ;;
    *)
      # старые Android без cmd wifi status
      s=$(dumpsys wifi 2>/dev/null | grep -m1 'mWifiInfo SSID: .*Supplicant state: COMPLETED' \
          | sed -e 's/.*mWifiInfo SSID: //' -e 's/, BSSID:.*//' -e 's/^"\(.*\)"$/\1/') ;;
  esac
  case "$s" in ''|'<unknown ssid>'|'<none>'|0x) return 1 ;; esac
  printf '%s' "$s"
}
ssid_is_home() {
  if [ -z "$1" ] || [ ! -f "$HOME_FILE" ]; then return 1; fi
  grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$HOME_FILE" 2>/dev/null | grep -Fxq -- "$1"
}

wifi_is_default() {
  local r
  r=$(dumpsys connectivity 2>/dev/null | awk '
    /^ *Active default network:/ { act = $NF; seen = 1 }
    /NetworkAgentInfo/ && match($0, /network\{[0-9]+\}/) {
      id = substr($0, RSTART + 8, RLENGTH - 9)
      if (!(id in kind)) kind[id] = ($0 ~ /ni\{WIFI/ || $0 ~ /Transports: [A-Z|]*WIFI/ || $0 ~ /InterfaceName: wlan/) ? "wifi" : "other"
    }
    END {
      if (!seen) print "unknown"
      else if (act == "none" || act == "null") print "none"
      else if (act in kind) print kind[act]
      else print "unknown"
    }')
  case "$r" in wifi|unknown) return 0 ;; *) return 1 ;; esac
}

active_ssid() {
  local s
  s=$(current_ssid) || return 1
  wifi_is_default || return 1
  printf '%s' "$s"
}

# Mobile operator whitelist detection: Russian mobile carriers sometimes enforce
# whitelists where foreign non-blocked sites cannot connect, while Russian sites do.
WL_FOREIGN="github.com www.microsoft.com www.apple.com www.wikipedia.org www.cloudflare.com"
WL_ALLOWED="ya.ru vk.com www.gosuslugi.ru mail.ru"
wl_probe() {
  command -v curl >/dev/null 2>&1 || { echo unknown; return 0; }
  local d="$STATE_DIR/wlprobe.$$" h f=0 w=0
  rm -rf "$d"; mkdir -p "$d" || { echo unknown; return 0; }
  for h in $WL_FOREIGN; do
    ( curl -s -k -o /dev/null -m 6 --connect-timeout 5 -w '%{time_connect}' "https://$h/" > "$d/f.$h" 2>/dev/null ) &
  done
  for h in $WL_ALLOWED; do
    ( curl -s -k -o /dev/null -m 6 --connect-timeout 5 -w '%{time_connect}' "https://$h/" > "$d/w.$h" 2>/dev/null ) &
  done
  wait
  for h in "$d"/f.*; do awk '{ exit !($1 + 0 > 0) }' "$h" 2>/dev/null && f=$((f + 1)); done
  for h in "$d"/w.*; do awk '{ exit !($1 + 0 > 0) }' "$h" 2>/dev/null && w=$((w + 1)); done
  rm -rf "$d"
  if [ "$f" -ge 2 ]; then echo normal
  elif [ "$f" = 0 ] && [ "$w" -ge 2 ]; then echo whitelist
  elif [ "$f" = 0 ] && [ "$w" = 0 ]; then echo offline
  else echo partial; fi
}

on_wifi() {
  local d n="${NFQWS_SYSNET:-/sys/class/net}"
  for d in "$n"/wlan*; do
    [ "$(cat "$d/operstate" 2>/dev/null)" = up ] && return 0
  done
  return 1
}

# ── Умный режим ──────────────────────────────────────────────────────────
# Стратегия с оркестратором smart (lua/zapret-smart.lua) учится, какой вариант
# обхода работает для сайта, и запоминает это для каждой сети отдельно. Модуль
# говорит ей, в какой сети телефон, и есть ли сеть вообще.
smart_active() { case "$NFQWS_BASE_ARGS" in *zapret-smart.lua*) return 0 ;; esac; return 1; }

# id и подпись сети: Wi‑Fi — по SSID, мобильная — по коду оператора. Нет
# маршрута наружу — сети нет (offline): отказы тогда не считаются
smart_net_id() {
  local dev ssid op name
  dev=$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}')
  if [ -z "$dev" ]; then printf 'offline\t'; return 0; fi
  if on_wifi && ssid=$(active_ssid) && [ -n "$ssid" ]; then
    printf 'wifi-%s\t%s' "$(printf '%s' "$ssid" | cksum | cut -d' ' -f1)" "$ssid"
    return 0
  fi
  case "$dev" in wlan*) printf 'wifi\tWi‑Fi'; return 0 ;; esac
  op=$(getprop gsm.operator.numeric 2>/dev/null); op=${op%%,*}
  name=$(getprop gsm.operator.alpha 2>/dev/null); name=${name%%,*}
  case "$op" in
    ''|*[!0-9]*) printf 'mobile\t%s' "${name:-mobile}" ;;
    *) printf 'mobile-%s\t%s' "$op" "${name:-$op}" ;;
  esac
}

smart_net_update() {
  mkdir -p "$SMART_DIR" "$STATE_DIR" 2>/dev/null
  local line id label
  line=$(smart_net_id); id=${line%%	*}; label=${line#*	}
  [ "$id" = "$(cat "$SMART_NET_FILE" 2>/dev/null)" ] || printf '%s\n' "$id" > "$SMART_NET_FILE"
  [ "$id" = offline ] && return 0
  # подпись сети для WebUI — один раз
  grep -q "^$id	" "$SMART_DIR/nets.tsv" 2>/dev/null || printf '%s\t%s\n' "$id" "$label" >> "$SMART_DIR/nets.tsv"
  return 0
}

# ---------------------------------------------------------------- VPN pause
# Returns 0 if an active VPN interface is up (tun+, wg+, ppp+, tap+, tailscale+)
vpn_active() {
  local dev flags
  local n="${NFQWS_SYSNET:-/sys/class/net}"
  for dev in "$n"/tun* "$n"/wg* "$n"/ppp* "$n"/ipsec* "$n"/tap* "$n"/tailscale*; do
    [ -d "$dev" ] || continue
    flags=$(cat "$dev/flags" 2>/dev/null)
    if [ -n "$flags" ]; then
      case "$flags" in
        0x*) [ $(( flags & 1 )) -eq 1 ] && return 0 ;;
        *)   [ $(( flags & 1 )) -eq 1 ] 2>/dev/null && return 0 ;;
      esac
    elif [ -f "$dev/operstate" ] && [ "$(cat "$dev/operstate" 2>/dev/null)" != "down" ]; then
      return 0
    fi
  done
  if command -v ip >/dev/null 2>&1; then
    ip link show 2>/dev/null | grep -Eq ':[[:space:]]*(tun|wg|ppp|ipsec|tap|tailscale)[0-9]*[ :].*<[A-Z0-9_,]*UP' && return 0
  fi
  return 1
}

# ---------------------------------------------------------------- network strategy caching
_raw_network_id() {
  local ssid op
  if ssid=$(current_ssid 2>/dev/null) && [ -n "$ssid" ]; then
    printf 'wifi:%s' "$ssid"
    return 0
  fi
  op=$(getprop gsm.operator.alpha 2>/dev/null | cut -d',' -f1 | tr -d '\r\n')
  [ -z "$op" ] && op=$(getprop gsm.sim.operator.alpha 2>/dev/null | cut -d',' -f1 | tr -d '\r\n')
  if [ -n "$op" ]; then
    printf 'cell:%s' "$op"
  else
    printf 'cellular'
  fi
  return 0
}

current_network_key() {
  local raw kind val safe hex
  raw=$(_raw_network_id)
  case "$raw" in
    wifi:*|cell:*)
      kind="${raw%%:*}"
      val="${raw#*:}"
      safe=$(printf '%s' "$val" | tr -c 'a-zA-Z0-9._-' '_')
      if [ "$safe" != "$val" ]; then
        hex=$(printf '%s' "$val" | od -An -tx1 2>/dev/null | tr -d ' \n')
        printf '%s_%s_%s' "$kind" "$safe" "$hex"
      else
        printf '%s_%s' "$kind" "$safe"
      fi
      ;;
    *) printf 'cellular' ;;
  esac
  return 0
}

current_network_title() {
  local raw
  raw=$(_raw_network_id)
  case "$raw" in
    wifi:*) printf 'Wi-Fi «%s»' "${raw#wifi:}" ;;
    cell:*) printf 'Mobile network (%s)' "${raw#cell:}" ;;
    *)      printf 'Mobile network' ;;
  esac
  return 0
}

save_net_strategy() { # <strategy_name> [net_key]
  local strat="$1" key="${2:-$(current_network_key 2>/dev/null)}" title
  if [ -z "$strat" ] || [ -z "$key" ]; then
    return 1
  fi
  [ -d "$NET_STRATEGIES_DIR" ] || mkdir -p "$NET_STRATEGIES_DIR" 2>/dev/null
  printf '%s\n' "$strat" > "$NET_STRATEGIES_DIR/$key"
  title=$(current_network_title 2>/dev/null)
  [ -n "$title" ] && printf '%s\n' "$title" > "$NET_STRATEGIES_DIR/$key.title"
  return 0
}

load_net_strategy() { # [net_key] -> prints strategy name
  local key="${1:-$(current_network_key 2>/dev/null)}"
  [ -f "$NET_STRATEGIES_DIR/$key" ] || return 1
  local s
  s=$(head -n1 "$NET_STRATEGIES_DIR/$key" 2>/dev/null | tr -d '\r\n')
  [ -n "$s" ] || return 1
  printf '%s' "$s"
}

list_net_strategies() {
  local f key strat title
  for f in "$NET_STRATEGIES_DIR"/*; do
    [ -f "$f" ] || continue
    case "$f" in *.title) continue ;; esac
    key="${f##*/}"
    strat=$(head -n1 "$f" 2>/dev/null | tr -d '\r\n')
    title=""
    [ -f "$f.title" ] && title=$(head -n1 "$f.title" 2>/dev/null | tr -d '\r\n')
    [ -n "$title" ] || title="$key"
    printf '%s\t%s\t%s\n' "$key" "$strat" "$title"
  done
}

clear_net_strategies() {
  rm -rf "$NET_STRATEGIES_DIR"/* 2>/dev/null
}
