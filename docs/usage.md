# Usage

The user-facing guide is [README.md](../README.md). This file keeps the notes that came from real use.

- Porthole guests must click "Разрешить" on the offered port. Until then Porthole opens nothing on their PC and the plugin stays at "подключаемся…". Verified on a real two-PC link: `Get-NetTCPConnection -LocalPort 47800` was empty until the friend allowed it, and it connected right after.
- A host listener on 127.0.0.1 is enough for Porthole (verified on the same link, direct connection, 12 ms).
- Porthole's Steam launch options (OpenGL, Software, MSVC build) only change how its window is drawn or built; any of them works.
- Porthole's "Виртуальная LAN" add-on is not needed for port sharing.
- The menu is in Russian on a Russian Windows and in English otherwise; `lang=ru|en` forces it.
- Version 1.0 cannot join a 1.1 room (protocol 2). Install 1.1 by hand once; from then on mpv offers new releases at startup.
