@echo off
chcp 65001 >nul
setlocal
echo.
echo  ChatGPT Wallpaper Skin - installer
echo  ----------------------------------
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
set RC=%ERRORLEVEL%
echo.
if not "%RC%"=="0" (
  echo Installer exited with code %RC%. Read the message above.
) else (
  echo Install finished. You can close this window.
)
pause
endlocal
