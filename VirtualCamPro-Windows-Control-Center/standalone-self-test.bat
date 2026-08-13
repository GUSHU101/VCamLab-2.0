@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0"
title VirtualCamPro - Deep Self-Test

echo ============================================================
echo  VirtualCamPro Deep Self-Test
echo ============================================================
echo.

powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass ^
    -File "%~dp0scripts\verify-standalone.ps1"
if errorlevel 1 goto self_test_failed

echo.
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass ^
    -File "%~dp0scripts\deep-self-test.ps1"
if errorlevel 1 goto self_test_failed

echo.
echo [OK] Deep self-test completed without structural/runtime failures.
echo Warnings above indicate optional environment items that may still need attention.
echo.
pause
exit /b 0

:self_test_failed
set "VCAM_TEST_RC=%ERRORLEVEL%"
echo.
echo [ERROR] Deep self-test failed with exit code %VCAM_TEST_RC%.
echo Review the first [FAIL] line above. Startup failures are also logged under:
echo %%LOCALAPPDATA%%\VirtualCamPro\logs\control-center-startup.log
echo.
pause
exit /b %VCAM_TEST_RC%
