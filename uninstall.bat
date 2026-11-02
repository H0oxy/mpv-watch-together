@echo off
chcp 65001 >nul
set "DST=%APPDATA%\mpv\scripts\watch-together"
if exist "%DST%" rmdir /s /q "%DST%"
echo Плагин удалён. Перезапусти mpv.
pause
