#!/bin/sh
# Packaging tests: the module archive must contain module files only.
#
# Two independent guards are checked, because either one alone is easy to defeat:
#
#   1. tools/build.py packs from an allow-list and then verifies the archive —
#      a path outside the list is an error, not a warning;
#   2. customize.sh deletes the developer directories at install time, in case
#      the archive was built by hand (a plain `zip -r .` from the repo root).
#
# The second guard has to be a deletion rather than an `unzip -x` pattern: in
# unzip `*` does not cross `/`, so `tests/*` only filters the top level and
# `tests/module/*` still lands. The simulation below proves that end to end.
#
# Needs a python 3 interpreter for the builder; skips itself without one.

HERE=$(cd "$(dirname "$0")" && pwd)
TESTS_DIR=$(cd "$HERE/.." && pwd)
REPO_DIR=$(cd "$TESTS_DIR/.." && pwd)
. "$TESTS_DIR/lib/harness.sh"

PY="${NFQWS_TEST_PYTHON:-}"
if [ -z "$PY" ]; then
  for c in python3 python py; do
    if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
  done
fi
if [ -z "$PY" ] && [ -x "$HOME/.workbuddy-ai/binaries/python/versions/3.13.12/python.exe" ]; then
  PY="$HOME/.workbuddy-ai/binaries/python/versions/3.13.12/python.exe"
fi
if [ -z "$PY" ]; then
  printf 'SKIP  no python interpreter found (set NFQWS_TEST_PYTHON)\n'
  exit 0
fi
# tools/ is host-only and deliberately untracked (tests/run.sh enforces it), so
# a fresh checkout has no builder; the suite is about the local packaging aid
if [ ! -f "$REPO_DIR/tools/build.py" ]; then
  printf 'SKIP  tools/build.py is host-only and not present in this checkout\n'
  exit 0
fi

# A bare temp dir rather than sandbox_init(): this suite reads the repository
# directly and does not need the module sandbox. SANDBOX is set so harness_finish
# cleans it up.
SANDBOX=$(mktemp -d "${NFQWS_TEST_TMP:-/tmp}/nfqws2-pack.XXXXXX") || exit 1
SANDBOX=$(cd "$SANDBOX" && pwd)

MODULE_FILES="action.sh boot-completed.sh customize.sh service.sh uninstall.sh module.prop icon.png LICENSE README.md changelog.md"
MODULE_DIRS="bin $([ -d "$REPO_DIR/binaries" ] && echo binaries) blobs defaults lib lists lua strategies strategy-catalogs system webroot"

# ── builder ───────────────────────────────────────────────────────────────────
section "tools/build.py produces a module-only archive"

OUT="$SANDBOX/module.zip"
"$PY" "$REPO_DIR/tools/build.py" "$OUT" > "$SANDBOX/build.log" 2>&1
assert_rc 0 $? "the builder exits 0"
assert_file "$OUT" "the archive is created"

if [ -f "$OUT" ]; then
  "$PY" - "$OUT" > "$SANDBOX/tops.txt" <<'PY'
import sys, zipfile
names = zipfile.ZipFile(sys.argv[1]).namelist()
tops = sorted({n.split('/')[0] for n in names})
print('TOPS ' + ' '.join(tops))
print('FILES ' + str(sum(1 for n in names if not n.endswith('/'))))
print('DEVS ' + ' '.join(sorted(n for n in names
      if n.startswith(('tests/', 'tools/', '.workbuddy-ai/', '.git/')))))
print('ZIPS ' + ' '.join(sorted(n for n in names if n.endswith('.zip'))))
PY
  tops=$(sed -n 's/^TOPS //p' "$SANDBOX/tops.txt")
  files=$(sed -n 's/^FILES //p' "$SANDBOX/tops.txt")
  devs=$(sed -n 's/^DEVS //p' "$SANDBOX/tops.txt")
  zips=$(sed -n 's/^ZIPS //p' "$SANDBOX/tops.txt")

  expected=$(printf '%s %s' "$MODULE_FILES" "$MODULE_DIRS" | tr ' ' '\n' | grep -v '^$' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
  assert_eq "$expected" "$tops" "the archive holds exactly the module top level"
  assert_eq "" "$devs" "no developer directory is archived"
  assert_eq "" "$zips" "no nested archive is archived"
  assert_ge "$files" 140 "the archive carries the whole module ($files files)"

  "$PY" - "$OUT" "$REPO_DIR" <<'PY' > "$SANDBOX/required.txt"
import os, sys, zipfile
names = set(zipfile.ZipFile(sys.argv[1]).namelist())
for n in ('module.prop', 'icon.png', 'customize.sh', 'service.sh', 'action.sh', 'boot-completed.sh', 'uninstall.sh',
          'bin/nfqws2-ctl', 'bin/pkglist.jar', 'system/bin/nfqws2-ctl', 'lib/common.sh', 'defaults/nfqws2.conf',
          'webroot/index.html', 'webroot/config.json'):
    print(('OK  ' if n in names else 'MISSING ') + n)
if os.path.isdir(os.path.join(sys.argv[2], 'binaries')):
    for abi in ('android-arm', 'android-arm64', 'android-x86', 'android-x86_64'):
        n = 'binaries/%s/nfqws2' % abi
        print(('OK  ' if n in names else 'MISSING ') + n)
PY
  missing=$(grep '^MISSING ' "$SANDBOX/required.txt" | sed 's/^MISSING //' | tr '\n' ' ')
  assert_eq "" "$missing" "every file the installer needs is present"
fi

# ── installer cleanup ─────────────────────────────────────────────────────────
section "customize.sh removes developer directories on install"

# The paths are listed across a line continuation, so match the quoted argument
# rather than the whole command.
assert_contains "$(cat "$REPO_DIR/customize.sh")" '"$MODPATH/tests"' "tests/ is deleted at install time"
assert_contains "$(cat "$REPO_DIR/customize.sh")" '"$MODPATH/tools"' "tools/ is deleted at install time"
assert_contains "$(cat "$REPO_DIR/customize.sh")" '.workbuddy-ai' ".workbuddy-ai/ is deleted at install time"

if command -v unzip >/dev/null 2>&1; then
  # A deliberately naive archive: everything in the repo, exactly what
  # `zip -r` from the root would produce.
  "$PY" - "$REPO_DIR" "$SANDBOX/naive.zip" <<'PY' >/dev/null 2>&1
import os, sys, zipfile
repo, dst = sys.argv[1], sys.argv[2]
z = zipfile.ZipFile(dst, 'w', zipfile.ZIP_DEFLATED)
for root, dirs, files in os.walk(repo):
    dirs[:] = [d for d in dirs if d not in ('.git',)]
    for f in files:
        p = os.path.join(root, f)
        z.write(p, os.path.relpath(p, repo).replace(os.sep, '/'))
z.close()
PY
  assert_file "$SANDBOX/naive.zip" "the naive archive was built"

  MODPATH="$SANDBOX/naive-out"
  mkdir -p "$MODPATH"
  unzip -o "$SANDBOX/naive.zip" -x 'META-INF/*' -d "$MODPATH" >/dev/null 2>&1

  # This is the point of the whole exercise: the `-x` pattern alone does NOT
  # stop nested developer files.
  nested=$(find "$MODPATH/tests" -type f 2>/dev/null | head -1)
  if [ -n "$nested" ]; then
    _ok "unzip -x alone lets nested tests/ through (hence the deletion)"
  else
    _fail "unzip -x filtered nested tests/ — the deletion may be unnecessary, re-check the premise"
  fi

  rm -rf "$MODPATH/tests" "$MODPATH/tools" "$MODPATH/.workbuddy-ai" \
         "$MODPATH/.git" "$MODPATH/.github" "$MODPATH/.gitattributes" \
         "$MODPATH/CONTRIBUTING.md" "$MODPATH/java" \
         "$MODPATH/docs" "$MODPATH/update.json" \
         "$MODPATH/.gitignore"
  rm -f "$MODPATH"/*.zip

  left=$(find "$MODPATH" -maxdepth 1 -mindepth 1 -exec basename {} \; | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
  assert_eq "$expected" "$left" "after cleanup only module entries remain"

  devs=$(find "$MODPATH" \( -path '*/tests/*' -o -path '*/tools/*' -o -path '*/.workbuddy-ai/*' -o -name '*.zip' \) 2>/dev/null | head -3)
  assert_eq "" "$devs" "nothing developer-ish survives the cleanup"
else
  printf '   SKIP  unzip is not available, installer simulation skipped\n'
fi

harness_finish
