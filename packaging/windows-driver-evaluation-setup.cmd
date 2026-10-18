@echo off
setlocal DisableDelayedExpansion
rem SPDX-License-Identifier: Apache-2.0
rem Private driver evaluation only; this does not install the macOpenVM agent.
rem Refuse before any driver command if elevation or any required input is missing.
if not exist "%SystemRoot%\System32\fltmc.exe" goto adminRequired
"%SystemRoot%\System32\fltmc.exe" >nul 2>&1
if not "%errorlevel%"=="0" goto adminRequired
if not exist "%SystemRoot%\System32\pnputil.exe" goto incomplete
if exist "%SystemRoot%\System32\pnputil.exe\" goto incomplete
call :requireInput "%~dp0drivers\display\viogpudo.cat" 11882
if errorlevel 1 goto incomplete
call :requireInput "%~dp0drivers\display\viogpudo.inf" 2889
if errorlevel 1 goto incomplete
call :requireInput "%~dp0drivers\display\viogpudo.sys" 118936
if errorlevel 1 goto incomplete
call :requireInput "%~dp0drivers\display\virtio-win_license.txt" 1598
if errorlevel 1 goto incomplete
call :requireInput "%~dp0drivers\netkvm\netkvm.cat" 12496
if errorlevel 1 goto incomplete
call :requireInput "%~dp0drivers\netkvm\netkvm.inf" 18828
if errorlevel 1 goto incomplete
call :requireInput "%~dp0drivers\netkvm\netkvm.sys" 200344
if errorlevel 1 goto incomplete
call :requireInput "%~dp0drivers\netkvm\netkvmp.exe" 266904
if errorlevel 1 goto incomplete
call :requireInput "%~dp0drivers\netkvm\virtio-win_license.txt" 1598
if errorlevel 1 goto incomplete
call :requireInput "%~dp0drivers\vioser\vioser.cat" 12074
if errorlevel 1 goto incomplete
call :requireInput "%~dp0drivers\vioser\vioser.inf" 2623
if errorlevel 1 goto incomplete
call :requireInput "%~dp0drivers\vioser\vioser.sys" 97944
if errorlevel 1 goto incomplete
call :requireInput "%~dp0drivers\vioser\virtio-win_license.txt" 1598
if errorlevel 1 goto incomplete
call :requireInput "%~dp0README.txt" 382
if errorlevel 1 goto incomplete
rem Every package, helper and notice passed preflight before the first PnPUtil call.
set "mvoRebootRequired=0"
echo macOpenVM driver evaluation setup
echo Windows signature enforcement remains enabled.
call :installDriver "%~dp0drivers\display\viogpudo.inf" "Display"
if errorlevel 1 goto failed
call :installDriver "%~dp0drivers\netkvm\netkvm.inf" "Network"
if errorlevel 1 goto failed
call :installDriver "%~dp0drivers\vioser\vioser.inf" "Serial"
if errorlevel 1 goto failed
echo.
echo Driver package processing completed. Verify device health in Windows.
if "%mvoRebootRequired%"=="1" echo Windows reported that a restart is required.
echo This evaluation does not install the macOpenVM guest agent.
pause
exit /b 0

:installDriver
echo.
echo Processing %~2 driver package...
"%SystemRoot%\System32\pnputil.exe" /add-driver "%~1" /install
set "mvoDriverResult=%errorlevel%"
echo PnPUtil returned %mvoDriverResult% for %~2.
if "%mvoDriverResult%"=="0" exit /b 0
if "%mvoDriverResult%"=="3010" (
  set "mvoRebootRequired=1"
  exit /b 0
)
if "%mvoDriverResult%"=="259" (
  echo No matching device needs this package, or Windows selected a better driver.
  echo Package processing alone does not verify that this device is working.
  exit /b 0
)
exit /b 1

:failed
echo.
echo Driver processing stopped. Review the PnPUtil result above.
echo Do not disable signature enforcement or other Windows protections.
pause
exit /b 1

:requireInput
if not exist "%~1" exit /b 1
if exist "%~1\" exit /b 1
for %%I in ("%~1") do if not "%%~zI"=="%~2" exit /b 1
exit /b 0

:adminRequired
echo Administrator access could not be confirmed.
echo Right-click macOpenVM Setup.cmd and choose Run as administrator.
echo No driver command was run.
pause
exit /b 1

:incomplete
echo A required driver, helper, notice or Windows utility is missing or has the wrong size.
echo Preserve this disc and obtain the complete reviewed carrier.
echo No driver command was run.
pause
exit /b 1
