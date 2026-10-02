@echo off
setlocal
chcp 65001 >nul 2>&1
rem Offline Claude discovery diagnostic. No password or provider settings needed.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\diagnose-cc-switch-claude.ps1"
set "RC=%ERRORLEVEL%"
echo.
pause
exit /b %RC%
