@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0"

if /I "%~1"=="--self-test" goto gui_self_test
if /I "%~1"=="--smoke-test" goto gui_smoke_test
if /I "%~1"=="--debug" goto gui_debug
if /I "%~1"=="--deep-self-test" goto deep_self_test

rem Normal launch: keep the console hidden, but the PowerShell wrapper will show a
rem visible error dialog and write a startup log if GUI initialization fails.
start "VirtualCamPro Windows Control Center" powershell.exe -NoLogo -NoProfile -STA ^
    -ExecutionPolicy Bypass -WindowStyle Hidden ^
    -File "%~dp0scripts\launch-control-center.ps1"
exit /b 0

:gui_debug
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass ^
    -File "%~dp0scripts\launch-control-center.ps1" -DebugConsole
set "VCAM_RC=%ERRORLEVEL%"
if not "%VCAM_RC%"=="0" (
    echo.
    echo [ERROR] Control Center failed. The startup error is shown above.
    echo Log: %%LOCALAPPDATA%%\VirtualCamPro\logs\control-center-startup.log
    pause
)
exit /b %VCAM_RC%

:gui_self_test
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass ^
    -File "%~dp0scripts\launch-control-center.ps1" -SelfTest -DebugConsole
exit /b %ERRORLEVEL%

:gui_smoke_test
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass ^
    -File "%~dp0scripts\launch-control-center.ps1" -SmokeTest -DebugConsole
exit /b %ERRORLEVEL%

:deep_self_test
call "%~dp0standalone-self-test.bat"
exit /b %ERRORLEVEL%
