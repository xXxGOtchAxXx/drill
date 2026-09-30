@echo off
REM ---------------------------------------------------------------------------
REM  GPO computer STARTUP script wrapper.
REM  Add THIS .cmd file on the "Scripts" tab (not the "PowerShell Scripts" tab)
REM  of Computer Configuration > Policies > Windows Settings > Scripts (Startup).
REM  It bypasses any PowerShell execution-policy setting for this one run only,
REM  and points the script at its own folder, where the .ttf files also live.
REM ---------------------------------------------------------------------------
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%PS%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0Install-DomainFonts.ps1" -SourcePath "%~dp0." %*
exit /b %ERRORLEVEL%
