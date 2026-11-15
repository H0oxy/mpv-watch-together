# Bugs and pitfalls

## mpv Lua is 5.1 (LuaJIT): `//` is a syntax error
Symptom: the script fails to load. Cause: integer division `//` exists only in Lua 5.3+. Fix: `math.floor(a / b)`. Verified: e2e test loads the script.

## Windows PowerShell 5.1 misreads UTF-8 scripts without BOM
Symptom: Cyrillic strings in a `.ps1` turn into mojibake. Cause: 5.1 reads BOM-less files as ANSI. Fix: keep `bridge.ps1` ASCII; all Russian text lives in `main.lua`. Verified: a test script with Cyrillic failed to match menu titles until the comparison was removed.

## select.lua overwrites `menu-data`
Symptom (expected, avoided): a submenu set once disappears after pause/track changes. Cause: select.lua rewrites `menu-data` from menu.conf when its dirty items update. Fix: observe `menu-data` and re-insert our item. Verified: the item is still present after a pause toggle in a real window.

## Seek/pause echo between peers
Cause: applying a remote state changes local properties, which would be sent back. With pause applied before the seek finishes, the echoed old position could pull the peer back. Fix: skip local changes that match `expected_pause` / `expected_speed`, and ignore the `playback-restart` caused by our own seek; states are applied idempotently. Verified: e2e "no ping-pong" check.

## Host tick undoes the joiner's seek
Symptom: the joiner seeks, both players end up back at the old position (e2e "seek B -> A (playing)" failed once; a stress run lost 1 of 12 seeks). Cause, two races:
1. The `ignore_restart_until` flag skipped "the next restart" after our follow seek. A user seek merged with ours into one restart and was never sent.
2. A tick handled after mpv executed the user seek but before its `playback-restart` event reached the script looked like drift. The correction seek overrode the user's.

Fix:
1. `own_seek` compares the landing position with our own target.
2. Ticks wait 0.25 s, then skip while `seeking` or within 1.5 s of our own action.

Verified: 60 random actions in the stress run with no loss; e2e "joiner seeks vs ticks".

## Guest's own answer undoes its newer action (protocol 2)
Symptom: a guest unpauses and seeks right away, and the whole room ends up at the old position (scale test with 5 guests failed about 1 run in 2). Debug log of the guest:
1. `local action pause at 3.4`.
2. `state e2 pause by P1 pos=3.45` arrives after mpv executed the seek to 250, but before its `playback-restart` reached the script.
3. The guest applied the state (`follow seek 250.04 -> 3.55`).
4. The restart then reported a "user seek" at the current position, 3.55, so the host followed it back.

Fix: a state whose `by` is our own room name is never applied, only counted against `pending`. We already did that action locally. Verified: scale with 5 guests 6/6 runs (was failing about half), e2e 25/25.

## Merged follow seeks reported as user seeks
Cause: two quick follow seeks can produce one or two restarts; remembering only the last target made the other restart look like a user action. Fix: `own_seeks` keeps every follow seek of the last 5 s, and a restart near any of them is ours.

## Players that follow a seek land behind
Symptom: after a guest's seek during playback, the others were up to about 0.3 s behind, right at the correction threshold, so the spread check failed now and then. Cause: an exact seek decodes from a keyframe while the room keeps playing. Fix: measure each player's seek time (`seek_latency`) and aim that far ahead when seeking during playback.

## Test artifact: sequential reads look like drift
Symptom: with 21 players, "spread" was up to 0.4 s although the players were in sync. Cause: the test reads positions one by one, and playing players move during the reads. Fix: tests move each playing position back by the time since the first read.

## Test artifact: the countdown pause read too early
Symptom: features.ps1 "next episode starts paused for everyone" failed 2 runs in 6 with `pause` false on episode 2. Cause: the test read `pause` the moment both file names had changed, but the countdown pauses at the episode's first `playback-restart` (see "Countdown deadlock"), 60-90 ms later; a throwaway probe measured that gap on 3 of 3 episode changes. Fix: the test waits up to 2 s for the pause and then checks that the episode is still under 1.5 s in. Verified: features passed three runs in a row.

## Test artifact: throttling a stream showed no buffering
Symptom: the guest played on for 30+ s at 6 KB/s, a sixth of the bitrate. Cause: with the server unthrottled at start, it pushed megabytes into the loopback TCP buffers, and mpv kept reading from them. `--demuxer-max-bytes` did not limit this, and mpv showed `Cache: 599s`. Fix: in the test, start the stream at a rate slightly above the bitrate with `--cache-secs=5`, then slow it down; buffering starts within seconds.

## Countdown deadlock after an episode ends by itself
Symptom: the next episode opened paused, but the countdown never started it. Cause: after a gapless change, mpv plays out the old audio first ("blocked, waiting for old audio to play"). Pausing at `file-loaded` stopped that, so `playback-restart` never came. The plugin then saw "still loading" and held the room, and the countdown waited for the hold. Fixes:
1. Start the countdown at the first `playback-restart`.
2. "Loading" ends at `file-loaded`; later delays are buffering, which is detected separately.

Verified: features.ps1 countdown checks pass, and buffering.ps1 still sees the slow-load case.

## `~~/` without a config folder
Cause: with `--no-config`, `expand-path ~~/x` returns plain `x`, so state files would land in mpv's working folder (the project folder in tests). Fix: `state_file()` returns nil unless the path is absolute; then nothing is written. Verified: no `watch_together_*.json` in the project after all test runs.

## Leftover test mpv instances
Symptom: a test run where nobody connects and the status property is empty. Cause: an earlier diagnostic run piped into `Select-Object -First`, which stopped the script before its `finally` and left 12 mpv instances holding the `wt-scale-*` pipe names. Fix: never truncate test output that way; kill leftovers by pipe name (`CommandLine -match 'wt-'`), never all mpv processes.

## Members panel overlapped mpv's messages
Symptom (seen by the user): the on-screen member list sat on top of other text. Cause: the panel was anchored top left, where mpv draws OSD messages (our notices, volume, seek time) and the stats page. Fix: anchor it top right, below the fullscreen window buttons, with shorter lines and a smaller font. Verified with screenshots of panel + notice, panel + stats, and a 640×480 window.

## Players up to 0.3 s apart while paused
Symptom: the panel showed "+0.3 s" for a paused guest. Cause: the drift threshold was the same while paused as while playing. Fix: about one frame while paused (see development.md, paused precision). Verified: gap 0–0.08 s over 5 pauses with 3 players.

## Panel times a second apart while the drift showed +0.0
Symptom (real use, screenshot): the members panel showed the host at 0:06:56 and the guest at 0:06:55 (+0.0 s); in a test the guest showed -1.0 s while it really played in sync. Two causes, both display only (guests sync from the host's ticks, not from this list). 1) The guest's time was its raw last status, up to a second old, next to the host's live time-pos; only `off` was projected. 2) `off` was projected from `g.at`, which any message refreshes; the guest sends `ping` just before `status`, so when the host's timer ran between the two, the old position got a fresh timestamp and lost a whole second. Fix: the guest's `pos` in the room list is projected too, from `g.pos_at`, set only by `status`. Verified: features.ps1 "room list time runs on between statuses" (a raw guest sends one status, then only pings) failed with pos 100.07 after 2.5 s and passes with the fix; e2e "member times in the room list agree".

## Episode switch echo
Risk: B switches to follow A, B's own `file-loaded` would ask A to switch again, and quick switches could bounce back and forth. Fix: a file change made to follow the room (`expected_switch` matches `playlist-pos`) is not reported as a user action. Verified: e2e "stable: no ping-pong"; episode changes from host and guests.

## "Different file" warning flashes at episode boundaries
Cause: for a moment the peer is already on the next episode. Fix: no warning for 3 s after a file load or a follow switch (`quiet_until`).

## A guest flashed "in the room" while the host had no room yet
Symptom (real use, 1.6.0 test build): a guest who joined before the host opened the room saw "Ты в комнате" and "Связь с хостом потеряна, переподключаемся" in turn every 2 s. Cause: Porthole listens on the guest's PC as soon as the port is allowed, accepts the link, and drops it when nothing listens on the host's side. The guest took the TCP connect for the room. Fix: the guest becomes `connected` (and shows "in the room") at the host's first message. A link that drops before that is retried quietly. Verified: a throwaway probe with a listener that accepts and closes saw `connected` with the old main.lua and only `connecting` with the new one; e2e "a link dropped before the host answers is not the room" does the same.

## main.lua stopped loading at 201 locals
Symptom: after the online buffer was added, every torrent test failed; mpv logged `main.lua:2334: main function has more than 200 local variables`, and the script was not loaded at all. Cause: LuaJIT allows 200 active locals per function, and the main chunk already had exactly 200 in 1.5.4. The buffer added six. Fix: the buffer helpers became one table, `buffer`, and the torrent section's private helpers moved into a `do ... end` block. Verified: the script loads; adding 25 locals at the end, or 20 inside the torrent block, still loads; every suite passes on a copy that logs reads of missing globals.

## A function called above its definition stops the whole script
Symptom: buffering.ps1 "B buffers -> hold (timeout 6 s)" failed every time after the "in the room" fix, and passed on the commit before it. Cause: the fix moved `report_wait()` into `on_host_message`, which comes before `local function report_wait` in the file. There the name is a nil global, and a guest that was already buffering when the host answered hit `attempt to call global 'report_wait'`. mpv then unloads the script. Fix: forward-declare `report_wait` next to the other late definitions. Verified: the debug log of B showed the Lua error; after the fix every suite was run against a copy whose `_G` logs each read of a missing global.

## Friend stuck at "подключаемся…" with Porthole
Symptom: the host shows "комната открыта", the friend keeps connecting forever. Cause: the friend had not clicked Разрешить on the offered port, so nothing listened on 47800 on their PC. Fix: allow the port in Porthole. Verified on a real two-PC link: it connected right after the friend allowed the port. A 127.0.0.1-only listener on the host works with Porthole.

## `playback-restart` fires on file start
Fix: the first restart after `file-loaded` is not treated as a user seek; otherwise opening a file would seek the peer to 0.

## A download could replace a file of another series
Risk (found in an audit): "Download all" picks the folder when each queued file starts. A guest who opens a video from another folder meanwhile gets the rest written there, and `Move-Item -Force` replaced a same-named `01.mkv`. Fix: `fetch.ps1` refuses when the target exists, and moves without `-Force`. Verified: fetch.ps1 against an existing file reports "already exists" and leaves it untouched.

## A guest seek during a hold started the room
Risk (found in an audit, race of about one RTT): only `pause` requests were held back while the room waits. A seek or speed request sent before the guest saw the hold carried `paused=false`, so the host played and broadcast it. Fix: while `holding` or counting down, the host forces `paused = true` on any request. Not reproduced; e2e, buffering and features still pass.

## A guest who came back quickly got a "(p1)" name
Symptom (real use, three people): a guest left and rejoined; the room showed "Kio" and "Kio (p1)", then "Kio" went away and the guest stayed "Kio (p1)". Cause: the old connection was dead but still open (the tunnel had not closed it yet), so the host made the new name unique. Fix: `hello` carries the player's `cid`; a hello with a `cid` already in the room drops the old member and closes its connection (`watch-together-close`). Verified: features.ps1 opens a connection with a cid, a second one with the same cid and a third with another cid, all named Kio: the room shows "Kio" and "Kio (pN)", and the first connection gets closed. Its first version passed on the old main.lua: it accepted the expected names the moment they appeared, before the third hello was handled, so it now judges the state after two ticks.

## Watching from the host failed on files over 2 GB
Symptom (real use, a 3.6 GB 4K episode): "Watching from host: Cannot convert argument "val2", with value: "3508312763", for "Min" to type "System.Int32"". Cause: in PowerShell 5.1, `[Math]::Min([int]$a, [int64]$b)` binds the Int32 overload and fails on a large `$b`; `stream.ps1` had `[int]$Chunk`. Fix: `[int64]$Chunk`. Any `[Math]::Min`/`Max` on file offsets needs an int64 first argument. Verified: tests\stream.ps1 fails at offsets 0 and 2147483640 of a sparse 5 GB file with the old code and passes with the fix. Its first version passed on the broken code too: a response cut off after the header compared equal on zero bytes, so it now requires the full amount.

## A finished download was sometimes not added to the playlist
Symptom: features.ps1 failed "downloaded episode added to the playlist" about once in five runs; the file was complete, the guest later ran out of episodes and stood idle. Cause: `fetch.ps1` sends `done` and exits; the subprocess callback can run first and clear `dl_current`, and the handler dropped events for anything but `dl_current`. Fix: the callback keeps the name in `dl_finished`, and a `done` for it is still accepted. Verified: features.ps1 passed in 4 runs after the fix; the race was not reproduced on demand.

## One peer that stops reading blocks the host bridge
Risk (found in an audit): writes to peers are blocking. A peer whose TCP window stays at zero would stop the bridge loop for everyone. Fix: `SendTimeout = 5000` on each peer socket; the write throws and the peer is closed. Not reproduced; whether Porthole passes back-pressure is unknown.

## mpv turns a magnet into a file path
Symptom: `loadfile "magnet:?xt=…"` did nothing in torrent mode, and the entry showed as `C:\…\magnet:?xt=…`. Cause: mpv 0.41 sees no `scheme://` in a magnet, takes it for a relative path, puts the working folder in front and turns `/` into `\` (`tr=udp://x/announce` becomes `tr=udp:\x\announce`). Fix: the `on_load` hook takes everything from `magnet:?`, turns `\` back into `/`, and restores `=scheme:/x` to `=scheme://x`. The menu's "Open torrent" never puts the magnet into the playlist. Verified: probed with a real mpv; tests\torrent.ps1 "the magnet reached the engine unchanged".

## Two guests on one PC fetched the same .torrent file
Symptom: in tests\torrent.ps1 one of two guests fell back to the bare hash. Cause: both saved the host's `<hash>.torrent` to the same path in `%TEMP%\watch-together`; one removed or refused the other's file. Fix: `fetch.ps1 -SaveAs <hash>-<pid>.torrent`, deleted after the engine has read it. Verified: both guests add the file (`/log` of the fake engine), and no file is left behind.

## The last seconds of a file were not remembered
Symptom: reopening a torrent offered an episode watched minutes before, not the last one. Cause: `remember()` ran only every 10 s, so a file left within 10 s of a change was never saved. Fix: `remember()` also runs in an `on_unload` hook. Verified: tests\torrent.ps1 "the chooser resumes the torrent where it stopped" failed before and passes after.

## The pinned engine (Silo.2) refused its command line
Symptom (real use): opening a .torrent downloaded the engine, then showed "Torrent: the torrent engine stopped" and nothing else. Cause: Silo.2, the newest TorrServer release at the time, accepts only `-c <config.yaml>` (`flag provided but not defined: -p`). The flags we used belong to the MatriX line, and the offline tests never start a real engine. The real reason was also hidden: `torrent.ps1` reported it, but the job failure that followed overwrote it with "stopped". Fix: pin MatriX.150, whose source at that tag has `-p`/`-i`/`-d`. The engine's stderr goes to `engine-errors.log`, its first line becomes the error, and Lua keeps the helper's last error for the jobs it fails. Verified: ran the Silo.2 exe by hand with our arguments and got that message; MatriX.150's flags and routes checked in its source at the tag. Live (2026-11-15): MatriX.150 started with these flags and played a torrent in a room with a guest over Porthole.

## The engine outlived mpv, and the next one could not open its db
Symptom (real use, after the password update): opening a .torrent showed "Torrent: the engine exited: ... ffprobe and avprobe not found in $PATH" and nothing played. Causes:
1. An engine of the previous build (no password, port 47802) was still running with no mpv left. The watchdog compared the process path with `-Exe` as `main.lua` passes it: `...\Roaming/mpv/watch_together_engine/TorrServer.exe`, with "/" from `utils.join_path`. Windows reports "\". The paths never matched, so no engine was ever stopped.
2. That engine held `config.db`, and the new one exited with `error open bboltDB: ... config.db` after a 5 s `timeout`.
3. The message showed the first stderr line, a harmless note, instead of the last one, the cause.

Fix:
1. `torrent.ps1` makes `-Exe` a full path (`[IO.Path]::GetFullPath`).
2. Before starting an engine it stops any other `TorrServer.exe` from our folder and waits for it to exit. A named mutex keeps two mpv windows from doing that to each other.
3. The error is the last line.

Verified: engine.ps1 now passes the exe with "/" and leaves an older engine running from the folder. The helper before the fix failed "an older engine left in our folder is stopped first", "a second mpv window uses the running engine" and "the engine goes once the last player is gone"; with the fix all 7 checks pass. The engine.ps1 stand-in has no db, so the bbolt lock itself was seen only in the user's `engine-errors.log`.

## Any web page could drive the torrent engine
Risk (found in an audit, not exploited): TorrServer allows every origin and private-network requests (`AllowAllOrigins`, `AllowPrivateNetwork` in MatriX.150 `server.go`), and the plugin ran it without a password on a fixed port (47802). A page open in the browser while the engine ran could `POST /torrents` (add any torrent: the PC downloads and shares it) or `/settings`. Fix: TorrServer's HTTP password (`-a`, a random password in `accs.db`) on a random port, both kept in `engine.json`. After each start the helper checks that `/settings` without the password gets 401, because TorrServer silently runs open when it cannot read `accs.db`. `/stream` stays open in TorrServer; the random port is what hides it. Verified: tests\engine.ps1 with a stand-in engine that behaves like TorrServer's auth. Live (2026-11-15): the real MatriX.150 started with `-a`, passed the 401 check (the helper refuses it otherwise), and played a torrent.

## A second mpv window lost its torrent when the first one closed
Risk (found in an audit): windows share one engine, and the watchdog stopped it when the mpv that started it exited. The other window's streams broke, and no one started the engine again; a crashed engine stayed down too. Fix: the watchdog waits until no process with that mpv's name runs. `torrent.ps1` checks `/echo` every 5 s and starts the engine again after two misses, on the same port with the same password. Verified: tests\engine.ps1 "a dead engine starts again on the same port", "the engine goes once the last player is gone".

## A guest whose room torrent failed never tried again
Symptom (real use, a guest behind a proxy): the guest's engine got no file list in 90 s, and the guest stayed on its old file even after the proxy was turned off. Cause: `on_room_torrent` returned early for the hash it already had, and the host sends the torrent only on hello and on a change. Fix: a failure clears `room_torrent` and the same message is tried again every 30 s while it is still the host's last one. Verified: tests\torrent.ps1 "a room torrent that failed is tried again" (the fake engine learns the torrent only after the first try).

## The engine watchdog could kill an unrelated process
Risk (found while debugging the above): the watchdog killed the engine's pid when mpv exited. An engine that had already died left that pid free, and Windows may reuse it. Fix: the watchdog stops the pid only if its path is our `TorrServer.exe`. Verified with two `ping.exe` stand-ins: the matching one was killed, the one with another path was left running.

## The swarm check showed ✗ 0.0 Mbit/s while the torrent played fine
Symptom (real use): the host's check showed "✗ 0.0 of ~8.5 Mbit/s, 19 peers" on an episode it had opened before. Cause: TorrServer (MatriX.150) leaves `download_speed` out of its status when it is 0 (checked live: the field appeared only in the seconds it downloaded). While paused, it fetches nothing once its cache and mpv's are full. Every sample was 0. Fix: a second without download is not a sample; with none at all, a player holding 60 s or more shows "✓ N s of video buffered". Only one that holds less, after the full check time, shows ✗ 0. Verified: tests\torrent.ps1 (buffered and slow cases); live stats read from the user's engine.

## A guest that never reached the episode was "measuring" forever
Symptom (real use): a guest's check line stayed at "measuring". Cause not confirmed yet; the likely one is that the guest's engine had no file list for the torrent, so the guest stayed on its old file, and a check on a file that is no torrent stream was counted as "measuring". Fix so far: such a guest shows "not on this episode yet", and torrent mode now writes `watch_together_torrent.log` (see torrent.md, Log) to find the real cause.

## A torrent added twice never answered the first time
Risk (found in review): `torrent.ps1` kept one pending add per hash, so a second add of the same torrent replaced the first, and the first caller (a deferred `on_load` hook) would wait forever. Fix: each add is its own job. Not reproduced.
