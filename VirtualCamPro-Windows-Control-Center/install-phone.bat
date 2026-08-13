@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0"
title VirtualCamPro - iPhone Installer

set "VCAM_INSTALL_MODE=Install"
if /I "%~1"=="--self-test" goto self_test
if /I "%~1"=="--setup" (
    set "VCAM_INSTALL_MODE=Setup"
    shift
)
if /I "%~1"=="--check" (
    set "VCAM_INSTALL_MODE=Check"
    shift
)
if /I "%~1"=="--verify" (
    set "VCAM_INSTALL_MODE=Verify"
    shift
)
if /I "%~1"=="--help" goto usage
if /I "%~1"=="-h" goto usage

set "VCAM_INSTALL_HOST=%~1"
set "VCAM_INSTALL_PACKAGE=%~2"
set "VCAM_INSTALL_PORT=%~3"
set "VCAM_INSTALL_FPS=%~4"
set "VCAM_INSTALL_URL=%~5"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass ^
    -File "%~dp0scripts\install-ios.ps1" ^
    -Mode "%VCAM_INSTALL_MODE%" ^
    -PhoneHost "%VCAM_INSTALL_HOST%" ^
    -PackagePath "%VCAM_INSTALL_PACKAGE%" ^
    -PhonePort "%VCAM_INSTALL_PORT%" ^
    -PreferredFPS "%VCAM_INSTALL_FPS%" ^
    -StreamURL "%VCAM_INSTALL_URL%"
exit /b %errorlevel%

:self_test
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass ^
    -File "%~dp0scripts\install-ios.ps1" -Mode SelfTest
exit /b %errorlevel%

:usage
echo Usage:
echo   install-phone.bat --check PHONE_IP [PACKAGE.deb] [SSH_PORT]
echo   install-phone.bat --verify PHONE_IP [PACKAGE.deb] [SSH_PORT]
echo   install-phone.bat PHONE_IP [PACKAGE.deb] [SSH_PORT]
echo   install-phone.bat --setup PHONE_IP [PACKAGE.deb] [SSH_PORT] [PHONE_FPS] [STREAM_URL]
echo   install-phone.bat --self-test
echo.
echo Defaults: user mobile, SSH port 22, newest local VirtualCamPro .deb.
echo --setup derives the PC address and writes the phone stream URL automatically.
echo Optional environment variables: VCAM_PHONE_HOST, VCAM_PHONE_PORT,
echo VCAM_PHONE_USER, VCAM_DEB_PATH, VCAM_PHONE_FPS, and VCAM_STREAM_URL.
exit /b 64
