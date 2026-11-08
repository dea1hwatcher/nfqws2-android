# nfqws2-android

[English](README_EN.md) | [Русский](README.md)

<img align='right' src='icon.png' width='220px' alt="nfqws2-android Icon">

Full-featured Android port of **nfqws2** ([zapret2](https://github.com/bol-van/zapret) by bol-van) with Keenetic strategy syntax support.

[![KernelSU](https://img.shields.io/badge/KernelSU-Supported-brightgreen.svg)](https://github.com/tiann/KernelSU)
[![Magisk](https://img.shields.io/badge/Magisk-Supported-blue.svg)](https://github.com/topjohnwu/Magisk)
[![APatch](https://img.shields.io/badge/APatch-Supported-orange.svg)](https://github.com/bmax121/APatch)
[![Release](https://img.shields.io/github/v/release/Dea1hwa1cher/nfqws2-android?label=Release)](https://github.com/Dea1hwa1cher/nfqws2-android/releases/latest)
[![Telegram](https://img.shields.io/badge/Telegram-Project_Chat-26A5E4?logo=telegram&logoColor=white)](https://t.me/nfqws2android)
[![License](https://img.shields.io/badge/License-MIT-lightgrey.svg)](LICENSE)

This module is designed for native, kernel-level DPI circumvention via the `netfilter` subsystem (NFQUEUE). Unlike VPN-based tools (V2Ray, ByeDPI, etc.), this method **does not create a virtual network interface (tun)**, consumes no extra battery, and does not throttle network throughput.

Community support, strategy discussion, and news — in our Telegram chat: **[t.me/nfqws2android](https://t.me/nfqws2android)**

![WebUI: status, strategy selection, lists](docs/screenshots/dark.png)

## Features

* **Native operation via NFQUEUE**: on-the-fly packet modification without starting a local VPN service.
* **Grouped ready-to-use strategies**: Flowseal ALT, FAKE TLS AUTO, SIMPLE FAKE, Turkish ISP presets, and custom author presets. Every strategy can be edited directly in the WebUI and restored to default in a single tap.
* **Import nfqws2-keenetic configs**: automatically converts Keenetic configs to native strategies and adds them to the selector. Multiple configs can be imported simultaneously.
* **Pause on Home Wi-Fi**: if your home router already handles DPI circumvention, configure the module to automatically pause on your home network.
* **Per-app filtering**: apply bypass rules only to selected apps or exclude specific apps from interception.
* **Logs with summary statistics**: tracking service starts, auto-restarts, errors, and domains automatically learned into `auto.list`. Features an "Errors" filter and syntax highlighting.
* **Full backup**: backup configuration, lists, custom strategies, and theme settings as a single `.zip` archive in your `Download` folder.
* **In-manager module updates**: KernelSU, Magisk, and APatch automatically notify you when a new release is available.
* **Material Design 3 WebUI**: Light, Dark, and AMOLED themes, dynamic monet palette derived from wallpaper or a custom color wheel, with full Russian and English localization.
* **Terminal CLI control**: global `nfqws2-ctl` command in `/system/bin` — query status, switch strategies, inspect logs, and manage parameters via `su -c nfqws2-ctl ...`.

![WebUI: logs, settings, theme](docs/screenshots/light.png)

## Requirements

1. **KernelSU**, **APatch**, or **Magisk**<sup>([without WebUI](https://github.com/topjohnwu/Magisk/issues/8609#event-15568590949))</sup>.
2. CPU architecture: **ARM64** (`arm64-v8a`), **ARM** (`armeabi-v7a`), **x86**, **x86_64**.

## Also Supported:

- [KsuWebUI](https://github.com/5ec1cff/KsuWebUIStandalone)
- [WebUI-X](https://github.com/MMRLApp/WebUI-X-Portable)
- [MMRL](https://github.com/MMRLApp/MMRL)

## Installation

1. Download the latest `.zip` archive from [Releases](https://github.com/Dea1hwa1cher/nfqws2-android/releases/latest).
2. Install the module through your root manager.
3. Reboot your device.
4. The service will start automatically on boot.

## Acknowledgments

* [bol-van](https://github.com/bol-van) — for the original and unrivaled zapret project.
* [nfqws2-keenetic](https://github.com/nfqws/nfqws2-keenetic) — for config adaptation concepts and auto-strategy logic.
* [dpi-detector](https://github.com/Runnin4ik/dpi-detector) — for DPI blocking detection and classification algorithms.
* [nfqws-menu](https://github.com/rndnaame/nfqws-menu) — for strategies, blobs, and hosting IP address lists.
* [bindhosts](https://github.com/bindhosts/bindhosts) — for references and design ideas.
* Developers of [KernelSU](https://github.com/tiann/KernelSU), [Magisk](https://github.com/topjohnwu/Magisk), and [APatch](https://github.com/bmax121/APatch).
