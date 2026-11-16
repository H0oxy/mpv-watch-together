# Installs mpv for the current user (no admin) when it is missing. Called by install.bat.
# Prints "found <path>", "installed <path>" or "error <text>". The build is shinchiro's latest release;
# its SHA256 comes from the GitHub API and is checked before anything is unpacked.
param([switch]$CheckOnly)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$dir = Join-Path $env:LOCALAPPDATA 'Programs\mpv'
try {
    # PATH, our own folder, or the "App Paths" entry the official installer writes.
    $cmd = Get-Command mpv.exe -ErrorAction SilentlyContinue
    $reg = foreach ($h in 'HKLM:', 'HKCU:') {
        $v = (Get-ItemProperty "$h\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\mpv.exe" -ErrorAction SilentlyContinue).'(default)'
        if ($v -and (Test-Path $v)) { $v }
    }
    $have = if ($cmd) { $cmd.Source } elseif (Test-Path (Join-Path $dir 'mpv.exe')) { Join-Path $dir 'mpv.exe' } else { $reg | Select-Object -First 1 }
    if ($have) { "found $have"; return }
    if ($CheckOnly) { 'missing'; return }

    $rel = Invoke-RestMethod -UseBasicParsing 'https://api.github.com/repos/shinchiro/mpv-winbuild-cmake/releases/latest'
    $asset = $rel.assets | Where-Object { $_.name -match '^mpv-x86_64-\d+-git-[0-9a-f]+\.7z$' } | Select-Object -First 1
    if (-not $asset) { throw 'no mpv build in the latest release' }
    $tmp = Join-Path $env:TEMP ('mpv-install-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $tmp | Out-Null
    try {
        $arc = Join-Path $tmp $asset.name
        Invoke-WebRequest -UseBasicParsing $asset.browser_download_url -OutFile $arc
        $want = ([string]$asset.digest) -replace '^sha256:', ''
        if ($want -and (Get-FileHash $arc -Algorithm SHA256).Hash -ne $want) { throw 'download is damaged (SHA256 differs)' }
        # tar.exe (bsdtar) ships with Windows 10 1803+ and reads 7z.
        # Unpacked aside and moved in only when whole, so a half-unpacked folder is never taken for an install.
        $x = Join-Path $tmp 'x'
        New-Item -ItemType Directory $x | Out-Null
        & "$env:SystemRoot\System32\tar.exe" -xf $arc -C $x
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $x 'mpv.exe'))) { throw 'could not unpack the archive' }
        New-Item -ItemType Directory -Force (Split-Path $dir) | Out-Null
        if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
        Move-Item $x $dir
    } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }

    $exe = Join-Path $dir 'mpv.exe'
    & $exe --register 2>$null | Out-Null   # "Open with" entries for the current user; not fatal
    $lnk = Join-Path ([Environment]::GetFolderPath('Programs')) 'mpv.lnk'
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
    $s.TargetPath = $exe; $s.WorkingDirectory = $dir; $s.Save()
    "installed $exe"
} catch { "error $($_.Exception.Message)" }
