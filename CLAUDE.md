# watch-together (mpv plugin)

A host and any number of guests, each with its own copy of the same video (or each streaming the same torrent): mpv stays in sync on pause, seek, speed and episode over TCP. The intended tunnel is Porthole (Steam). Windows only.

- `watch-together/main.lua`: mpv script with the right-click menu, the sync logic, on-screen messages (Russian or English by Windows display language; strings in `STRINGS`) and the update prompt. `VERSION` and `PROTOCOL` live at the top.
- `watch-together/bridge.ps1`: PowerShell relay between mpv JSON IPC and TCP peers (host: many guests).
- `watch-together/tracks.lua`: which subtitle, audio and font files of a torrent go with which episode (pure Lua, `require`d by main.lua).
- `watch-together/sysinfo.ps1`: Windows language and Steam name at startup.
- `watch-together/update.ps1`: checks and installs GitHub releases.
- `watch-together/share.ps1` / `fetch.ps1`: episode download, host side / guest side.
- `watch-together/stream.ps1`: guest's local HTTP server for watching from the host without downloading.
- `watch-together/torrent.ps1`: torrent mode: downloads (pinned SHA256), starts and drives TorrServer.
- `install.bat` / `uninstall.bat`: copy the plugin to, or remove it from, `%APPDATA%\mpv\scripts\watch-together`.

Tests: `powershell -ExecutionPolicy Bypass -File tests\e2e.ps1 -Mpv C:\programs\mpv\mpv.exe`, `tests\scale.ps1 -GuestCount 20`, `tests\buffering.ps1`, `tests\features.ps1`, `tests\stream.ps1`, `tests\torrent.ps1` (offline, fake engine), `tests\engine.ps1` (offline, stand-in TorrServer), `tests\tracks.ps1` (track matching on torrent layouts), `tests\update.ps1` (network; need `ffmpeg` on PATH the first time; buffering also needs `python`).

Release: bump `VERSION` in `main.lua`, commit, push, create GitHub release `v<VERSION>`. Users get asked to update at the next mpv start.

Rules:
- No dependencies beyond mpv and the PowerShell that ships with Windows. The one exception is the torrent engine: downloaded on first use of torrent mode from its release, run only with the hash pinned in `ENGINE`, never committed.
- Keep the `.ps1` files ASCII.
- Never feed peer data to mpv as commands, only validated numbers and names.
- Only the host decides the room state.
- Kill leftover test mpv instances by pipe name, never all mpv processes: the user may be watching.

Docs:
- [docs/development.md](docs/development.md): layout, protocol, updates, tests, conventions
- [docs/usage.md](docs/usage.md): notes from real use with Porthole
- [docs/decisions.md](docs/decisions.md): why a custom plugin, Porthole, star topology, Steam names, update flow, TorrServer
- [docs/torrent.md](docs/torrent.md): torrent mode: engine, stream URLs, opening, room messages, swarm check
- [docs/bugs.md](docs/bugs.md): verified pitfalls
