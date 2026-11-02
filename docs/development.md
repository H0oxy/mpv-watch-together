# Development

## Layout

```
watch-together/main.lua    menu, sync logic, OSD (runs inside mpv)
watch-together/bridge.ps1  TCP <-> mpv IPC relay (child process of mpv)
tests/e2e.ps1              two headless mpv instances over loopback
install.bat, uninstall.bat
```

## How it fits together

1. A menu click sends `script-message watch-together-host|join|join-clipboard|leave`.
2. `main.lua` makes sure `input-ipc-server` is set (it sets `mpv-watch-together-<pid>` if empty), then starts `bridge.ps1` with `subprocess` (async, `playback_only=false`). Aborting that command kills the bridge.
3. Bridge to Lua: `script-message-to <script> watch-together-net <kind> [data]`, where kind is `listening | connecting | connected | disconnected | error | in`.
4. Lua to bridge: broadcast `script-message watch-together-out <json>`. The bridge sees it as an IPC `client-message` event.
5. The bridge exits when the mpv pipe closes. The host accepts a new connection that replaces the old one. The joiner retries every 2 s.

## Peer protocol (newline-delimited JSON, UTF-8)

| `t` | fields | meaning |
|---|---|---|
| `hello` | `dur`, `name`, `pl`, `follow` | sent on connect and on every file load; `pl` is the 0-based `playlist-pos`. With `follow=true`, the receiver switches to that episode: first a playlist entry with the same file name, else the same `pl` index. The host sends `follow=true` on connect, and both sides send it on a file change that they did not make to follow the friend (`expected_switch`). If no switch happens, the host answers with `state` ev=`sync` |
| `state` | `ev`, `pos`, `dur`, `paused`, `speed` | `ev`: `pause`, `seek`, `speed` (user action, shown on OSD), `sync`, `tick` (host heartbeat, 1 s) |
| `ping` / `pong` | `id` | RTT estimate (smoothed), used to project the remote position |

Applying a state is idempotent: it sets pause or speed only if they differ, and seeks only if the drift is over `threshold` (0.3 s). Echoes therefore die after one round. Local changes caused by a remote state are not re-sent: `expected_pause` and `expected_speed` filter property changes, and `own_seek` (target and time of our last follow seek) filters `playback-restart`. A restart counts as ours only if it landed within 1 s of that target, so a user seek merged with ours is still sent.

Only the joiner applies `tick`, and only after a 0.25 s delay (the position is advanced by the delay). It skips the tick while `seeking` or within 1.5 s of its own pause/seek/speed (`last_local_action`). The delay lets mpv deliver queued `seek`/`playback-restart` events of a user seek before the drift is judged. States whose `dur` differs by more than 1 s are ignored and trigger a one-time "different file" warning.

## Options

`%APPDATA%\mpv\script-opts\watch_together.conf`:

```
port=47800
bind=127.0.0.1      # host listen address; 0.0.0.0 for LAN/Tailscale
address=127.0.0.1   # where "join" connects (Porthole maps the host port here)
threshold=0.3
lang=auto           # auto | ru | en
```

## Language

All user-facing text is in the `STRINGS` table in `main.lua` (`ru`, `en`), formatted through `T(key, ...)`. With `lang=auto`, the script runs `powershell -Command [Globalization.CultureInfo]::CurrentUICulture.Name` once at startup (async). Any `ru*` result gives Russian, anything else gives English. Until the answer arrives (under a second), the menu is in English. The menu entry is found by its `watch-together-leave` command, not by its title, because the title changes with the language. The detected language is published in `user-data/watch-together/lang`.

Verified: `lang=ru` and `lang=en` give the full menu in that language, and `auto` gave `ru` on a Windows whose first display language is `ru`. Not verified on an English Windows. Note that a PowerShell started from this dev environment reports `en-US` while mpv started normally reports `ru`.

## Test

```
powershell -ExecutionPolicy Bypass -File tests\e2e.ps1 -Mpv C:\programs\mpv\mpv.exe
```

It starts two `--no-config --vo=null` mpv instances with port 47899. Each has a two-episode playlist (600 s and 400 s test videos in `%TEMP%`). It checks:

- connect;
- the joiner follows the host's episode and position;
- friend file names are known;
- pause, seek (paused and playing) and speed both ways;
- 6 joiner seeks at random moments against the host's ticks, none lost;
- drift under 0.3 s over 5 s;
- manual next/previous episode both ways;
- no echo loop;
- disconnect detection.

Last run (mpv 0.41.0-dev): all 16 checks passed, max drift 0.12 s. A separate stress run (5 seeds, 12 random joiner seeks or pauses each, 60 actions in total) lost none.

Manual checks done once (not automated):

- the menu item appears at the top of the right-click menu in a real window and survives select.lua rewrites;
- the "У тебя / У друга" items show file names, with `&` escaped;
- different file names fall back to the playlist index;
- auto-advance at the end of an episode on both sides ends on the same episode with no switching back and forth;
- join before the host exists keeps retrying;
- the host leaving and coming back reconnects;
- a busy port shows an error;
- no orphan `bridge.ps1` after mpv is killed.

## Conventions

- `bridge.ps1` stays ASCII: Windows PowerShell 5.1 reads BOM-less scripts as ANSI. All user-facing text lives in `main.lua` (UTF-8).
- `install.bat` / `uninstall.bat`: UTF-8 with `chcp 65001`, CRLF line endings.
- mpv Lua is LuaJIT/5.1: no `//` operator, no `goto` assumptions.
