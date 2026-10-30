@echo off
REM AquaVR: git add + commit + push (bypasses ExecutionPolicy)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0push.ps1"
pause
