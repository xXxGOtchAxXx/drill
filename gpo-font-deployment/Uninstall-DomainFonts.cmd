@echo off
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%PS%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0Uninstall-DomainFonts.ps1" -FontFileName al-mohanad.ttf,al-mohanad-bold.ttf
exit /b %ERRORLEVEL%
