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

rem mpv itself: offered only when it is neither on PATH nor in the folder install-mpv.ps1 uses.
for /f "usebackq delims=" %%L in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-mpv.ps1" -CheckOnly`) do set "MPVSTATE=%%L"
if "%MPVSTATE%"=="missing" (
    echo mpv не найден ни в PATH, ни в списке установленных программ.
    choice /c YN /m "Скачать и установить mpv (около 35 МБ, без прав администратора)"
    if errorlevel 1 if not errorlevel 2 (
        for /f "usebackq delims=" %%L in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-mpv.ps1"`) do echo %%L
    )
)

rem Anime4K shaders: optional, asked until mpv.conf turns them on (older installs added only the hotkeys).
findstr /c:"Anime4K_" "%APPDATA%\mpv\mpv.conf" >nul 2>&1 || (
    echo.
    echo Anime4K - апскейлер, убирает мыльные края в аниме. Работает сразу; Ctrl+0 выключает, Ctrl+1 включает обратно.
    choice /c YN /m "Установить Anime4K"
    if errorlevel 1 if not errorlevel 2 (
        for /f "usebackq delims=" %%L in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-anime4k.ps1"`) do echo %%L
        findstr /c:"Anime4K_" "%APPDATA%\mpv\mpv.conf" >nul 2>&1 || (
            echo.
            echo ВНИМАНИЕ: Anime4K НЕ установлен, причина в строке выше. Запусти install.bat ещё раз.
            echo.
        )
    )
)

xcopy "%SRC%" "%DST%\" /E /I /Y /Q >nul || (
    echo Не удалось скопировать файлы в "%DST%".
    pause
    exit /b 1
)

echo Готово: плагин установлен в "%DST%".
echo Перезапусти mpv. Меню: правый клик - "Совместный просмотр".
pause
