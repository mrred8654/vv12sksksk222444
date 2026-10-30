# Настройка твоего ПК и iPhone (фаза 1)

## 1. Git на ПК (одноразово, ~2 мин)

```powershell
winget install --id Git.Git -e --accept-source-agreements --accept-package-agreements
```

После установки закрой и снова открой терминал (чтобы PATH обновился). Проверка: `git --version`.

## 2. iTunes (обязательно, для usbmuxd)

Скачай и установи **iTunes для Windows с сайта Apple** (64-bit):
https://www.apple.com/itunes/download/win64
Важно: версия с сайта apple.com, **НЕ Microsoft Store** (драйверы Apple Mobile Device входят в неё).
Запускать после установки не нужно — нужны только драйверы.

## 3. Sideloadly (подпись и установка IPA на iPhone)

1. Скачай: https://sideloadly.io → Windows версия.
2. Установи, включи iPhone кабелем, разблокируй iPhone, нажми «Trust» (Доверять).

## 4. Первый билд: push и артефакт

1. Открой PowerShell: `cd $env:USERPROFILE\AquaVR`
2. Запусти `.\scripts\push.ps1`
   - В первый раз откроется браузер с логином GitHub — залогинься, всё.
3. На GitHub: вкладка **Actions** → job «iOS build (unsigned IPA)» → жди зелёную галочку (~4–6 мин).
4. Внизу job'а скачай **AquaVR-unsigned-ipa** (zip с ipa внутри, распакуй).

⚠️ Репозиторий должен оставаться **публичным** (Settings → General → Danger Zone: если Private —
macOS-раннеры Actions платные, сборка зависнет в `Waiting for a runner`).

## 5. Подпись и установка на iPhone (Sideloadly)

1. Открой Sideloadly, перетащи `AquaVR-unsigned.ipa` в окно.
2. Введи свой Apple ID (iCloud-почта) → Start.
3. Если окно «Developer Mode»: на iPhone **Настройки → Конфиденциальность и безопасность →
   Режим разработчика → Включить** (попросит перезагрузку).
4. Иконка AquaVR появится на SpringBoard. Первый запуск iPhone скажет «Непроверенный разработчик» —
   Настройки → Основные → VPN и управление устройством → своему Apple ID → «Доверять».

Ограничения бесплатного Apple ID: подпись на **7 дней** (перевыпускается тем же Sideloadly, те же 2 мин),
до **3 приложений**. Всё для фаз 1–5 хватит с запасом.

## 6. Что проверяем на iPhone (критерий фазы 1)

Открой AquaVR → нажми «Start gyro test» → покрути телефон:
- `pitch/roll/yaw` должны меняться плавно, без дёрганий.

Пришли мне скрин с цифрами (или скажи «гиро ок») — стартуем фазу 2 (USB-туннель).
