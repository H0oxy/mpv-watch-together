# Torrent mode without a network: tests\fake_torrserver.py stands in for TorrServer and serves the e2e test
# videos as a two-episode torrent. A is the host, B a guest without the episodes, C a guest with its own copy
# of episode 1, D a guest of a raw host that sends bad torrent messages.
# Usage: powershell -ExecutionPolicy Bypass -File tests\torrent.ps1 -Mpv C:\path\mpv.exe [-Python python]
# Needs the test videos that e2e.ps1 creates in %TEMP%.
param([string]$Mpv = 'mpv', [string]$Python = 'python', [int]$Port = 47870, [int]$SharePort = 47871,
      [int]$EnginePort = 47872, [int]$RawPort = 47873)
$ErrorActionPreference = 'Stop'
$script = Join-Path (Split-Path $PSScriptRoot) 'watch-together'
$ep1 = Join-Path $env:TEMP 'watch-together-ep1.mkv'; $ep2 = Join-Path $env:TEMP 'watch-together-ep2.mkv'
$run = Join-Path $env:TEMP ('wt-torrent-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$cDir = Join-Path $run 'c-episodes'
New-Item -ItemType Directory -Force $run, $cDir | Out-Null
Copy-Item $ep1 (Join-Path $cDir 'S01E01.mkv')   # C's own copy of the torrent's first episode
$cover = Join-Path $run 'cover.jpg'; [IO.File]::WriteAllBytes($cover, (New-Object byte[] 1000))
$utf8 = New-Object System.Text.UTF8Encoding($false)
# The panel's marks; this file stays ASCII (PowerShell 5.1 reads BOM-less scripts as ANSI).
$yes = [string][char]0x2713; $no = [string][char]0x2717; $dash = [string][char]0x2014

$h1 = '1111111111111111111111111111111111111111'   # a magnet
$h2 = '2222222222222222222222222222222222222222'   # a .torrent file
$tfile = Join-Path $run 'show two.torrent'; [IO.File]::WriteAllText($tfile, $h2)
$speedFile = Join-Path $run 'speed.txt'; [IO.File]::WriteAllText($speedFile, '50000000')
$cfg = @{ torrents = @{ $h1 = @(@('Show/S01E01.mkv', $ep1), @('Show/S01E02.mkv', $ep2), @('Show/cover.jpg', $cover));
                        $h2 = @(@('Two/T01.mkv', $ep2), @('Two/T02.mkv', $ep1)) };
          speed_file = $speedFile }
$cfgFile = Join-Path $run 'fake.json'; [IO.File]::WriteAllText($cfgFile, (ConvertTo-Json -Depth 6 $cfg))
$magnet = "magnet:?xt=urn:btih:$h1&dn=Show&tr=udp%3A%2F%2Ftracker.example%3A80"

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
function P($ipc, [string]$prop) { I $ipc @('get_property', $prop) }
function Wait-Until([scriptblock]$cond, [double]$s = 5) {
    $e = [DateTime]::Now.AddSeconds($s)
    while ([DateTime]::Now -lt $e) { if (& $cond) { return $true }; Start-Sleep -Milliseconds 200 }
    & $cond
}
function Start-Player([string]$n, [string[]]$files, [int]$port = $Port) {
    $dir = Join-Path $run "cfg-$n"
    New-Item -ItemType Directory -Force $dir | Out-Null
    $opts = "watch_together-port=$port,watch_together-share_port=$SharePort,watch_together-auto_update=no," +
            "watch_together-lang=en,watch_together-name=$n,watch_together-torrent_check=4," +
            "watch_together-torrent_url=http://127.0.0.1:$EnginePort"
    Start-Process $Mpv -PassThru -WindowStyle Hidden -ArgumentList (@("--config-dir=`"$dir`"", '--vo=null', '--ao=null', '--idle=yes',
        "--script=$script", "--script-opts=$opts", "--input-ipc-server=wt-tor-$n") + ($files | ForEach-Object { "`"$_`"" }))
}
function Title($ipc) { [string](P $ipc 'media-title') }
function Engine-Count($ipc) { @((P $ipc 'playlist') | Where-Object { $_.filename -like "http://127.0.0.1:$EnginePort/stream/*" }).Count }
function Panel($ipc) { @(P $ipc 'user-data/watch-together/panel') -join ' | ' }
function Added { @(Invoke-RestMethod -UseBasicParsing "http://127.0.0.1:$EnginePort/log") }
function Spread($list) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = foreach ($x in $list) {
        $pos = P $x 'time-pos'
        if (-not (P $x 'pause')) { $pos -= $sw.Elapsed.TotalSeconds }
        $pos
    }
    ($p | Measure-Object -Maximum).Maximum - ($p | Measure-Object -Minimum).Minimum
}

$fake = Start-Process $Python -PassThru -WindowStyle Hidden -ArgumentList @('-I', "`"$(Join-Path $PSScriptRoot 'fake_torrserver.py')`"", "$EnginePort", "`"$cfgFile`"")
$procs = @()
$listener = $null
try {
    [void](Wait-Until { try { [void](Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:$EnginePort/echo"); $true } catch { $false } } 10)
    $procs += Start-Player 'A' @($ep1)
    $procs += Start-Player 'B' @($ep1)
    $procs += Start-Player 'C' @((Join-Path $cDir 'S01E01.mkv'))
    $a = Open-Ipc 'wt-tor-A'; $b = Open-Ipc 'wt-tor-B'; $c = Open-Ipc 'wt-tor-C'
    [void](Wait-Until { (P $a 'time-pos') -gt 0 -and (P $b 'time-pos') -gt 0 -and (P $c 'time-pos') -gt 0 } 10)

    # Alone: a magnet turns into the torrent's videos, the chooser picks episode 2, which opens paused.
    $null = I $a @('loadfile', $magnet, 'replace')
    $ok = Wait-Until { (Engine-Count $a) -eq 2 } 10
    Start-Sleep -Milliseconds 300  # the chooser opens right after the files are in
    $null = I $a @('script-message', 'watch-together-pick', '2')
    $ok = $ok -and (Wait-Until { (Title $a) -eq 'S01E02.mkv' -and (P $a 'duration') -gt 0 } 10)
    $pl = @((P $a 'playlist') | ForEach-Object { $_.filename })
    Check 'magnet becomes the video files, the chosen one plays' ($ok -and $pl.Count -eq 2 -and -not ($pl -like 'magnet:*')) ($pl -join ', ')
    Check 'picked episode opens paused for the swarm check' ((P $a 'pause') -eq $true) ''
    Check 'the magnet reached the engine unchanged' ((Added) -contains $magnet) ((Added) -join ', ')
    $ok = Wait-Until { (Panel $a) -match "$yes A" } 10
    Check 'alone: the check shows a fast swarm as enough' $ok (Panel $a)

    # The stream buffer: chosen in the menu, cut while free RAM runs low, back once memory is free again.
    # (torrent.ps1 also reports the real free RAM every 5 s, so the fake reports repeat until they show.)
    $null = I $a @('script-message', 'watch-together-buffer', '2048')
    $ok = Wait-Until { (P $a 'demuxer-max-bytes') -eq 1536MB -and (P $a 'demuxer-max-back-bytes') -eq 512MB } 3
    Check 'the buffer choice reaches the playing stream' $ok ("ahead={0} behind={1}" -f (P $a 'demuxer-max-bytes'), (P $a 'demuxer-max-back-bytes'))
    $ok = Wait-Until { $null = I $a @('script-message-to', 'watch_together', 'watch-together-ram', '500', '8000'); (P $a 'demuxer-max-bytes') -eq 96MB } 5
    Check 'low free RAM cuts the buffer' $ok ("ahead={0}" -f (P $a 'demuxer-max-bytes'))
    $ok = Wait-Until { $null = I $a @('script-message-to', 'watch_together', 'watch-together-ram', '30000', '32000'); (P $a 'demuxer-max-bytes') -eq 1536MB } 5
    Check 'free RAM again restores it' $ok ("ahead={0}" -f (P $a 'demuxer-max-bytes'))

    # Room: B (nothing of the torrent) and C (own episode 1) join and follow onto episode 2.
    $null = I $a @('script-message', 'watch-together-host'); Start-Sleep -Milliseconds 800
    $null = I $b @('script-message', 'watch-together-join'); $null = I $c @('script-message', 'watch-together-join')
    $ok = Wait-Until { (Title $b) -eq 'S01E02.mkv' -and (Title $c) -eq 'S01E02.mkv' } 15
    Check 'guests follow the host onto a torrent episode' $ok ("b={0} c={1}" -f (Title $b), (Title $c))
    Check 'guests add the magnet with its trackers' (@((Added) | Where-Object { $_ -eq $magnet }).Count -ge 3) ((Added) -join ', ')
    $cl = @((P $c 'playlist') | ForEach-Object { $_.filename })
    Check "C keeps its own episode 1 and streams only episode 2" ((Engine-Count $c) -eq 1 -and ($cl -like '*S01E01.mkv').Count -eq 1) ($cl -join ', ')

    # The swarm check: everyone measures; a slow swarm is flagged; play ends the check for all.
    $null = I $a @('script-message', 'watch-together-check')
    $ok = Wait-Until { $p = Panel $a; $p -match "$yes A" -and $p -match "$yes B" -and $p -match "$yes C" } 15
    Check 'room check: everyone fast enough' $ok (Panel $a)
    Check 'guests see the check too' ((Panel $b) -match 'Checking the swarm|Swarm check') (Panel $b)
    $blog = Get-Content -Raw -Encoding UTF8 (Join-Path $run 'cfg-B\watch_together_torrent.log') -ErrorAction SilentlyContinue
    Check "a guest's torrent log tells the story" ($blog -match 'room torrent: 1{40}' -and $blog -match 'episodes known' -and $blog -match 'check start: hash 1{40}') ''
    [IO.File]::WriteAllText($speedFile, '1000')
    $null = I $a @('script-message', 'watch-together-check')
    $ok = Wait-Until { $p = Panel $a; $p -match "$no A" -and $p -match "$no B" } 15
    Check 'room check: a slow swarm is flagged' $ok (Panel $a)
    [IO.File]::WriteAllText($speedFile, '50000000')
    $null = I $b @('set_property', 'pause', $false)   # a guest's play starts the room and ends the check
    $ok = Wait-Until { -not (P $a 'pause') -and -not (P $c 'pause') -and (Panel $a) -notmatch 'swarm' -and (Panel $b) -notmatch 'swarm' } 10
    Check 'play ends the check for everyone' $ok ("a={0} | b={1}" -f (Panel $a), (Panel $b))
    Start-Sleep 2
    $s = Spread @($a, $b, $c)
    Check 'torrent episode plays in sync' ($s -lt 0.3) ("spread={0:N3}s" -f $s)

    # Episode change: C goes to its own file, B streams.
    $null = I $a @('playlist-prev')
    $ok = Wait-Until { (Title $b) -eq 'S01E01.mkv' -and (Title $c) -eq 'S01E01.mkv' } 10
    Check 'host episode change: C plays its own copy, B the stream' ($ok -and (P $c 'path') -notlike 'http*' -and (P $b 'path') -like 'http*') ("c={0}" -f (P $c 'path'))
    Start-Sleep 1
    $null = I $b @('seek', 120, 'absolute')
    $ok = Wait-Until { [math]::Abs((P $a 'time-pos') - 120) -lt 3 -and [math]::Abs((P $c 'time-pos') - 120) -lt 3 } 10
    Start-Sleep 1.5
    Check 'guest seek on a torrent episode reaches everyone' ($ok -and (Spread @($a, $b, $c)) -lt 0.3) ''
    $null = I $a @('script-message', 'watch-together-check')   # pauses the room on episode 1
    $ok = Wait-Until { (Panel $a) -match "$yes C $dash own file" } 10
    Check 'room check: a guest with its own copy needs no swarm' $ok (Panel $a)
    $null = I $a @('set_property', 'pause', $false)

    # A .torrent file: guests get it from the host's share port and add it as a file.
    $null = I $a @('loadfile', $tfile, 'replace')
    [void](Wait-Until { (Engine-Count $a) -eq 2 } 10)
    Start-Sleep -Milliseconds 300
    $null = I $a @('script-message', 'watch-together-pick', '1')
    $ok = Wait-Until { (Title $b) -eq 'T01.mkv' -and (Title $c) -eq 'T01.mkv' } 20
    $fileAdds = @((Added) | Where-Object { $_ -like "file:///*/watch-together/$h2-*.torrent" })
    Check 'a .torrent reaches the guests through the share port' ($ok -and $fileAdds.Count -ge 2) ((Added) -join ', ')
    Check "the room's old torrent leaves the guests' playlists" (-not (@((P $b 'playlist') | Where-Object { $_.filename -like "*$h1*" }))) ''
    $null = I $a @('set_property', 'pause', $false)

    # Resume memory per torrent: back to the magnet, from the clipboard this time; the chooser preselects the
    # episode watched last. The user's clipboard is put back afterwards.
    $saved = P $a 'clipboard/text'
    $null = I $a @('set_property', 'clipboard/text', $magnet)
    $null = I $a @('script-message', 'watch-together-open-torrent')
    Start-Sleep 1.5   # the file list, then the chooser
    $null = I $a @('script-message', 'watch-together-pick')   # the preselected one
    $ok = Wait-Until { (Title $a) -eq 'S01E01.mkv' -and (P $a 'time-pos') -gt 100 -and (Engine-Count $a) -eq 2 } 10
    if ($null -ne $saved) { $null = I $a @('set_property', 'clipboard/text', $saved) }
    $pl = @((P $a 'playlist') | ForEach-Object { $_.filename })
    Check 'from the clipboard, the chooser resumes the torrent where it stopped' $ok ("{0} at {1}; {2}" -f (Title $a), (P $a 'time-pos'), ($pl -join ', '))
    $null = I $a @('set_property', 'pause', $false)

    # Back to a local file: the room is no torrent room any more.
    $null = I $a @('loadfile', $ep1, 'replace')
    $ok = Wait-Until { (Engine-Count $b) -eq 0 } 10
    Check 'host back on a local file: guests drop the torrent episodes' $ok ("b streams: {0}" -f (Engine-Count $b))

    # A raw host sends bad torrent messages; nothing but a clean magnet may reach D's engine.
    $listener = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $RawPort)
    $listener.Start()
    $procs += Start-Player 'D' @($ep1) $RawPort
    $d = Open-Ipc 'wt-tor-D'
    [void](Wait-Until { (P $d 'time-pos') -gt 0 } 10)
    $null = I $d @('script-message', 'watch-together-join')
    $peer = $listener.AcceptTcpClient(); $ps = $peer.GetStream()
    function Send-Raw($obj) { $x = $utf8.GetBytes((ConvertTo-Json -Compress -Depth 5 $obj) + "`n"); $ps.Write($x, 0, $x.Length) }
    $before = (Added).Count
    Send-Raw @{ t = 'welcome'; you = 'D' }
    Send-Raw @{ t = 'torrent'; hash = 'zz' + $h1.Substring(2) }
    Send-Raw @{ t = 'torrent'; hash = '../' + $h1.Substring(3) }
    Start-Sleep 1.5
    Check 'bad hashes never reach the engine' ((Added).Count -eq $before) ((Added) | Select-Object -Skip $before)
    Send-Raw @{ t = 'torrent'; hash = $h1.ToUpper(); magnet = "magnet:?xt=urn:btih:$h1`nquit" }
    $ok = Wait-Until { (Engine-Count $d) -eq 2 } 10
    $new = @((Added) | Select-Object -Skip $before)
    Check 'a magnet with a line break is replaced by a plain one' ($ok -and $new.Count -eq 1 -and $new[0] -eq "magnet:?xt=urn:btih:$h1") ($new -join ', ')
    $peer.Close()
} finally {
    foreach ($p in $procs) { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
    if ($listener) { $listener.Stop() }
    if (-not $fake.HasExited) { Stop-Process -Id $fake.Id -Force -ErrorAction SilentlyContinue }
    Get-CimInstance Win32_Process -Filter "Name='mpv.exe'" | Where-Object { $_.CommandLine -match 'wt-tor-' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Remove-Item -Recurse -Force $run -ErrorAction SilentlyContinue
}
if ($failures) { Write-Host "$failures check(s) failed"; exit 1 }
Write-Host 'all checks passed'
