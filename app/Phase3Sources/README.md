# app/Phase3Sources — стейджинг порта Phase 3

Файлы здесь **не компилируются** (project.yml тянет только `app/Sources`).
Переносятся в `app/Sources` за один коммит, когда в CI появится артефакт
`ALVRClientCore-xcframework` и workflow `ios.yml` научится эмбеддить
`app/ALVRClientCore.xcframework` перед xcodegen.

Происхождение: порт из `vendor/alvr-visionos/ALVRClient` (AGPL-3.0).
**В момент интеграции этих файлов в приложение LICENSE репозитория меняется
с MIT на AGPL-3.0-or-later**, README отмечает источник и лицензию.

Порядок интеграции (см. docs/PHASE3.md):
1. `NALParser.swift` — без изменений, только компилируемость.
2. `VideoHandler.swift` — декодер (H264/HEVC), выход фикс: 8-bit 4:2:0 biplanar video-range.
3. `AlvrSession.swift` — event-цикл client_core + очередь кадров + report-путь.
4. `HeadTracker.swift` — CoreMotion 3DoF → alvr_send_tracking("/user/head").
5. `FrameRenderer.swift` — MTKView: два plane-текстуры → шейдер YCbCr→RGB, один глаз.
6. StatusView: третья секция «ALVR» (статус/лаги/START кнопка) + вызов AlvrSession.start().
