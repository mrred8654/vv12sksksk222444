# Дорожная карта AquaVR

Цель MVP: вplistтет тeled SteamVR-игры на iPhone 12 Pro в коробке, USB-only, бесплатно и безлиMITно.

## Фаза 0 — разведка ✅ (завершена)
- [x] Протокол ALVR изучен: control = TCP, stream = TCP/UDP; discovery UDP:9943
- [x] Выбран ARC<string>: ALVR streamer **TCP-режим** + iproxy/usbmuxd (как ALVR wired setup, но для iOS)
- [x] Доноры кода: alvr-visionos (Swift+Rust XCFramework), kotleni/iPhoneVR (MIT, стрим на iOS уже работал), PhoneVR (интеграция client_core)

## Фаза 1 — скелет и пайплайн сборки ✅ (завершена 31.10.2026)
- [x] Скелет репо: README, ROADMAP, LICENSE, USER-SETUP
- [x] CI: GitHub Actions macOS → unsigned IPA (xcodegen + xcodebuild)
- [x] SwiftUI-приложение: статус-экран + тест гиро (CoreMotion)
- [x] Пользователь: Sideloadly → приложение на iPhone
- [x] Проверка: гиро-цифры шевелятся на iPhone («гиро ок»)

Критерий приёмки: **AquaVR установлен на iPhone через Sideloadly и тестирует CoreMotion.** ✅

## Фаза 2 — USB-туннель ✅ (завершена 31.10.2026)
- [x] NWListener на 127.0.0.1:9943/9944 (контрол + stream TCP), NSListener-фичи: протокол v0.1+ замер скорости
- [x] Туннель ПК: `pymobiledevice3 usbmux forward` (usbmuxd из Store-iTunes, socket 127.0.0.1:27015) — scripts/phase2_usb.ps1
- [x] Замер: **RX 202 Мбит/с, TX 268 Мбит/с** (16 МБ каждую сторону; tools/aqua_speedtest.py)
- [x] Найдено: при выключении экрана iOS подвешивает app и убивает сокеты → держать экран/добавить фоновое аудио в Фазе 3+

Критерий: TCP-поток PC→iPhone по кабелю ≥ 100 Мбит/с устойчиво. ✅ (202!)

## Фаза 3 — стрим и SteamVR-HMD (в работе)
- [x] Разведка донора: connection.rs клиент слушает TCP 9943; стрим = TCP (wired/settings); UDP-announce вырезаем
- [x] Карта порта: docs/PHASE3.md (перенос/выброс/HeadTracker CoreMotion + патчи client_core)
- [x] Сабмодуль ALVR @ e3fd448 (v20.14.1) + scripts/build_xcframework.sh + workflow rust.yml (CI артефакт ALVRClientCore-xcframework)
- [ ] CI собрал ALVRClientCore.xcframework (aarch64-apple-ios) — сверить alvr_client_core.h
- [ ] Перенос Swift-ядра: EventHandler/VideoHandler/NALParser/Renderer-report в app/Sources
- [ ] HeadTracker (CoreMotion 3DoF) + alvr_send_tracking/view_params
- [ ] Metal-слой: CVPixelBuffer → YCbCr→RGB → CAMetalLayer (1 глаз)
- [ ] Подключение: ALVR v20.14.1 ПК, TCP-режим, Add manually 127.0.0.1 + туннель phase2
- [ ] Первый декодированный кадр + «HMD detected» в SteamVR

Критерий: SteamVR Home отображается на iPhone (моно-режим ок).

## Фаза 4 — VR-сборка
- [ ] Стерео (2 глаза) + Metal композитор
- [ ] CoreMotion поза → ALVR (трекинг поворотов)
- [ ] Коррекция линз (феріх delleфlt параметры; QR потом)

Критерий: гиро-повороты в SteamVR Home; стерео без раздвоения.

## Фаза 5 — играбельность
- [ ] Звук (AudioToolbox/Audio Unit)
- [ ] Глисад коmpensión / latency tuning (targeting < 100 ms motion-to-photon)
- [ ] Авто-реконнект при выдёргивании кабеля
- [ ] USB-only проверка: Wi-Fi выключен — всё работает

Критерий: сидячие игры (гонки/симуляторы, геймпад) 20 мин без вылетов.

## Позже
- QR-калибровка линз, FFR/фовеация, USB wake-автоматика (Shortcuts-рецепт в README)
