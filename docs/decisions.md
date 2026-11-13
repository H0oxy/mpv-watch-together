# Decisions

## Dual copy (both have the file), not streaming from one PC

Streaming needs host upload bandwidth above the video bitrate (about 3–10 Mbit/s for a 1080p web-rip, 20–40+ Mbit/s for a BD remux [uncertain]), an HTTP server with Range support for seeking, and it stalls when the host closes mpv. With dual copies, only small control messages travel, seeking is instant, and drift stays under 0.1 s.

## Custom plugin instead of Syncplay

Syncplay (1.7.6, Aug 2026, Apache 2.0, free public servers) already does dual-copy sync. The user chose a custom plugin for a right-click menu inside mpv with no separate app. Trade-off: we maintain our own code.

## Transport: Porthole over Steam

Options considered:

- Syncplay public servers: no extra install, but the protocol is undocumented.
- Tailscale: the friend needs an account.
- Port forwarding: fails behind CGNAT.

Porthole (free on Steam, released 3 Aug 2026) forwards a local TCP port to Steam friends, P2P or via the Valve relay, so neither side touches the router. The plugin is transport-agnostic: plain TCP to `address:port`.

Verified on a real two-PC link: Porthole reaches a host listener bound to 127.0.0.1, and the connection was direct (12 ms). [uncertain] Porthole encryption is not verified.

## Networking helper in PowerShell

mpv Lua/JS scripts have no sockets. PowerShell 5.1 ships with Windows, so the friend installs nothing. The helper only relays lines; all logic stays in Lua, where properties are cheap to read and the OSD text can be Unicode.

## Menu via `menu-data`

mpv 0.40+ binds right-click to `select/context-menu`, which shows the native Windows menu built from the `menu-data` property. select.lua fills that property from menu.conf and rewrites it when its items change. The plugin observes `menu-data` and re-inserts its submenu at the top whenever it is missing or stale. This way the user's menu.conf is never edited.

## Sync model: star, host is the only authority

With more than two people, letting every player broadcast its own actions leads to disagreement when two act at once. In protocol 2:

- Guests connect only to the host.
- A guest's action is a request.
- The host applies requests in arrival order and broadcasts each result with an increasing `epoch` and `by`.

Everyone ends up in the last state the host broadcast. The host sends `tick` every second; guests catch up small drift by speed and seek only past `threshold` (0.5 s), and ignore ticks older than their own unanswered request. A mesh (everyone to everyone) would need N² links through Porthole and an agreement protocol; the star needs one link per guest.

Cost: the host's upload grows with the guests (tick + room list per guest per second, about 0.3–3 KB each). Measured with 20 guests on one PC: host bridge about 2.5% of one core.

## "Only the host controls" is enforced by guests and the host

The host refuses requests with `control=host` and answers with `sync`. Guests know the mode from the `room` message, so they revert locally right away instead of waiting for the refusal. That makes a forbidden pause blink for a moment instead of playing on for a round trip.

## Names from Steam

Porthole connects Steam friends but exposes no API. Steam stores the persona name of every account that signed in on this PC in `config\loginusers.vdf`; the one with `MostRecent "1"` is the current user. The plugin reads that once at startup. It falls back to `%USERNAME%`, and `name=` overrides both.

## Updates from GitHub releases, with a question

The user asked for a check at every mpv start and a question before installing. Updates come from releases, not from every push to `main`, so a half-done commit never reaches users. Files are downloaded to a temp folder and copied only when all downloads succeeded and `main.lua` is present. The new code runs after the next mpv start, because the loaded script cannot replace itself.
