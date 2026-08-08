@echo off
rem Build and run the test suites.
rem   test        offline suites only
rem   test net    also run the suite that talks to real servers
rem   test all    same as "test net"
setlocal enabledelayedexpansion

set ROOT=%~dp0
set OUT=%ROOT%bin
set UNITS=%ROOT%build\units

set SUITES=smoke stream loop fuzz ux
if /I "%~1"=="net" set SUITES=smoke stream loop fuzz ux net
if /I "%~1"=="all" set SUITES=smoke stream loop fuzz ux net

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

rem The MCP transport tests need something to talk to.  srvmock is a fixture,
rem not a suite: it is built here but its exit code is nobody's pass or fail,
rem and it is built WITHOUT -gh on purpose - heaptrc's report on exit would go
rem down the same stdout the protocol is framed on and corrupt every reply.
"%FPC%" %FLAGS% -o"%OUT%\srvmock.exe" "%ROOT%tests\srvmock.lpr" >nul
if errorlevel 1 (
  echo BUILD FAILED: srvmock
  "%FPC%" %FLAGS% -o"%OUT%\srvmock.exe" "%ROOT%tests\srvmock.lpr"
  exit /b 1
)

rem The sandbox tests need something that runs INSIDE the job object: whether
rem breakaway is refused and whether the process cap bites are both things
rem only a child can report.  A fixture like srvmock, and built without -gh
rem for the same reason - it writes a small file the suite then parses, and a
rem heaptrc report is not something that parser expects.
"%FPC%" %FLAGS% -o"%OUT%\sbxmock.exe" "%ROOT%tests\sbxmock.lpr" >nul
if errorlevel 1 (
  echo BUILD FAILED: sbxmock
  "%FPC%" %FLAGS% -o"%OUT%\sbxmock.exe" "%ROOT%tests\sbxmock.lpr"
  exit /b 1
)

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
