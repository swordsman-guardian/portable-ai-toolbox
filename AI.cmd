@echo off
rem ============================================================
rem  AI.cmd -- DIRECT MODE. Double-click to start.
rem  Drag a folder onto this file to use it as the working dir.
rem
rem  NOTE: ASCII-only on purpose. cmd.exe reads batch files in the
rem  OEM codepage (936 here), so UTF-8 Chinese in a .cmd would be
rem  mojibake. All Chinese UI comes from the PowerShell scripts,
rem  which are UTF-8 *with BOM*.
rem ============================================================
chcp 65001 >nul 2>&1
setlocal

set "LAUNCH=%~dp0scripts\launch.ps1"
if not exist "%LAUNCH%" (
    echo.
    echo   [ERROR] Cannot find: %LAUNCH%
    echo   The USB drive may be incomplete.
    echo.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%LAUNCH%" %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo   [ERROR] launch.ps1 exited with code %RC%
    echo.
    pause
)
endlocal
exit /b %RC%
