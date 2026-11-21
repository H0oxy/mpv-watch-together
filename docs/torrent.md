# Torrent mode

The host opens a magnet or a .torrent; every player streams the episode from its own torrent engine while it downloads. Nothing of the video is written to disk. The room's sync is unchanged: an episode is a playlist entry whose name the room compares like any file name. Why it is built this way: [decisions.md](decisions.md#torrent-mode-torrserver-downloaded-on-first-use).

## Engine

TorrServer (github.com/YouROK/TorrServer, GPL-3.0), one Windows exe from the MatriX line (MatriX.150). `ENGINE` at the top of `main.lua` pins its release URL and SHA256; the plugin never ships it. A different pinned version replaces the old exe on the next start, because its hash no longer matches.

`torrent.ps1` starts with the first torrent command and keeps running while mpv runs. It turns `-Exe` into a full Windows path first: `main.lua` joins the folder and the file name with "/", and process paths come back with "\", so the path checks below would not know our own engine.

**Why a password and a random port.** TorrServer's API allows every origin (MatriX.150 `server.go`: `AllowAllOrigins = true`, `AllowPrivateNetwork = true`). Without a password, any web page open while the engine runs could add torrents or change its settings through `http://127.0.0.1:<port>`. So our engine runs with TorrServer's HTTP password (`-a`, account `wt` in `accs.db`), which `/settings`, `/torrents` and the other API routes need. `/stream`, `/play` and `/echo` stay open in TorrServer, and a random port is what keeps a page from finding them easily.

1. If `torrent_url` is set, it only checks `/echo` there and starts nothing, with no password (the user's own engine).
2. Otherwise it reads `engine.json` (`{port, pass}`) in `~~/watch_together_engine`. If the engine there answers `/echo`, refuses `/settings` without the password (401) and takes it with it, that engine is used: another mpv window started it.
3. Else, holding the named mutex `Local\watch-together-engine` (helpers of several mpv windows take turns, so only one starts an engine), it stops any other `TorrServer.exe` running from our folder. That one is an older plugin's engine without a password, or a hung one, and it would hold `config.db` (bbolt): a new engine then fails with `error open bboltDB ... timeout`. Then it makes sure that `TorrServer.exe` exists and matches the pinned hash. If not, it downloads it to `.part` (reporting `engine <bytes> <total>`), checks the hash, and renames it. A mismatch is an error, and the file is deleted.
4. **Port and password.** The port is `torrent_port` if set, else the one in `engine.json` if it is still free, else a free one. The password is the one in `engine.json`, else 16 random bytes. Both go to `engine.json` and the password to `accs.db` (`{"wt": "<pass>"}`).
5. **Start.** It runs `TorrServer.exe -p <port> -i 127.0.0.1 -d <engine dir> -a`, with stderr in `engine-errors.log`. If the engine exits before `/echo` answers, the last line of that log becomes the error the user sees (TorrServer logs harmless notes first, such as "ffprobe and avprobe not found in $PATH").
6. **Password check.** TorrServer silently runs without a password when it cannot read `accs.db` (`auth.go`: `getAccounts` returns nil and no middleware is added). So once it answers, the same 401 check runs. An engine that takes requests without the password is stopped and refused: "the engine started without its password".
7. **Watchdog.** It also starts a hidden `powershell` (`-EncodedCommand`). Every 5 s that process looks for a `powershell` whose command line runs `torrent.ps1` with our `-Exe` (compared with "/" turned into "\"). Once there is none, it kills the engine, but only if its pid still belongs to `TorrServer.exe` at our path: an engine that died earlier may have left its pid to another program. Every mpv window that uses the engine runs such a helper, so the engine stays while any of them does. A helper ends with its mpv, also a killed one: its IPC pipe breaks and the read loop exits. mpv kills `torrent.ps1` itself on a normal exit, so the helper cannot clean up. (It used to wait for every process named like the starting mpv, and any mpv window, even one without a torrent, kept the engine: bugs.md.)
8. **Settings.** It reads `/settings`, then writes them back with `cacheSize = torrent_cache MB`, `useDisk = false`, and Bonjour, DLNA, Rutor and Torznab off. The settings are replaced as a whole, which is why they are read first. For room peers (below) it also sets `PeersListenPort` to a port free for TCP and UDP (the BitTorrent client listens on both and does not start if either is taken; a new one each start) and `UploadRateLimit = 1048576` KB/s with `DisableUpload = false`.
9. It answers `ready <base url>`, and Lua takes its stream address from that. Commands sent before that wait in `engine.queue`. Then it reads `PeersListenPort` back from `/settings` and reports `peerport <n>` (also for another window's engine, and again after a restart); Lua puts it in `user-data/watch-together/peer-port`.

**Health check.** Every 5 s `torrent.ps1` checks `/echo`. After two misses in a row (10 s, so a slow answer under load does not count), it runs steps 2-9 again with `-Restart`. If something still holds the port, that is the engine being slow, and no second engine starts. A new start reuses the port and password, so the playlist's stream URLs keep working; it reports `restarted`, plus `ready <base>` if the port had to change. Torrents come back from the engine's db (`save_to_db`) when their stream is asked for. `engine_hash()` accepts any `127.0.0.1` port, so entries made before a port change still count as torrent streams.

Commands (Lua → `script-message watch-together-torrent-cmd …`, seen by `torrent.ps1` as `client-message`):

| command | what happens | answer |
|---|---|---|
| `add <id> <link>` | `POST /torrents {action: add, link, save_to_db: true}`, then `get` every second until `file_stats` appear (90 s limit) | `files <id> <hash> <json [{i, path, length}]>` or `error <id> <text>` |
| `probe <hash>` / `probe-stop` | `get` every second | `stat <hash> <bytes/s> <active peers> <seeders>` |
| `peer <hash> <address> <share port> <who>` / `peer-stop` | guest: room peer link (below) | none |
| `help <guest id> <hash> <index> <byte>` | host: a reader where that guest is stuck (below), closed 6 s after the last ask | none |
| `fonts <hash> <i:ext:length;…>` | saves each file as `%TEMP%\watch-together\fonts\<hash>\<i>.<ext>` through `/stream?link&index&play`, one at a time, keeping one of the right size from earlier | `fonts <hash> <failed count>` |

`link` is a magnet, a bare hash, or `file:///C:/path/x.torrent`; TorrServer's `ParseLink` takes all three. `save_to_db` matters: TorrServer closes a torrent that has had no reader for up to a minute (`TorrentDisconnectTimeout`), and a later `/stream?link=<hash>` brings it back from its db with the original trackers. Without the db it would come back from the hash alone.

Verified in TorrServer's source (2026-11-15): `file_stats[].id` is the 1-based file number, and `/stream?index=N` looks the file up by that id. `add` replies before the metadata is there. `/stream` serves Range requests through `http.ServeContent`.

## Streams and names

An episode is `<ENGINE_BASE>/stream/<pct-encoded file name>?link=<hash>&index=<id>&play`.

- `basename()` drops `?…` and percent-decodes, so the name is the torrent's file name, and `follow_file`, `missing_files`, history and the duration check work as for local files. A local copy with the same name still wins over the stream.
- mpv's `filename` property keeps the query, so all room code reads `media_name()` (`basename(path)`) instead.
- `engine_hash(path)` returns the hash and the index of such a URL, or nil.
- The `on_load` hook at priority 50 gives these URLs the online buffer (development.md, Online buffer and the RAM guard) and sets `force-media-title` to the file name. TorrServer MatriX.150 reads ahead a fixed 16 MB past mpv's read position (`updateRA`: `adj := int64(16 << 20)`), so mpv's buffer, not the engine's `cacheSize`, decides how far ahead a torrent downloads.

Only video files (by extension) go into the playlist, or all files if there are none, in natural order (`S1E2` before `S1E10`). `set_torrent_files()` does this for the host and for guests, and also works out the extra tracks (below).

## Extra tracks

Releases often carry voice-overs and subtitles as separate files, laid out in any way: `Rus Sound/<studio>/<episode>.mka`, `Subs/Show.S01E02.rus.srt`, `.ru.srt` next to the video, a folder per episode, per season. mpv finds such files only for local videos in the same folder, so torrent mode attaches them itself. `tracks.lua` (pure Lua; `tests\tracks.ps1` runs it on file lists) decides which file goes with which video; `main.lua` adds them.

**Kinds** by extension: video, subtitles (`srt ass ssa vtt sup smi`), audio (`mka aac ac3 eac3 dts flac mp3 opus m4a thd` …), fonts (`ttf otf ttc`). An audio or subtitle file under a folder named OST, Soundtrack, Music (or Cyrillic equivalents) is an album, not a track (unless the videos' own path has that word).

**Matching.** Names become tokens: words and numbers, `01` = `1`, an 8-hex CRC dropped, and a number right after letters also gives a pair (`S02E01` → `s 2 e 1 s:2 e:1`). Nothing depends on fixed words: what all the files of one set share is taken off, and the rest is what tells them apart.

1. **Scope:** the nearest folder above the track that holds videos. Only those videos are candidates (a season folder keeps season 1's subtitles off season 2).
2. **One video in scope** (a film, a folder per episode): the track is its own.
3. **Several:** the video's own part = its tokens minus what all videos in scope share; the track's own part = its tokens minus what all tracks of its kind in its folder share. A lone track, or a folder whose tracks share their numbers (rus + eng of one episode), takes off what the videos share instead.
   - Every number of the track's own part must be in the video's own part (as a set: a season number is often in both the folder and the name of a video, once in a subtitle's name). A track whose own part has no number is not placed.
   - Among those videos, the score counts the video's own numbers found in the track's tokens (+1) or missing (−1); words (`sp`, a title, `s:2` pairs, the track's studio) only decide between equal numbers.
   - The single best wins. A tie places nothing: a missing track beats one on the wrong episode.

Checked layouts (tests\tracks.lua): a studio folder plus two subtitle folders with specials `Sp 1` beside episode `01` and a Bonus folder; flat `.ru.srt` plus studio folders named only `E01.mka` or `2x01`, with a constant `S02` and `DDP5.1`; rus/eng in one Subs folder; season folders with episode titles only in the video names (`s02e05_Red.Herring.2`); a film with Subs/Audio and an OST album; a folder per episode; two studios side by side (`01 [AniLibria]`, `01 [Anidub]`); voice-overs of all languages under one Cyrillic folder; a lone subtitle; a fansub release with CRCs; two seasons in one folder; and what cannot be told (no number, other numbering), which stays unplaced.

**Title and language.** The title is the track's folders below the scope, without folders every placed track of its kind shares ("Rus Sound", "Озвучки", whatever the name), plus the words of its file name the video lacks (`rus`, `forced`, `LostFilm`); one studio's folder shared by all its tracks is still the name when nothing else is left. The language is, in this order: a language word in the file name's own part or the nearest folder (`rus`, `eng`, `RusSub`, `русский`; two-letter codes only as the name's last part, `x.ru.srt`, because `it`, `de` are title words), else `ru` for a known Russian studio (a list of Latin names in tracks.lua) or Cyrillic in the title. A folder shared by all tracks gives no Cyrillic hint: "Озвучки/ENG/…" is English. Tracks named commentary or original are no voice-over.

**Adding.** An `on_preloaded` hook (the file is open, tracks not chosen yet) runs `sub-add` / `audio-add <engine url> auto <title> <lang>` for the episode's tracks, all at once through `mp.command_native_async` with the hook deferred: each waits for its first pieces from the swarm, so one by one they would add up. The hook goes on when all are in or after 5 s; a later one still joins the track list, only after mpv's choice. Measured with mpv 0.41: tracks added this way take part in mpv's own choice (`alang`/`slang`), and three tracks behind a server that waits 2 s per request were in after 2.1 s.

**Which audio plays.** mpv keeps no manual track choice from one file to the next (checked: aid=2 picked in file 1, file 2 started on the default), and it never prefers an external track of unknown language. So for a player whose display language is Russian, with no `alang` and `aid=auto`, `pick_audio()` sets `file-local-options/aid` per episode: the video's own Russian track, else the release's first Russian track (folder order), else its first voice-over of unknown language (a separate audio file is almost always a translation). Otherwise mpv chooses. Subtitles are left to mpv. mpv drops the language `und`, so "unknown" cannot be expressed through `alang`.

**Fonts.** When a torrent has ASS/SSA tracks and font files, `fonts` asks torrent.ps1 to save them (names `<file id>.<ext>`, never the torrent's). Once they are in, every torrent episode that loads gets `file-local-options/sub-fonts-dir` set to that folder. Checked with mpv 0.41: libass loads the folder's fonts when it is set in `on_preloaded`; set during playback, even with `sub-reload`, it is not loaded, so fonts that arrive late apply from the next episode. `uninstall.bat` removes `%TEMP%\watch-together`, fonts included.

Each player attaches tracks from its own engine; nothing about tracks goes over the room. A guest with its own copy of an episode gets what mpv itself finds next to it.

## Opening

- **From the menu** (Open torrent from clipboard, host or alone): `open_torrent(text, nil)`. What plays now keeps playing until an episode is picked; then the picked one is loaded with `replace`, and the others are inserted before and appended after it.
- **Through mpv** (command line, drag and drop, a playlist): an `on_load` hook at priority 9 catches `magnet:?` and existing local `.torrent` paths. It calls `hook:defer()`, inserts the episodes after the link's entry, and after the pick runs `playlist-play-index` and `hook:cont()`. mpv then drops the link's own load, because a new file was requested. The link's entry is in `replaced` and goes at the next `start-file`. mpv waits for a deferred hook even when told to quit, so while the hook is held a forced `CLOSE_WIN` binding (the window's close button) closes the chooser, continues the hook and quits.
- mpv takes a magnet for a relative file path: the entry becomes `<cwd>\magnet:?…` with `/` turned into `\` (`udp://x` → `udp:\x`). The hook takes everything from `magnet:?`, turns `\` back into `/`, and restores `scheme:/x` to `scheme://x` (see bugs.md).
- **A torrent watched before** (history entry `btih:<hash>` naming one of its episodes) opens no chooser: it plays that episode from the remembered time (`pending_resume`) and says "Resuming <episode> at <time>". Another episode is in the playlist. The history is written only with `resume_memory` on.
- **Chooser** for a new torrent: `mp.input.select`. `submit`, `closed` (Esc at the top: the first episode) and `script-message watch-together-pick [k]` (tests) all end in `finish`, which runs once.
  - **One folder at a time** (`tracks.folder`): a folder's subfolders, as `Season 1/  (12)` (the count of episodes), and its own files; a folder that holds only one subfolder (the torrent's own wrapper) is skipped into. Inside a folder, the first item is `..  Back`; Esc also goes up a level. Going up puts the folder just left in focus. The next view opens from `closed`, which the console sends after `submit`, deferred by a zero timeout.
  - **Labels** (`tracks.short_names`): no sizes, only what tells the entries apart. Per name: the extension and every bracketed group (`[..]`, `(..)`, `{..}`, full-width brackets) go; a `[..]` that is only a number (`[01]`, `[S01E02]`) stays, it may be the episode. Then the start and the end all names of the view share go, up to a word end (`Show - 01 - Title 1080p WEB-DL` -> `01 - Title`), so quality tags written in any way vanish when they are the same everywhere. If that leaves a label empty or equal to another, the names are shown without the shared part, then as they are. A label over 70 chars loses its middle. No fixed words. Known limit: a word that ends every episode title (`... Title`) goes with the shared end. The season goes between them (`041 — Season 2 — Show`): the folders between the torrent's own folder and the episode, cleaned like names and without the show's title, left out when the label already holds `S01E05`. Folder rows keep their words (`Season 1/  (40)`, not `1`); the prompt shows the folder path. The console's select filters by typed text, so with 100+ episodes typing `041` or `S2` narrows the list. The show's title goes after the episode (`01 — Show name`, cut at 40 chars): the start the names shared (second result of `short_names`), else the torrent's own folder name cleaned the same way. `watch-together-pick [k]` still takes the index in the whole playlist.

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

## Room peers

In a room the engines also exchange pieces: every guest's engine is a BitTorrent peer of the host's, through the host's share port, and a stuck guest gets a reader in the host's engine where it stands. Details: [torrent-peers.md](torrent-peers.md).

## Next episode ahead

`preload_next()` runs in the 1 s timer for every player. Once a torrent episode has `torrent_preload` seconds (120) or less left, it looks at the next playlist entry, only once per episode (`preloaded_path`). If that entry is an engine stream, it sends `preload <hash> <index>`. A next entry that is a local file or a host stream needs nothing, so a guest with its own copy fetches nothing.

`torrent.ps1` sends `GET /stream?link=<hash>&index=<i>&preload` as a `HttpWebRequest.GetResponseAsync()`, because TorrServer answers only once the preload is done, and a newer preload aborts the older one. When it finishes, it reports `preloaded <hash> <index>`, or `preload-failed <hash> <index> <text>`, both for the log.

TorrServer (MatriX.150 `apihelper.go`, `preload.go`) fetches `cacheSize × preloadCache %` from the start of the file, plus the last piece or 8 MB (an index is often there). `torrent.ps1` sets `preloadCache = 50`, so that is 128 MB of the 256 MB cache. The pieces stay in the engine's cache, and the next episode's first reads come from there.

Test: torrent.ps1 "near the end, the next episode is fetched ahead". The room is 70 s before the end of episode 1: A and B, who stream it, ask the fake engine for index 2 exactly once each; C, on its own copy, asks for nothing.

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
- an older engine already running from our folder without a password being stopped before ours starts;
- a free port and a password in `engine.json`, and the API refusing a request without it;
- a second mpv window using the running engine;
- a killed engine coming back on the same port;
- an engine that ignores its password (environment variable `FAKE_IGNORE_AUTH`) being refused and stopped;
- the watchdog stopping the engine once the only player that uses it is killed, while three other mpv windows (without a helper) stay open; the killed player's helper exits by itself.

The exe path goes in as `main.lua` gives it, with "/" separators. Last run: 7/7; the helper before the fixes below failed 3 of them.

`tests\torrent.ps1` runs offline. `tests\fake_torrserver.py` answers the calls the plugin makes:
- `/echo`, `/settings`;
- `/torrents add|get` (`add` without metadata, like the real one);
- `/stream` with Range over the e2e test videos;
- `download_speed` from a file the test rewrites.

`/log` lists every link that was added. The checks:
- magnet → episodes → chooser → paused pick;
- seasons in folders: into a folder, Back, Esc, the folder left in focus, a pick (by keys);
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
- room peers: each guest's tracker names its tunnel for the room torrent and nobody for another hash; bytes go both ways from the tunnel through the host's share port to a listener standing in for the host's engine (`bt_port` in the fake's settings);
- a stuck guest gets a reader in the host's engine where it stands (the fake's streams of the .torrent stop after 150 KB, `stall`; the host's Range request shows in `/log`);
- the watched part keeps to its own limit (`demuxer-donate-buffer` off);
- a room torrent the guest's engine could not take is tried again (`fake_torrserver.py` reads its config on every request, so the test adds the torrent after the first try failed);
- a torrent watched before goes on where it stopped without the chooser;
- the window's close button quits mpv while a dropped torrent's chooser is open (`keypress CLOSE_WIN`);
- extra tracks: a player with Russian display language gets the episode's voice-over (title from its studio folder, `ru`) and subtitles, hears the voice-over first, the font is fetched, and the next episode gets its own files and the font folder. The stand-in audio files are episodes, so the test counts only audio and subtitle tracks.

Last run: 39/39. `tests\tracks.ps1`: 13/13.

## Log

`~~/watch_together_torrent.log` (`%APPDATA%\mpv\watch_together_torrent.log`), also in mpv's log at info. `tlog()` writes:
- the helper starting and exiting, with its stderr;
- the engine download and `ready`;
- every add and its answer (hash, number of files), and engine errors;
- the picked episode;
- how many extra tracks and font files a torrent has, the tracks each episode gets, which audio was put first, and when the fonts are in;
- the room torrent a guest got, whether the .torrent came from the share port, and how many episodes it knows;
- a room file the guest doesn't have (once per name);
- every `file-loaded` while torrents are involved;
- the check start and stop, and each speed sample with the peer count and seconds buffered;
- room peers: the guest's link on and off, and on the host each guest whose engine linked.

Past 1 MB at startup the log moves to `.old`. When something fails on a friend's PC, ask for this file.

Not covered offline: the real engine download and hash check, TorrServer's own behaviour (speed units, idle close, seeking in a real swarm), and the firewall prompt. These need a live run with the network. The pinned-engine mistake (Silo.2, bugs.md) shows why: the fake engine cannot catch a real engine that refuses its command line.
