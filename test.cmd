@echo off
rem Build and run the test suites.
rem   test        offline suites only
rem   test net    also run the suite that talks to real servers
rem   test all    same as "test net"
setlocal enabledelayedexpansion

set ROOT=%~dp0
set OUT=%ROOT%bin
set UNITS=%ROOT%build\units

set SUITES=smoke stream
if /I "%~1"=="net" set SUITES=smoke stream net
if /I "%~1"=="all" set SUITES=smoke stream net

set FPC=
for %%C in (fpc.exe) do if not "%%~$PATH:C"=="" set FPC=%%~$PATH:C
if "%FPC%"=="" for /d %%D in ("C:\lazarus\fpc\*") do (
  if exist "%%D\bin\x86_64-win64\fpc.exe" set FPC=%%D\bin\x86_64-win64\fpc.exe
)
if "%FPC%"=="" for /d %%D in ("C:\FPC\*") do (
  if exist "%%D\bin\x86_64-win64\fpc.exe" set FPC=%%D\bin\x86_64-win64\fpc.exe
)
if "%FPC%"=="" (
  echo Free Pascal compiler not found.
  exit /b 1
)

if not exist "%OUT%" md "%OUT%"
if not exist "%UNITS%" md "%UNITS%"

set FLAGS=-MObjFPC -Scghi -O1 -vew -Fu"%ROOT%src" -FU"%UNITS%" -FE"%OUT%"
set RC=0

rem -gh makes the RTL report anything the suite allocated and did not free.
rem JSON ownership here is manual, so a leak is a real defect, not noise.
for %%T in (%SUITES%) do (
  "%FPC%" %FLAGS% -gh -o"%OUT%\%%T.exe" "%ROOT%tests\%%T.lpr" >nul
  if errorlevel 1 (
    echo BUILD FAILED: %%T
    "%FPC%" %FLAGS% -o"%OUT%\%%T.exe" "%ROOT%tests\%%T.lpr"
    exit /b 1
  )
  echo --- %%T ---
  "%OUT%\%%T.exe"
  if errorlevel 1 set RC=1
)

if "%RC%"=="0" (echo. & echo ALL SUITES PASSED) else (echo. & echo SUITE FAILURES)
exit /b %RC%
