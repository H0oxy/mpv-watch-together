# Torrent mode: room peers

Part of torrent mode ([torrent.md](torrent.md)): the engines of a room exchange pieces.

Each player's engine downloads from the swarm on its own. In a room the engines also exchange pieces, so a guest whose swarm is slow gets what the host's engine has, and the host gets what a guest's engine has. Porthole only lets guests reach the host's ports, so every guest's engine is a peer of the host's engine, and guests exchange through it. Why this way: [decisions.md](decisions.md#torrent-mode-torrserver-downloaded-on-first-use).

**The link (guest).** Once the guest's engine has the room torrent and the host announced its share port (`files`), the 1 s timer of the torrent section sends `peer <hash> <address> <share port> <who>` (and `peer-stop` when the room torrent goes or the guest leaves; a restarted helper is told again). `torrent.ps1` then:
1. listens on two free 127.0.0.1 ports: a tracker and a tunnel;
2. adds `magnet:?xt=urn:btih:<hash>&tr=http://127.0.0.1:<tracker>/announce` to its engine, after a `get` of the hash: a torrent the engine had closed while idle comes back from its db with its own trackers first, not only with ours. This repeats every 60 s and after an engine restart;
3. answers an announce for that hash with one compact peer, the tunnel (`d8:intervali30e5:peers6:…e`), and any other hash with none;
4. passes each connection to the tunnel on to `<address>:<share port>` with the line `{"peer": "<hash>", "who": …}`, waits for `{"ok": true}`, and then copies raw bytes both ways.

TorrServer drops `x.pe` (peer addresses) from magnets (`utils/link.go` `fromMagnet`), but keeps `tr`, and `AddTorrentSpec` of the anacrolix fork it uses (tsynik/torrent v1.2.34) adds the trackers of a second add to the torrent already there. That is why a tracker carries the peer.

**The host side.** `share.ps1` takes a `peer` request, connects to `127.0.0.1:<peer-port>` and copies both ways; it reports `peer <who>` once, which goes into the torrent log. Without a peer port (no engine yet) it answers `{"error": "no torrent engine"}`.

**Seeding.** anacrolix uploads to a peer only while it seeds, or else at most 100 KB more than it got from that peer (`connection.go` `uploadAllowed`). A stuck guest has nothing to give, so the engine seeds: TorrServer turns `Seed` on only with an upload limit, hence 1 GB/s, which is no limit (the user's choice). It also uploads to the public swarm that way.

**Help for a stuck guest.** The host's engine keeps only the pieces around its readers (MatriX.150 `cache.go`: from a reader's offset, 5 % of `cacheSize / readers` behind and 95 % ahead), and the host's mpv reads up to its online buffer ahead. So the part where a guest is stuck has usually left the host's engine already. Each second, a guest on an engine stream that is short of video (`paused-for-cache`, or the demuxer still reading with under 10 s buffered) sends `{t: "need", pos}`, where `pos` is mpv's `stream-pos`, the byte of the file it plays. The host keeps it in `g.need`, and its 1 s timer sends `help <id> <hash> <index> <pos>` while the ask is under 3 s old and the guest is on the host's file. `torrent.ps1` opens `GET /stream?link&index&play` with `Range: bytes=<pos>-` and never reads it: the reader stays at `pos`, and the engine fetches that part, which the guest's engine then takes over the link. It opens the request again when the guest moved 32 MB on (or 8 MB back), after 40 s (TorrServer parks a reader idle for 60 s), and closes it 6 s after the last `help`. At most 8 such readers.

Not done: the host asking guests for help the same way (the link carries pieces both ways, but no guest keeps a reader where the host is stuck).

Verified live (2026-11-22, two MatriX.150 engines on one PC, a made-up hash, DHT and retrackers off): the settings are taken and the BitTorrent port listens; the engine announces to the tracker added by a second add; it dials the peer the tracker names, and through a relay to the other engine's port both show `active_peers = 1`. Not verified: pieces of a real torrent going over the link.

Tests: tests	orrent.ps1, see [torrent.md](torrent.md#tests).
