# dlssnr: DLSS NR in mpv (experiment)

An mpv C plugin that runs every presented frame through NVIDIA's DLSS NR (NGX feature 18,
`nvngx_dlssnr.dll`). Separate from watch-together: it needs a C++ build and an NVIDIA RTX GPU, and it
is not shipped with releases. The NR runtime is a community-modified NVIDIA file. It is never stored
here; the plugin loads it from a folder you point it at (for example Veyra's
`runtime\experimental\nr-original`).

## Build and run

- `build.bat`: needs Visual Studio Build Tools 2022. On first run it fetches the NGX SDK headers and
  static lib (github.com/NVIDIA/DLSS) and mpv's `client.h` into `sdk\`. Output: `out\dlssnr.dll`,
  `out\nrtest.exe`.
- Install: copy `out\dlssnr.dll` and `dlssnr-menu.lua` into `%APPDATA%\mpv\scripts\` and add to
  `mpv.conf`:
  ```
  d3d11-output-format=rgba8
  script-opts-append=dlssnr-dir=<folder with nvngx_dlssnr.dll>
  script-opts-append=dlssnr-start=no
  ```
  Uninstall: delete both files and those lines. Do not also pass `--script=...dlssnr.dll`: two
  copies would hook Present twice.
- Use: right click → DLSS NR: on/off, strength (25-100 %), style (0-2). Keys: Ctrl+N on/off,
  Ctrl+Shift+N next style, in both Latin and Russian layouts. The first switch-on loads the runtime
  and freezes the picture for ~2 s. Log: `%TEMP%\dlssnr.log`.
- Script options: `dlssnr-dir`, `dlssnr-intensity` (0..1, default 1), `dlssnr-style` (0..2),
  `dlssnr-start` (yes/no).

## How it works

- mpv has no hook into its renderer, so the plugin patches `Present`/`Present1` in DXGI's shared
  swap chain vtable (through a throwaway swap chain) and processes the back buffer in place right
  before it is shown. Subtitles and the OSD go through NR too.
- The NR runtime accepts only D3D12, while mpv renders with D3D11. The plugin keeps its own D3D12
  device on the same adapter; frames move through two shared textures and one shared fence, all
  GPU-side (`nr_bridge.h`).
- `dlssnr-menu.lua` owns everything the user sees: the "DLSS NR" submenu in mpv's native context
  menu (`menu-data`, inserted after the watch-together submenu), keys and OSD text. The C plugin
  only takes `script-message dlssnr-toggle | dlssnr-style <n> | dlssnr-intensity <x>` and publishes
  `user-data/dlssnr/{enabled,style,intensity,status,info}`.
- Call contract (app id 0x0876232C, the `GetModuleFileNameW` caller-name shim, parameters, zero
  motion vectors, constant depth 0.5) is ported from Veyra-NRVideo (GPL-3.0), so this code is GPL-3.0.

## Tests

- `out\nrtest.exe <runtime dir> <in.rgba> <w> <h> <out.rgba>`: one frame through the bridge outside
  mpv, prints NR GPU time and how much changed.
- `test-mpv.ps1 -Video <clip> -RuntimeDir <dir>`: mpv with the plugin (pipe-named instance, no user
  config), screen grabs with NR on and off of the same frame, fails if they match or the log has
  errors. Needs `ffmpeg`. Do not move or resize the window while it runs.

## Measurements (RTX 5070 Ti, runtime 310.8.0 original)

NR GPU time per frame: 1280x720 3 ms, 1920x1080 4.6 ms, 2560x1440 7.6 ms, 3840x2160 17 ms.
NR runs at window size, so a 4K fullscreen window costs the most.

## Pitfalls

- D3D11 entry points of the runtime refuse to start: `NVSDK_NGX_D3D11_Init_Ext` returns 0xBAD00001
  (feature not supported). Only D3D12 works, hence the bridge.
- D3D11 cannot open a texture created by D3D12 (`OpenSharedResource1` returns E_INVALIDARG). Create
  the shared texture in D3D11 and open it in D3D12 instead.
- The back buffer must be RGBA8, so the plugin requires `--d3d11-output-format=rgba8`; other formats
  (10-bit, HDR) are refused with an OSD message.
- Every window size change recreates the NR feature (~70-100 ms hitch).
- A Lua `mp.get_property` on a `user-data` string returns it JSON-quoted (`"yes"`), so comparisons
  silently fail. Read `user-data` with `get_property_native` / observe it as `native`.
- With the Russian layout mpv reports Ctrl+N as `Ctrl+т`, so a binding on `Ctrl+n` alone never fires.
  Bind both.
