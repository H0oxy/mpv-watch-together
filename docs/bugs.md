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

## Episode switch echo
Risk: B switches to follow A, B's own `file-loaded` would ask A to switch again, and quick switches could bounce back and forth. Fix: a file change made to follow the room (`expected_switch` matches `playlist-pos`) is not reported as a user action. Verified: e2e "stable: no ping-pong"; episode changes from host and guests.

## "Different file" warning flashes at episode boundaries
Cause: for a moment the peer is already on the next episode. Fix: no warning for 3 s after a file load or a follow switch (`quiet_until`).

## Friend stuck at "подключаемся…" with Porthole
Symptom: the host shows "комната открыта", the friend keeps connecting forever. Cause: the friend had not clicked Разрешить on the offered port, so nothing listened on 47800 on their PC. Fix: allow the port in Porthole. Verified on a real two-PC link: it connected right after the friend allowed the port. A 127.0.0.1-only listener on the host works with Porthole.

## `playback-restart` fires on file start
Fix: the first restart after `file-loaded` is not treated as a user seek; otherwise opening a file would seek the peer to 0.

## A download could replace a file of another series
Risk (found in an audit): "Download all" picks the folder when each queued file starts. A guest who opens a video from another folder meanwhile gets the rest written there, and `Move-Item -Force` replaced a same-named `01.mkv`. Fix: `fetch.ps1` refuses when the target exists, and moves without `-Force`. Verified: fetch.ps1 against an existing file reports "already exists" and leaves it untouched.

## A guest seek during a hold started the room
Risk (found in an audit, race of about one RTT): only `pause` requests were held back while the room waits. A seek or speed request sent before the guest saw the hold carried `paused=false`, so the host played and broadcast it. Fix: while `holding` or counting down, the host forces `paused = true` on any request. Not reproduced; e2e, buffering and features still pass.

## One peer that stops reading blocks the host bridge
Risk (found in an audit): writes to peers are blocking. A peer whose TCP window stays at zero would stop the bridge loop for everyone. Fix: `SendTimeout = 5000` on each peer socket; the write throws and the peer is closed. Not reproduced; whether Porthole passes back-pressure is unknown.
