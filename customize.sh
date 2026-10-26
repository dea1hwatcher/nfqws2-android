#!/system/bin/sh

# grab own info (version)
version=$(sed -n 's/^version=//p' "$MODPATH/module.prop" | tr -d '\r')

ui_print "*******************************************"
ui_print "- nfqws2-android"
ui_print "- $version "
ui_print "*******************************************"

case "$ARCH" in
  arm64) BIN=android-arm64 ;;
  arm) BIN=android-arm ;;
  x86_64) BIN=android-x86_64 ;;
  x86) BIN=android-x86 ;;
  *) abort "! Unsupported architecture: ${ARCH:-unknown}" ;;
esac
ui_print "- Architecture: $ARCH -> $BIN"

rm -rf "$MODPATH/tests" "$MODPATH/tools" "$MODPATH/.workbuddy-ai" \
       "$MODPATH/.git" "$MODPATH/.github" "$MODPATH/.gitattributes" \
       "$MODPATH/CONTRIBUTING.md" "$MODPATH/java" \
       "$MODPATH/docs" "$MODPATH/update.json"
rm -f "$MODPATH"/*.zip

for f in \
  service.sh action.sh boot-completed.sh uninstall.sh lib/common.sh bin/nfqws2-ctl \
  system/bin/nfqws2-ctl defaults/nfqws2.conf \
  "binaries/$BIN/nfqws2"
do
  [ -s "$MODPATH/$f" ] || abort "! Missing or empty module file: $f"
done

cp -f "$MODPATH/binaries/$BIN/nfqws2" "$MODPATH/bin/nfqws2" ||
  abort "! Failed to install nfqws2 binary"
[ -s "$MODPATH/bin/nfqws2" ] || abort "! Installed nfqws2 binary is empty"
rm -rf "$MODPATH/binaries"

# Module icon for Magisk / KernelSU / APatch / MMRL managers
if [ -f "$MODPATH/webroot/icon.png" ]; then
  cp -f "$MODPATH/webroot/icon.png" "$MODPATH/icon.png" 2>/dev/null || true
fi

CONF=/data/adb/nfqws2
mkdir -p "$CONF/lists" "$CONF/state" "$CONF/logs" "$CONF/imports" "$CONF/strategies" ||
  abort "! Cannot create $CONF; check /data/adb access"

if [ -f "$CONF/nfqws2.conf" ]; then
  ui_print "- Keeping existing config: $CONF/nfqws2.conf"
  cp -f "$MODPATH/defaults/nfqws2.conf" "$CONF/nfqws2.conf.dist" ||
    abort "! Failed to save the default config"
else
  cp -f "$MODPATH/defaults/nfqws2.conf" "$CONF/nfqws2.conf" ||
    abort "! Failed to create $CONF/nfqws2.conf"
  ui_print "- Created config: $CONF/nfqws2.conf"
fi

DIST="$CONF/lists/.dist"
PEND="$CONF/lists/.pending"
mkdir -p "$DIST" "$PEND" || abort "! Cannot create list update directories"

for src in "$MODPATH"/lists/*.list; do
  [ -f "$src" ] || continue
  f=${src##*/}
  dst="$CONF/lists/$f"

  if [ "$f" = auto.list ]; then
    if [ ! -f "$dst" ]; then
      cp -f "$src" "$dst" || abort "! Failed to install $f"
    fi
    cp -f "$src" "$DIST/$f" || abort "! Failed to save release copy of $f"
    continue
  fi

  if [ ! -f "$dst" ] || cmp -s "$src" "$dst"; then
    cp -f "$src" "$dst" || abort "! Failed to install $f"
    rm -f "$PEND/$f"
  elif [ -f "$DIST/$f" ] && cmp -s "$src" "$DIST/$f"; then
    :
  elif [ -f "$DIST/$f" ] && cmp -s "$dst" "$DIST/$f"; then
    cp -f "$src" "$dst" || abort "! Failed to update $f"
    rm -f "$PEND/$f"
  else
    case " user exclude ipset ipset_exclude probe_hosts " in
      *" ${f%.list} "*)
        cp -f "$src" "$PEND/$f" || abort "! Failed to save pending update for $f"
        ui_print "- $f has local changes; the release version is available in the WebUI"
        ;;
      *)
        cp -f "$src" "$dst" || abort "! Failed to migrate $f"
        rm -f "$PEND/$f"
        ;;
    esac
  fi

  cp -f "$src" "$DIST/$f" || abort "! Failed to save release copy of $f"
done

if [ ! -f "$CONF/apps.list" ]; then
  printf '%s\n' "# App packages (APP_MODE=include|exclude), one per line" > "$CONF/apps.list" ||
    abort "! Failed to create $CONF/apps.list"
fi
if [ ! -f "$CONF/home_wifi.list" ]; then
  printf '%s\n' "# Home Wi-Fi SSIDs, one per line" > "$CONF/home_wifi.list" ||
    abort "! Failed to create $CONF/home_wifi.list"
fi

if [ -d "$MODPATH/strategy-catalogs" ]; then
  mkdir -p "$CONF/strategy-catalogs" || abort "! Failed to create $CONF/strategy-catalogs"
  cp -rf "$MODPATH/strategy-catalogs"/* "$CONF/strategy-catalogs/" 2>/dev/null || true
fi

# set perms to nfwqws2
busybox chmod +x "$MODPATH/bin/nfqws2"
busybox chmod +x "$MODPATH/bin/nfqws2-ctl"
busybox chmod +x "$MODPATH/boot-completed.sh" 2>/dev/null || chmod +x "$MODPATH/boot-completed.sh" 2>/dev/null
busybox chmod +x "$MODPATH/system/bin/nfqws2-ctl" 2>/dev/null || chmod +x "$MODPATH/system/bin/nfqws2-ctl" 2>/dev/null

# CLI symlinks for APatch and KernelSU environments
for p in /data/adb/ap/bin /data/adb/ksu/bin; do
  if [ -d "$p" ]; then
    ln -sf /data/adb/modules/nfqws2-android/bin/nfqws2-ctl "$p/nfqws2-ctl" 2>/dev/null || true
  fi
done
