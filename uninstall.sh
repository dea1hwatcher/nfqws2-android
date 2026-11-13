#!/system/bin/sh
MODDIR="${0%/*}"
case "$MODDIR" in /*) ;; *) MODDIR="$(cd "$MODDIR" 2>/dev/null && pwd)" ;; esac
# Release the named wakelock; it can outlive the module process
if [ -w /sys/power/wake_unlock ] 2>/dev/null; then
  echo nfqws2-android > /sys/power/wake_unlock 2>/dev/null
fi
[ -f "$MODDIR/service.sh" ] || MODDIR=/data/adb/modules/nfqws2-android
# Avoid calling kill with an empty PID
wpid=$(cat /data/adb/nfqws2/state/watchdog.pid 2>/dev/null)
if [ -n "$wpid" ]; then kill "$wpid" 2>/dev/null; fi
wnpid=$(cat /data/adb/nfqws2/state/netwatch.pid 2>/dev/null)
if [ -n "$wnpid" ]; then kill "$wnpid" 2>/dev/null; fi
wlpid=$(cat /data/adb/nfqws2/state/wlwatch.pid 2>/dev/null)
if [ -n "$wlpid" ]; then kill "$wlpid" 2>/dev/null; fi
sh "$MODDIR/service.sh" stop >/dev/null 2>&1
killall -9 nfqws2 2>/dev/null
rm -f /data/adb/ap/bin/nfqws2-ctl /data/adb/ksu/bin/nfqws2-ctl 2>/dev/null
# Remove runtime state, net strategies, logs, and configuration on uninstall
rm -rf /data/adb/nfqws2/state
rm -rf /data/adb/nfqws2 2>/dev/null || true
exit 0
