@echo off
setlocal
title Install Media Link Launcher

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-media-link-launcher.ps1"
set "MediaLinkLauncherExitCode=%ERRORLEVEL%"

echo.
if not "%MediaLinkLauncherExitCode%"=="0" (
    echo Installation did not complete.
)
pause
exit /b %MediaLinkLauncherExitCode%