# Settings, watching from the host, episode download, next-episode countdown and resume memory, with a
# host (A) and a guest (B). B has only episode 1, watches episode 2 from A, then downloads it. Each player gets its own config folder in
# %TEMP%, so settings and history are really written, but never into the user's mpv folder.
# Usage: powershell -ExecutionPolicy Bypass -File tests\features.ps1 -Mpv C:\path\mpv.exe
# Needs the test videos that e2e.ps1 creates in %TEMP%.
param([string]$Mpv = 'mpv', [int]$Port = 47884, [int]$SharePort = 47885)
$ErrorActionPreference = 'Stop'
$script = Join-Path (Split-Path $PSScriptRoot) 'watch-together'
$ep1 = Join-Path $env:TEMP 'watch-together-ep1.mkv'; $ep2 = Join-Path $env:TEMP 'watch-together-ep2.mkv'
$run = Join-Path $env:TEMP ('wt-features-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$cfgA = Join-Path $run 'cfg-a'; $cfgB = Join-Path $run 'cfg-b'; $bDir = Join-Path $run 'b-episodes'
New-Item -ItemType Directory -Force $cfgA, $cfgB, $bDir | Out-Null
Copy-Item $ep1 $bDir
$utf8 = New-Object System.Text.UTF8Encoding($false)
$failures = 0
function Check([string]$name, [bool]$ok, [string]$detail) {
    $mark = if ($ok) { 'PASS' } else { 'FAIL'; $script:failures++ }
    Write-Host ("[{0}] {1} {2}" -f $mark, $name, $detail)
}
function Open-Ipc([string]$pipe) {
    $s = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipe, [System.IO.Pipes.PipeDirection]::InOut)
    for ($i = 0; $i -lt 50; $i++) { try { $s.Connect(200); break } catch { } }
    $w = New-Object System.IO.StreamWriter($s, $utf8); $w.AutoFlush = $true
    @{ r = (New-Object System.IO.StreamReader($s, $utf8)); w = $w; id = 0 }
}
function I($ipc, [object[]]$cmd) {
    $ipc.id++
    $ipc.w.WriteLine((ConvertTo-Json -Compress -InputObject @{ command = $cmd; request_id = $ipc.id }))
    while ($true) { $m = ConvertFrom-Json $ipc.r.ReadLine(); if ($m.request_id -eq $ipc.id) { return $m.data } }
}
function Wait-Until([scriptblock]$cond, [double]$s = 5) {
    $e = [DateTime]::Now.AddSeconds($s)
    while ([DateTime]::Now -lt $e) { if (& $cond) { return $true }; Start-Sleep -Milliseconds 200 }
    & $cond
}
function Start-Player([string]$n, [string]$cfg, [string[]]$files) {
    $opts = "watch_together-port=$Port,watch_together-share_port=$SharePort,watch_together-auto_update=no," +
            "watch_together-lang=en,watch_together-countdown=3,watch_together-name=$n"
    Start-Process $Mpv -PassThru -WindowStyle Hidden -ArgumentList (@("--config-dir=`"$cfg`"", '--vo=null', '--ao=null',
        "--script=$script", "--script-opts=$opts", "--input-ipc-server=wt-feat-$n") + ($files | ForEach-Object { "`"$_`"" }))
}
# A raw request to the host's share port: what does it answer for this name?
function Ask-Share([string]$name) {
    $c = New-Object System.Net.Sockets.TcpClient('127.0.0.1', $SharePort)
    try {
        $s = $c.GetStream()
        $req = $utf8.GetBytes((ConvertTo-Json -Compress @{ file = $name; offset = 0; who = 'test' }) + "`n")
        $s.Write($req, 0, $req.Length)
        $s.ReadTimeout = 5000
        $buf = New-Object System.Collections.Generic.List[byte]
        while (($b = $s.ReadByte()) -ge 0 -and $b -ne 10) { $buf.Add([byte]$b) }
        $utf8.GetString($buf.ToArray())
    } finally { $c.Close() }
}

$procs = @((Start-Player 'A' $cfgA @($ep1, $ep2)), (Start-Player 'B' $cfgB @((Join-Path $bDir 'watch-together-ep1.mkv'))))
try {
    $a = Open-Ipc 'wt-feat-A'; $b = Open-Ipc 'wt-feat-B'
    [void](Wait-Until { (I $a @('get_property', 'time-pos')) -gt 0 -and (I $b @('get_property', 'time-pos')) -gt 0 } 10)

    # Settings: toggled twice, saved to the player's own config folder.
    $null = I $a @('script-message', 'watch-together-setting', 'countdown')
    Start-Sleep -Milliseconds 300
    $off = Get-Content -Raw (Join-Path $cfgA 'watch_together_settings.json') | ConvertFrom-Json
    $null = I $a @('script-message', 'watch-together-setting', 'countdown')
    Start-Sleep -Milliseconds 300
    $on = Get-Content -Raw (Join-Path $cfgA 'watch_together_settings.json') | ConvertFrom-Json
    Check 'settings saved on toggle' ((-not $off.countdown) -and $on.countdown) ("off={0} on={1}" -f $off.countdown, $on.countdown)
    # Download folder choice: saved, and back to the default (no download goes to the real Downloads here).
    $null = I $b @('script-message', 'watch-together-download-to', 'downloads')
    Start-Sleep -Milliseconds 300
    $dl = (Get-Content -Raw (Join-Path $cfgB 'watch_together_settings.json') | ConvertFrom-Json).download_to
    $null = I $b @('script-message', 'watch-together-download-to', 'video')
    Start-Sleep -Milliseconds 300
    $back = (Get-Content -Raw (Join-Path $cfgB 'watch_together_settings.json') | ConvertFrom-Json).download_to
    Check 'download folder choice saved' ($dl -eq 'downloads' -and $back -eq 'video') ("{0} -> {1}" -f $dl, $back)

    $null = I $a @('script-message', 'watch-together-host'); Start-Sleep -Milliseconds 800
    $null = I $b @('script-message', 'watch-together-join')
    $ok = Wait-Until { (I $b @('get_property', 'user-data/watch-together/status')) -eq 'connected' } 10
    Check 'connect' $ok ''

    # The share port serves playlist files only.
    $denied = @('..\..\Windows\win.ini', 'watch-together-rate.txt', 'C:\Windows\win.ini') | ForEach-Object { Ask-Share $_ }
    Check 'files outside the playlist are refused' (-not ($denied | Where-Object { $_ -notmatch 'not shared' })) ($denied -join ' | ')

    # Watching from the host: B lacks episode 2 and plays it from A through stream.ps1.
    $null = I $b @('script-message', 'watch-together-stream-toggle')
    $ok = Wait-Until { (I $b @('get_property', 'playlist-count')) -eq 2 } 10
    $url = I $b @('get_property', 'playlist/1/filename')
    Check 'host episodes added as streams' ($ok -and $url -like 'http://127.0.0.1:*/watch-together-ep2.mkv') "$url"
    $null = I $a @('playlist-next')
    $ok = Wait-Until { (I $b @('get_property', 'filename')) -eq 'watch-together-ep2.mkv' -and (I $b @('get_property', 'path')) -like 'http*' } 15
    Check 'guest follows the host onto a streamed episode' $ok ''
    $cache = '{0}/{1}' -f ((I $b @('get_property', 'demuxer-max-bytes')) / 1MB), ((I $b @('get_property', 'demuxer-max-back-bytes')) / 1MB)
    Check 'stream gets 384/128 MB of cache' ($cache -eq '384/128') $cache
    $null = I $a @('set_property', 'pause', $false)
    $null = I $a @('seek', 300, 'absolute')
    $ok = Wait-Until { $pa = I $a @('get_property', 'time-pos'); $pb = I $b @('get_property', 'time-pos')
                       $pa -gt 300 -and $pb -and [math]::Abs($pa - $pb) -lt 0.3 -and -not (I $b @('get_property', 'pause')) } 15
    Check 'streamed episode plays in sync after a seek' $ok ("A {0:N2} B {1:N2}" -f (I $a @('get_property', 'time-pos')), (I $b @('get_property', 'time-pos')))
    $null = I $b @('script-message', 'watch-together-stream-toggle')
    $ok = Wait-Until { (I $b @('get_property', 'playlist-count')) -eq 1 } 5
    Check 'turning it off removes the streams' $ok ''
    $null = I $a @('playlist-prev')
    [void](Wait-Until { (I $b @('get_property', 'filename')) -eq 'watch-together-ep1.mkv' } 10)
    $cache = '{0}/{1}' -f ((I $b @('get_property', 'demuxer-max-bytes')) / 1MB), ((I $b @('get_property', 'demuxer-max-back-bytes')) / 1MB)
    Check 'a local file keeps mpv''s cache size' ($cache -eq '150/50') $cache

    # Download with a partial file already there: it must continue and end byte-identical.
    $part = Join-Path $bDir 'watch-together-ep2.mkv.part'
    $head = New-Object byte[] 3000000
    $fs = [IO.File]::OpenRead($ep2); [void]$fs.Read($head, 0, $head.Length); $fs.Close()
    [IO.File]::WriteAllBytes($part, $head)
    $null = I $b @('script-message', 'watch-together-dl-all')
    $got = Join-Path $bDir 'watch-together-ep2.mkv'
    $ok = Wait-Until { Test-Path -LiteralPath $got } 30
    $same = $ok -and (Get-FileHash $got).Hash -eq (Get-FileHash $ep2).Hash
    Check 'guest downloads the missing episode, .part continued, identical' $same ''
    $ok = Wait-Until { (I $b @('get_property', 'playlist-count')) -eq 2 } 5
    Check 'downloaded episode added to the playlist' $ok ''
    Check 'no .part left' (-not (Test-Path -LiteralPath $part)) ''

    # Countdown: episode 1 ends by itself, episode 2 starts paused for everyone, then plays.
    $null = I $a @('seek', 596, 'absolute')
    $ok = Wait-Until { (I $a @('get_property', 'filename')) -eq 'watch-together-ep2.mkv' -and (I $b @('get_property', 'filename')) -eq 'watch-together-ep2.mkv' } 15
    $paused = (I $a @('get_property', 'pause')) -and (I $b @('get_property', 'pause'))
    Check 'next episode starts paused for everyone' ($ok -and $paused) ("A {0} {1} B {2} {3}" -f (I $a @('get_property', 'filename')),
        (I $a @('get_property', 'pause')), (I $b @('get_property', 'filename')), (I $b @('get_property', 'pause')))
    $ok = Wait-Until { -not (I $a @('get_property', 'pause')) -and -not (I $b @('get_property', 'pause')) } 6
    Check 'countdown ends, everyone plays' $ok ''

    # Countdown stopped by the guest pressing play, then started by the next play.
    $null = I $a @('playlist-prev')
    [void](Wait-Until { (I $b @('get_property', 'filename')) -eq 'watch-together-ep1.mkv' } 8)
    Start-Sleep 1
    $null = I $a @('seek', 596, 'absolute')
    [void](Wait-Until { (I $a @('get_property', 'filename')) -eq 'watch-together-ep2.mkv' -and (I $b @('get_property', 'pause')) } 15)
    $null = I $b @('set_property', 'pause', $false)
    Start-Sleep 5
    Check 'guest play during the countdown stops it' ((I $a @('get_property', 'pause')) -and (I $b @('get_property', 'pause'))) ''
    $null = I $b @('set_property', 'pause', $false)
    $ok = Wait-Until { -not (I $a @('get_property', 'pause')) } 4
    Check 'next play starts the episode' $ok ''

    # Resume memory: leave on episode 2, go elsewhere, host again and accept the offer.
    $null = I $a @('seek', 120, 'absolute')
    Start-Sleep 1
    $null = I $a @('script-message', 'watch-together-leave')
    Start-Sleep -Milliseconds 500
    $hist = Get-Content -Raw (Join-Path $cfgA 'watch_together_history.json') | ConvertFrom-Json
    $entry = $hist.PSObject.Properties | Select-Object -First 1
    Check 'history saved on leave' ($entry.Value.file -eq 'watch-together-ep2.mkv' -and [math]::Abs($entry.Value.pos - 121) -lt 3) ("{0} @ {1:N0}" -f $entry.Value.file, $entry.Value.pos)
    $null = I $a @('playlist-prev')
    [void](Wait-Until { (I $a @('get_property', 'filename')) -eq 'watch-together-ep1.mkv' } 5)
    $null = I $a @('script-message', 'watch-together-host')
    $ok = Wait-Until { (I $a @('get_property', 'user-data/mpv/console/open')) -eq $true } 5
    Check 'offer to continue appears' $ok ''
    $null = I $a @('keypress', 'ENTER')
    $ok = Wait-Until { (I $a @('get_property', 'filename')) -eq 'watch-together-ep2.mkv' -and [math]::Abs((I $a @('get_property', 'time-pos')) - 121) -lt 5 } 8
    Check 'accepting it opens episode 2 at the remembered time' $ok ("{0} @ {1:N0}" -f (I $a @('get_property', 'filename')), (I $a @('get_property', 'time-pos')))
} finally {
    $procs | ForEach-Object { if (-not $_.HasExited) { $_.Kill() } }
}
$litter = @(Get-ChildItem (Split-Path $PSScriptRoot) -Recurse -Filter 'watch_together_*.json' -ErrorAction SilentlyContinue)
Check 'nothing written into the project folder' ($litter.Count -eq 0) ($litter.FullName -join ', ')
if ($failures) { Write-Host "$failures check(s) failed"; exit 1 }
Write-Host 'All checks passed'
