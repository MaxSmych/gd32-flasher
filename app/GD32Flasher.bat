@echo off
rem Cyrillic paths passed as an argument arrive mangled, so cd into the script
rem folder first and launch it by bare name. The GUI hides this console itself.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -STA -File "GD32Flasher.ps1"
if errorlevel 1 (
    echo.
    echo ================ GD32Flasher failed to start ================
    echo See the error above. Press any key to close.
    pause
)
