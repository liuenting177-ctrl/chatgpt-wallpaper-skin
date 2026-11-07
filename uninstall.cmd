@echo off
chcp 65001 >nul
setlocal
echo.
echo  ChatGPT Wallpaper Skin - uninstaller
echo  ------------------------------------
echo.
if exist "%~dp0uninstall.ps1" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\uninstall.ps1" %*
)
set RC=%ERRORLEVEL%
echo.
if not "%RC%"=="0" echo Uninstaller exited with code %RC%.
pause
endlocal
