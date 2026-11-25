#!/system/bin/sh
# lifecycle hook called early in boot by Magisk, KernelSU, or APatch (before zygote)
umask 077
MODDIR="${0%/*}"
case "$MODDIR" in /*) ;; *) MODDIR="$(cd "$MODDIR" 2>/dev/null && pwd)" ;; esac
[ -f "$MODDIR/service.sh" ] || MODDIR=/data/adb/modules/nfqws2-android
. "$MODDIR/lib/common.sh"
load_conf >/dev/null 2>&1

# 1. Clean up stale locks, pidfiles and leftover sockets from unexpected shutdown/reboot
rm -f "$PIDFILE" "$WD_PIDFILE" "$WN_PIDFILE" "$WL_PIDFILE" "$SK_PIDFILE" "$STATE_DIR/probe.pid" 2>/dev/null || true
rm -rf "$STATE_DIR"/*.lock 2>/dev/null || true
rm -f /data/local/tmp/nfqws2* 2>/dev/null || true

# 2. Early carrier tethering check bypass
# Set net.tethering.noprovisioning before system_server starts TetheringService
# (tether_dun_required via `settings` is deferred to boot-completed.sh when system_server is up)
if [ "$ENABLE_HOTSPOT" = "1" ]; then
  for r in /data/adb/ksu/bin/resetprop /data/adb/magisk/resetprop /data/adb/ap/bin/resetprop resetprop; do
    if [ -x "$r" ] || command -v "$r" >/dev/null 2>&1; then
      "$r" -n net.tethering.noprovisioning true >/dev/null 2>&1 && break
    fi
  done
fi

# 3. Early stealth hiding mechanisms (SuSFS, KernelSU ksud umount, SELinux context)
apply_stealth_hiding >/dev/null 2>&1 || true

exit 0
