# mpv watch-together

An mpv script for watching the same video with a friend on another PC. Each of you plays your own copy of the file, and the script keeps pause, seeking, playback speed and the current episode in sync over one TCP connection. The connection runs through [Porthole](https://store.steampowered.com/app/4963920/Porthole_Local_Port_Sharing/), a free Steam app that shares a local port with Steam friends, so nobody has to open ports on the router.

The menu and on-screen messages follow the Windows display language: Russian on Russian Windows, English on any other. This README gives the English labels with the Russian ones in parentheses. Porthole labels are quoted from its Russian interface.

## Requirements

- Windows 10 or 11. The network part is a PowerShell script, and Windows PowerShell 5.1 ships with the system.
- mpv 0.40 or newer. The script adds its items to mpv's built-in right-click menu. Tested on mpv 0.41.
- Steam and Porthole on both PCs.
- The same video files on both PCs. For a series, load the episodes in the same order.

## Install

Each person does this once.

1. Download the repository (Code → Download ZIP) and unpack it.
2. Run `install.bat`. It copies the `watch-together` folder to `%APPDATA%\mpv\scripts\`.
3. Restart mpv.

If your mpv is portable and has a `portable_config` folder next to `mpv.exe`, copy `watch-together` into `portable_config\scripts\` by hand instead. To remove the script, run `uninstall.bat`.

## Watching together

One of you hosts the room and the other joins it.

### Host

1. Open the video in mpv.
2. Right-click the video and choose Watch together → Create room (port 47800) (Совместный просмотр → Создать комнату).
3. Start Porthole and create a lobby.
4. Open the port selection and add a port: protocol `tcp`, address `127.0.0.1`, port `47800`. Leave "Предложить под другим портом" unchecked. Click "Добавить", then "Готово". The bottom of the lobby window now shows "Раздаётся: TCP 47800".
5. Invite your friend from the friends list or send them the lobby code.

### Friend

1. Open the same video in mpv.
2. Start Porthole and join the host's lobby.
3. Click "Разрешить" on the offered port 47800. Porthole opens the port on your PC only after you allow it.
4. In mpv, right-click and choose Watch together → Join friend (Porthole) (Совместный просмотр → Подключиться к другу).

Both screens show "Friend connected" ("Друг подключился"), and the friend's player jumps to the host's episode and position. If the friend connects before the host has shared the port, the script keeps retrying every two seconds, so there is no need to click again.

When you are done, choose Leave room (Выйти из комнаты) or just close mpv.

## What gets synced

Pause, play, seeking and speed changes go both ways, whoever makes them. When one of you switches episodes, the other player opens the file with the same name from its playlist, or the one at the same playlist position if the names differ (different releases of a show, for example).

The host sends its position every second. If the friend's player drifts more than 0.3 seconds away, it seeks to catch up. In the automated test on one PC the players stayed within 0.12 seconds of each other.

The script compares files by duration. If they differ by more than a second, it warns that the friend has a different file and stops syncing until you are both on the same one.

The menu shows the connection status and the file each of you has open (You / Friend, У тебя / У друга).

## Troubleshooting

The friend's status stays at "connecting…" ("подключаемся…"). Run this on the friend's PC:

```powershell
Get-NetTCPConnection -LocalPort 47800 -State Listen
```

Empty output means Porthole has not opened the port there. Either the friend has not clicked "Разрешить", or the host has not shared the port in this lobby.

"Error: cannot listen on 127.0.0.1:47800" means another program already uses the port. Pick a different port on both PCs (see below) and share that port in Porthole.

## Without Porthole

The script needs nothing more than a TCP connection, so a LAN, Tailscale or a forwarded port also work. On the host, create `%APPDATA%\mpv\script-opts\watch_together.conf` with:

```
bind=0.0.0.0
```

The friend copies the host's address, for example `100.64.0.5:47800`, and chooses Join address from clipboard (Подключиться к адресу из буфера обмена).

All options for `watch_together.conf`:

```
port=47800          # room port
bind=127.0.0.1      # address the host listens on
address=127.0.0.1   # where Join friend connects
threshold=0.3       # drift in seconds before a correcting seek
lang=auto           # auto, ru or en
```

## How it works

`watch-together/main.lua` runs inside mpv. It builds the menu, watches the player and decides what to sync. mpv scripts cannot open network sockets, so it starts `watch-together/bridge.ps1`, which connects to mpv's JSON IPC pipe and relays lines between mpv and the friend's PC. The protocol and the design decisions are in [docs/](docs/).

To run the tests, which start two mpv instances on one PC and check pause, seeking, speed, episode switching and drift (`ffmpeg` must be on PATH to generate the test videos):

```powershell
powershell -ExecutionPolicy Bypass -File tests\e2e.ps1 -Mpv C:\path\to\mpv.exe
```
