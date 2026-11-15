# AGENTS.md — Working Guide for nfqws2-android

This document defines the architecture, invariants, development workflows, and constraints for autonomous AI agents and developers working on the `nfqws2-android` repository.

`nfqws2-android` is a high-performance Magisk / KernelSU / APatch root module for Android that circumvents Deep Packet Inspection (DPI). The module is powered by the `nfqws2` daemon (a fork of `bol-van/zapret2`), which intercepts IP packets via netfilter `NFQUEUE` and modifies them according to desync strategies defined in `strategies/*.conf` and Lua scripts in `lua/`. The user interface is an M3 WebUI located in `webroot/`, communicating with the backend via the `bin/nfqws2-ctl` control utility.

> [!IMPORTANT]
> Every agent working in this repository must maintain traffic integrity, strictly adhere to target shell dialect constraints, preserve POSIX safety, run full regression tests before committing, and sign all commits (`git commit -s`). Never push changes to a remote repository without explicit instruction from the repository owner.

---

## 1. Repository Architecture & Components

```
nfqws2-android/
├── bin/                    # Precompiled runtime binaries (nfqws2 daemon, pkglist.jar) & ctl CLI
├── binaries/               # Architecture-specific binaries (android-arm, arm64, x86, x86_64)
├── blobs/                  # Binary fake payload packets (QUIC Initial, TLS ClientHello, HTTP)
├── defaults/               # Default fallback configs, strategy definitions, and list templates
├── lib/                    # Shared core shell library (lib/common.sh)
├── lists/                  # Active domain and IP target/exclusion lists
├── lua/                    # Lua desync engine scripts (zapret-auto.lua, zapret-lib.lua, etc.)
├── strategies/             # Strategy configuration files (*.conf) and meta.tsv
├── strategy-catalogs/      # Categorized strategy lists (tcp_tls, tcp_http, udp_quic, udp_voice)
├── system/                 # System binary symlinks for terminal CLI execution
├── tests/                  # Multi-shell test harness, mocks, and Playwright WebUI test suites
├── webroot/                # Material 3 responsive WebUI frontend (HTML, CSS, JS)
├── customize.sh            # Magisk/KernelSU installation script
├── service.sh              # Late-start daemon service and background watcher controller
├── post-fs-data.sh         # Early-mount initialization
├── boot-completed.sh       # Post-boot trigger handler
└── uninstall.sh            # Clean removal script (purges runtime state and config data)
```

### Component Roles
- **Core Daemon (`bin/nfqws2`)**: Native C binary compiled with LuaJIT and libnetfilter_queue support. Intercepts packets matching iptables rules and applies packet fragmentation, fake payloads, out-of-order sequencing, and SNI desynchronization.
- **Service Controller (`service.sh`)**: Manages the lifecycle of `nfqws2`, applies iptables rules, monitors VPN interfaces, controls watchdog processes (`smartkill`, `wlwatch`, `watchdog`, `netwatch`), and performs automated traffic rollback if a restart fails.
- **Library (`lib/common.sh`)**: Central POSIX shell library containing 240+ functions for firewall rule manipulation, process management, config parsing, state persistence, interface detection, and lock synchronization.
- **Control Interface (`bin/nfqws2-ctl`)**: The primary CLI entry point for both interactive terminal use and the WebUI. Exposes commands for service control, strategy selection, app filtering, diagnostics, configuration linting, and JSON status reporting.
- **WebUI (`webroot/`)**: Responsive, lightweight Material 3 web application running inside root manager WebUI containers (KernelSU/APatch) or via local HTTP daemon. Interacts with the backend solely via `nfqws2-ctl`.

---

## 2. Test Suites & Verification Harness

All changes must pass regression tests before being considered complete.

### Test Commands

```sh
sh tests/run.sh              # Run the complete test suite (18 suites, dash and bash)
sh tests/run.sh --fast       # Fast run: skips slow firewall/service mutations and browser suites
sh tests/run.sh --keep       # Preserve temporary sandbox directories for inspection
sh tests/module/test_ctl.sh  # Run a single module test suite (e.g. test_ctl, test_data, test_smart)
```

### Test Harness Rules & Execution Model
1. **Multi-Shell Compatibility**: Tests run under both `dash` and `bash` (`NFQWS_TEST_SHELLS`). `lib/common.sh` must parse and execute cleanly in both environments.
2. **Parallel Suite Execution**: Suites run in parallel up to `JOBS` (defaults to CPU core count up to 8). On Windows / Git Bash, process spawn overhead is high (~0.3s per spawn). To run tests sequentially, set `NFQWS_TEST_JOBS=1`.
3. **Headless Browser Suites**: Browser suites (`webui: rendered geometry`, `webui: memory & leak audit`, etc.) require Node.js and Playwright. The environment variable `NODE_PATH` must point to `node_modules` containing `playwright`, otherwise browser suites are automatically skipped (`SKIP`).
4. **Sandboxed Mocking**: `tests/lib/harness.sh` creates an isolated clone of the repository in `/tmp/nfqws2-test.XXXXXX` and injects high-fidelity mocks for `iptables`, `iptables-restore`, `iptables-save`, `nfqws2`, `curl`, `getprop`, `pm`, `sysctl`, `settings`, and `rm`.
5. **Stateful Firewall Mocking**: Mock iptables rules are stored in real state files in `MOCK_IPT_STORE`. Draining loops such as `while iptables -D ...; do :; done` rely on actual rules being removed on each iteration until empty. Mocks must never be simplified to a static "always return 0".
6. **No Local Binary Builds Required**: The `bin/nfqws2` binary is compiled exclusively via GitHub Actions CI (`.github/scripts/build-android-binaries.sh`). Changes to shell scripts, Lua scripts, configs, and the WebUI do not require a local C/C++ compiler.

---

## 3. Shell Dialect & Android Runtime Pitfalls (`mksh` / `ash`)

Production scripts run in Android's `/system/bin/sh` (`mksh`) and busybox `ash`. These environments differ significantly from GNU `bash` and desktop `dash`. Desktop test runners do not catch these pitfalls automatically.

### Proven Traps & Invariants

#### 1. Scope and Variable Assignment in `local`
In `mksh` and `ash`, variable expansion in chained declarations occurs **before** preceding assignments take effect:
```sh
# BROKEN in mksh/ash: $i expands BEFORE assignment!
local i="$1" pidf="/data/run/nfqws2.$i.pid"

# CORRECT: Split declarations onto separate lines
local i="$1"
local pidf="/data/run/nfqws2.$i.pid"
```

#### 2. Single-Read Buffer Collapsing in `/proc/sys/*`
Linux `/proc/sys/*` synthetic files yield their full contents in a single `read()` syscall. `mksh` built-in `read` reads character-by-character; when it issues a second read, the kernel returns EOF (`0 bytes`), causing values to truncate to the first byte.
- **Rule**: Never use `read -r var < /proc/sys/...` in Android shell scripts.
- **Solution**: Parse `/proc/sys/*` via `cat`, `awk`, or `tr` (see `sysctl_apply` and `bench_port_base` in `lib/common.sh`).

#### 3. Standard `awk` Constraints on Android
Android ships with a minimal `awk` (typically Toybox / Toolbox or BusyBox awk), not GNU `gawk`:
- `strtonum()` does NOT exist in Android `awk`.
- `length(array)` is NOT supported in standard awk.
- Hexadecimal ports in `/proc/net/tcp*` and `/proc/net/udp*` must be converted via manual base-16 arithmetic loops.

#### 4. Forbidden Conditional Pattern: `A && B || C`
Never write `A && B || C`. In shell grammar, if `A` succeeds but `B` fails, `C` **will execute**.
```sh
# BROKEN: If $own_lock is 1 and svc_lock_release fails, log_error executes!
[ "$own_lock" = "1" ] && svc_lock_release || log_error

# CORRECT: Use explicit if/then/else blocks
if [ "$own_lock" = "1" ]; then
  svc_lock_release
fi
```
`tests/module/test_data.sh` statically parses `lib/common.sh` and fails if `A && B || C` chains are introduced.

#### 5. Subshell Pipeline Deadlocks in Control Scripts
Interactive subshells with pipelines (`cmd1 | cmd2 | cmd3`) inside `nfqws2-ctl` can hang due to Android pseudo-terminal (PTY) buffering and process inheritance.
- Write intermediate pipeline data to a temporary file, and pass the file directly to `awk` or `grep` as an argument.

#### 6. Strict LF Line Endings
All repository files must use Unix LF line endings (`\n`). Windows tools (PowerShell redirection `>`, Python `open(..., 'w')` on Windows, Notepad) inject CRLF (`\r\n`), causing Android's shell to fail with `\r: command not found`.
- Verified via `.gitattributes` and `tests/module/test_data.sh`.
- Check diffs before committing using `git diff --check`.

---

## 4. Network, Firewall & Traffic Invariants

Modifications to firewall rules and process lifecycle affect live network connections. These invariants must never be violated without physical device verification.

### 1. Queue Listener Exclusivity (`-EBUSY`)
The Linux netfilter queue system allows exactly **one** active user-space process to bind to an `NFQUEUE` queue number at any given moment. A second `bind()` call returns `-EBUSY`.
- When restarting or applying a new strategy, the service must cleanly stop and release the running daemon before spawning a new one.

### 2. Mandatory `--queue-bypass` Flag
Every iptables rule targeting `NFQUEUE` must include `--queue-bypass`.
```sh
# REQUIRED: Packets continue normally if daemon crashes or restarts
iptables -w -t mangle -A nfqws_post -p tcp -j NFQUEUE --queue-num 200 --queue-bypass

# FORBIDDEN: Missing --queue-bypass causes traffic blackholing if daemon dies
iptables -w -t mangle -A nfqws_post -p tcp -j NFQUEUE --queue-num 200
```

### 3. Atomic `iptables-restore` Transactions
`iptables -D` operations cannot be batched inside an `iptables-restore` payload. Attempting to flush (`-F`) or delete (`-X`) a chain that is not created in the current transaction will abort the entire transaction.
- Isolate chain cleanup or verify existing chains before applying bulk table changes.

### 4. "Stopped" State Invariant
A stopped module state strictly guarantees that **zero iptables rules and zero custom chains** remain active in the kernel.
- `service.sh stop` must invoke `firewall_ok` and return non-zero if any lingering jumps or chains are detected.

### 5. Verified Rollback Gate on Restart
A running process PID does not guarantee functioning DPI bypass. `service.sh replace_daemon` runs connectivity probes before stopping the old instance (baseline) and two rounds after starting the new instance.
- If traffic passed before the restart but fails after, the service automatically rolls back to the last known working configuration snapshot.
- The working snapshot is updated **only after** traffic successfully passes the verification gate, preventing broken configurations from becoming the rollback target.

### 6. Chain Precedence and Rule Order
Diagnostic and parallel benchmark chains (`nfqws_bench`) must precede standard service chains (`nfqws_post`, `nfqws_pre`).
- If the service re-applies firewall rules while a benchmark or probe is running, packets must continue routing through the active probe queue.
- Rule order is verified by matching rule line indices in `iptables -S`.

### 7. Idempotent Reapplication
Applying firewall rules without an explicit stop must never duplicate rules.
- Always use a draining loop (`while iptables -D ...; do :; done`) immediately before inserting (`-I`), such as with the `NAT_FIX` jump in `POSTROUTING`.

### 8. Kernel Sysctl Preservation
Kernel tuning parameters altered by the module are saved in `state/sysctls` upon activation and restored when stopped.
- Never artificially shorten `nf_conntrack_tcp_timeout_established`: Android push notifications depend on TCP heartbeats spanning up to 28 minutes.

### 9. VoWiFi (Wi-Fi Calling) vs VPN Isolation
When Wi-Fi Calling is enabled, Android brings up an `ipsec*` network interface that routes IMS signaling (`uidrange 0-0`).
- `vpn_active()` in `lib/common.sh` must check `ip rule` to ensure that application UIDs (`uidrange >= 10000`) are present before treating an `ipsec*` interface as a user VPN and pausing circumvention.

---

## 5. WebUI Architecture & Golden Standards

The WebUI is an adaptive, high-performance interface built with vanilla JavaScript, modern CSS tokens, and Material 3 design principles.

- **Directory Layout**:
  - `webroot/index.html`: Structural markup for screens, lists, modals, and icon definitions.
  - `webroot/css/base.css`: Design tokens, Material 3 color roles, typography, and foundational controls.
  - `webroot/css/app.css`: Screen layouts, cards, and responsive component styling.
  - `webroot/js/*.js`: Screen controllers (`status.js`, `lists.js`, `logs.js`, `config.js`, `apps.js`, `theme.js`, etc.).
  - `webroot/js/i18n-en.js`: English translations keyed to canonical Russian UI strings.
- **Typography & Layout Invariants**:
  - The root element `html, body` must declare `font-size: >= 15px;` (1rem = 15–16px).
  - Absolute font size floor: No visible text element may render below `12px` (no `text-[9px]..text-[11px]`).
  - Numbers, timers, bitrates, and packet counters must use `font-variant-numeric: tabular-nums` to eliminate jitter.
- **Dialogs & Modals**:
  - All modals must follow a structured chassis pattern: header, scrollable body (`overflow-y-auto`, `max-height: 85vh`), and footer.
  - Backdrop tap and `Escape` key dismissal must always resolve the active modal promise.
- **Memory & Resource Leak Prevention**:
  - The WebUI runs continuously in the user's root manager. Event listeners, intervals, and observers must be cleaned up when screens are unmounted.
  - Verified via Node.js garbage collection testing: `node --expose-gc tests/webui/test_memory.js`.

---

## 6. Git, Commit & Release Invariants

- **Signed Commits**: Every commit must be signed off with the author's identity: `git commit -s`.
- **Pre-Commit Verification**: A commit is permitted **only** after the full test suite (`sh tests/run.sh`) passes with 0 errors on the local machine.
- **Single Responsibility**: One commit per distinct change or fix. Commit message bodies must clearly explain *why* the change was made, referencing root causes.
- **Never Track `tools/`**: The `tools/` directory is strictly for local developer utilities. `tests/run.sh` will fail if any file in `tools/` is tracked by git.
- **Release Procedure**:
  1. Increment `version` and `versionCode` in `module.prop` and `update.json`.
  2. Document changes in `changelog.md` under both `RU` and `EN` sections.
  3. Commit changes to `main` with `chore(release): bump version to vX.Y.Z and update changelog`.
  4. Tag the release (`git tag vX.Y.Z`).
  5. Push commits and tags to GitHub only when instructed by the repository owner (`git push origin main; git push origin vX.Y.Z`).
  6. The GitHub Actions workflow `.github/workflows/release.yml` will automatically build the cross-architecture binaries, package the module zip, extract release notes from `changelog.md`, and publish the release.

---

## 7. Device Interaction & ADB Debugging

- **Path Conversions & Quoting**:
  - Always prefix ADB commands with `MSYS_NO_PATHCONV=1` when pushing from Windows environments using `cygpath -w`.
  - Avoid deeply nested quotes in `su -c "..."`. Write complex scripts to a temporary file, push to `/data/local/tmp/`, and execute via `su -c 'sh /data/local/tmp/test.sh'`.
- **Hot-Deploy Backup**:
  - Before modifying a running module on a real device, take a full tarball backup:
    ```sh
    tar cf /data/local/tmp/mod-backup-$(date +%s).tar -C /data/adb/modules/nfqws2-android .
    ```
  - After deploying changes, verify checksum parity against git `HEAD` using `sha256sum`.
- **Limits of Host Mocking**:
  - Host sandboxes prove syntax, logic, and state transitions, but cannot prove real kernel behavior (e.g. netfilter queue binding, real curl socket binding with `--local-port`, conntrack table behavior, or high-throughput queue bypass under load). Real traffic behavior must be validated on an actual Android device.

---

## 8. Rejected Features & Deliberate Exclusions

Do not attempt to implement, port, or reintroduce the following features:

1. **`--fastpath-workaround=auto`**: Specifically designed for Keenetic router hardware acceleration. Completely irrelevant and dysfunctional on Android kernels.
2. **Hotspot Client IP Filtering**: Explicitly rejected by repository architecture decisions.
3. **Hardcoded DNS & Hosts Pinning**: Permanently removed in commit `2e41b9f`. Do not re-add DNS overriding or static hosts manipulation into module scripts.
4. **Speculative `kill_descendants` Rewrites**: Modifying positional parsing of `/proc/PID/stat` to handle process names with spaces (`comm`) was investigated and **not confirmed**. Do not change process tree termination without empirical reproduction on real hardware.
