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

## Sync model

Host is the clock: it sends `tick` every second, and the joiner corrects drift over 0.3 s with an exact seek. User actions on either side are sent as full states. Applying them is idempotent, so echoes stop after one round.
