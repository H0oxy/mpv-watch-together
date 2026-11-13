# mpv watch-together

An mpv script for watching the same video with friends on other PCs. Everyone plays their own copy of the file, and the script keeps pause, seeking, playback speed and the current episode in sync over TCP. One person hosts the room and any number of guests join it. The connection runs through [Porthole](https://store.steampowered.com/app/4963920/Porthole_Local_Port_Sharing/), a free Steam app that shares a local port with Steam friends, so nobody has to open ports on the router.

The menu and on-screen messages follow the Windows display language: Russian on Russian Windows, English on any other. This README gives the English labels with the Russian ones in parentheses. Porthole labels are quoted from its Russian interface.

## Requirements

- Windows 10 or 11. The network part is a PowerShell script, and Windows PowerShell 5.1 ships with the system.
- mpv 0.40 or newer. The script adds its items to mpv's built-in right-click menu. Tested on mpv 0.41.
- Steam and Porthole on every PC.
- The same video files on every PC, or a guest without them watches the host's files over the network (see [Episodes a guest doesn't have](#episodes-a-guest-doesnt-have)). For a series, load the episodes in the same order.

## Install

Each person does this once.

1. Download the [latest release](https://github.com/H0oxy/mpv-watch-together/releases/latest) (Source code (zip)) and unpack it.
2. Run `install.bat`. It copies the `watch-together` folder to `%APPDATA%\mpv\scripts\`.
3. Restart mpv.

If your mpv is portable and has a `portable_config` folder next to `mpv.exe`, copy `watch-together` into `portable_config\scripts\` by hand instead. To remove the script, run `uninstall.bat`.

After that the script updates itself. Each time mpv starts it checks the latest release on GitHub, and if there is a newer one it asks whether to install it. The new version takes effect the next time you start mpv. If you say no, the menu keeps an Update to … item (Обновить до …) for later.

## Watching together

### Host

1. Open the video in mpv.
2. Right-click the video and choose Watch together → Create room (Совместный просмотр → Создать комнату). The room uses port 47800.
3. Start Porthole and create a lobby.
4. Open the port selection and add a port: protocol `tcp`, address `127.0.0.1`, port `47800`. Leave "Предложить под другим портом" unchecked. Click "Добавить", then "Готово". The bottom of the lobby window now shows "Раздаётся: TCP 47800".
5. To let guests download your episodes or watch them without downloading, add port `47801` the same way.
6. Invite your friends from the friends list or send them the lobby code.

### Guests

1. Open the same video in mpv. If you don't have it, open any video and turn on watching from the host after step 4.
2. Start Porthole and join the host's lobby.
3. Click "Разрешить" on the offered port 47800, and on 47801 if offered: that one is for downloading the host's episodes or watching them from the host. Porthole opens a port on your PC only after you allow it.
4. In mpv, right-click and choose Watch together → Join a friend (Совместный просмотр → Подключиться к другу).

A guest who joins jumps to the host's episode and position, whatever they were watching before. If a guest connects before the host has shared the port, the script retries every two seconds, so there is no need to click again.

When you are done, choose Leave room (Выйти из комнаты) or just close mpv.

## What gets synced

Pause, play, seeking, speed and episode changes reach everyone, whoever makes them. On-screen messages name the person, for example "Alex: paused". The name is the one from Steam; without Steam the script uses the Windows user name.

When someone switches episodes, the others open the file with the same name from their playlist, or the one at the same playlist position if the names differ (different releases of a show, for example). Files are compared by duration: if yours differs from the host's by more than a second, the script warns you and stops syncing until you are on the same file.

The host decides under Who can pause and seek (Кто может ставить паузу и перематывать). Everyone (Все) means anyone can pause, seek, change speed or switch episodes. Only me (Только я) means the guests just watch: a guest who tries any of that is put back to where the host is, with a message saying why.

If someone's player stalls, the room waits for them. That happens when a player is buffering (a stream or a slow network drive can't keep up) or still opening the file after an episode change. Everyone's player pauses, and everyone sees whom the room is waiting for and why, for example "Waiting for: Alex (buffering)" ("Ждём: Alex (буферизация)"); the person it waits for sees "you". Pressing play meanwhile is remembered but not done. Once everyone is ready, playback resumes for all at the same spot. Short stalls under half a second are ignored. After 30 seconds the room gives up on that person and plays on, saying so.

When an episode ends by itself, the next one opens paused for everyone with "Next episode in 10 s" ("Следующая серия через 10 с") on screen, then starts for all at once. Anyone who presses play (Space) during the count stops it; the next play starts the episode.

When the host opens a room in a folder the group watched before, mpv asks "Continue from S01E05, 12:34?" ("Продолжить с …?"). The episode and time are remembered every 10 seconds while you are in a room.

The host can turn off the countdown, resume memory, episode sharing and waiting for stalled members under Settings (Настройки), When you host (Когда ты хост). The choices are kept between sessions.

The menu lists the members with their files, and Show friends' time on screen (Показывать время друзей на экране) adds a live list with everyone's position and how far ahead or behind the host they are.

## Episodes a guest doesn't have

A guest can download an episode the host has or watch it straight from the host. Both use the second port, 47801, which the host shares in Porthole next to 47800. The host shares only the files in its mpv playlist and nothing else on its disk, so if your friends need the whole season, open the whole season folder in mpv.

Download episodes from host (Скачать серии у хоста) gets one episode or all missing ones. The file goes into the folder of the video you have open, next to your other episodes, and joins the playlist. An interrupted download continues where it stopped. Under Where to save episodes (Куда сохранять серии) in the same submenu you can switch to your Downloads folder instead.

Watch online (Смотреть онлайн, the first item of the menu for a guest) adds the host's episodes you lack to your playlist. They play straight from the host and are never saved to disk. You follow the host to these episodes as you would to your own files, and an episode you do have plays from your copy.

The file comes over four connections at once, because through Porthole one connection gets only part of the tunnel's speed. On one real Porthole link a single connection got 28 Mbit/s and four got 38 Mbit/s. A 4K episode needs about 19 Mbit/s, so one guest can watch 4K this way. Several guests watching 4K share the host's connection, and the room may have to wait while someone buffers.

mpv keeps up to 512 MB of such an episode in RAM: 384 MB ahead and 128 MB behind, which is about two and a half minutes of 4K ahead. Short slowdowns in the tunnel go unnoticed, and a short rewind plays without loading again. The `stream_cache` setting changes the size.

## How sync works

The host's player is the reference. A guest's action goes to the host as a request; the host applies it and sends the result to everyone, so two people acting at once still end up in the same place. Once a second the host sends its position. A guest a little off (up to half a second) catches up by playing up to 5% faster or slower for a few seconds, without a jump and at the same pitch. Only a bigger gap is fixed with a seek. A guest who prefers the old way turns off Settings → Catch up with the room smoothly (Настройки → Догонять комнату плавно): then any drift over 0.3 seconds is fixed with a seek. When seeking during playback, each player aims ahead by its own measured seek time, so it lands level with the others instead of behind.

In tests on one PC with 21 players (a host and 20 guests), a pause reached everyone within 0.3 seconds and the spread between players stayed under 0.2 seconds. The host's network helper used about 2% of one CPU core.

## Troubleshooting

A guest's status stays at "connecting…" ("подключаемся…"). Run this on the guest's PC:

```powershell
Get-NetTCPConnection -LocalPort 47800 -State Listen
```

Empty output means Porthole has not opened the port there. Either the guest has not clicked "Разрешить", or the host has not shared the port in this lobby.

Downloading or watching from the host fails. Check port 47801 the same way on the guest's PC (`Get-NetTCPConnection -LocalPort 47801 -State Listen`). The host has to share it in the lobby, and the guest has to allow it.

"Error: cannot listen on 127.0.0.1:47800" means another program already uses the port. Pick a different port on every PC (see below) and share that port in Porthole.

A member "has an old plugin version": versions before 1.1 cannot join a 1.1 room. That person should install the latest release once by hand; later versions update themselves.

## Settings

Create `%APPDATA%\mpv\script-opts\watch_together.conf` with any of these lines:

```
port=47800          # room port
bind=127.0.0.1      # address the host listens on (0.0.0.0 for LAN or Tailscale)
address=127.0.0.1   # where Join a friend connects
threshold=0.5       # drift in seconds before a correcting seek; less is caught up by speed
soft_sync=yes       # guest: catch up small drift by speed; no = seek over 0.3 s (also in the menu)
lang=auto           # auto, ru or en
name=               # your name in the room; empty means the Steam name
control=all         # host's default control: all or host
max_guests=50       # host refuses connections beyond this
wait_for_others=yes # host pauses the room while someone buffers or loads a file
wait_timeout=30     # seconds to wait for one person before playing on
countdown=10        # seconds of "next episode in" countdown
resume_memory=yes   # remember episode and time, offer them when hosting again
share_files=yes     # let guests download episodes from the host
share_port=47801    # port for those downloads
download_dir=       # a fixed folder for downloads; empty = the menu choice (open video's folder or Downloads)
stream_cache=512    # MB of RAM for an episode watched from the host: 3/4 ahead, 1/4 behind; 0 = mpv's default
auto_update=yes     # check GitHub releases when mpv starts
```

The on/off settings from the menu are stored in `%APPDATA%\mpv\watch_together_settings.json` and take priority over this file. Resume points are in `watch_together_history.json` in the same folder.

Without Porthole, any TCP connection works (LAN, Tailscale, a forwarded port). Set `bind=0.0.0.0` on the host. The host chooses Copy invite for friends (Скопировать приглашение для друзей) and sends the copied text, for example `100.64.0.5:47800`, to the guests. Each guest copies it and chooses Join by copied address (Подключиться по скопированному адресу). The script picks a Tailscale address first, then a home network one. With Porthole the copied address is `127.0.0.1:<port>`, which is what Join a friend uses anyway.

## How it works

`watch-together/main.lua` runs inside mpv: menu, sync logic, messages. mpv scripts cannot open network sockets, so it starts `watch-together/bridge.ps1`, which connects to mpv's JSON IPC pipe and relays lines between mpv and the other PCs. `sysinfo.ps1` reads the Windows language and the Steam name at startup, `update.ps1` checks and installs releases, and `share.ps1` / `fetch.ps1` send and receive episodes. For watching from the host, `stream.ps1` runs on the guest as a small local HTTP server: mpv plays from it, and it fetches the file from the host's `share.ps1` in pieces over four connections. The protocol and the design decisions are in [docs/](docs/).

Tests start several mpv instances on one PC (`ffmpeg` must be on PATH to generate the test videos):

```powershell
powershell -ExecutionPolicy Bypass -File tests\e2e.ps1 -Mpv C:\path\to\mpv.exe
powershell -ExecutionPolicy Bypass -File tests\scale.ps1 -Mpv C:\path\to\mpv.exe -GuestCount 20
powershell -ExecutionPolicy Bypass -File tests\buffering.ps1 -Mpv C:\path\to\mpv.exe   # needs python
powershell -ExecutionPolicy Bypass -File tests\features.ps1 -Mpv C:\path\to\mpv.exe
```

To measure a real tunnel, run `tests\speed.ps1 -Name "<file name>"` on a guest's PC while the host has a room open with that file in its playlist. It reports the download speed from the host with 1, 2, 4 and 8 connections.
