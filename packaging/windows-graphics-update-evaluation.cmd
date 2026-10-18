@echo off
setlocal DisableDelayedExpansion
rem SPDX-License-Identifier: Apache-2.0
rem Private signed-driver update. The pinned support disc carries the unmodified package.
rem Retain the prior package/disc and Windows Driver Store for rollback.
set "mvoGraphics=HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
set "mvoScheduler=%mvoGraphics%\Scheduler"
set "mvoRestoreOK=1"
set "mvoPreemptionKind="
set "mvoPreemptionValue="
set "mvoTdrKind="
set "mvoTdrValue="
"%SystemRoot%\System32\whoami.exe" /groups | "%SystemRoot%\System32\findstr.exe" /c:"S-1-16-12288" >nul
if errorlevel 1 (
  echo Run this reviewed update as administrator.
  exit /b 1
)
"%SystemRoot%\System32\reg.exe" query "%mvoGraphics%" >nul 2>&1
if errorlevel 1 (
  echo Could not read the existing graphics settings. No update was started.
  exit /b 1
)
"%SystemRoot%\System32\reg.exe" query "%mvoScheduler%" >nul 2>&1
if errorlevel 1 (
  echo Could not read the installed driver's scheduler settings. No update was started.
  exit /b 1
)
for /f "tokens=1,2,3" %%A in ('reg query "%mvoScheduler%" /v EnablePreemption 2^>nul') do if /I "%%A"=="EnablePreemption" (
  set "mvoPreemptionKind=%%B"
  set "mvoPreemptionValue=%%C"
)
for /f "tokens=1,2,3" %%A in ('reg query "%mvoGraphics%" /v TdrDebugMode 2^>nul') do if /I "%%A"=="TdrDebugMode" (
  set "mvoTdrKind=%%B"
  set "mvoTdrValue=%%C"
)
if defined mvoPreemptionKind if /I not "%mvoPreemptionKind%"=="REG_DWORD" exit /b 1
if defined mvoTdrKind if /I not "%mvoTdrKind%"=="REG_DWORD" exit /b 1
rem Preserve the two non-secret values even if Windows stops during the update.
set "mvoRecoveryDirectory=%ProgramFiles%\macOpenVM Graphics Recovery"
if not exist "%mvoRecoveryDirectory%" (
  mkdir "%mvoRecoveryDirectory%"
  if errorlevel 1 exit /b 1
)
set "mvoRecoveryFile=%mvoRecoveryDirectory%\before-v04-%RANDOM%-%RANDOM%.txt"
if exist "%mvoRecoveryFile%" exit /b 1
(
  echo macOpenVM graphics settings before the v0.4 update
  echo EnablePreemption,%mvoPreemptionKind%,%mvoPreemptionValue%
  echo TdrDebugMode,%mvoTdrKind%,%mvoTdrValue%
) > "%mvoRecoveryFile%"
"%SystemRoot%\System32\findstr.exe" /x /c:"EnablePreemption,%mvoPreemptionKind%,%mvoPreemptionValue%" "%mvoRecoveryFile%" >nul
if errorlevel 1 (
  echo Could not preserve the graphics settings. No update was started.
  exit /b 1
)
"%SystemRoot%\System32\findstr.exe" /x /c:"TdrDebugMode,%mvoTdrKind%,%mvoTdrValue%" "%mvoRecoveryFile%" >nul
if errorlevel 1 exit /b 1
echo Updating the reviewed Microsoft-catalog-signed graphics package.
"%SystemRoot%\System32\pnputil.exe" /add-driver "%~dp0drivers\viogpu3d.inf" /install
set "mvoDriverResult=%errorlevel%"
rem Restore immediately on every installer outcome, before any pause or restart.
call :restore "%mvoScheduler%" EnablePreemption "%mvoPreemptionKind%" "%mvoPreemptionValue%"
call :restore "%mvoGraphics%" TdrDebugMode "%mvoTdrKind%" "%mvoTdrValue%"
if not "%mvoRestoreOK%"=="1" (
  echo Graphics settings restoration failed. Do not start a performance test or restart.
  exit /b 2
)
echo Existing graphics recovery settings verified after restoration.
echo Restored and verified.>> "%mvoRecoveryFile%"
if "%mvoDriverResult%"=="0" goto processed
if "%mvoDriverResult%"=="3010" goto processed
echo PnPUtil returned %mvoDriverResult%. Driver loading is not verified.
exit /b 3

:processed
echo Package processing completed. Restart Windows, then verify driver hashes and device health.
echo Package processing does not prove graphics performance or the active refresh rate.
pause
exit /b 0

:restore
if "%~3"=="" (
  "%SystemRoot%\System32\reg.exe" delete "%~1" /v "%~2" /f >nul 2>&1
) else (
  "%SystemRoot%\System32\reg.exe" add "%~1" /v "%~2" /t REG_DWORD /d "%~4" /f >nul 2>&1
  if errorlevel 1 set "mvoRestoreOK=0"
)
set "mvoReadKind="
set "mvoReadValue="
"%SystemRoot%\System32\reg.exe" query "%~1" >nul 2>&1
if errorlevel 1 set "mvoRestoreOK=0"
for /f "tokens=1,2,3" %%A in ('reg query "%~1" /v "%~2" 2^>nul') do if /I "%%A"=="%~2" (
  set "mvoReadKind=%%B"
  set "mvoReadValue=%%C"
)
if /I not "%mvoReadKind%"=="%~3" set "mvoRestoreOK=0"
if /I not "%mvoReadValue%"=="%~4" set "mvoRestoreOK=0"
exit /b 0
