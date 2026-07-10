@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File C:\OEM\bootstrap.ps1
if errorlevel 1 exit /b %errorlevel%
exit /b 0
