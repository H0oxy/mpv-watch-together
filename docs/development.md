# Development

## Layout

```
watch-together/main.lua     menu, sync logic, OSD, updater UI (runs inside mpv)
watch-together/bridge.ps1   TCP <-> mpv IPC relay; host: many guests, join: one link
watch-together/sysinfo.ps1  startup: Windows display language + Steam persona name; -Addresses: IPv4 list
watch-together/update.ps1   GitHub release check / install
watch-together/share.ps1    host: serves playlist files to guests on share_port
watch-together/fetch.ps1    guest: downloads one file from share.ps1, resumable
watch-together/stream.ps1   guest: local HTTP server for mpv, fetches pieces from share.ps1 over 4 connections
tests/e2e.ps1               host + 2 guests over loopback, 25 checks
tests/scale.ps1             host + N guests, load check (not run by e2e)
tests/buffering.ps1         waiting for a buffering/loading guest (needs python)
tests/slow_server.py        throttled HTTP file server for buffering.ps1
tests/features.ps1          settings, watching from host, downloads, countdown, resume memory (own config folders in %TEMP%)
tests/stream.ps1            stream.ps1 + share.ps1 without a room: byte ranges of a 50 MB and a sparse 5 GB file, and through a relay that cuts every connection after 700 KB
tests/update.ps1            manual, needs the network: update.ps1 check and install against the real releases
tests/speed.ps1             manual: download speed from a host's share port with 1, 2, 4, 8 connections
install.bat, uninstall.bat
```

## Processes and messages

1. A menu click sends `script-message watch-together-<action>` (`host`, `join`, `join-clipboard`, `leave`, `control <all|host>`, `invite`, `panel`, `update`, `install`).
2. `main.lua` makes sure `input-ipc-server` is set (`mpv-watch-together-<pid>` if empty), then starts `bridge.ps1` with an async `subprocess` (`playback_only=false`). Aborting that command kills the bridge.
3. Bridge to Lua: `script-message-to <script> watch-together-net <kind> [id] [data]`. Kinds: `listening`, `connecting`, `connected <id>`, `disconnected <id>`, `in <id> <line>`, `error <text>`. The host bridge names guests `p1`, `p2`, ...; the join bridge names the host `host`.
4. Lua to bridge: broadcast `script-message watch-together-out <target> <json>`, where target is a peer id or `*` (all peers). The bridge sees it as an IPC `client-message`.
5. The bridge exits when the mpv pipe closes. The joiner reconnects every 2 s. A peer write blocked for 5 s (`SendTimeout`) closes that peer. The host refuses connections beyond `-MaxPeers` (`max_guests`). The bridge reads raw bytes and splits lines itself: a peer whose line passes 1 MB is closed, so an endless line cannot fill the host's memory. `script-message watch-together-close <id>` closes one peer.

## Protocol (version 2, newline-delimited JSON)

The topology is a star. The host is the only authority; guests talk only to the host.

Guest to host:

| `t` | fields | meaning |
|---|---|---|
| `hello` | `v`, `name`, `cid` | first message; `v` must be 2. `cid` is the player's id (16 hex digits in `settings`, a new one per run without a config folder). A hello whose `cid` is already in the room replaces that member: the host drops the old entry without a "left" notice and closes its connection, so a guest who comes back keeps its name |
| `req` | `ev`, `pos`, `paused`, `speed`, `dur`, `file`, `pl` | a local user action: `ev` is `pause`, `seek`, `speed` or `file` |
| `status` | `file`, `pos`, `paused`, `rtt` | every second, for the member list |
| `wait` | `reason` (`buffering`, `loading` or empty) | sent when this player starts or stops waiting |
| `ping` | `id` | every second; the host answers `pong` |

Host to guests:

| `t` | fields | meaning |
|---|---|---|
| `state` | `epoch`, `ev`, `by`, `pos`, `paused`, `speed`, `dur`, `file`, `pl`, optional `you`, optional `wait[]` | `ev`: `sync` (to one guest: on hello, or refusing a request), `pause`/`seek`/`speed`/`file` (a change, to all, `epoch` +1, `by` = who did it), `hold`/`resume` (the room starts/stops waiting), `tick` (every second, same `epoch`). `wait` lists `{name, reason}` while the room waits |
| `room` | `control`, `members[]` | every second; members: `name`, `file`, `pos`, `paused`, `host`, `stale`, `off` (seconds ahead of the host), `wait`; a guest's `pos` is its last status projected to the moment the list is built (`pos + (now - status received + rtt/2) * speed`), so it compares with the host's own `pos` |
| `notice` | `key` (`joined`/`left`/`gave_up`), `name` | for the OSD |
| `files` | `names[]`, `port` | the host's local playlist file names (empty when sharing is off), on hello and on every playlist or file change |

State events added in 1.4:

- `countdown`: the next episode started by itself and everyone pauses; the state carries `countdown` (seconds left), and so do ticks.
- `go`: the count ended and everyone plays.
- `wait_req`: someone pressed play during the count; the field is `who`, not `by`, so the guest who asked applies it too.
| `welcome` | `you` | instead of `sync` when the host has no file loaded |
| `pong` | `id` | RTT |

### Host

- A local action (pause observer, speed observer, `playback-restart` that is not ours, `file-loaded`) is broadcast as a new epoch with `by` = host name.
- `req` with `control=all`: the host applies it to itself (position projected by the guest's `rtt/2`) and broadcasts it with `by` = guest name. With `control=host` or invalid data, the host answers that guest with `sync`. A `file` request makes the host follow the file (`follow_file`); the broadcast happens on `file-loaded` with `by` = `switch_by`.
- Names are made unique (`Name (p2)`); the guest learns its room name from `you`.

### Guest

- A local action becomes a `req`, and `pending.count` goes up. With `control=host`, it is reverted to the last host state instead (`apply_host_state`), with an OSD notice.
- A non-tick state with `by` = our room name is the answer to our own request. It is not applied, because we already did that locally and may have done more since. It only lowers `pending.count`.
- Other non-tick states are applied right away: follow the file if it differs, else check the duration, then `apply`.
- A tick is handled 0.25 s later. It is skipped while a request is pending (up to 3 s), while `seeking`, within 1.5 s of our own action, or if its epoch is older than the last state. Otherwise it is applied like a state (drift over `threshold` means a seek, smaller drift a speed nudge).
- The host position is projected as `pos + (now - received + rtt/2) * speed` while playing. `rtt` is the smallest of the last 10 pings, so one slow ping does not shift it.

### Not reporting our own changes

`apply` sets `expected_pause` and `expected_speed`, and records each seek in `own_seeks` (`pos`, `at`, `playing`). A `playback-restart` counts as ours if it landed within 1 s of any recorded target from the last 5 s; that entry is removed. mpv can merge several seeks into one restart, so a single "last target" is not enough. `expected_switch` does the same for files.

### Waiting for a stalled member

Every player checks itself every 0.25 s (`current_wait`). The reasons are:

- `loading`: `start-file` was more than 0.7 s ago without a `playback-restart`. `end-file` clears it, so a file that fails to open does not block.
- `buffering`: `paused-for-cache` has been on for more than 0.5 s. It stays on until `cache_ready()`, meaning a local file, `demuxer-cache-idle`, EOF, or at least 2 s of `demuxer-cache-duration`. Otherwise the room would resume and stall again at once.

A change is reported to the host with `wait`; the host checks its own state directly.

The host keeps `holding`, `want_paused` and `wait_list`. `update_hold()` runs on every `wait`, on disconnects, and every second. The waiting list includes:

- the host itself;
- every guest with a `wait`, protocol 2, heard from in the last 6 s, and waiting less than `wait_timeout`.

A guest over the limit is dropped once (`gave_up` notice to all).

- When the list becomes non-empty, the host pauses itself (`expected_pause`) and broadcasts `hold` with `paused = true`.
- When it becomes empty, the host restores `want_paused` and broadcasts `resume`.

`want_paused` follows the users' pause actions, so play pressed during a hold is remembered. A host play is undone locally; a guest play request is answered with a `hold` state to that guest. Ticks carry `wait`, and everyone re-shows "waiting for ..." each second; the waiting player sees "you".

Old 1.2 guests never send `wait`, and they apply `hold`/`resume` like any other paused/playing state, so `PROTOCOL` stays 2.

Test: `tests\buffering.ps1` (needs python). B streams the test videos from `tests\slow_server.py`, whose rate comes from a file. B starts at 45 KB/s, a bit above the ~34 KB/s bitrate, with `--cache-secs=5`; unthrottled, the server stuffs megabytes into the TCP buffers and a later slowdown shows only after minutes. The test checks:

- buffering pauses everyone and reports the reason;
- play during the hold is held back;
- everyone resumes in sync;
- a slow episode load waits with reason `loading`;
- a 6 s timeout plays on.

Last run: 8/8. Screenshots checked: the host sees "Ждём: Аня (буферизация)", the guest sees "Ждём: тебя (буферизация)", then "Все готовы, продолжаем".

### Next-episode countdown

- `end-file` with reason `eof` sets `eof_advance`.
- On the host's next `file-loaded`, `countdown_pending` is set (when the setting is on and guests are there).
- On the first `playback-restart` of that file, the host pauses, sets `countdown_end`, and broadcasts `countdown`. Pausing at `file-loaded` instead would deadlock: after a gapless change mpv first plays out the old audio, which never finishes while paused (see bugs.md).
- The 1 s timer shows the count and calls `finish_countdown()` at 0, which plays and broadcasts `go` (or leaves it to the buffering hold).
- A play during the count, from the host or a guest request, calls `stop_countdown(who)`: it pauses again, sets `want_paused`, and broadcasts `wait_req`. The next play is an ordinary unpause.
- A guest that reached the end by itself sets `keep_file_until = now + 3` and does not follow the host back to the old episode meanwhile.

### Resume memory

`remember()` runs every 10 s and in `stop()` while `role` is set. It stores `{file, pos, t}` under the lower-cased folder of the current local file in `~~/watch_together_history.json` (50 newest folders). `host()` calls `offer_resume()`, which asks with `mp.input.select` when the remembered file differs or is more than 30 s from the current position. "Yes" seeks, or switches the file and seeks on `file-loaded` (`pending_resume`).

### Settings and state files

`settings` (`soft_sync`, `wait_for_others`, `countdown`, `resume_memory`, `share_files`) start from the conf options, and are then overridden by `~~/watch_together_settings.json`, which the menu toggles write. `state_file()` returns nil when `~~/` does not expand to an absolute path: with `--no-config` it becomes a bare relative name. Then settings and history stay in memory, so test runs never write into the folder mpv was started from.

Both files are written by `write_state()`: the text goes to `<file>.tmp`, then the old file is removed and the `.tmp` renamed (Windows' rename does not replace). `read_state()` falls back to the `.tmp` when the file is missing, which covers a crash between the two steps. `settings.cid`, the player's room id, is generated once and saved with the settings.

### Episode sharing

The host starts `share.ps1` with the room when `share_files` is on. It connects to the mpv pipe and listens on `bind:share_port`.

Protocol, one connection per file:

1. The guest sends a JSON line `{file, offset, who}`.
2. The host answers with `{size, offset}` or `{error}`, then the raw bytes from `offset`.

With `length` in the request (a piece for `stream.ps1`), the host reads exactly that many bytes (at most 16 MB) into memory and sends them; an offset outside the file gets `{error: "bad range", size}` instead of a restart from 0. Pieces are announced on the host once per guest and file (`watching`), not per request.

`file` must be the exact file name of a local entry of the host's current playlist, queried from mpv for every request. Names with path characters are refused, and so is everything else: verified with `..\..\Windows\win.ini`, an absolute path, and a file next to the episodes. Transfers run concurrently via `CopyToAsync`.

The guest menu lists host names that are neither in the guest's playlist nor in `download_dir()`:

- `download_dir` option if set;
- else, with `settings.download_to = "video"` (default, menu "Where to save"), the current local file's folder;
- else the Downloads folder: the real one from `sysinfo.ps1` (`shell:Downloads`, it can be moved), `%USERPROFILE%\Downloads` until that answer arrives.

Downloads run one at a time through `fetch.ps1`. It writes `<name>.part` and continues an existing one when the host accepts the offset, then renames the file and reports `done`. It never replaces an existing file: the target folder is chosen when each download starts and can change while a queue runs. `main.lua` then appends the file to the playlist and follows the room if it is on that file. Progress comes as `progress` script messages every second. Names from the host pass `safe_name()` before they become paths.

### Watching from the host

"Watch online" (guest menu, first item) starts `stream.ps1`. It listens on a free port of 127.0.0.1 and reports `ready <port>`; `main.lua` then appends `http://127.0.0.1:<port>/<percent-encoded name>` for every host file not in the playlist, and `follow_file` finds them by name like local files (`basename` decodes URLs, a local copy wins over a stream). mpv's `filename` of such a URL is the decoded name, so status, sync and history see the host's file name.

`stream.ps1` answers one mpv request at a time; a new one (a seek) drops the old. It fetches 2 MB pieces with `length` over 4 connections at once and sends them to mpv in order; the first piece goes to mpv as it arrives. A piece whose connection breaks is asked for again from where it stopped, up to 3 times. Turning it off, leaving or losing the room stops `stream.ps1` and removes the stream entries.

An `on_load` hook gives these URLs a bigger cache through `file-local-options`: `stream_cache` MB (512 by default), 3/4 as `demuxer-max-bytes`, 1/4 as `demuxer-max-back-bytes`. mpv's own 150/50 MB is about a minute of 4K ahead. Local files keep the user's settings. Test: features.ps1 "stream gets 384/128 MB of cache", "a local file keeps mpv's cache size".

Why several connections: through Porthole one connection got 28 Mbit/s, 4 got 38, 8 got 44 (`tests\speed.ps1`, a real two-PC link). The tunnel caps the total, so more connections give less and less. One 4K episode (~19 Mbit/s) fits; several 4K guests share the cap. Loopback through `stream.ps1`: 188 MB/s, byte-identical for ranges at 0, 1, piece edges and the last byte, 416 past the end.

Test: `features.ps1` "host episodes added as streams", "guest follows the host onto a streamed episode", "streamed episode plays in sync after a seek", "turning it off removes the streams".

### Paused precision

`apply` seeks when the difference exceeds `threshold` (0.5 s) while playing, but only `max(0.1, 1.5 / container-fps)` while paused. A paused seek is invisible, and the limit stays above one frame so a coarse frame rate does not seek on every tick. Measured with 3 players over 5 pauses: gap 0–0.08 s (it was up to 0.3 s).

### Soft drift correction

A guest whose drift while playing is between 0.04 s and `threshold` does not seek: `apply` sets `nudge = 1 + clamp(drift / 2, ±0.05)` and plays at `room speed * nudge`, so each tick roughly halves the drift. mpv keeps the pitch (scaletempo2), and up to 5 % is not heard. The host is the reference and never nudges.

- The nudged speed goes through `expected_speed`, so the observer does not report it. Requests send `speed / nudge`, the room speed.
- A user speed change during a nudge keeps the user's change: `[`/`]` multiply the nudged speed, so it is divided by `nudge`; Backspace sets exactly 1, which is kept.
- `end_nudge()` restores the room speed on leave, disconnect, "lost" and any local action, since ticks stop steering for a while then.
- `settings.soft_sync` (option `soft_sync`, menu Settings, saved like the host settings) turns it off: no nudge, and the playing seek limit is `min(threshold, 0.3)`, the 1.4.1 behavior. Turning it off ends a running nudge.

Test: e2e "small drift caught up by speed, no seek" sends B a fake tick 0.3 s ahead; B must speed up instead of seeking, the spread stays under 0.2 s and settles under 0.1 s at speed 1, and the host and C keep speed 1. A second check presses "]" on B during a nudge: the host must get exactly 1.1. Steady spread with 3 players: 0.04 s.

### Seek latency

While a seek decodes, the picture stands still and the room keeps playing. `seek_latency` is the smoothed time from our seek command to its restart (only seeks made while playing). Seeks during playback aim `seek_latency * speed` ahead.

## Options

`%APPDATA%\mpv\script-opts\watch_together.conf`: `port`, `bind`, `address`, `threshold`, `lang`, `name`, `control`, `max_guests`, `auto_update`. See README for defaults.

## Language and name

`sysinfo.ps1` runs once at startup (async) when `lang=auto` or `name` is empty. It prints `{"lang": CurrentUICulture.Name, "steam": PersonaName}`. The Steam name comes from `<SteamPath>\config\loginusers.vdf` (the account with `MostRecent "1"`, else the first). `SteamPath` is read from `HKCU\Software\Valve\Steam`. Any `ru*` language gives Russian. Until the answer arrives (under a second), the menu is in English and the name is `%USERNAME%`. User-facing text lives in `STRINGS` (`ru`, `en`) and goes through `T(key, ...)`.

Invite address (host only): with `bind` other than `0.0.0.0`, the clipboard gets `<bind>:<port>`. With `0.0.0.0`, `sysinfo.ps1 -Addresses` lists IPv4 addresses of active non-loopback interfaces, and `ip_rank` picks one in this order:

1. Tailscale `100.64/10`
2. `192.168/16`
3. `10/8`
4. public addresses
5. `172.16/12` (often Hyper-V/WSL virtual adapters)
6. link-local `169.254/16`

The text is written to `clipboard/text`. e2e checks the `127.0.0.1` case and restores the user's clipboard. The `0.0.0.0` path is checked piecewise (address listing on a real PC, ranking on sample sets), not end to end, because hosting on all interfaces would open a firewall prompt.

The menu entry is found by its `watch-together-update` / `watch-together-install` command (always one of them), not by its title and not by `leave`, which is hidden outside a room. Buttons that cannot be pressed now are left out, not greyed: create / join only outside a room, leave only in one. Info lines (status, members, version) stay as disabled items. Button titles carry no details in parentheses and are written for people who have never seen the plugin. Member positions are not shown in the menu: writing `menu-data` makes mpv delete and rebuild every native menu item, even while the menu is open. Live times go to an ASS overlay (`show_panel`, max 20 lines). The overlay is anchored top right (`\an9\pos(res_x-20, 50)`, `res_y` 720, `res_x` from the OSD aspect), with names cut to 20 and files to 28 characters. The top left belongs to mpv's own messages (our notices, volume, seek time, stats), and y=50 keeps it below the fullscreen window buttons. Checked with screenshots: notice + panel, stats + panel, and a 640×480 window.

## Updates

`update.ps1 -Dir <script dir> -Current <VERSION>` prints `available <tag>` or `latest` (GitHub `releases/latest` of `H0oxy/mpv-watch-together`). With `-Install <tag>`, it lists `contents/watch-together?ref=<tag>`, downloads every file into a temp folder, checks that `main.lua` is there, then copies the files over the script folder and prints `updated <tag>`. Errors print `error <text>`. `main.lua` checks 3 s after startup and asks with `mp.input.select`.

Release process:

1. Bump `VERSION` in `main.lua`.
2. Commit and push.
3. Create the GitHub release `v<VERSION>` from `main`.

Every user is offered the new release the next time they start mpv. Bump `PROTOCOL` when old clients can no longer talk to new ones.

## Tests

```
powershell -ExecutionPolicy Bypass -File tests\e2e.ps1 -Mpv C:\programs\mpv\mpv.exe
powershell -ExecutionPolicy Bypass -File tests\scale.ps1 -Mpv C:\programs\mpv\mpv.exe -GuestCount 20
```

`e2e.ps1` runs a host and two guests with the same name (port 47899, `auto_update=no`, `lang=en`). Each player has a two-episode playlist (600 s and 400 s test videos in `%TEMP%`). It checks:

- connect;
- guests follow the host's episode and position;
- unique names and the member list;
- pause, seek and speed from the host and from guests;
- 6 random guest seeks against ticks;
- two guests seeking to different places at once settle on one;
- spread under 0.3 s;
- episode changes both ways;
- "only host" reverting guest pause, seek and episode;
- control back to everyone;
- a late joiner from another episode and time;
- no echo loop;
- leaving.

Spread is measured with every playing position moved back to the time of the first read, because the reads are sequential.

Last results (mpv 0.41.0-dev, one PC):

- e2e: 28/28.
- features: 15/15.
- buffering: 8/8.
- scale with 5 guests: 6/6 runs.
- scale with 20 guests: connect + sync 1.5 s, pause to all 0.08 s, guest seek to all 0.33 s, spread under 0.2 s, host bridge about 2% of a core.

`scale.ps1` stops its mpv instances in `finally`. Do not pipe it into `Select-Object -First`: that stops the script before `finally` runs and leaves mpv instances holding the test pipe names.

## Conventions

- The `.ps1` files stay ASCII: Windows PowerShell 5.1 reads BOM-less scripts as ANSI. All user-facing text lives in `main.lua` (UTF-8).
- `install.bat` / `uninstall.bat`: UTF-8 with `chcp 65001`, CRLF, kept as-is by `.gitattributes`.
- mpv Lua is LuaJIT/5.1: no `//`, no `goto`.
- Debug traces: `--msg-level=watch_together=debug` logs local actions, requests, received states and follow seeks.
