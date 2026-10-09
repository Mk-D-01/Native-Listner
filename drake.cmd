@echo off
rem Starts Drake in this console (shows what it hears). Use "start /b" or drake-hidden.vbs for no window.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0drake.ps1"
