#!/system/bin/sh
# lifecycle hook called by Magisk, KernelSU, or APatch
umask 077
MODDIR="${0%/*}"
case "$MODDIR" in /*) ;; *) MODDIR="$(cd "$MODDIR" 2>/dev/null && pwd)" ;; esac
[ -f "$MODDIR/service.sh" ] || MODDIR=/data/adb/modules/nfqws2-android
. "$MODDIR/lib/common.sh"
load_conf >/dev/null 2>&1

log_msg "boot-completed: running hook (sys.boot_completed=1)"
[ -f "$CONFDIR/disable" ] && exit 0

# restore the service after boot if it should be running
if [ "$AUTOSTART" = "1" ] || [ -f "$DESIRED_FILE" ]; then
  if ! is_running; then
    if [ ! -f "$HOME_PAUSED_FILE" ]; then
      log_msg "boot-completed: nfqws2 is inactive after system boot — restoring..."
      sh "$MODDIR/service.sh" autostart >/dev/null 2>&1
    fi
  else
    protect_process "$(cat "$PIDFILE" 2>/dev/null)"
    if ! firewall_ok; then
      log_msg "boot-completed: restoring firewall rules"
      firewall_start
    fi
  fi
fi

# ensure watchdog and netwatch are running
sh "$MODDIR/service.sh" ensure_watchdog >/dev/null 2>&1

exit 0
