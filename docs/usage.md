# Usage

Requirements on both PCs: Windows 10/11, mpv 0.40 or newer (for the built-in right-click menu; tested on 0.41.0-dev), Steam with Porthole (free), and the same video file.

The menu is in Russian on a Russian Windows and in English otherwise (`lang=ru|en` in `script-opts/watch_together.conf` forces it). The steps below use the Russian labels.

## Install (each person)

1. Unpack the folder and double-click `install.bat`. It copies `watch-together` to `%APPDATA%\mpv\scripts\`.
2. Restart mpv.

Portable mpv with a `portable_config` folder next to `mpv.exe` ignores `%APPDATA%\mpv`. In that case, copy `watch-together` into `portable_config\scripts\` by hand.

## Watch

1. Both open the same file in mpv.
2. Host: right-click, then **Совместный просмотр → Создать комнату (порт 47800)**.
3. Host in Porthole: create a lobby, share TCP port 47800, and send the lobby code to the friend.
4. Friend in Porthole: join the lobby and click Разрешить on port 47800. Without it Porthole never opens the port on the friend's PC and the plugin stays at "подключаемся…" (verified on a real link: `Get-NetTCPConnection -LocalPort 47800` was empty until the friend allowed it).
5. Friend: right-click, then **Совместный просмотр → Подключиться к другу (Porthole)**.
6. "Друг подключился" appears on screen. From then on, pause, seek and speed are mirrored.

Episodes: load the same episodes in the same order on both PCs (drag the whole batch into mpv). On connect, the friend jumps to the host's episode. A manual episode change on either side switches the other, matching by file name first and by playlist position if names differ. The menu shows both current files ("У тебя" / "У друга").

Without Porthole (LAN, Tailscale, port forwarding): set `bind=0.0.0.0` in `script-opts/watch_together.conf` on the host. The friend copies `IP:47800` and uses **Подключиться к адресу из буфера обмена**.
