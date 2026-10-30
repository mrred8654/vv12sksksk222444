@echo off
REM AquaVR Phase 2: start USB tunnel 9943/9944 + speed test (double click).
REM iPhone: AquaVR open, press "Start USB 9943/9944".
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0phase2_usb.ps1"
pause
