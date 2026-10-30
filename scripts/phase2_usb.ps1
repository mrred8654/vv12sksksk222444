# AquaVR Phase 2: USB tunnel via usbmuxd (Lightning cable) + optional speed test.
# iPhone must be connected by cable, AquaVR open with "Start USB 9943/9944" pressed.
# NOTE: ASCII only on purpose - PowerShell 5.1 misreads UTF-8 .ps1 without BOM.
param(
    [switch]$NoTest
)
$ErrorActionPreference = "Continue"

Write-Host "== AquaVR USB tunnel (usbmuxd) =="

function Ensure-Forward($port) {
    $existing = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "port ${port}: already listening on PC - skip"
        return
    }
    Start-Process -FilePath "py" `
        -ArgumentList "-m", "pymobiledevice3", "usbmux", "forward", "--host", "127.0.0.1", "$port", "$port" `
        -WindowStyle Minimized
    Write-Host "tunnel ${port} -> iPhone:${port} started (minimized window)"
}

Ensure-Forward 9943
Ensure-Forward 9944
Start-Sleep -Milliseconds 2000

if (-not $NoTest) {
    Write-Host ""
    Write-Host "== Speed test through tunnel =="
    & py "$PSScriptRoot\..\tools\aqua_speedtest.py" 33
}
