@echo off
chcp 65001 >nul
set "DST=%APPDATA%\mpv\scripts\watch-together"
if exist "%DST%" rmdir /s /q "%DST%"
rem The torrent engine the plugin downloaded on first use of a magnet.
set "ENG=%APPDATA%\mpv\watch_together_engine"
if exist "%ENG%" rmdir /s /q "%ENG%"
echo Плагин удалён. Перезапусти mpv.
pause
