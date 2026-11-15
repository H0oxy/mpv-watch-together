@echo off
chcp 65001 >nul
set "DST=%APPDATA%\mpv\scripts\watch-together"
if exist "%DST%" rmdir /s /q "%DST%"
rem The torrent engine the plugin downloaded on first use of a magnet. A running one (mpv still open, or one
rem left over) keeps its files locked, so it is stopped first: only an engine from that folder.
set "ENG=%APPDATA%\mpv\watch_together_engine"
if exist "%ENG%" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "$d = Join-Path $env:APPDATA 'mpv\watch_together_engine\*'; $p = @(Get-Process TorrServer -ErrorAction SilentlyContinue | Where-Object { $_.Path -like $d }); $p | Stop-Process -Force; $p | Wait-Process -Timeout 5 -ErrorAction SilentlyContinue"
    rmdir /s /q "%ENG%"
)
rem Torrent mode's log and the .torrent files guests fetched from their hosts.
del /q "%APPDATA%\mpv\watch_together_torrent.log" "%APPDATA%\mpv\watch_together_torrent.log.old" 2>nul
if exist "%TEMP%\watch-together" rmdir /s /q "%TEMP%\watch-together"
echo Плагин удалён. Перезапусти mpv.
pause
