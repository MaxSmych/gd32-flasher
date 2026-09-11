@echo off
rem Collects why GD32Flasher does not start on this machine.
rem Writes a log to the Desktop and keeps the window open.
setlocal
cd /d "%~dp0"
set "LOG=%USERPROFILE%\Desktop\gd32flasher_diag.txt"

echo GD32Flasher diagnostics > "%LOG%"
echo Date: %DATE% %TIME% >> "%LOG%"
echo User: %USERNAME% on %COMPUTERNAME% >> "%LOG%"
echo Folder: %CD% >> "%LOG%"
echo. >> "%LOG%"

echo --- files in folder --- >> "%LOG%"
dir /b >> "%LOG%" 2>&1
echo. >> "%LOG%"

echo --- powershell --- >> "%LOG%"
where powershell >> "%LOG%" 2>&1
powershell -NoProfile -Command "$PSVersionTable.PSVersion.ToString()" >> "%LOG%" 2>&1
echo. >> "%LOG%"

echo --- execution policy --- >> "%LOG%"
powershell -NoProfile -Command "Get-ExecutionPolicy -List | Out-String" >> "%LOG%" 2>&1
echo. >> "%LOG%"

echo --- WinForms availability --- >> "%LOG%"
powershell -NoProfile -ExecutionPolicy Bypass -STA -Command "Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing; 'WinForms OK'" >> "%LOG%" 2>&1
echo. >> "%LOG%"

echo --- script launch attempt (errors below, if any) --- >> "%LOG%"
powershell -NoProfile -ExecutionPolicy Bypass -STA -Command "& { $ErrorActionPreference='Stop'; try { $null = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path '.\GD32Flasher.ps1').Path, [ref]$null, [ref]$null); 'Script found and parsed OK' } catch { 'FAILED: ' + $_.Exception.Message } }" >> "%LOG%" 2>&1
echo. >> "%LOG%"

echo --- blocked file check (Mark of the Web) --- >> "%LOG%"
powershell -NoProfile -Command "Get-ChildItem -Recurse -File | Get-Item -Stream Zone.Identifier -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FileName" >> "%LOG%" 2>&1
echo. >> "%LOG%"

type "%LOG%"
echo.
echo ============================================================
echo Log saved to: %LOG%
echo Send this file if the program still does not start.
echo ============================================================
pause
