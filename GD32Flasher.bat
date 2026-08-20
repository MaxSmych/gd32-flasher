@echo off
rem Launch GD32Flasher GUI without a console window.
start "" powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0GD32Flasher.ps1"
