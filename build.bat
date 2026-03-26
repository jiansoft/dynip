@echo off
setlocal

REM `%~dp0` means "the directory that this batch file lives in".
REM We use it so the wrapper can find `build.ps1` no matter where cmd was launched from.
set "SCRIPT_DIR=%~dp0"
REM The real build logic lives in PowerShell.
set "PS_SCRIPT=%SCRIPT_DIR%build.ps1"

REM Stop immediately if the PowerShell script is missing.
if not exist "%PS_SCRIPT%" (
  echo PowerShell build script not found: %PS_SCRIPT%
  exit /b 1
)

REM Forward all original command-line arguments to `build.ps1`.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %*
REM `%ERRORLEVEL%` is the exit code from the last external command.
set "EXIT_CODE=%ERRORLEVEL%"

REM `endlocal` clears local variables, so we return the stored exit code in the same line.
endlocal & exit /b %EXIT_CODE%
