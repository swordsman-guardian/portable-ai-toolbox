@echo off
rem ============================================================
rem  AI-settings -- CONFIG MODE.
rem  Menu: start / install harness / pick working dir /
rem        switch provider / self-check / quit.
rem
rem  NOTE: ASCII-only on purpose (see AI.cmd for why).
rem ============================================================
chcp 65001 >nul 2>&1
setlocal

set "LAUNCH=%~dp0scripts\launch.ps1"
if not exist "%LAUNCH%" (
    echo.
    echo   [ERROR] Cannot find: %LAUNCH%
    echo.
    pause
    exit /b 1
)

set "PSENGINE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if defined PROCESSOR_ARCHITEW6432 set "PSENGINE=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSENGINE%" (
    echo [ERROR] Windows PowerShell is unavailable on this computer.
    pause
    exit /b 1
)
"%PSENGINE%" -NoProfile -ExecutionPolicy Bypass -File "%LAUNCH%" -Config
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo   [ERROR] exited with code %RC%
    echo.
    pause
)
exit /b %RC%
