@echo off
REM Double-click / cmd launcher for real Admin Web (Chrome + browser login).
setlocal
cd /d "%~dp0\.."
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_admin_web.ps1"
exit /b %ERRORLEVEL%
