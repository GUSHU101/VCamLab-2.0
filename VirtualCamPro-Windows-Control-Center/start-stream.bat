@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass ^
    -File "%~dp0scripts\verify-standalone.ps1" -Quiet
if errorlevel 1 exit /b %errorlevel%

if exist "%~dp0obs-vcam-config.cmd" call "%~dp0obs-vcam-config.cmd"

if /I "%~1"=="--self-test" goto self_test
if /I "%~1"=="--check" goto check

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\windows-vcam.ps1" ^
    -Mode Stream -Source "%~1" -Orientation "%~2" -Resolution "%~3" ^
    -Quality "%~4" -FramesPerSecond "%~5" -Port "%~6" -Transport "%~7"
exit /b %errorlevel%

:check
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\windows-vcam.ps1" ^
    -Mode Check -Transport "%VCAM_TRANSPORT%"
exit /b %errorlevel%

:self_test
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\windows-vcam.ps1" -Mode SelfTest
exit /b %errorlevel%
