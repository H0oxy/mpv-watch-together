@echo off
chcp 65001 >nul
setlocal
set "SRC=%~dp0watch-together"
set "DST=%APPDATA%\mpv\scripts\watch-together"

if not exist "%SRC%\main.lua" (
    echo Не найдена папка watch-together рядом с install.bat.
    echo Распакуй архив целиком и запусти install.bat из него.
    pause
    exit /b 1
)

xcopy "%SRC%" "%DST%\" /E /I /Y /Q >nul || (
    echo Не удалось скопировать файлы в "%DST%".
    pause
    exit /b 1
)

echo Готово: плагин установлен в "%DST%".
echo Перезапусти mpv. Меню: правый клик - "Совместный просмотр".
pause
