# watch-together (mpv plugin)

Two people, two PCs, each with its own copy of the same video: mpv stays in sync on pause, seek and speed over one TCP link. The intended tunnel is Porthole (Steam). Windows only.

- `watch-together/main.lua`: mpv script with the right-click menu, the sync logic and Russian on-screen messages.
- `watch-together/bridge.ps1`: PowerShell relay between mpv JSON IPC and the TCP peer. ASCII only.
- `install.bat` / `uninstall.bat`: copy the plugin to, or remove it from, `%APPDATA%\mpv\scripts\watch-together`.

Test: `powershell -ExecutionPolicy Bypass -File tests\e2e.ps1 -Mpv C:\programs\mpv\mpv.exe` (needs `ffmpeg` on PATH the first time).

Rules: no dependencies beyond mpv and the PowerShell that ships with Windows; keep `bridge.ps1` ASCII; never feed peer data to mpv as commands, only validated numbers.

Docs:
- [docs/development.md](docs/development.md): setup, test, protocol, conventions
- [docs/usage.md](docs/usage.md): install and use with Porthole
- [docs/decisions.md](docs/decisions.md): why a custom plugin, why Porthole, design choices
- [docs/bugs.md](docs/bugs.md): verified pitfalls
