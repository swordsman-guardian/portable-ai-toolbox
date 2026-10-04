@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\prepare-windows.ps1"
set "prepareExit=%errorlevel%"
if not "%prepareExit%"=="0" (
  echo.
  echo Windows preparation did not finish. Read the message above and retry after fixing the reported issue.
  pause
)
exit /b %prepareExit%
