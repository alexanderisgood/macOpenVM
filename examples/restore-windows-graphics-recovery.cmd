@echo off
rem SPDX-License-Identifier: Apache-2.0
rem Original, scoped repair of the two overrides in the evaluated graphics INF.
fltmc >nul 2>&1
if errorlevel 1 (
  powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
setlocal
set "tdr="
set "preemption="
for /f "tokens=3" %%A in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" /v TdrDebugMode 2^>nul') do set "tdr=%%A"
for /f "tokens=3" %%A in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Scheduler" /v EnablePreemption 2^>nul') do set "preemption=%%A"
echo Restoring Windows graphics recovery defaults.
echo Only the known driver-added values 1 and 0 will be removed.
if "%tdr%"=="0x1" reg delete "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" /v TdrDebugMode /f
if "%preemption%"=="0x0" reg delete "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Scheduler" /v EnablePreemption /f
echo Current overrides, if any:
reg query "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" /v TdrDebugMode
reg query "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Scheduler" /v EnablePreemption
echo Restart Windows after verifying the diagnostics show both values unset.
pause
