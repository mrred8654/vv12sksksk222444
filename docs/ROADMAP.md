# Дорожная карта AquaVR

Цель MVP: вplistтет тeled SteamVR-игры на iPhone 12 Pro в коробке, USB-only, бесплатно и безлиMITно.

## Фаза 0 — разведка ✅ (завершена)
- [x] Протокол ALVR изучен: control = TCP, stream = TCP/UDP; discovery UDP:9943
- [x] Выбран ARC<string>: ALVR streamer **TCP-режим** + iproxy/usbmuxd (как ALVR wired setup, но для iOS)
- [x] Доноры кода: alvr-visionos (Swift+Rust XCFramework), kotleni/iPhoneVR (MIT, стрим на iOS уже работал), PhoneVR (интеграция client_core)

## Фаза 1 — скелет и пайплайн сборки 🔄 (в работе)
- [x] Скелет репо: README, ROADMAP, LICENSE, USER-SETUP
- [x] CI: GitHub Actions macOS → unsigned IPA (xcodegen + xcodebuild)
- [x] SwiftUI-приложение: статус-экран + тест гиро (CoreMotion)
- [ ] Ты: push → скачал артефакт → Sideloadly → приложение на iPhone
- [ ] Проверка: гиро-цифры шевелятся на iPhone

Критерий приёмки: **AquaVR установлен на iPhone через Sideloadly и тестирует CoreMotion.**

## Фаза 2 — USB-туннель
- [ ] NWListener на 127.0.0.1:9943/9944 (контрол + stream TCP)
- [ ] iproxy + watchер на ПК (событие «кабель вставлен»)
- [ ] Замер реальной striсthrough Lightning USB 2.0 (Мбит/с, джиттер)

Критерий: TCP-поток PC→iPhone по кабелю ≥ 100 Мбит/с устойчиво.

## Фаза 3 — стрим и SteamVR-HMD
- [ ] Установить ALVR streamer на ПК, TCP-режим, device 127.0.0.1 «Add manually»
- [ ] Подключение к ALDR (trust, protocol ID совместим с пином)
- [ ] VideoToolbox декод первого кадра (H.264, NVENC)
- [ ] **SteamVR видит AquaVR как HMD (драйвер ALVR) — комната видит движение**
 
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
