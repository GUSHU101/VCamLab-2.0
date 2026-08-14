@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0"
title VirtualCamPro - OBS Launcher

set "VCAM_FFMPEG_PATH="
set "VCAM_OBS_PATH="
set "VCAM_OBS_SCENE="
set "VCAM_ORIENTATION=landscape"
set "VCAM_RESOLUTION=auto"
set "VCAM_FPS=auto"
set "VCAM_QUALITY=1"
set "VCAM_SCALE_MODE=fill"
set "VCAM_PORT=8888"
set "VCAM_BIND_ADDRESS=0.0.0.0"
set "VCAM_TRANSPORT=mjpeg"
set "VCAM_HLS_SEGMENT_SECONDS=0.25"
set "VCAM_HLS_LIST_SIZE=6"
set "VCAM_HLS_VIDEO_BITRATE_KBPS=12000"
set "VCAM_HLS_MAXRATE_KBPS=16000"
set "VCAM_HLS_BUFSIZE_KBPS=12000"
set "VCAM_HLS_PRESET=ultrafast"
set "VCAM_OBS_WAIT_SECONDS=15"
set "VCAM_RESTART_ON_DISCONNECT=true"
set "VCAM_DEVICE_NAME=OBS Virtual Camera"
set "VCAM_RT_BUFFER_MB=64"
set "VCAM_THREAD_QUEUE_SIZE=4"
set "VCAM_ENCODER_THREADS=4"
set "VCAM_OUTPUT_QUEUE_SIZE=3"
set "VCAM_TCP_SEND_BUFFER_MB=1"
set "VCAM_REQUIRE_OBS_MODE_MATCH=true"
set "VCAM_AUTO_REFRESH_OBS_VIRTUAL_CAMERA=true"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass ^
    -File "%~dp0scripts\verify-standalone.ps1" -Quiet
if errorlevel 1 exit /b %errorlevel%

if exist "%~dp0obs-vcam-config.cmd" call "%~dp0obs-vcam-config.cmd"

:parse_options
if /I "%~1"=="--transport" (
    if "%~2"=="" goto usage
    set "VCAM_TRANSPORT=%~2"
    shift
    shift
    goto parse_options
)

if /I "%~1"=="--check" goto check
if /I "%~1"=="--self-test" goto self_test
if /I "%~1"=="--gui" goto launch_gui
if /I "%~1"=="--no-pause" goto launch_no_pause
if not "%~1"=="" goto launch_custom_fps

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\windows-vcam.ps1" ^
    -Mode Obs -Transport "%VCAM_TRANSPORT%"
set "VCAM_EXIT_CODE=%errorlevel%"
echo.
pause
exit /b %VCAM_EXIT_CODE%

:launch_no_pause
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\windows-vcam.ps1" ^
    -Mode Obs -FramesPerSecond "%~2" -Transport "%VCAM_TRANSPORT%"
exit /b %errorlevel%

:launch_gui
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\windows-vcam.ps1" ^
    -Mode Obs -Transport "%VCAM_TRANSPORT%"
set "VCAM_EXIT_CODE=%errorlevel%"
if "%VCAM_EXIT_CODE%"=="0" exit /b 0
echo.
echo Bridge startup failed with exit code %VCAM_EXIT_CODE%. Review the error above.
pause
exit /b %VCAM_EXIT_CODE%

:check
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\windows-vcam.ps1" ^
    -Mode Check -FramesPerSecond "%~2" -Transport "%VCAM_TRANSPORT%"
exit /b %errorlevel%

:launch_custom_fps
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\windows-vcam.ps1" ^
    -Mode Obs -FramesPerSecond "%~1" -Transport "%VCAM_TRANSPORT%"
set "VCAM_EXIT_CODE=%errorlevel%"
echo.
pause
exit /b %VCAM_EXIT_CODE%

:self_test
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\windows-vcam.ps1" -Mode SelfTest
exit /b %errorlevel%

:usage
echo Usage: start-obs-vcam.bat [--transport mjpeg^|hls] [fps^|--check [fps]^|--self-test^|--gui^|--no-pause [fps]]
exit /b 64
