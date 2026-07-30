@echo off
setlocal
title Uninstall Media Link Launcher

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall-media-link-launcher.ps1"
set "MediaLinkLauncherExitCode=%ERRORLEVEL%"

echo.
if not "%MediaLinkLauncherExitCode%"=="0" (
    echo Uninstallation did not complete.
)
pause
exit /b %MediaLinkLauncherExitCode%