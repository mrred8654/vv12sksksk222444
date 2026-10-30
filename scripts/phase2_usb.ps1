# AquaVR Phase 2: USB-туннель через usbmuxd (Lightning-кабель) + опциональный спидтест.
# iPhone должен быть подключён кабелем и на нём запущено AquaVR с кнопкой "Старт USB 9943/9944".
param(
    [switch]$NoTest
)
$ErrorActionPreference = "Continue"

Write-Host "== AquaVR USB-туннель (usbmuxd) =="

function Ensure-Forward($port) {
    $existing = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "порт ${port}: уже слушается на ПК — туннель пропущен"
        return
    }
    Start-Process -FilePath "py" `
        -ArgumentList "-m", "pymobiledevice3", "usbmux", "forward", "--host", "127.0.0.1", "$port", "$port" `
        -WindowStyle Minimized
    Write-Host "туннель ${port} -> iPhone:${port} запущен (окно в трее)"
}

Ensure-Forward 9943
Ensure-Forward 9944
Start-Sleep -Milliseconds 2000

if (-not $NoTest) {
    Write-Host ""
    Write-Host "== Спидтест через туннель =="
    & py "$PSScriptRoot\..\tools\aqua_speedtest.py" 33
}
