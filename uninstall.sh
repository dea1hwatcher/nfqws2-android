#!/system/bin/sh
MODDIR="${0%/*}"
case "$MODDIR" in /*) ;; *) MODDIR="$(cd "$MODDIR" 2>/dev/null && pwd)" ;; esac
# Release the named wakelock; it can outlive the module process
if [ -w /sys/power/wake_unlock ] 2>/dev/null; then
  echo nfqws2-android > /sys/power/wake_unlock 2>/dev/null
fi
[ -f "$MODDIR/service.sh" ] || MODDIR=/data/adb/modules/nfqws2-android
# Avoid calling kill with an empty PID and verify cmdline before killing
kill_if_mod() {
  local p="$1" pat="$2" cmd=""
  [ -n "$p" ] || return 0
  if [ -r "/proc/$p/cmdline" ]; then
    cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
    case "$cmd" in *"$pat"*) kill "$p" 2>/dev/null ;; esac
  else
    kill "$p" 2>/dev/null
  fi
}
wpid=$(cat /data/adb/nfqws2/state/watchdog.pid 2>/dev/null)
if [ -n "$wpid" ]; then kill_if_mod "$wpid" "service.sh"; fi
wnpid=$(cat /data/adb/nfqws2/state/netwatch.pid 2>/dev/null)
if [ -n "$wnpid" ]; then kill_if_mod "$wnpid" "service.sh"; fi
wlpid=$(cat /data/adb/nfqws2/state/wlwatch.pid 2>/dev/null)
if [ -n "$wlpid" ]; then kill_if_mod "$wlpid" "service.sh"; fi
sh "$MODDIR/service.sh" stop >/dev/null 2>&1
for p in $(pidof nfqws2 2>/dev/null); do
  if [ -r "/proc/$p/cmdline" ]; then
    cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
    case "$cmd" in *"$MODDIR"*|*nfqws2-android*) kill -9 "$p" 2>/dev/null ;; esac
  fi
done
rm -f /data/adb/ap/bin/nfqws2-ctl /data/adb/ap/bin/zapret2-status \
      /data/adb/ksu/bin/nfqws2-ctl /data/adb/ksu/bin/zapret2-status \
      /sbin/nfqws2-ctl /sbin/zapret2-status \
      /debug_ramdisk/nfqws2-ctl /debug_ramdisk/zapret2-status 2>/dev/null
# Remove runtime state, net strategies, logs, and configuration on uninstall
rm -rf /data/adb/nfqws2/state
rm -rf /data/adb/nfqws2 2>/dev/null || true
exit 0
