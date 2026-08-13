@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0"
title VirtualCamPro - Standalone Self-Test

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\verify-standalone.ps1"
if errorlevel 1 exit /b %errorlevel%

call "%~dp0start-stream.bat" --self-test
if errorlevel 1 exit /b %errorlevel%

call "%~dp0start-obs-vcam.bat" --self-test
if errorlevel 1 exit /b %errorlevel%

call "%~dp0install-phone.bat" --self-test
if errorlevel 1 exit /b %errorlevel%

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install-ios-gui.ps1" -SelfTest
if errorlevel 1 exit /b %errorlevel%

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install-ios-gui.ps1" -SmokeTest
if errorlevel 1 exit /b %errorlevel%

echo [OK] All standalone companion-tool self-tests passed.
exit /b 0
