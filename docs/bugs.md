# Bugs and pitfalls

## mpv Lua is 5.1 (LuaJIT): `//` is a syntax error
Symptom: the script fails to load. Cause: integer division `//` exists only in Lua 5.3+. Fix: `math.floor(a / b)`. Verified: e2e test loads the script.

## Windows PowerShell 5.1 misreads UTF-8 scripts without BOM
Symptom: Cyrillic strings in a `.ps1` turn into mojibake. Cause: 5.1 reads BOM-less files as ANSI. Fix: keep `bridge.ps1` ASCII; all Russian text lives in `main.lua`. Verified: a test script with Cyrillic failed to match menu titles until the comparison was removed.

## select.lua overwrites `menu-data`
Symptom (expected, avoided): a submenu set once disappears after pause/track changes. Cause: select.lua rewrites `menu-data` from menu.conf when its dirty items update. Fix: observe `menu-data` and re-insert our item. Verified: the item is still present after a pause toggle in a real window.

## Seek/pause echo between peers
Cause: applying a remote state changes local properties, which would be sent back. With pause applied before the seek finishes, the echoed old position could pull the peer back. Fix: skip local changes that match `expected_pause` / `expected_speed`, and ignore the `playback-restart` caused by our own seek; states are applied idempotently. Verified: e2e "no ping-pong" check.

## Episode switch echo
Risk: B switches to follow A, B's own `file-loaded` would ask A to switch again, and quick switches could bounce back and forth. Fix: `hello.follow` is sent only for file changes we did not make to follow the friend (`expected_switch` matches `playlist-pos`). The host does not answer a hello with a switch, only on connect. Verified: e2e "stable: no ping-pong"; manual auto-advance on both sides.

## "Different file" warning flashes at episode boundaries
Cause: for a moment the peer is already on the next episode. Fix: no warning for 3 s after a file load or a follow switch (`quiet_until`).

## Friend stuck at "подключаемся…" with Porthole
Symptom: the host shows "комната открыта", the friend keeps connecting forever. Cause: the friend had not clicked Разрешить on the offered port, so nothing listened on 47800 on their PC. Fix: allow the port in Porthole. Verified on a real two-PC link: it connected right after the friend allowed the port. A 127.0.0.1-only listener on the host works with Porthole.

## `playback-restart` fires on file start
Fix: the first restart after `file-loaded` is not treated as a user seek; otherwise opening a file would seek the peer to 0.
