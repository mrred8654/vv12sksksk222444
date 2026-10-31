# Фаза 3 — ALVR-клиент на iOS: карта порта и план

Донор: **alvr-visionos** (клон в `vendor/`, не часть репо) + upstream **ALVR** (сабмодуль `ALVR/`, запинен).

## 1. Версии и пины

| Что | Значение | Почему |
|---|---|---|
| ALVR сабмодуль `ALVR/` | коммит `e3fd448029c795b1b2d5835c84c6588bf01bae0d` | workspace **v20.14.1** («with-psvr2-audio-fix»); protocol ID этой версии |
| ALVR на ПК | v20.14.1 или близкий (совместимый protocol ID) | клиент шлёт `protocol_id`; сервер сверяет совместимость |
| Донор Swift | `vendor/alvr-visionos` @ main | перенос Entry/EventHandler/VideoHandler/NALParser/Renderer/Settings |
| Rust | stable ≥ 1.82 (`rust-version.workspace`), target `aarch64-apple-ios`, профиль `distribution` | как у донора |

## 2. Архитектура

```
ПК (Windows)                          iPhone (AquaVR.ipa)
ALVR streamer (TCP-режим, NVENC)
  │ TCP connect→ 127.0.0.1:9943 ──usbmuxd tunnel──▶ client_core: TcpListener 9943 (контроль, bincode+LD)
  │ TCP connect→ 127.0.0.1:9944 ──usbmuxd tunnel──▶ client_core: StreamSocket (TCP 9944, видео H264)
SteamVR драйвер ALVR                    │
                                        ▼
                        Swift-клей: EventHandler (poll_event) →
                          VideoHandler: AnnexB→CMSampleBuffer→VTDecompressionSession→CVPixelBuffer
                          Renderer: Metal-слой (1 глаз, YCbCr→RGB шейдер)
                          HeadTracker: CoreMotion 3DoF → alvr_send_tracking
```

Факты разведки (client_core @ e3fd448):
- Клиент **слушает** TCP 9943; сервер сам подключается. UDP-броадкаст `AnnouncerSocket` — единственный сетевой emits клиента: **вырезаем** (§5).
- `negotiated_config.wired=true` → стрим автоматически TCP. Иначе берётся `settings.connection.stream_protocol` из настроек сервера → на ПК выставить **TCP**.
- Recv-циклы видео/audio/haptics, keepalive, statistics, prediction — всё внутри client_core; Swift их не дублирует.
- Конфиг клиента (hostname/protocol_id) — `app_dirs2` → sandbox-совместимо (Application Support).

## 3. Карта порта (файл → судьба)

| Файл донора | Судьба | Комментарий |
|---|---|---|
| `EventHandler.swift` | **Портим** (адаптация) | Ядро: OutgoingWorker, event-цикл `alvr_poll_event`, коллбэк декодера `handleNals` (lag-guard, IDR-request). Убрать: mDNS (`handleMdnsBroadcasts`), `exit(0)` на background (наше приложение обязано жить в фоне — урок Фазы 2), вызовы WorldTracker.* → HeadTracker. |
| `VideoHandler.swift` | **Портим почти целиком** | `createVideoDecoder` (H264/HEVC desc), `annexBBufferToCMSampleBuffer` (in-place+copy), `feedVideoIntoDecoder`, `getYUVTransformForVideoFormat`, тейблы приватных MTLPixelFormat — переиспользуемое. AV1-ветка мёртвая (A14 нет аппаратного AV1) → `encoder_av1: false`. |
| `NALParser.swift` | **Портим as-is** | `findNaluIndices`, `extractParameterSets` — чистые функции. |
| `Renderer.swift` | **Портим частично** | Берём report-путь (`alvr_report_compositor_start` / `alvr_report_submit` c `lastSubmittedTimestamp`) и идею очереди `frameQueue`. Металл переписываем: у нас CAMetalLayer/MTKView на 1 глаз, кадр = CVPixelBuffer → шейдер YCbCr→RGB ( getYUVTransform × getTextureTypesForFormat). FFR/timewarp/chromaKey — НЕ переносим (Фаза 5+). |
| `Settings.swift` / GlobalSettings | Минимум | Читаем `alvr_get_settings_json` при событиях; локальные тумблеры донора (chroma/persona) не нужны. |
| `ALVRClientApp.swift`, `Entry/`, Info.plist donor | НЕ переносим | Свой SwiftUI-статус-экран AquaVR. |
| `WorldTracker.swift` (204 КБ, ARKit) | **НЕ переносим** | Забираем только вызовы: `alvr_send_tracking(ts, motions, count, nil, nil)` + `alvr_send_view_params(ptr[2])` (см. §4). |
| `RealityKit*`, `CameraView`, `ALVREyeBroadcast`, `Input/`, `Chaperone/Ffr/PerformanceHud` | НЕ переносим | Управление — геймпад на ПК (ALVR server умеет gamepad input); телефон = только head. |
| `Shaders.metal` | Идея | Портим только видео-шейдер (YCbCr→RGB); модели/hud выбрасываем. |

## 4. CoreMotion вместо WorldTracker (3DoF)

iPhone в Cardboard = 3DoF (rotation-only). Новый `HeadTracker.swift`:

```swift
// CMDeviceMotion.attitude.quaternion (x,y,z,w) → AlvrDeviceMotion:
//   device_id  = HEAD_ID (alvr_get_device_id("head"), см. сгенерированный alvr_client_core.h)
//   pose.orientation — сверить порядок компонентов с from_capi_quat в c_api.rs (x,y,z,w!)
//   pose.position = (0,0,0)
//   linear_velocity = angular_velocity = 0
// На каждый кадр рендера: alvr_send_tracking(poll_ts, &motion, 1, nil, nil)
// Один раз (и при изменении): alvr_send_view_params(&viewParams)
//   — фиксированные FoV под Cardboard (~90-96°) + IPD 0.063
```

Prediction: client_core для HEAD сам предсказывает и в v20-протоколе зануляет скорость головы — для сидячих игр этого достаточно.

## 5. Патчи client_core (как патч-файл, НЕ правки сабмодуля)

Сабмодуль — read-only снапшот upstream (`git diff` в нём нельзя кProtect-ировать). Патчи храним как `scripts/client_core_patches.patch`, применяем `git apply` в `build_xcframework.sh` перед cargo build. Так рост protocol ID (драйвер сервера!) остаётся чистым.

1. **AnnouncerSocket → no-op** (`alvr/client_core/src/sockets.rs`): `announce_broadcast()` → `Ok(())` без `send_to`. Ноль UDP/Wi-Fi-пакетов. Цикл соединения не меняется: клиент вечно ждёт TCP-подключения сервера на 9943 через туннель.
2. **Микрофон** (`alvr/client_core/src/connection.rs`): `AudioDevice::new_input` на iOS тянет mic-permission и AVAudioSession — для сидячих игр не нужно. Замена: `microphone_sample_rate: 48000` хардкод (сервер по умолчанию mic выключен; capabilities — декларация).
3. Не трогать: `set_wifi_lock` — android-only.

Патчи транспортного уровня — protocol ID не зависит от них.

## 6. USB-интеграция

| Сокет | Кто слушает | Туннель |
|---|---|---|
| 9943 control | client_core `TcpListener` на телефоне (привязка 0.0.0.0, приём с 127.0.0.1) | PC forwarder 9943→телефон 9943 (Фаза 2, доказано 202 Мбит/с) |
| 9944 stream | `StreamSocketBuilder::listen_for_server`, TCP после handshake | forwarder 9944→9944 |
| UDP 9943 discovery | вырезано патчем | — |

Аудио (urок Фазы 2): приложение обязано жить при замке экрана → AVAudioSession `.playback` (тишина/звук игры) сразу при старте стрима; НЕ `exit(0)` на background (в порте EventHandler это выбрасываем).

## 7. CI-план

- Новый workflow **`.github/workflows/rust.yml`** (создан): macos-latest → сабмодули → rustup `aarch64-apple-ios` → `scripts/build_xcframework.sh` (cargo build `alvr_client_core` + cbindgen `alvr_client_core.h` + фреймворк-шаблон `scripts/framework_template/ios/Info.plist`) → артефакт `ALVRClientCore-xcframework`.
- Шаг 3.2 (обновление `ios.yml`): download-artifact xcframework → положить в `app/ALVRClientCore.xcframework` → xcodegen (embedded framework) → unsigned IPA.
- Каждую ступень Swift-интеграции коммитим отдельно: зелёная сборка = переход к следующей.

## 8. Чек-лист приёма Phase 3 (действия юзера на ПК)

1. Поставить ALVR **v20.14.1** (GitHub releases), SteamVR.
2. Настройки ALVR: Connection → Stream Protocol = **TCP**; Devices → **Add manually** → IP `127.0.0.1`.
3. Порядок запуска: SteamVR → ALVR server → `phase2_usb.bat` → телефон AquaVR «Старт» (экран открыт до старта стрима; в Cardboard после).
4. Ожидание: в ALVR dashboards появится «(Manual)»-девайс → **Trust** → SteamVR видит HMD → первый декодированный кадр на экране iPhone (mono-рендер пока ок).

## 9. Риски (что проверить первым, когда артефакт будет)

- **C-структуры**: до написания Swift-обёрток сверить раскладку `AlvrDeviceMotion`/`AlvrViewParams` по сгенерированному `alvr_client_core.h` (alignment/padding!).
- cdylib внутри .framework на iOS: путь донора проверен (visionOS re-pack), но надо глазами: `otool -l` на dylib в CI-логе (`@rpath` id — уже делается `install_name_tool -id`).
- CoreMotion poll: 100 Гц не нужно — шлём на кадре рендера (90–120 Гц достаточно).
- KEEPALIVE_TIMEOUT (~10 c) при рестарте туннеля:client_core переживает переподключение сам (lifecycle-loop).
