@echo off
REM AquaVR Phase 2: поднять USB-туннель 9943/9944 + замер скорости (двойной клик).
REM iPhone: AquaVR открыто, кнопка "Старт USB 9943/9944" нажата.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0phase2_usb.ps1"
pause
