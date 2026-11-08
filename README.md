# nfqws2-android

[English](README_EN.md) | [Русский](README.md)

<img align='right' src='icon.png' width='220px' alt="nfqws2-android Icon">

Полнофункциональный порт **nfqws2** ([zapret2](https://github.com/bol-van/zapret) от bol-van) с поддержкой синтаксиса стратегий Keenetic для Android.

[![KernelSU](https://img.shields.io/badge/KernelSU-Supported-brightgreen.svg)](https://github.com/tiann/KernelSU)
[![Magisk](https://img.shields.io/badge/Magisk-Supported-blue.svg)](https://github.com/topjohnwu/Magisk)
[![APatch](https://img.shields.io/badge/APatch-Supported-orange.svg)](https://github.com/bmax121/APatch)
[![Release](https://img.shields.io/github/v/release/Dea1hwa1cher/nfqws2-android?label=Release)](https://github.com/Dea1hwa1cher/nfqws2-android/releases/latest)
[![Telegram](https://img.shields.io/badge/Telegram-чат_проекта-26A5E4?logo=telegram&logoColor=white)](https://t.me/nfqws2android)
[![License](https://img.shields.io/badge/License-MIT-lightgrey.svg)](LICENSE)

Модуль предназначен для обхода ТСПУ/DPI нативно на уровне ядра через подсистему `netfilter` (NFQUEUE). В отличие от VPN-приложений (V2Ray, ByeDPI и др.), этот метод **не создает виртуального сетевого интерфейса (tun)**, не расходует дополнительный заряд батареи и не режет скорость соединения.

Вопросы, подбор стратегий и новости — в Telegram-чате проекта: **[t.me/nfqws2android](https://t.me/nfqws2android)**

![WebUI: состояние, выбор стратегии, списки](docs/screenshots/dark.png)

## Особенности

* **Нативная работа через NFQUEUE**: модификация пакетов «на лету» без поднятия локального VPN-сервиса.
* **Готовые стратегии по группам**: Flowseal ALT, FAKE TLS AUTO, SIMPLE FAKE и авторские пресеты. Любую можно отредактировать прямо в WebUI и в один тап вернуть к исходнику.
* **Импорт конфигов nfqws2-keenetic**: файлы приводятся к виду встроенных стратегий и появляются в выборе стратегии. Можно импортировать сразу несколько.
* **Пауза в домашней Wi‑Fi сети**: если ваш роутер уже обходит DPI, модуль можно настроить на автоотключение в домашней сети.
* **Фильтрация приложений**: обход только для выбранных приложений или для всех, кроме них.
* **Журналы с краткой статистикой**: запуски, автоперезапуски, ошибки и домены, которые модуль сам добавил в `auto.list`. Фильтр «Ошибки» и подсветка синтаксиса.
* **Резервная копия**: конфиг, списки, стратегии и оформление — одним архивом в `Download`.
* **Обновления модуля из менеджера**: KernelSU, Magisk и APatch сами покажут, что вышла новая версия.
* **WebUI в стиле Material Design 3**: светлая, тёмная и AMOLED-тема, выбор акцента с обоев или на цветовом круге, русский и английский язык.
* **Управление из терминала**: глобальная команда `nfqws2-ctl` в `/system/bin` — статус, смена стратегий, журналы и проверка параметров через `su -c nfqws2-ctl ...`.

![WebUI: журналы, настройки, тема оформления](docs/screenshots/light.png)

## Требования

1. Установленный **KernelSU**, **APatch** или **Magisk**<sup>([без WebUI](https://github.com/topjohnwu/Magisk/issues/8609#event-15568590949))</sup>.
2. Архитектура процессора: **ARM64** (`arm64-v8a`), **ARM** (`armeabi-v7a`), **x86**, **x86_64**.

## Также поддерживается:

- [KsuWebUI](https://github.com/5ec1cff/KsuWebUIStandalone)
- [WebUI-X](https://github.com/MMRLApp/WebUI-X-Portable)
- [MMRL](https://github.com/MMRLApp/MMRL)

## Установка

1. Скачайте последний `.zip` архив из раздела [Releases](https://github.com/Dea1hwa1cher/nfqws2-android/releases/latest).
2. Установите модуль через Ваш root-менеджер.
3. Перезагрузите устройство.
4. Служба запустится автоматически при загрузке системы.

## Благодарности

* [bol-van](https://github.com/bol-van) — за оригинальный и непревзойденный проект zapret.
* [nfqws2-keenetic](https://github.com/nfqws/nfqws2-keenetic) — за идеи адаптации конфигов и логику авто-стратегий.
* [dpi-detector](https://github.com/Runnin4ik/dpi-detector) — за алгоритмы детекции и классификации блокировок DPI.
* [nfqws-menu](https://github.com/rndnaame/nfqws-menu) — за стратегии, блобы и списки адресов хостингов.
* [bindhosts](https://github.com/bindhosts/bindhosts) — за множество референсов и идей.
* Разработчикам [KernelSU](https://github.com/tiann/kernelSU), [Magisk](https://github.com/topjohnwu/magisk) и [APatch](https://github.com/bmax121/APatch).
