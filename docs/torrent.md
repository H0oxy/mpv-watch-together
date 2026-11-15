# Torrent mode

The host opens a magnet or a .torrent; every player streams the episode from its own torrent engine while it downloads. Nothing of the video is written to disk. The room's sync is unchanged: an episode is a playlist entry whose name the room compares like any file name. Why it is built this way: [decisions.md](decisions.md#torrent-mode-torrserver-downloaded-on-first-use).

## Engine

TorrServer (github.com/YouROK/TorrServer, GPL-3.0), one Windows exe from the MatriX line (MatriX.150). `ENGINE` at the top of `main.lua` pins its release URL and SHA256; the plugin never ships it. A different pinned version replaces the old exe on the next start, because its hash no longer matches.

`torrent.ps1` starts with the first torrent command and keeps running while mpv runs:

**Why a password and a random port.** TorrServer's API allows every origin (MatriX.150 `server.go`: `AllowAllOrigins = true`, `AllowPrivateNetwork = true`). Without a password, any web page open while the engine runs could add torrents or change its settings through `http://127.0.0.1:<port>`. So our engine runs with TorrServer's HTTP password (`-a`, account `wt` in `accs.db`), which `/settings`, `/torrents` and the other API routes need. `/stream`, `/play` and `/echo` stay open in TorrServer, and a random port is what keeps a page from finding them easily.

1. If `torrent_url` is set, it only checks `/echo` there and starts nothing, with no password (the user's own engine).
2. Otherwise it reads `engine.json` (`{port, pass}`) in `~~/watch_together_engine`. If the engine there answers `/echo`, refuses `/settings` without the password (401) and takes it with it, that engine is used: another mpv window started it.
3. Else it makes sure that `TorrServer.exe` there exists and matches the pinned hash. If not, it downloads it to `.part` (reporting `engine <bytes> <total>`), checks the hash, and renames it. A mismatch is an error, and the file is deleted.
4. **Port and password.** The port is `torrent_port` if set, else the one in `engine.json` if it is still free, else a free one. The password is the one in `engine.json`, else 16 random bytes. Both go to `engine.json` and the password to `accs.db` (`{"wt": "<pass>"}`).
5. **Start.** It runs `TorrServer.exe -p <port> -i 127.0.0.1 -d <engine dir> -a`, with stderr in `engine-errors.log`. If the engine exits before `/echo` answers, the first line of that log becomes the error the user sees.
6. **Password check.** TorrServer silently runs without a password when it cannot read `accs.db` (`auth.go`: `getAccounts` returns nil and no middleware is added). So once it answers, the same 401 check runs. An engine that takes requests without the password is stopped and refused: "the engine started without its password".
7. **Watchdog.** It also starts a hidden `powershell` (`-EncodedCommand`). That process waits until no process with the starting mpv's name is left, then kills the engine, but only if its pid still belongs to `TorrServer.exe` at our path: an engine that died earlier may have left its pid to another program. Waiting for the last mpv, not the one that started it, keeps the engine for other windows. mpv kills `torrent.ps1` itself on exit, so the helper cannot clean up.
8. **Settings.** It reads `/settings`, then writes them back with `cacheSize = torrent_cache MB`, `useDisk = false`, and Bonjour, DLNA, Rutor and Torznab off. The settings are replaced as a whole, which is why they are read first.
9. It answers `ready <base url>`, and Lua takes its stream address from that. Commands sent before that wait in `engine.queue`.

**Health check.** Every 5 s `torrent.ps1` checks `/echo`. After two misses in a row (10 s, so a slow answer under load does not count), it runs steps 2-9 again with `-Restart`. If something still holds the port, that is the engine being slow, and no second engine starts. A new start reuses the port and password, so the playlist's stream URLs keep working; it reports `restarted`, plus `ready <base>` if the port had to change. Torrents come back from the engine's db (`save_to_db`) when their stream is asked for. `engine_hash()` accepts any `127.0.0.1` port, so entries made before a port change still count as torrent streams.

Commands (Lua → `script-message watch-together-torrent-cmd …`, seen by `torrent.ps1` as `client-message`):

| command | what happens | answer |
|---|---|---|
| `add <id> <link>` | `POST /torrents {action: add, link, save_to_db: true}`, then `get` every second until `file_stats` appear (90 s limit) | `files <id> <hash> <json [{i, path, length}]>` or `error <id> <text>` |
| `probe <hash>` / `probe-stop` | `get` every second | `stat <hash> <bytes/s> <active peers> <seeders>` |

`link` is a magnet, a bare hash, or `file:///C:/path/x.torrent`; TorrServer's `ParseLink` takes all three. `save_to_db` matters: TorrServer closes a torrent that has had no reader for up to a minute (`TorrentDisconnectTimeout`), and a later `/stream?link=<hash>` brings it back from its db with the original trackers. Without the db it would come back from the hash alone.

Verified in TorrServer's source (2026-11-15): `file_stats[].id` is the 1-based file number, and `/stream?index=N` looks the file up by that id. `add` replies before the metadata is there. `/stream` serves Range requests through `http.ServeContent`.

## Streams and names

An episode is `<ENGINE_BASE>/stream/<pct-encoded file name>?link=<hash>&index=<id>&play`.

- `basename()` drops `?…` and percent-decodes, so the name is the torrent's file name, and `follow_file`, `missing_files`, history and the duration check work as for local files. A local copy with the same name still wins over the stream.
- mpv's `filename` property keeps the query, so all room code reads `media_name()` (`basename(path)`) instead.
- `engine_hash(path)` returns the hash and the index of such a URL, or nil.
- The `on_load` hook at priority 50 gives these URLs the online buffer (development.md, Online buffer and the RAM guard) and sets `force-media-title` to the file name. TorrServer MatriX.150 reads ahead a fixed 16 MB past mpv's read position (`updateRA`: `adj := int64(16 << 20)`), so mpv's buffer, not the engine's `cacheSize`, decides how far ahead a torrent downloads.

Only video files (by extension) go into the playlist, or all files if there are none, in natural order (`S1E2` before `S1E10`).

## Opening

- **From the menu** (Open torrent from clipboard, host or alone): `open_torrent(text, nil)`. What plays now keeps playing until an episode is picked; then the picked one is loaded with `replace`, and the others are inserted before and appended after it.
- **Through mpv** (command line, drag and drop, a playlist): an `on_load` hook at priority 9 catches `magnet:?` and existing local `.torrent` paths. It calls `hook:defer()`, inserts the episodes after the link's entry, and after the pick runs `playlist-play-index` and `hook:cont()`. mpv then drops the link's own load, because a new file was requested. The link's entry is in `replaced` and goes at the next `start-file`.
- mpv takes a magnet for a relative file path: the entry becomes `<cwd>\magnet:?…` with `/` turned into `\` (`udp://x` → `udp:\x`). The hook takes everything from `magnet:?`, turns `\` back into `/`, and restores `scheme:/x` to `scheme://x` (see bugs.md).
- **Chooser:** `mp.input.select`. The history entry `btih:<hash>` preselects its episode and resumes it (`pending_resume`). `submit`, `closed` (Esc) and `script-message watch-together-pick [k]` (tests) all end in `finish`, which runs once.

Resume memory for torrents works alone too: `remember()` runs for an engine URL even without a room, and the `on_unload` hook saves the position of every file that is left.

## Room

Host → guests: `{t: "torrent", hash, magnet?, tfile?}`. It is sent on hello, and in `file-loaded` whenever the hash of the current file differs from `sent_torrent`, before the `file` state, so a guest knows the torrent before it looks for the file. Without `hash` it means the room no longer watches a torrent. `tfile: true` means the guest should fetch `<hash>.torrent` from the share port. `share.ps1` serves that one name from `user-data/watch-together/torrent-name` / `torrent-file`, and nothing else beyond the playlist.

Guests send `hello.torrent = true`; the host warns about a member without it (`old_torrent`). PROTOCOL stays 2: older clients ignore unknown messages.

Guest (`on_room_torrent`):

1. Validation:
   - a `hash` that is not 40 hex digits ends it;
   - a `magnet` over 8 KB, or with spaces or control characters, is replaced by `magnet:?xt=urn:btih:<hash>`.

   The link goes to the engine only inside a JSON body, never into an mpv command.
2. With `tfile`, `fetch.ps1 -Event watch-together-tfile -SaveAs <hash>-<pid>.torrent` fetches it into `%TEMP%\watch-together`, so two players on one PC don't share the file. The engine reads it at `add`, and it is deleted after the answer. If the fetch fails, the magnet is used.
3. The engine's hash must equal the announced one; otherwise the fallback is tried, else an error.
4. `add_torrent_entries` appends the episodes the guest has neither as a file nor as a stream, then `apply_host_state` after 0.5 s.
5. While `room_torrent` is set, `follow_file` does not fall back to the host's playlist position: a missing name is still being added, not another release.
6. A new torrent or none (`drop_room_torrent`, also on leave) removes the old torrent's entries. The playing one is marked in `replaced` and goes at the next `start-file`.
7. If adding fails (an error, no file list within 90 s, or a hash other than the announced one, with no fallback left), `room_torrent` is cleared and the same message is tried again 30 s later. That only happens while the guest is in the room and the host has sent no other torrent since (`last_room_torrent`). The host sends it only on hello and on a change, so without this a guest would stay on its old file until it rejoined.

## Swarm check

- **Start:** when an episode is picked with `torrent_check > 0`, `check_after_pick` is set and `pause` turns on before the load. In the host's `file-loaded` that matches it, `start_check()` runs. The menu item Check the torrent pauses and starts it as well.
- **Each player:** `check = {hash, length, started, ends, sum, n, peers}`. It sends `probe <hash>`. A sample counts only from 5 s after the start (peers are still connecting) and only if the engine downloaded something in that second. TorrServer leaves `download_speed` out of its status when it is 0, and it fetches nothing while its own cache and mpv's are full, which is common while paused on an episode watched before. A zero can mean "nothing left to fetch" as well as "nothing comes". `check_result()`:
  - `need` is `length × 8 / duration`, in bit/s;
  - `speed` is the mean of the counted samples × 8. It is 0 once the check time has run out with none counted, and nil before that;
  - `buf` is mpv's `demuxer-cache-duration`;
  - `{local = true}` for a guest on its own copy of the host's file, `{away = true}` for a guest still on another file.
- **Room:** the host broadcasts `{t: "check", on}`. Guests set `check_wanted`, run their own check (again after every `file-loaded`), and send `{t: "check", r}` every second. The host stores `g.check` (numbers checked) and puts every member's `check` and `room.check = {left}` into the room info.
- **Panel:** while a check runs, `update_panel()` shows `check_lines()` instead of the member list:
  - ✓ when speed ≥ 1.5 × need;
  - ⚠ from 1 ×;
  - ✗ below;
  - "N s of video buffered" (✓) when nothing was downloaded but the player already holds at least 60 s (`CHECK_BUFFER_OK`);
  - "measuring" without data;
  - "own file" for a local copy, "not on this episode yet" for an `away` guest.

  The lines are also published as `user-data/watch-together/panel` for tests.
- **End:** the first unpause on the host, or when alone, ends it: the pause observer runs before the `expected_pause` filter, so a guest's play request ends it too. So do a file change on the host, or leaving.

## Tests

`tests\engine.ps1` runs `torrent.ps1` with its own engine, offline. The engine is a stand-in TorrServer compiled from C# in the test: it takes `-p -i -d -a` and, like the real one, wants the password from `accs.db` only with `-a` and only if the file reads. A probe script in an idle mpv records the helper's reports. It checks:
- a free port and a password in `engine.json`, and the API refusing a request without it;
- a second mpv window using the running engine;
- a killed engine coming back on the same port;
- an engine that ignores its password (environment variable `FAKE_IGNORE_AUTH`) being refused and stopped;
- the watchdog stopping the engine once no process of the player's name is left. A renamed `ping.exe` stands in for mpv; a real mpv name would wait for every mpv on the PC.

Last run: 6/6.

`tests\torrent.ps1` runs offline. `tests\fake_torrserver.py` answers the calls the plugin makes:
- `/echo`, `/settings`;
- `/torrents add|get` (`add` without metadata, like the real one);
- `/stream` with Range over the e2e test videos;
- `download_speed` from a file the test rewrites.

`/log` lists every link that was added. The checks:
- magnet → episodes → chooser → paused pick;
- the magnet reaches the engine unchanged;
- the check alone, in a room, with a slow swarm, and for a guest with its own copy;
- play ends the check;
- guests follow, sync, seek, and change episodes;
- a .torrent through the share port;
- old entries dropped;
- clipboard open plus resume;
- back to a local file;
- bad hashes and a magnet with a line break never reach the engine;
- a guest's torrent log records the room torrent, its episodes and the check;
- a room torrent the guest's engine could not take is tried again (`fake_torrserver.py` reads its config on every request, so the test adds the torrent after the first try failed).

Last run: 28/28.

## Log

`~~/watch_together_torrent.log` (`%APPDATA%\mpv\watch_together_torrent.log`), also in mpv's log at info. `tlog()` writes:
- the helper starting and exiting, with its stderr;
- the engine download and `ready`;
- every add and its answer (hash, number of files), and engine errors;
- the picked episode;
- the room torrent a guest got, whether the .torrent came from the share port, and how many episodes it knows;
- a room file the guest doesn't have (once per name);
- every `file-loaded` while torrents are involved;
- the check start and stop, and each speed sample with the peer count and seconds buffered.

Past 1 MB at startup the log moves to `.old`. When something fails on a friend's PC, ask for this file.

Not covered offline: the real engine download and hash check, TorrServer's own behaviour (speed units, idle close, seeking in a real swarm), and the firewall prompt. These need a live run with the network. The pinned-engine mistake (Silo.2, bugs.md) shows why: the fake engine cannot catch a real engine that refuses its command line.
