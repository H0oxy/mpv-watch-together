# Torrent mode

The host opens a magnet or a .torrent; every player streams the episode from its own torrent engine while it downloads. Nothing of the video is written to disk. The room's sync is unchanged: an episode is a playlist entry whose name the room compares like any file name. Why it is built this way: [decisions.md](decisions.md#torrent-mode-torrserver-downloaded-on-first-use).

## Engine

TorrServer (github.com/YouROK/TorrServer, GPL-3.0), one Windows exe from the MatriX line (MatriX.150). `ENGINE` at the top of `main.lua` pins its release URL and SHA256; the plugin never ships it. A different pinned version replaces the old exe on the next start, because its hash no longer matches.

`torrent.ps1` starts with the first torrent command and keeps running while mpv runs:

1. If `torrent_url` is set, it only checks `/echo` there and starts nothing.
2. Otherwise, with no engine answering on `http://127.0.0.1:<torrent_port>`, it makes sure that `~~/watch_together_engine/TorrServer.exe` exists and matches the pinned hash. If not, it downloads it to `.part` (reporting `engine <bytes> <total>`), checks the hash, and renames it. A mismatch is an error, and the file is deleted.
3. It runs `TorrServer.exe -p <port> -i 127.0.0.1 -d <engine dir>`, with stderr in `engine-errors.log` next to it. If the engine exits before `/echo` answers, the first line of that log becomes the error the user sees. It also starts a hidden `powershell` (`-EncodedCommand`) that waits for mpv's pid and then kills the engine, but only if that pid still belongs to `TorrServer.exe` at our path: an engine that died earlier may have left its pid to another program. mpv kills `torrent.ps1` itself on exit, so it cannot clean up.
4. It reads `/settings`, then writes them back with `cacheSize = torrent_cache MB`, `useDisk = false`, and Bonjour, DLNA, Rutor and Torznab off. The settings are replaced as a whole, which is why they are read first.
5. It answers `ready`. Commands sent before that wait in `engine.queue` in Lua.

An engine that already answers on the port, started by another mpv or left from a crash, is reused and left running.

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
- The `on_load` hook at priority 50 gives these URLs the `stream_cache` sizes and sets `force-media-title` to the file name.

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

## Swarm check

- **Start:** when an episode is picked with `torrent_check > 0`, `check_after_pick` is set and `pause` turns on before the load. In the host's `file-loaded` that matches it, `start_check()` runs. The menu item Check the torrent pauses and starts it as well.
- **Each player:** `check = {hash, length, started, ends, sum, n, peers}`. It sends `probe <hash>`. Samples count only from 5 s after the start, while peers are still connecting. `check_result()`:
  - `need` is `length × 8 / duration`, in bit/s;
  - `speed` is the mean of the samples × 8;
  - on a non-engine file it is `{local = true}`.
- **Room:** the host broadcasts `{t: "check", on}`. Guests set `check_wanted`, run their own check (again after every `file-loaded`), and send `{t: "check", r}` every second. The host stores `g.check` (numbers checked) and puts every member's `check` and `room.check = {left}` into the room info.
- **Panel:** while a check runs, `update_panel()` shows `check_lines()` instead of the member list:
  - ✓ when speed ≥ 1.5 × need;
  - ⚠ from 1 ×;
  - ✗ below;
  - "measuring" without data;
  - "own file" for a local copy.

  The lines are also published as `user-data/watch-together/panel` for tests.
- **End:** the first unpause on the host, or when alone, ends it: the pause observer runs before the `expected_pause` filter, so a guest's play request ends it too. So do a file change on the host, or leaving.

## Tests

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
- bad hashes and a magnet with a line break never reach the engine.

Last run: 22/22.

Not covered offline: the real engine download and hash check, TorrServer's own behaviour (speed units, idle close, seeking in a real swarm), and the firewall prompt. These need a live run with the network. The pinned-engine mistake (Silo.2, bugs.md) shows why: the fake engine cannot catch a real engine that refuses its command line.
