# mpv watch-together

An mpv script for watching the same video with friends on other PCs. Everyone plays their own copy of the file, and the script keeps pause, seeking, playback speed and the current episode in sync over TCP. One person hosts the room and any number of guests join it. The connection runs through [Porthole](https://store.steampowered.com/app/4963920/Porthole_Local_Port_Sharing/), a free Steam app that shares a local port with Steam friends, so nobody has to open ports on the router. Instead of files, the host can also open a magnet link or a .torrent, and everyone watches it while it downloads, with no file on disk (see [Watching a torrent](#watching-a-torrent)).

The menu and on-screen messages follow the Windows display language: Russian on Russian Windows, English on any other. This README gives the English labels with the Russian ones in parentheses. Porthole labels are quoted from its Russian interface.

## Requirements

- Windows 10 or 11. The network part is a PowerShell script, and Windows PowerShell 5.1 ships with the system.
- mpv 0.40 or newer. The script adds its items to mpv's built-in right-click menu. Tested on mpv 0.41.
- Steam and Porthole on every PC.
- The same video files on every PC, or a guest without them watches the host's files over the network (see [Episodes a guest doesn't have](#episodes-a-guest-doesnt-have)). For a series, load the episodes in the same order.
- Or no files at all: the host opens a magnet link or a .torrent, and everyone watches while it downloads (see [Watching a torrent](#watching-a-torrent)).

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

The host decides under Room settings (Настройки комнаты). Everyone controls (Управляют все) means anyone can pause, seek, change speed or switch episodes. Only the host controls (Управляет только хост) means the guests just watch: a guest who tries any of that is put back to where the host is, with a message saying why.

If someone's player stalls, the room waits for them. That happens when a player is buffering (a stream or a slow network drive can't keep up) or still opening the file after an episode change. Everyone's player pauses, and everyone sees whom the room is waiting for and why, for example "Waiting for: Alex (buffering)" ("Ждём: Alex (буферизация)"); the person it waits for sees "you". Pressing play meanwhile is remembered but not done. Once everyone is ready, playback resumes for all at the same spot. Short stalls under half a second are ignored. After 30 seconds the room gives up on that person and plays on, saying so.

When an episode ends by itself, the next one starts for everyone at once; a player still opening it makes the room wait for it as above. The host can turn on a countdown under Settings (Настройки): Wait 10 s before the next episode (Перед следующей серией ждать 10 с). Then the next episode opens paused for everyone with "Next episode in 10 s" ("Следующая серия через 10 с") on screen and starts for all when the count ends. Anyone who presses play (Space) during the count stops it; the next play starts the episode.

When the host opens a room in a folder the group watched before, mpv asks "Continue from S01E05, 12:34?" ("Продолжить с …?"). The episode and time are remembered every 10 seconds while you are in a room.

The host can turn on the countdown, and turn off resume memory, episode sharing and waiting for stalled members under Settings (Настройки), When you host (Когда ты хост). The choices are kept between sessions.

The menu lists the members with their files, and Friends' time on screen (Время друзей на экране) adds a live list with everyone's position and how far ahead or behind the host they are.

## Episodes a guest doesn't have

A guest can download an episode the host has or watch it straight from the host. Both use the second port, 47801, which the host shares in Porthole next to 47800. The host shares only the files in its mpv playlist and nothing else on its disk, so if your friends need the whole season, open the whole season folder in mpv.

Download episodes (Скачать серии) gets one episode or all missing ones. The file goes into the folder of the video you have open, next to your other episodes, and joins the playlist. An interrupted download continues where it stopped. Under Where to save (Куда сохранять) in the same submenu you can switch to your Downloads folder instead.

Watch online (Смотреть онлайн, the first item of the menu for a guest) adds the host's episodes you lack to your playlist. They play straight from the host and are never saved to disk. You follow the host to these episodes as you would to your own files, and an episode you do have plays from your copy.

The file comes over four connections at once, because through Porthole one connection gets only part of the tunnel's speed. On one real Porthole link a single connection got 28 Mbit/s and four got 38 Mbit/s. A 4K episode needs about 19 Mbit/s, so one guest can watch 4K this way. Several guests watching 4K share the host's connection, and the room may have to wait while someone buffers.

mpv keeps such an episode in RAM up to the online buffer: 1.5 GB by default, 3/4 ahead and 1/4 behind, so 1.1 GB ahead, about eight minutes of 4K. Short slowdowns go unnoticed, and a short rewind plays without loading again. Settings → Online buffer (Настройки → Буфер онлайн-просмотра) changes the size from 256 MB to 4 GB. While free memory runs low, the plugin shrinks the buffer, so that at least 1 GB or 15% of the RAM (whichever is more) stays free for everything else, and grows it back once memory is free again. Most of the cut (3/4) comes off the part already watched, the rest off the far end of the part ahead, so a short rewind still plays from memory. Shrink when memory is low (Уменьшать, если мало памяти) in the same submenu turns that off.

## Watching a torrent

Instead of files on disk, the host can open a magnet link or a .torrent. Nobody needs the video beforehand, the host included: every player downloads the episode it plays from the torrent while it plays, and keeps it only in memory.

1. Copy the magnet link, or the path of a .torrent file (Shift + right-click on the file → Copy as path). In mpv, right-click → Watch together → Open torrent from clipboard (Совместный просмотр → Открыть торрент из буфера обмена). Dragging a .torrent onto mpv or starting `mpv "magnet:?…"` works too.
2. The first time, the plugin downloads its torrent engine, [TorrServer](https://github.com/YouROK/TorrServer) (about 64 MB), from that project's GitHub release, and runs it only if it matches the checksum built into the plugin. Windows may ask whether TorrServer may use the network. Allow it: if you don't, it still works, but fewer peers can connect to you and the download is slower.
3. mpv lists the torrent's videos. Pick the episode to start from (Esc starts the first). All episodes go into the playlist, but only the one playing is downloaded. A torrent you watched before asks nothing: it goes on with the episode and the time you stopped at ("Resuming …"), and any other episode is in the playlist.
4. The episode opens paused, and the swarm check (Проверка раздачи) runs in the top right corner for 20 seconds. Each player shows how fast the torrent downloads compared with what the video needs:
   - ✓ fast enough, with a margin;
   - ⚠ just about enough, short pauses are likely;
   - ✗ too slow, expect frequent pauses.

   Press Space whenever you are ready; that ends the check. Watch together → Check the torrent (Проверить раздачу) runs it again.

Voice-overs and subtitles that come as separate files in the torrent (a "Rus Sound/Studio" folder, "Subs", "Show.S01E02.rus.srt" next to the video, and so on) join each episode's audio and subtitle tracks, named after their folder or studio. The plugin works out which file goes with which episode from the names alone, whatever the release's layout; a file it cannot place for sure is left out rather than put on the wrong episode. With Windows in Russian and no `alang` in mpv.conf, a Russian voice-over plays first: a track marked Russian, a known Russian studio (LostFilm, AniLibria, Кубик в Кубе and many more), a folder name in Cyrillic, or else the release's first separate voice-over. Fonts for ASS subtitles are fetched too and used by every episode that starts after they arrive. Everyone in a room picks their own voice-over and subtitles.

If a guest's check line stays at "not on this episode yet", the guest's player has no list of the torrent's files yet. Torrent mode keeps a log in `%APPDATA%\mpv\watch_together_torrent.log`; send it along when something goes wrong.

In a room, the guests get the same torrent from the host and each downloads it on their own PC. The video doesn't go through the host or Porthole. A guest who has an episode on disk plays that copy. A magnet reaches the guests as it is. A .torrent goes through port 47801, so share that port as well. Without it the guests start from the torrent's hash alone, which finds peers more slowly. A guest with a plugin older than 1.6 doesn't see the torrent, and the host gets a message about it.

Privacy: in a room each guest's own engine joins the host's torrent, so every guest's IP address is visible to that swarm, as with any torrent client. The guests also get the magnet link or the .torrent as the host has it, with its tracker addresses. A private tracker's address often carries a personal key, so open such a torrent in a room only with people you trust.

Two minutes before a torrent episode ends, each player's engine starts fetching the beginning of the next episode (128 MB), so the next one starts right away, in a room and alone. `torrent_preload` sets how early.

A jump to a part that hasn't been downloaded yet makes the engine fetch that part first, so the room waits a few seconds ("Waiting for: Alex (buffering)"). How long depends on the swarm. A torrent needs more download speed than the video's bitrate on every PC; the check shows whether there is enough.

The engine listens only on 127.0.0.1, on a random port, and its controls need a password the plugin makes up and keeps in `%APPDATA%\mpv\watch_together_engine\engine.json`, so a web page open in your browser can't add torrents to it. It keeps running while any mpv window is open, so several windows share it, and if it crashes, the plugin starts it again within about 10 seconds. If a guest's player can't load the room's torrent (no file list from the swarm in time, a proxy in the way), it tries again every 30 seconds.

Memory: up to 256 MB in the engine (`torrent_cache`) plus the online buffer (1.5 GB by default, see above). The engine downloads only 16 MB past what mpv has read, so the online buffer decides how far ahead a torrent is downloaded: a bigger one rides out longer slow spells of the swarm. Nothing of the video is written to disk. The engine itself lives in `%APPDATA%\mpv\watch_together_engine`. `uninstall.bat` stops it if it runs and removes it, with torrent mode's log; your settings and resume points stay.

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

A guest's torrent never loads (its check line stays at "not on this episode yet", or "Torrent: …" shows an error). A proxy or VPN app can be in the way: one friend's player loaded the torrent only after the proxy app was set to direct. Also check that Windows let TorrServer use the network. The guest's `%APPDATA%\mpv\watch_together_torrent.log` shows what the engine did, and the player tries again every 30 seconds by itself.

"Torrent: the engine exited: …" shows the last line the engine wrote, and the whole log is in `%APPDATA%\mpv\watch_together_engine\engine-errors.log`. "The engine started without its password, so it is not used" means TorrServer could not read its password file; the plugin refuses an engine that would answer anyone.

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
countdown=0         # seconds of a "next episode in" countdown; 0 = none, the next episode starts at once
resume_memory=yes   # remember episode and time, offer them when hosting again
share_files=yes     # let guests download episodes from the host
share_port=47801    # port for those downloads
download_dir=       # a fixed folder for downloads; empty = the menu choice (open video's folder or Downloads)
stream_cache=1536   # MB of the online buffer (host or torrent episodes): 3/4 ahead, 1/4 behind; 0 = mpv's default
ram_guard=yes       # shrink the online buffer while free memory runs low
torrent_port=0      # local port of the torrent engine (127.0.0.1 only); 0 = a free one, chosen when it starts
torrent_cache=256   # MB of RAM the torrent engine keeps
torrent_url=        # use a TorrServer you already run, e.g. http://127.0.0.1:8090; empty = the plugin's own
torrent_check=20    # seconds of the swarm check after picking an episode; 0 = off
torrent_preload=120 # seconds before a torrent episode ends to fetch the next one's start; 0 = off
auto_update=yes     # check GitHub releases when mpv starts
```

The on/off settings from the menu are stored in `%APPDATA%\mpv\watch_together_settings.json` and take priority over this file. Resume points (per folder of episodes, or per torrent) are in `watch_together_history.json` in the same folder.

Without Porthole, any TCP connection works (LAN, Tailscale, a forwarded port). Set `bind=0.0.0.0` on the host. The host chooses Copy invite (Скопировать приглашение) and sends the copied text, for example `100.64.0.5:47800`, to the guests. Each guest copies it and chooses Join by copied address (Подключиться по скопированному адресу). The script picks a Tailscale address first, then a home network one. With Porthole the copied address is `127.0.0.1:<port>`, which is what Join a friend uses anyway.

## How it works

`watch-together/main.lua` runs inside mpv: menu, sync logic, messages. mpv scripts cannot open network sockets, so it starts `watch-together/bridge.ps1`, which connects to mpv's JSON IPC pipe and relays lines between mpv and the other PCs. `sysinfo.ps1` reads the Windows language and the Steam name at startup, `update.ps1` checks and installs releases, and `share.ps1` / `fetch.ps1` send and receive episodes. For watching from the host, `stream.ps1` runs on the guest as a small local HTTP server: mpv plays from it, and it fetches the file from the host's `share.ps1` in pieces over four connections. For torrents, `torrent.ps1` downloads and starts TorrServer and talks to its HTTP API; mpv plays each episode straight from TorrServer. The protocol and the design decisions are in [docs/](docs/).

Tests start several mpv instances on one PC (`ffmpeg` must be on PATH to generate the test videos):

```powershell
powershell -ExecutionPolicy Bypass -File tests\e2e.ps1 -Mpv C:\path\to\mpv.exe
powershell -ExecutionPolicy Bypass -File tests\scale.ps1 -Mpv C:\path\to\mpv.exe -GuestCount 20
powershell -ExecutionPolicy Bypass -File tests\buffering.ps1 -Mpv C:\path\to\mpv.exe   # needs python
powershell -ExecutionPolicy Bypass -File tests\features.ps1 -Mpv C:\path\to\mpv.exe
powershell -ExecutionPolicy Bypass -File tests\stream.ps1 -Mpv C:\path\to\mpv.exe
powershell -ExecutionPolicy Bypass -File tests\torrent.ps1 -Mpv C:\path\to\mpv.exe     # needs python, no network
powershell -ExecutionPolicy Bypass -File tests\engine.ps1 -Mpv C:\path\to\mpv.exe      # the engine helper with a stand-in TorrServer, no network
powershell -ExecutionPolicy Bypass -File tests\tracks.ps1 -Mpv C:\path\to\mpv.exe      # which torrent file goes with which episode, on real layouts
```

To measure a real tunnel, run `tests\speed.ps1 -Name "<file name>"` on a guest's PC while the host has a room open with that file in its playlist. It reports the download speed from the host with 1, 2, 4 and 8 connections.
