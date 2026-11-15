@echo off
rem Builds out\nrtest.exe and out\dlssnr.dll (mpv C plugin) with MSVC Build Tools 2022.
setlocal
set VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe
for /f "usebackq delims=" %%i in (`"%VSWHERE%" -products * -property installationPath`) do set VS=%%i
call "%VS%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
cd /d "%~dp0"
if not exist sdk\lib\nvsdk_ngx_s.lib (
  mkdir sdk\include\mpv sdk\lib 2>nul
  for %%f in (nvsdk_ngx.h nvsdk_ngx_defs.h nvsdk_ngx_params.h nvsdk_ngx_helpers.h) do curl -sfL -o sdk\include\%%f https://raw.githubusercontent.com/NVIDIA/DLSS/main/include/%%f || exit /b 1
  curl -sfL -o sdk\lib\nvsdk_ngx_s.lib https://github.com/NVIDIA/DLSS/raw/main/lib/Windows_x86_64/x64/nvsdk_ngx_s.lib || exit /b 1
  curl -sfL -o sdk\include\mpv\client.h https://raw.githubusercontent.com/mpv-player/mpv/master/include/mpv/client.h || exit /b 1
)
if not exist out mkdir out
set CF=/nologo /std:c++20 /O2 /MT /EHsc /W3 /Isdk\include /DUNICODE /D_UNICODE /D_CRT_SECURE_NO_WARNINGS
set LIBS=sdk\lib\nvsdk_ngx_s.lib d3d11.lib d3d12.lib dxgi.lib user32.lib advapi32.lib
cl %CF% nrtest.cpp /Fo:out\ /Fe:out\nrtest.exe /link %LIBS% || exit /b 1
cl %CF% /DMPV_CPLUGIN_DYNAMIC_SYM /LD plugin.cpp /Fo:out\ /Fe:out\dlssnr.dll /link %LIBS% || exit /b 1
