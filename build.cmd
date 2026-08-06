@echo off
rem Build pasclaude.  Usage: build [debug|clean]
setlocal enabledelayedexpansion

set ROOT=%~dp0
set OUT=%ROOT%bin
set UNITS=%ROOT%build\units

if /I "%~1"=="clean" (
  if exist "%UNITS%" rd /s /q "%UNITS%"
  if exist "%OUT%\pasclaude.exe" del /q "%OUT%\pasclaude.exe"
  echo Cleaned.
  goto :eof
)

rem Locate the compiler: PATH first, then the usual Lazarus / FPC layouts.
set FPC=
for %%C in (fpc.exe) do if not "%%~$PATH:C"=="" set FPC=%%~$PATH:C
if "%FPC%"=="" for /d %%D in ("C:\lazarus\fpc\*") do (
  if exist "%%D\bin\x86_64-win64\fpc.exe" set FPC=%%D\bin\x86_64-win64\fpc.exe
)
if "%FPC%"=="" for /d %%D in ("C:\FPC\*") do (
  if exist "%%D\bin\x86_64-win64\fpc.exe" set FPC=%%D\bin\x86_64-win64\fpc.exe
)
if "%FPC%"=="" (
  echo Free Pascal compiler not found. Install FPC or Lazarus, or put fpc.exe on PATH.
  exit /b 1
)

set FLAGS=-MObjFPC -Scghi -O2 -Xs -vew
if /I "%~1"=="debug" set FLAGS=-MObjFPC -Scghi -O1 -gl -godwarfsets -vewnh

if not exist "%OUT%" md "%OUT%"
if not exist "%UNITS%" md "%UNITS%"

echo Using %FPC%
"%FPC%" %FLAGS% -Fu"%ROOT%src" -FU"%UNITS%" -FE"%OUT%" -o"%OUT%\pasclaude.exe" "%ROOT%src\pasclaude.lpr"
if errorlevel 1 exit /b 1
echo Built %OUT%\pasclaude.exe
