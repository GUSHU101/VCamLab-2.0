@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0"
if /I "%~1"=="--self-test" goto gui_self_test
if /I "%~1"=="--smoke-test" goto gui_smoke_test
start "VirtualCamPro Windows Control Center" powershell.exe -NoLogo -NoProfile ^
    -ExecutionPolicy Bypass -WindowStyle Hidden ^
    -File "%~dp0scripts\install-ios-gui.ps1"
exit /b %errorlevel%

:gui_self_test
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass ^
    -File "%~dp0scripts\install-ios-gui.ps1" -SelfTest
exit /b %errorlevel%

:gui_smoke_test
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass ^
    -File "%~dp0scripts\install-ios-gui.ps1" -SmokeTest
exit /b %errorlevel%
