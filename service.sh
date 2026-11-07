#!/system/bin/sh

MODDIR="${0%/*}"
case "$MODDIR" in /*) ;; *) MODDIR="$(cd "$MODDIR" 2>/dev/null && pwd)" ;; esac
umask 077
. "$MODDIR/lib/common.sh"
load_conf

STARTED_FILE="$STATE_DIR/started_at"
STARTED_CS_FILE="$STATE_DIR/started_cs"

wait_for_process() { # <pid> <expected state: up|down> <timeout in 50 ms ticks>
  local pid="$1" want="$2" ticks="${3:-24}" i=0 alive
  while [ "$i" -lt "$ticks" ]; do
    kill -0 "$pid" 2>/dev/null
    alive=$?
    if [ "$want" = "up" ] && [ "$alive" -eq 0 ]; then return 0; fi
    if [ "$want" = "down" ] && [ "$alive" -ne 0 ]; then return 0; fi
    sleep 0.05
    i=$((i + 1))
  done
  [ "$want" = "up" ] && kill -0 "$pid" 2>/dev/null
  [ "$want" = "down" ] && ! kill -0 "$pid" 2>/dev/null
}

# both start() failures end with the log tail; keep it in one place
start_failed() {
  log_msg "$1"
  log_msg "Last log lines:"
  tail -n 8 "$NFQWS_LOG" 2>/dev/null | while IFS= read -r l; do log_msg "  $l"; done
  update_description failed "$1"
  firewall_stop
}

# watchdog/netwatch: auto-restart, home Wi-Fi pause, VPN pause, whitelist pause, per-network strategies
wl_wanted() { [ "$WL_PAUSE" = "1" ] && { [ -f "$DESIRED_FILE" ] || [ -f "$HOME_PAUSED_FILE" ]; }; }
watchers_wanted() {
  { [ -f "$DESIRED_FILE" ] && { [ "$WATCHDOG" = "1" ] || smart_active; }; } || [ "$HOME_WIFI" = "1" ] || [ "$NET_STRATEGY" = "1" ] || [ "$VPN_PAUSE" = "1" ] || [ "$WL_PAUSE" = "1" ];
}

# One start/replace at a time. A lock older than two minutes was left by a
# crashed run; home_check() uses the same rule for its own lock. A waiter stays
# for up to 15 s: a watchdog auto-restart holds the lock for seconds on a slow
# device, and failing the user's command meanwhile would be wrong.
svc_lock_dir() { printf '%s/service.lock' "$STATE_DIR"; }
svc_lock_acquire() { # [max ticks of 0.2s]
  local lock i=0 max="${1:-75}"
  lock=$(svc_lock_dir)
  [ -n "$(find "$lock" -maxdepth 0 -mmin +2 2>/dev/null)" ] && rmdir "$lock" 2>/dev/null
  while :; do
    mkdir "$lock" 2>/dev/null && return 0
    i=$((i + 1))
    [ "$i" -ge "$max" ] && return 1
    sleep 0.2
  done
}
svc_lock_release() { rmdir "$(svc_lock_dir)" 2>/dev/null; }

start() {
  if is_running; then
    echo "Служба nfqws2 уже запущена (PID $(cat "$PIDFILE"))"
    return 0
  fi

  # replace_daemon() holds the same lock and calls start() to bring the new
  # process up; SVC_LOCK_HELD keeps start() from taking it a second time.
  local own_lock=1
  if [ "${SVC_LOCK_HELD:-0}" = "1" ]; then
    own_lock=0
  elif ! svc_lock_acquire; then
    log_msg "start: another start/replace holds $(svc_lock_dir) — nothing started"
    echo "Другой запуск уже выполняется" >&2
    return 1
  elif is_running; then
    # while we waited for the lock another operation brought the daemon up
    svc_lock_release
    echo "Служба nfqws2 уже запущена (PID $(cat "$PIDFILE" 2>/dev/null))"
    return 0
  fi

  _start_internal() {
    if [ ! -x "$NFQWS_BIN" ]; then
      chmod 0755 "$NFQWS_BIN" 2>/dev/null
      [ -x "$NFQWS_BIN" ] || { log_msg "Error: executable $NFQWS_BIN not found"; return 1; }
    fi
    local err
    err=$(validate_args_conf) || { log_msg "${err:-Error: arguments validation failed}"; return 1; }
    err=$(validate_strategy_blob_references "$CONFFILE") || { log_msg "${err:-Error: strategy blob or script file validation failed}"; return 1; }

    log_msg "Starting nfqws2..."
    kernel_modules
    rotate_logs start
    ensure_eol "$LISTS_DIR/auto.list"

    local args
    args=$(_startup_args)
    printf '%s\n' "$args" > "$ARGS_FILE"
    smart_net_update

    local dry_err
    if ! dry_err=$(dry_run_check "$args"); then
      log_msg "Error: nfqws2 --dry-run check failed"
      printf '%s\n' "$dry_err" >> "$NFQWS_LOG"
      start_failed "Error: nfqws2 startup parameters invalid (--dry-run check rejected)."
      return 1
    fi
    if [ -f "$SK_PIDFILE" ]; then
      kill -KILL "$(cat "$SK_PIDFILE" 2>/dev/null)" 2>/dev/null
      rm -f "$SK_PIDFILE"
      smartkill_chain del
    fi
    save_strategy_receipt "$CONFFILE" 2>/dev/null || true
    export Z2K_ORCHESTRA_FILE="$ORCHESTRA_MEMORY_FILE"
    cd "$MODDIR/bin" || return 1
    set -f

    # built-in --daemon: nfqws2 reparents to init and writes its PID to $PIDFILE
    rm -f "$PIDFILE"
    "$NFQWS_BIN" --daemon --pidfile="$PIDFILE" $args >> "$NFQWS_LOG" 2>&1
    local res=$?
    set +f

    if [ "$res" -ne 0 ]; then
      start_failed "Error: nfqws2 exited with code $res."
      return 1
    fi

    local pid=""
    [ -f "$PIDFILE" ] && pid=$(cat "$PIDFILE" 2>/dev/null)
    # a stray nfqws2 of another module must not be adopted as ours
    [ -n "$pid" ] || pid=$(our_pids | head -n 1)

    if [ -z "$pid" ] || ! wait_for_process "$pid" up 24; then
      start_failed "Error: nfqws2 failed to start."
      return 1
    fi

    echo "$pid" > "$PIDFILE"
    protect_process "$pid"
    date +%s > "$STARTED_FILE"
    awk '{ printf "%d\n", $1 * 100 }' /proc/uptime > "$STARTED_CS_FILE" 2>/dev/null

    # A successful command status alone does not prove both traffic hooks exist.
    if ! firewall_start || ! firewall_ok; then
      log_msg "Error: iptables rules failed to apply — traffic is not intercepted"
      # a daemon without rules is useless and a stale pidfile would claim it runs
      kill -TERM "$pid" 2>/dev/null
      rm -f "$PIDFILE"
      start_failed "Error: iptables rules failed to apply."
      return 1
    fi

    system_config
    acquire_wakelock
    echo 1 > "$DESIRED_FILE"
    log_msg "nfqws2 started (PID $pid, Native Daemon)"
    update_description running
    # During a replace the traffic verdict for this configuration is not known
    # yet: replace_daemon saves the snapshot only after the gate agrees, so a
    # configuration that starts but passes no traffic never becomes the "working"
    # one that a rollback restores.
    if [ "${SVC_DEFER_SNAPSHOT:-0}" != "1" ]; then
      save_working_snapshot
    fi
    ensure_watchdog
    return 0
  }

  local ret=0
  _start_internal || ret=$?
  [ "$own_lock" = "1" ] && svc_lock_release
  return $ret
}

# Restore the last working snapshot and bring the service up on it: used when a
# restart fails, or when the new configuration comes up but passes no traffic.
replace_restore_snapshot() {
  rollback_to_snapshot || return 1
  load_conf >/dev/null 2>&1 || return 1
  SVC_LOCK_HELD=1
  start
  local rc=$?
  SVC_LOCK_HELD=0
  if [ "$rc" -eq 0 ]; then
    log_msg "Rollback: service successfully restored from working snapshot"
    printf '{"time":%d,"strategy":"%s","status":"restored"}\n' \
      "$(date +%s 2>/dev/null || echo 0)" "$(get_current_strategy)" > "$STATE_DIR/last_rollback.json"
  else
    log_msg "replace: the snapshot did not start either"
  fi
  return "$rc"
}

replace_daemon() {
  if ! is_running; then
    start
    return $?
  fi

  if ! svc_lock_acquire; then
    log_msg "replace: another start/replace holds $(svc_lock_dir) — nothing done"
    echo "Другой запуск уже выполняется" >&2
    return 1
  fi

  _replace_internal() {
    local old_pid err args dry_err start_rc
    old_pid=$(cat "$PIDFILE" 2>/dev/null)
    if [ -z "$old_pid" ]; then
      log_msg "replace: no pidfile — restart skipped"
      return 1
    fi

    err=$(validate_args_conf) || { log_msg "${err:-Error: arguments validation failed}"; return 1; }
    err=$(validate_strategy_blob_references "$CONFFILE") || { log_msg "${err:-Error: strategy blob or script file validation failed}"; return 1; }

    args=$(_startup_args)
    printf '%s\n' "$args" > "$ARGS_FILE"

    if ! dry_err=$(dry_run_check "$args"); then
      log_msg "Error: nfqws2 --dry-run check failed"
      printf '%s\n' "$dry_err" >> "$NFQWS_LOG"
      log_msg "New strategy parameters are invalid — existing process PID $old_pid preserved"
      return 1
    fi
    save_strategy_receipt "$CONFFILE" 2>/dev/null || true

    # Remember whether the *old* configuration passed traffic: only with a working
    # baseline can a failing probe after the restart be blamed on the new one.
    local base_ok=0
    if health_probe; then base_ok=1; fi

    # The kernel allows one listener per NFQUEUE number: a second BIND answers
    # -EBUSY, so a new daemon cannot run next to the old one. Stop first: a short
    # gap is what actually happens, instead of a "zero downtime" attempt that
    # always failed and logged a startup error on every restart.
    log_msg "Restarting nfqws2 (NFQUEUE $NFQUEUE_NUM is exclusive, stopping first)"
    rotate_logs start
    stop >/dev/null 2>&1 || log_msg "replace: stop reported leftover rules — start will rebuild them"

    SVC_LOCK_HELD=1
    SVC_DEFER_SNAPSHOT=1
    start
    start_rc=$?
    SVC_DEFER_SNAPSHOT=0
    SVC_LOCK_HELD=0
    if [ "$start_rc" -ne 0 ]; then
      # the new configuration cannot come up: put the last working one back so
      # the phone is not left without a bypass until someone notices
      log_msg "replace: restart failed — restoring the last working snapshot"
      replace_restore_snapshot
      return 1
    fi

    # A daemon that is alive is not yet a working bypass. Traffic was fine before
    # the restart; if it is not fine now, twice in a row, the new configuration is
    # at fault and the old one comes back.
    if [ "$base_ok" = "1" ]; then
      sleep 1
      if ! health_probe; then
        sleep 3
        if ! health_probe; then
          log_msg "replace: the new configuration passes no traffic — restoring the last working snapshot"
          replace_restore_snapshot
          return 1
        fi
      fi
    fi

    # Past the verdict — good, or with no baseline to judge against — this
    # configuration is what the phone should fall back to.
    save_working_snapshot

    touch "$STATE_DIR/rollback_armed"
    (
      sleep 5
      if [ -f "$STATE_DIR/rollback_armed" ] && [ -f "$DESIRED_FILE" ]; then
        if is_running; then
          rm -f "$STATE_DIR/rollback_armed" 2>/dev/null
          save_working_snapshot
          log_msg "Watchdog Gate: new configuration successfully stabilized (5s)"
        else
          log_msg "Watchdog Gate: new process crashed within 5s — triggering auto-rollback!"
          rm -f "$STATE_DIR/rollback_armed" 2>/dev/null
          rollback
        fi
      else
        rm -f "$STATE_DIR/rollback_armed" 2>/dev/null
      fi
    ) >/dev/null 2>&1 &

    return 0
  }

  local ret=0
  _replace_internal || ret=$?
  svc_lock_release
  return $ret
}

rollback() {
  if [ ! -f "$SNAPSHOT_DIR/nfqws2.conf" ]; then
    log_msg "Rollback: no saved snapshot for rollback"
    return 1
  fi
  log_msg "WARNING: Guaranteed rollback to previous working configuration started"
  rollback_to_snapshot || return 1
  load_conf >/dev/null 2>&1
  local res=0
  if is_running; then
    replace_daemon || { stop; start; res=$?; }
  else
    start || res=$?
  fi
  if [ "$res" -eq 0 ]; then
    log_msg "Rollback: service successfully restored from working snapshot"
    printf '{"time":%d,"strategy":"%s","status":"restored"}\n' \
      "$(date +%s 2>/dev/null || echo 0)" "$(get_current_strategy)" > "$STATE_DIR/last_rollback.json"
  fi
  return $res
}

stop() {
  rm -f "$DESIRED_FILE" "$STARTED_FILE" "$STARTED_CS_FILE" "$STATE_DIR/rollback_armed"
  release_wakelock
  if [ -f "$SK_PIDFILE" ]; then
    kill -KILL "$(cat "$SK_PIDFILE" 2>/dev/null)" 2>/dev/null
    rm -f "$SK_PIDFILE"
    smartkill_chain del
  fi
  firewall_stop
  # параллельный подбор ставит свои цепи перед нашими; прерванный SIGKILL он
  # убрать не успевает, а «остановлено» должно означать чистый iptables
  if bench_leftovers; then bench_purge; fi
  # kernel settings we tuned for the bypass go back to what they were
  sysctl_restore
  if [ -f "$PIDFILE" ]; then
    local pid
    pid=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null
      wait_for_process "$pid" down 20 || kill -KILL "$pid" 2>/dev/null
    fi
    rm -f "$PIDFILE"
  fi
  # a leftover copy of our daemon still holds the queue: kill ours, not anyone
  # else's nfqws2 process
  local leftover p
  leftover=$(our_pids)
  for p in $leftover; do kill -9 "$p" 2>/dev/null; done
  sleep 0.1

  # a leftover chain still jumps to NFQUEUE with no listener, so the kernel
  # drops that traffic: stopped must mean rules gone
  if firewall_ok; then
    log_msg "Error: iptables rules remained active — traffic queued to NFQUEUE without listener"
    return 1
  fi

  log_msg "nfqws2 stopped"
  update_description stopped
  return 0
}


reload_lists() {
  is_running || { echo "Служба не запущена"; return 1; }
  kill -HUP "$(cat "$PIDFILE")" 2>/dev/null
  log_msg "Lists reloaded (SIGHUP)"
}

# Start a helper unless it already runs. Returns 0 when it was just started,
# 1 when it is running or the precondition failed. ensure_watchdog uses this
# to raise netwatch only alongside the watchdog
ensure_helper() {
  local pf="$1" sub="$2"; shift 2
  # bare "$@" is a no-op with no args in dash, but be explicit about it
  [ $# -eq 0 ] || { "$@" || return 1; }
  if [ -f "$pf" ] && kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null; then
    return 1
  fi
  (
    exec 0</dev/null
    exec >/dev/null 2>&1
    if command -v setsid >/dev/null 2>&1; then
      exec setsid sh "$MODDIR/service.sh" "$sub"
    else
      exec sh "$MODDIR/service.sh" "$sub"
    fi
  ) &
  return 0
}

ensure_watchdog() {
  # обрыв застрявших соединений — пока работает умный режим
  is_running && ensure_helper "$SK_PIDFILE" smartkill smart_active
  ensure_helper "$WL_PIDFILE" wlwatch wl_wanted
  watchers_wanted || return 0
  ensure_helper "$WD_PIDFILE" watchdog || return 0
  ensure_netwatch
}

# ── Умный режим: обрыв застрявших соединений ─────────────────────────────
SK_CHAIN=nfqws_smartkill
smartkill_chain() { # <add|del>
  local c
  for c in iptables ip6tables; do
    command -v "$c" >/dev/null 2>&1 || continue
    if [ "$1" = add ]; then
      $c -w -t filter -N $SK_CHAIN 2>/dev/null
      $c -w -t filter -C OUTPUT -j $SK_CHAIN 2>/dev/null || $c -w -t filter -I OUTPUT 1 -j $SK_CHAIN 2>/dev/null
    else
      while $c -w -t filter -D OUTPUT -j $SK_CHAIN 2>/dev/null; do :; done
      $c -w -t filter -F $SK_CHAIN 2>/dev/null
      $c -w -t filter -X $SK_CHAIN 2>/dev/null
    fi
  done
}
smartkill() {
  echo $$ > "$SK_PIDFILE"
  protect_process
  trap 'smartkill_exit; exit 0' TERM INT HUP
  local w="$SMART_KILL_FILE.work" ver ip lp c up flush=0 n learn_at=0 lp_pid= every
  # заявки прошлого запуска — до того, как цепочка заработает: их порты уже
  # могли достаться другим соединениям
  rm -f "$SMART_KILL_FILE"
  smartkill_chain add
  while :; do
    sleep 3
    conf_refresh
    is_running && smart_active || break
    read -r up _ < /proc/uptime; up=${up%.*}
    # фоновое обучение: раз в SMART_LEARN_EVERY секунд для сети подключения
    [ "$learn_at" = 0 ] && learn_at=$((up + 60))
    every=$SMART_LEARN_EVERY
    if [ -f "$SMART_TURBO_FILE" ] && [ "$(cat "$SMART_TURBO_FILE" 2>/dev/null)" -gt "$(date +%s)" ] 2>/dev/null; then
      every=$SMART_TURBO_EVERY
      [ "$learn_at" -gt $((up + every)) ] && learn_at=$((up + every))
    fi
    if [ "${SMART_LEARN:-1}" = 1 ] && [ "$up" -ge "$learn_at" ]; then
      learn_at=$((up + every))
      if [ -z "$lp_pid" ] || ! kill -0 "$lp_pid" 2>/dev/null; then
        sh "$MODDIR/bin/nfqws2-ctl" smart-learn-once </dev/null >/dev/null 2>&1 &
        lp_pid=$!
      fi
    fi
    if [ -s "$SMART_KILL_FILE" ]; then
      mv -f "$SMART_KILL_FILE" "$w" 2>/dev/null
      n=0
      while read -r ver ip lp; do
        case "$ver" in 4) c=iptables ;; 6) c=ip6tables ;; *) continue ;; esac
        case "$ip" in ''|*[!0-9a-fA-F.:]*) continue ;; esac
        case "$lp" in ''|*[!0-9]*) continue ;; esac
        $c -w -t filter -A $SK_CHAIN -p tcp -d "$ip" --sport "$lp" -j REJECT --reject-with tcp-reset 2>/dev/null && n=$((n + 1))
      done < "$w"
      rm -f "$w"
      [ "$n" -gt 0 ] && flush=$((up + 15))
    fi
    if [ "$flush" -gt 0 ] && [ "$up" -ge "$flush" ]; then
      iptables -w -t filter -F $SK_CHAIN 2>/dev/null; ip6tables -w -t filter -F $SK_CHAIN 2>/dev/null
      flush=0
    fi
  done
  smartkill_chain del
  smartkill_exit
}
smartkill_exit() {
  [ -n "$lp_pid" ] && kill "$lp_pid" 2>/dev/null
  smartkill_chain del 2>/dev/null
  [ "$(cat "$SK_PIDFILE" 2>/dev/null)" = "$$" ] && rm -f "$SK_PIDFILE"
  rm -f "$STATE_DIR/conf_seen.$$"
}
# Mobile operator whitelist detection loop: pauses bypass while active
wlwatch() {
  echo $$ > "$WL_PIDFILE"
  protect_process
  trap 'wlwatch_exit; exit 0' TERM INT HUP
  local up next=0 pend=0 net last="" res
  while :; do
    sleep 5
    conf_refresh
    wl_wanted || break
    read -r up _ < /proc/uptime; up=${up%.*}
    net=$(cat "$SMART_NET_FILE" 2>/dev/null)
    [ "$net" != "$last" ] && { last="$net"; next=0; pend=0; }
    [ "$up" -ge "$next" ] || continue
    if on_wifi || vpn_active; then
      [ -f "$WL_FILE" ] && { rm -f "$WL_FILE"; sh "$MODDIR/service.sh" home_check >/dev/null 2>&1; }
      pend=0; next=$((up + 60)); continue
    fi
    res=$(wl_probe)
    case "$res" in
      whitelist)
        if [ -f "$WL_FILE" ]; then next=$((up + 120))
        elif [ "$pend" -gt 0 ] && [ $((up - pend)) -ge 20 ]; then
          date +%s > "$WL_FILE"; pend=0; next=$((up + 120))
          sh "$MODDIR/service.sh" home_check >/dev/null 2>&1
        else
          [ "$pend" -gt 0 ] || pend=$up
          next=$((up + 20))
        fi ;;
      normal)
        pend=0; next=$((up + 300))
        [ -f "$WL_FILE" ] && { rm -f "$WL_FILE"; sh "$MODDIR/service.sh" home_check >/dev/null 2>&1; } ;;
      *) pend=0; next=$((up + 60)) ;;
    esac
  done
  if [ "$WL_PAUSE" != "1" ] && [ -f "$WL_FILE" ]; then rm -f "$WL_FILE"; sh "$MODDIR/service.sh" home_check >/dev/null 2>&1; fi
  wlwatch_exit
}
wlwatch_exit() {
  [ "$(cat "$WL_PIDFILE" 2>/dev/null)" = "$$" ] && rm -f "$WL_PIDFILE"
  rm -f "$STATE_DIR/conf_seen.$$"
}
conf_refresh() {
  local st="$STATE_DIR/conf_seen.$$"
  if [ ! -f "$st" ] || [ "$CONFFILE" -nt "$st" ]; then
    : > "$st"
    load_conf >/dev/null 2>&1
  fi
}

# Rebuild rules on events, not on a timer. Routers use a netfilter.d firmware
# hook for this; ip monitor is the Android equivalent. Watchdog is the
# fallback where ip monitor is unsupported
ensure_netwatch() {
  watchers_wanted || return 0
  ensure_helper "$WN_PIDFILE" netwatch command -v ip || return 0
}

# Network signature: outgoing interface dev and VPN/Wi-Fi flags.
# Changes immediately signal netwatch to update smart mode and firewall rules.
net_signature() {
  local dev
  dev=$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}')
  printf '%s|%s|%s' "$dev" "$(vpn_active && echo vpn)" "$(on_wifi && echo wifi)"
}

# Network change handling: DNS, smart mode, firewall rules, home/carrier check.
netwatch_apply() { # <reason for log>
  local sig
  sig=$(net_signature)
  # connection returned (no route before -> route present): phone is not idle
  case "$netsig" in '|'*) case "$sig" in '|'*) ;; *)
    rm -f "$IDLE_FILE" 2>/dev/null
    log_msg "netwatch: connection returned ($1)" ;; esac ;; esac
  netsig="$sig"
  smart_net_update
  if [ -f "$DESIRED_FILE" ] && is_running; then
    if [ -n "$ISP_INTERFACE" ] || [ "$ENABLE_HOTSPOT" = "1" ] || ! firewall_ok; then
      log_msg "netwatch: network changed ($1) — rebuilding rules"
      firewall_start
    else
      log_msg "netwatch: network changed ($1) — rules intact"
    fi
  fi
  home_check
  network_strategy_check
}

netwatch() {
  echo $$ > "$WN_PIDFILE"
  protect_process
  command -v ip >/dev/null 2>&1 || { rm -f "$WN_PIDFILE"; return 0; }

  local wake=0 mon="" reader="" sp="" netsig rq="" base=0 d backoff=2 started up me=$$
  local fifo="$STATE_DIR/netwatch.fifo"
  netsig=$(net_signature)
  trap 'wake=1' USR1
  trap 'kill -TERM "$mon" "$reader" "$sp" 2>/dev/null; rm -f "$WN_PIDFILE" "$fifo" "$STATE_DIR/conf_seen.$$"; exit 0' TERM INT HUP
  read -r up _ < /proc/uptime; base=${up%.*}; rq="${NW_RECHECK:-3 10 30}"
  while :; do
    if [ -z "$mon" ] || ! kill -0 "$mon" 2>/dev/null; then
      if [ -n "$mon" ]; then
        kill -TERM "$reader" 2>/dev/null
        read -r up _ < /proc/uptime
        if [ $(( ${up%.*} - started )) -lt 10 ]; then
          sleep "$backoff"; [ "$backoff" -lt 60 ] && backoff=$((backoff * 2))
        else backoff=2; fi
      fi
      rm -f "$fifo"; mkfifo "$fifo" 2>/dev/null || { sleep 60; continue; }
      while IFS= read -r _; do kill -USR1 "$me" 2>/dev/null || exit 0; done < "$fifo" &
      reader=$!
      ip monitor route link > "$fifo" 2>/dev/null &
      mon=$!
      read -r up _ < /proc/uptime; started=${up%.*}
    fi
    if [ "$wake" = 0 ]; then
      d=60
      if [ -n "$rq" ]; then
        read -r up _ < /proc/uptime; set -- $rq
        d=$(( base + $1 - ${up%.*} )); [ "$d" -lt 1 ] && d=1
      fi
      sleep "$d" & sp=$!
      [ "$wake" = 1 ] || wait "$sp"
      kill "$sp" 2>/dev/null; sp=""
    fi
    conf_refresh
    watchers_wanted || break
    if [ "$wake" = 1 ]; then
      while [ "$wake" = 1 ]; do wake=0; sleep 1; done
      netwatch_apply "ip monitor"
      read -r up _ < /proc/uptime; base=${up%.*}; rq="${NW_RECHECK:-3 10 30}"
      continue
    fi
    if [ -n "$rq" ]; then
      read -r up _ < /proc/uptime
      set -- $rq
      if [ $(( ${up%.*} - base )) -ge "$1" ]; then
        shift; rq="$*"
        if [ "$(net_signature)" != "$netsig" ]; then netwatch_apply "recheck"
        else
          smart_net_update
          [ -z "$rq" ] && { home_check; network_strategy_check; }
        fi
      fi
    fi
  done
  kill -TERM "$mon" "$reader" "$sp" 2>/dev/null
  rm -f "$WN_PIDFILE" "$fifo" "$STATE_DIR/conf_seen.$$"
}

# Auto-restart streak, kept in a file: a watchdog that dies (or a reboot) must
# not reset a failing loop into fast retries. A streak older than an hour counts
# as a fresh problem.
watchdog_fail_count() {
  local f="$STATE_DIR/watchdog_fails" n=0 t=0 now
  now=$(date +%s 2>/dev/null || echo 0)
  if [ -f "$f" ]; then
    read -r n t < "$f" 2>/dev/null
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    case "$t" in ''|*[!0-9]*) t=0 ;; esac
    if [ "$now" -gt 0 ] && [ $((now - t)) -gt 3600 ]; then n=0; fi
  fi
  printf '%s' "$n"
}
watchdog_fail_set() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  printf '%s %s\n' "$1" "$(date +%s 2>/dev/null || echo 0)" > "$STATE_DIR/watchdog_fails"
}

watchdog() {
  echo $$ > "$WD_PIDFILE"
  trap 'rm -f "$WD_PIDFILE"; exit 0' INT TERM EXIT
  protect_process
  local fails=0 tick=0 dpid
  while :; do
    sleep 20
    load_conf >/dev/null 2>&1
    watchers_wanted || break
    tick=$((tick + 1))
    { [ "$HOME_WIFI" = "1" ] || [ "$VPN_PAUSE" = "1" ]; } && [ $((tick % 3)) -eq 0 ] && home_check
    [ "$NET_STRATEGY" = "1" ] && [ $((tick % 3)) -eq 0 ] && network_strategy_check
    [ $((tick % 3)) -eq 0 ] && is_running && smart_net_update
    [ "$WATCHDOG" = "1" ] || continue
    [ -f "$DESIRED_FILE" ] || continue

    if ! is_running; then
      if [ -f "$STATE_DIR/rollback_armed" ]; then
        log_msg "watchdog: crash detected while rollback_armed — triggering auto-rollback"
        rm -f "$STATE_DIR/rollback_armed" 2>/dev/null
        rollback
        continue
      fi
      # the streak lives on disk: a reboot or a restarted watchdog must not turn
      # a failing loop back into an endless fast retry
      fails=$(watchdog_fail_count)
      fails=$((fails + 1))
      watchdog_fail_set "$fails"
      log_msg "watchdog: nfqws2 is inactive, auto-restarting (#$fails)..."
      firewall_stop
      start
      # first attempts are quick (crashes are usually transient), later ones back
      # off so a broken configuration cannot spin forever
      case "$fails" in
        1|2|3) sleep 2 ;;
        4) log_msg "watchdog: $fails restarts in a row — waiting a minute"; sleep 60 ;;
        5) log_msg "watchdog: $fails restarts in a row — waiting five minutes"; sleep 300 ;;
        *) log_msg "watchdog: $fails restarts in a row — waiting fifteen minutes" ; sleep 900 ;;
      esac
      continue
    fi

    # survived a full cycle: the streak is over
    if [ "$fails" -ne 0 ]; then
      fails=0
      rm -f "$STATE_DIR/watchdog_fails" 2>/dev/null
    fi

    # keep the daemon and watchdog protected from lmk
    dpid=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$dpid" ] && protect_process "$dpid"
    protect_process

    # fast iptables recovery after a network switch
    if ! firewall_ok; then
      log_msg "watchdog: iptables rules flushed by system — restoring"
      firewall_start
    fi
    [ $((tick % 25)) -eq 0 ] && rotate_logs
  done
  rm -f "$WD_PIDFILE"
}

# home Wi-Fi, VPN, and whitelist pause: home Wi-Fi, active VPN, or carrier whitelisting pause the service.
# A manual start there is remembered in home_override while that condition stays (@vpn, @wl or SSID).
home_check() {
  [ -n "$(find "$STATE_DIR/home.lock" -maxdepth 0 -mmin +2 2>/dev/null)" ] && rmdir "$STATE_DIR/home.lock" 2>/dev/null
  mkdir "$STATE_DIR/home.lock" 2>/dev/null || return 0

  local ssid="" vpn=0 wl=0 ovr="" want=""
  [ "$HOME_WIFI" = "1" ] && ssid=$(current_ssid)
  [ "$VPN_PAUSE" = "1" ] && vpn_active && vpn=1
  [ "$WL_PAUSE" = "1" ] && [ -f "$WL_FILE" ] && wl=1
  [ -f "$HOME_OVERRIDE_FILE" ] && ovr=$(cat "$HOME_OVERRIDE_FILE" 2>/dev/null)
  case "$ovr" in
    '') ;;
    @vpn) [ "$vpn" = 1 ] || { rm -f "$HOME_OVERRIDE_FILE"; ovr=""; } ;;
    @wl)  [ "$wl" = 1 ] || { rm -f "$HOME_OVERRIDE_FILE"; ovr=""; } ;;
    *)    [ "$ovr" = "$ssid" ] || { rm -f "$HOME_OVERRIDE_FILE"; ovr=""; } ;;
  esac

  if [ "$vpn" = 1 ] && [ "$ovr" != "@vpn" ]; then
    want="@vpn"
  elif [ "$wl" = 1 ] && [ "$ovr" != "@wl" ]; then
    want="@wl"
  elif [ "$HOME_WIFI" = "1" ] && ssid_is_home "$ssid" && [ "$ovr" != "$ssid" ]; then
    want="$ssid"
  fi

  if [ -n "$want" ]; then
    if is_running && [ ! -f "$HOME_PAUSED_FILE" ]; then
      case "$want" in
        @vpn) log_msg "VPN active — bypass paused" ;;
        @wl)  log_msg "Carrier whitelist active — bypass paused" ;;
        *)    log_msg "Home Wi-Fi «$want» — bypass paused" ;;
      esac
      stop >/dev/null 2>&1
      printf '%s' "$want" > "$HOME_PAUSED_FILE"
      update_description paused "$want"
    elif [ -f "$HOME_PAUSED_FILE" ] && [ "$(cat "$HOME_PAUSED_FILE" 2>/dev/null)" != "$want" ]; then
      printf '%s' "$want" > "$HOME_PAUSED_FILE"
      update_description paused "$want"
    fi
  elif [ -f "$HOME_PAUSED_FILE" ]; then
    case "$(cat "$HOME_PAUSED_FILE" 2>/dev/null)" in
      @vpn) log_msg "VPN disconnected — bypass resumed" ;;
      @wl)  log_msg "Carrier whitelist ended — bypass resumed" ;;
      *)    log_msg "Home Wi-Fi no longer active — bypass resumed" ;;
    esac
    rm -f "$HOME_PAUSED_FILE"
    start >/dev/null 2>&1 || log_msg "Failed to resume bypass after pause"
  fi
  rmdir "$STATE_DIR/home.lock" 2>/dev/null
  return 0
}

# On a network change apply the strategy saved for that network
network_strategy_check() {
  [ "$NET_STRATEGY" = "1" ] || return 0
  is_running || return 0
  [ -f "$HOME_PAUSED_FILE" ] && return 0 # keep the strategy during a home, VPN, or whitelist pause

  local cur_net last_net saved cur_strat
  cur_net=$(current_network_key 2>/dev/null)
  [ -n "$cur_net" ] || return 0
  last_net=$(cat "$STATE_DIR/last_network" 2>/dev/null)

  if [ "$cur_net" != "$last_net" ]; then
    printf '%s' "$cur_net" > "$STATE_DIR/last_network"
    saved=$(load_net_strategy "$cur_net" 2>/dev/null)
    cur_strat=$(get_current_strategy 2>/dev/null)
    if [ -n "$saved" ] && [ "$saved" != "$cur_strat" ]; then
      log_msg "Network changed to $(current_network_title 2>/dev/null || echo "$cur_net") — switching to saved strategy «$saved»"
      if sh "$MODDIR/bin/nfqws2-ctl" set-strategy "$saved" >/dev/null 2>&1; then
        stop >/dev/null 2>&1
        start >/dev/null 2>&1
      fi
    fi
  fi
  return 0
}

# Manual start clears the pause; on a home network or active VPN it records the condition as
# an override (@vpn or SSID) so the bypass keeps running there
manual_start() {
  local ssid
  rm -f "$HOME_PAUSED_FILE"
  if [ "$VPN_PAUSE" = "1" ] && vpn_active; then
    printf '@vpn' > "$HOME_OVERRIDE_FILE"
  elif [ "$WL_PAUSE" = "1" ] && [ -f "$WL_FILE" ]; then
    printf '@wl' > "$HOME_OVERRIDE_FILE"
  elif [ "$HOME_WIFI" = "1" ] && ssid=$(current_ssid) && ssid_is_home "$ssid"; then
    printf '%s' "$ssid" > "$HOME_OVERRIDE_FILE"
  fi
  start
}

# Boot/autostart respects disable, VPN pause, carrier whitelist pause, and Home Wi-Fi pause without
# setting user override files.
autostart_service() {
  [ -f "$CONFDIR/disable" ] && { log_msg "Found $CONFDIR/disable — autostart skipped"; update_description disabled; return 0; }
  local ssid
  if [ "$AUTOSTART" = "1" ] || [ -f "$DESIRED_FILE" ]; then
    if [ "$VPN_PAUSE" = "1" ] && vpn_active; then
      log_msg "VPN active — autostart deferred until disconnected"
      printf '@vpn' > "$HOME_PAUSED_FILE"
      update_description paused "@vpn"
    elif [ "$WL_PAUSE" = "1" ] && [ -f "$WL_FILE" ]; then
      log_msg "Carrier whitelist active — autostart deferred until ended"
      printf '@wl' > "$HOME_PAUSED_FILE"
      update_description paused "@wl"
    elif [ "$HOME_WIFI" = "1" ] && ssid=$(current_ssid) && ssid_is_home "$ssid"; then
      log_msg "Home Wi-Fi «$ssid» — autostart deferred until disconnected"
      printf '%s' "$ssid" > "$HOME_PAUSED_FILE"
      update_description paused "$ssid"
    else
      is_running || start || log_msg "Autostart failed"
    fi
  else
    is_running || update_description stopped
  fi
  ensure_watchdog
}

status_service() {
  if is_running; then
    echo "Служба NFQWS2 запущена (PID $(cat "$PIDFILE"))"
  else
    echo "Служба NFQWS2 остановлена"
  fi
}

case "$1" in
  start)              manual_start ;;
  autostart)          autostart_service ;;
  stop)               rm -f "$HOME_PAUSED_FILE" "$HOME_OVERRIDE_FILE"; stop ;;
  vpn_check|home_check|net_recheck) home_check; smart_net_update; ensure_watchdog ;;
  net_check)          network_strategy_check ;;
  restart)
    if is_running; then
      replace_daemon || { stop; start; }
    else
      start
    fi
    ;;
  replace)            replace_daemon ;;
  rollback)           rollback ;;
  reload)             reload_lists ;;
  status)             status_service ;;
  ensure_watchdog)    ensure_watchdog ;;
  watchdog)           watchdog ;;
  netwatch)           netwatch ;;
  smartkill)          smartkill ;;
  wlwatch)            wlwatch ;;
  firewall_apply)     firewall_start ;;
  firewall_stop)      firewall_stop ;;
  *)
    rm -f "$HOME_PAUSED_FILE" "$HOME_OVERRIDE_FILE" "$SK_PIDFILE" "$STATE_DIR"/conf_seen.*
    rmdir "$STATE_DIR/home.lock" 2>/dev/null
    update_description ready
    until [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; do sleep 3; done
    sleep 4
    load_conf >/dev/null 2>&1
    autostart_service
    ;;
esac
# Exit with the command status, not always 0: nfqws2-ctl passes it through,
# so a failed start is not read as success
exit $?
