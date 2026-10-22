@echo off
setlocal
set "SYSTEM_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%SYSTEM_PS%" (
  echo Windows PowerShell 5.1 is required.
  pause
  exit /b 70
)
"%SYSTEM_PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0HermesResearchSetup.Gui.ps1"
set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" pause
exit /b %EXIT_CODE%
