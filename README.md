# AquaVR — открытый SteamVR-клиент для iPhone в Cardboard-коробке

Бесплатная, безлимитная замена iVRy: стрим SteamVR-игр с ПК (Windows, NVIDIA → NVENC) на iPhone
**строго по Lightning-USB** (usbmuxd, ноль Wi-Fi). Телефон виден в SteamVR как настоящий HMD.

- Клиент (iPhone): Swift + Metal + VideoToolbox (декод H.264/HEVC) + CoreMotion/Cardboard SDK
- Сервер (ПК): [ALVR](https://github.com/alvr-org/ALVR) (готовый SteamVR-драйвер, TCP-режим) + iproxy-туннель через usbmuxd
- Сборка: GitHub Actions (macOS-раннер) → **unsigned IPA** → подпись [Sideloadly](https://sideloadly.io)

## Текущий этап

Смотри [docs/ROADMAP.md](docs/ROADMAP.md). Сейчас: **Фаза 1 — скелет и первый IPA на iPhone.**

## Как собрать и поставить (идёт в docs/USER-SETUP.md)

1. `git push` → GitHub Actions собирает **AquaVR-unsigned.ipa** (артефакт)
2. Скачать артефакт → подписать в Sideloadly своим Apple ID → установить на iPhone
3. Приложение показывает статус-экран и живые данные гиро — проверка фазы 1

## Лицензия

MIT для скелета. **Важно:** после интеграции `alvr-client_core` (Rust, AGPL-3.0) всё приложение
автоматически становится **AGPL-3.0** — открытый исходный код обязателен. Это осознанное решение
проекта, не проблема.
