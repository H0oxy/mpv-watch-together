# End-to-end check: three mpv instances on this PC, one host (A) and two guests (B, C) over loopback.
# Usage: powershell -ExecutionPolicy Bypass -File tests\e2e.ps1 [-Mpv C:\path\mpv.exe]
param([string]$Mpv = 'mpv', [int]$Port = 47899)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$script = Join-Path $root 'watch-together'
# Two "episodes" with different durations, so a wrong episode can't pass as the right one.
$ep1 = Join-Path $env:TEMP 'watch-together-ep1.mkv'
$ep2 = Join-Path $env:TEMP 'watch-together-ep2.mkv'
foreach ($e in @(@($ep1, 600), @($ep2, 400))) {
    if (-not (Test-Path $e[0])) {
        & ffmpeg -loglevel error -f lavfi -i "testsrc=size=320x240:rate=25:duration=$($e[1])" -f lavfi -i "sine=duration=$($e[1])" `
            -c:v libx264 -preset ultrafast -g 25 -c:a aac -shortest $e[0]
    }
}
$name1 = Split-Path $ep1 -Leaf
$name2 = Split-Path $ep2 -Leaf

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

function Invoke-Mpv($ipc, [object[]]$cmd) {
    $ipc.id++
    $ipc.w.WriteLine((ConvertTo-Json -Compress -InputObject @{ command = $cmd; request_id = $ipc.id }))
    while ($true) {
        $m = ConvertFrom-Json $ipc.r.ReadLine()
        if ($m.request_id -eq $ipc.id) { return $m.data }
    }
}
function Get-Prop($ipc, $name) { Invoke-Mpv $ipc @('get_property', $name) }
function Status($ipc) { Get-Prop $ipc 'user-data/watch-together/status' }
function Wait-Until([scriptblock]$cond, [double]$seconds = 5) {
    $end = [DateTime]::Now.AddSeconds($seconds)
    while ([DateTime]::Now -lt $end) { if (& $cond) { return $true }; Start-Sleep -Milliseconds 100 }
    & $cond
}
# Spread of positions across all players. Reads are sequential, so playing positions are moved back
# to the moment of the first read; otherwise the read time itself would show up as drift.
function Get-Spread($list) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = foreach ($x in $list) {
        $pos = Get-Prop $x 'time-pos'
        if (-not (Get-Prop $x 'pause')) { $pos -= $sw.Elapsed.TotalSeconds * (Get-Prop $x 'speed') }
        $pos
    }
    ($p | Measure-Object -Maximum).Maximum - ($p | Measure-Object -Minimum).Minimum
}
# A guest may be catching up a small drift, up to 5 % off the room speed.
function Near-Speed($ipc, [double]$room) { [math]::Abs((Get-Prop $ipc 'speed') / $room - 1) -le 0.051 }
function All-Same($list, $prop) { @($list | ForEach-Object { [string](Get-Prop $_ $prop) } | Select-Object -Unique).Count -eq 1 }

function Start-Player([string]$n, [string]$who) {
    Start-Process $Mpv -PassThru -WindowStyle Hidden -ArgumentList @(
        '--no-config', '--vo=null', '--ao=null', "--script=$script",
        "--script-opts=watch_together-port=$Port,watch_together-auto_update=no,watch_together-lang=en,watch_together-name=$who",
        "--input-ipc-server=wt-test-$n", "`"$ep1`"", "`"$ep2`"")
}

# B and C share a name on purpose: the host must keep them apart.
$procs = @((Start-Player 'a' 'Host'), (Start-Player 'b' 'Guest'), (Start-Player 'c' 'Guest'))
try {
    $a = Open-Ipc 'wt-test-a'; $b = Open-Ipc 'wt-test-b'; $c = Open-Ipc 'wt-test-c'
    $all = @($a, $b, $c)
    [void](Wait-Until { -not ($all | Where-Object { -not ((Get-Prop $_ 'time-pos') -gt 0) }) })

    # Guests start on another episode and position.
    foreach ($g in $b, $c) { Invoke-Mpv $g @('playlist-next') | Out-Null }
    [void](Wait-Until { (Get-Prop $b 'filename') -eq $name2 -and (Get-Prop $c 'filename') -eq $name2 -and (Get-Prop $c 'time-pos') -gt 0 })
    Invoke-Mpv $b @('seek', 100, 'absolute') | Out-Null
    Invoke-Mpv $c @('seek', 200, 'absolute') | Out-Null

    Invoke-Mpv $a @('script-message', 'watch-together-host') | Out-Null
    Start-Sleep -Milliseconds 500
    foreach ($g in $b, $c) { Invoke-Mpv $g @('script-message', 'watch-together-join') | Out-Null }
    $ok = Wait-Until { (Status $a) -eq 'hosting' -and (Status $b) -eq 'connected' -and (Status $c) -eq 'connected' -and (Get-Prop $a 'user-data/watch-together/room').members.Count -eq 3 } 15
    Check 'host + 2 guests connect' $ok "a=$(Status $a) b=$(Status $b) c=$(Status $c)"

    $ok = Wait-Until { (All-Same $all 'filename') -and (Get-Prop $b 'filename') -eq $name1 -and (Get-Spread $all) -lt 0.3 } 8
    Check 'guests follow host episode and position' $ok ("spread={0:N3}s" -f (Get-Spread $all))

    $names = @((Get-Prop $a 'user-data/watch-together/room').members | ForEach-Object { $_.name })
    Check 'same-named guests kept apart' ((@($names | Select-Object -Unique)).Count -eq 3) ($names -join ', ')
    $ok = Wait-Until { (Get-Prop $b 'user-data/watch-together/room').members.Count -eq 3 } 3
    Check 'guests see the member list' $ok ''

    Invoke-Mpv $a @('set_property', 'pause', $true) | Out-Null
    $ok = Wait-Until { (Get-Prop $b 'pause') -eq $true -and (Get-Prop $c 'pause') -eq $true } 3
    Check 'host pause -> guests' $ok ''

    Invoke-Mpv $a @('seek', 300, 'absolute') | Out-Null
    $ok = Wait-Until { [math]::Abs((Get-Prop $b 'time-pos') - 300) -lt 0.3 -and [math]::Abs((Get-Prop $c 'time-pos') - 300) -lt 0.3 } 3
    Check 'host seek (paused) -> guests' $ok ''

    Invoke-Mpv $b @('set_property', 'pause', $false) | Out-Null
    $ok = Wait-Until { (Get-Prop $a 'pause') -eq $false -and (Get-Prop $c 'pause') -eq $false } 3
    Check 'guest B play -> host and guest C' $ok ''

    Invoke-Mpv $c @('seek', 450, 'absolute') | Out-Null
    $ok = Wait-Until { (Get-Prop $a 'time-pos') -gt 449 -and (Get-Spread $all) -lt 0.3 } 4
    Check 'guest C seek (playing) -> everyone' $ok ("spread={0:N3}s" -f (Get-Spread $all))

    Invoke-Mpv $b @('set_property', 'speed', 1.5) | Out-Null
    $ok = Wait-Until { (Get-Prop $a 'speed') -eq 1.5 -and (Near-Speed $c 1.5) } 3
    Check 'guest speed -> everyone' $ok ''
    Invoke-Mpv $a @('set_property', 'speed', 1) | Out-Null
    $ok = Wait-Until { (Near-Speed $b 1) -and (Near-Speed $c 1) } 3
    Check 'host speed -> everyone' $ok ''

    # Guests seek at random moments against the host's 1 s ticks: a tick in flight must not undo them.
    $rand = New-Object Random 23
    $lost = foreach ($k in 1..6) {
        Start-Sleep -Milliseconds ($rand.Next(0, 1000))
        $g = if ($k % 2) { $b } else { $c }
        $target = 60 + 40 * $k
        Invoke-Mpv $g @('seek', $target, 'absolute') | Out-Null
        Start-Sleep 2.5
        $pa = Get-Prop $a 'time-pos'; $spread = Get-Spread $all
        if ($spread -ge 0.3 -or $pa -lt $target -or $pa -gt $target + 3) { "$target->a=$pa,spread=$spread" }
    }
    Check 'guest seeks vs ticks (6 random)' (-not $lost) ($lost -join ' ')

    # Two guests seek to different places at the same moment: the room must settle on one of them.
    Invoke-Mpv $b @('seek', 100, 'absolute') | Out-Null
    Invoke-Mpv $c @('seek', 200, 'absolute') | Out-Null
    Start-Sleep 3
    $pa = Get-Prop $a 'time-pos'
    $ok = (Get-Spread $all) -lt 0.3 -and (($pa -gt 100 -and $pa -lt 104) -or ($pa -gt 200 -and $pa -lt 204))
    Check 'conflicting guest seeks settle on one position' $ok ("a={0:N2} spread={1:N3}s" -f $pa, (Get-Spread $all))

    $drifts = foreach ($i in 1..10) { Start-Sleep -Milliseconds 500; Get-Spread $all }
    $max = ($drifts | Measure-Object -Maximum).Maximum
    Check 'spread while playing 5s' ($max -lt 0.3) ("max={0:N3}s" -f $max)

    # A fake tick tells B the host is 0.3 s ahead: B must catch up by speed, not seek, and settle back.
    $tick = ConvertTo-Json -Compress @{ t = 'state'; ev = 'tick'; pos = (Get-Prop $a 'time-pos') + 0.3; paused = $false; speed = 1;
                                        dur = (Get-Prop $b 'duration'); file = (Get-Prop $b 'filename') }
    Invoke-Mpv $b @('script-message-to', 'watch_together', 'watch-together-net', 'in', 'host', $tick) | Out-Null
    $nudged = Wait-Until { (Get-Prop $b 'speed') -gt 1.01 } 1.5
    $spreads = foreach ($i in 1..8) { Start-Sleep -Milliseconds 500; Get-Spread $all }
    $max = ($spreads | Measure-Object -Maximum).Maximum
    $settled = Wait-Until { (Get-Prop $b 'speed') -eq 1 -and (Get-Spread $all) -lt 0.1 } 10
    $ok = $nudged -and $max -lt 0.2 -and $settled -and (Get-Prop $a 'speed') -eq 1 -and (Get-Prop $c 'speed') -eq 1
    Check 'small drift caught up by speed, no seek' $ok ("nudged={0} max={1:N3}s settled={2} spread={3:N3}s" -f $nudged, $max, $settled, (Get-Spread $all))

    # The user presses "]" (x1.1) on B while it is nudged: the room gets 1.1, not 1.1 times the nudge.
    Invoke-Mpv $b @('script-message-to', 'watch_together', 'watch-together-net', 'in', 'host', ($tick -replace '"pos":[\d.]+', ('"pos":' + ((Get-Prop $a 'time-pos') + 0.3)))) | Out-Null
    $nudged = Wait-Until { (Get-Prop $b 'speed') -gt 1.01 } 1.5
    Invoke-Mpv $b @('multiply', 'speed', 1.1) | Out-Null
    $ok = $nudged -and (Wait-Until { [math]::Abs((Get-Prop $a 'speed') - 1.1) -lt 0.001 } 3)
    Check 'user speed change during a nudge reaches the room exactly' $ok ("nudged={0} a={1}" -f $nudged, (Get-Prop $a 'speed'))
    Invoke-Mpv $a @('set_property', 'speed', 1) | Out-Null
    [void](Wait-Until { (Near-Speed $b 1) -and (Near-Speed $c 1) } 3)

    Invoke-Mpv $b @('playlist-next') | Out-Null
    $ok = Wait-Until { (Get-Prop $a 'filename') -eq $name2 -and (Get-Prop $c 'filename') -eq $name2 } 5
    Check 'guest next episode -> everyone' $ok ("a={0} c={1}" -f (Get-Prop $a 'filename'), (Get-Prop $c 'filename'))
    Invoke-Mpv $a @('playlist-prev') | Out-Null
    $ok = Wait-Until { (Get-Prop $b 'filename') -eq $name1 -and (Get-Prop $c 'filename') -eq $name1 -and (Get-Spread $all) -lt 0.3 } 6
    Check 'host previous episode -> everyone, in sync' $ok ("spread={0:N3}s" -f (Get-Spread $all))

    # Only the host controls: guest actions are reverted, the host is not affected.
    Invoke-Mpv $a @('script-message', 'watch-together-control', 'host') | Out-Null
    $ok = Wait-Until { (Get-Prop $b 'user-data/watch-together/room').control -eq 'host' } 3
    Check 'control "only host" reaches guests' $ok ''
    Invoke-Mpv $b @('set_property', 'pause', $true) | Out-Null
    Start-Sleep 1.5
    Check 'only host: guest pause reverted' (-not (Get-Prop $a 'pause') -and -not (Get-Prop $b 'pause') -and -not (Get-Prop $c 'pause')) ''
    $pa = Get-Prop $a 'time-pos'
    Invoke-Mpv $c @('seek', 30, 'absolute') | Out-Null
    Start-Sleep 1.5
    Check 'only host: guest seek reverted' ((Get-Prop $a 'time-pos') -gt $pa -and (Get-Spread $all) -lt 0.3) ("spread={0:N3}s" -f (Get-Spread $all))
    Invoke-Mpv $b @('playlist-next') | Out-Null
    $ok = Wait-Until { (Get-Prop $b 'filename') -eq $name1 -and (Get-Prop $a 'filename') -eq $name1 -and (Get-Spread $all) -lt 0.3 } 6
    Check 'only host: guest episode change reverted' $ok ("b={0}" -f (Get-Prop $b 'filename'))
    Invoke-Mpv $a @('set_property', 'pause', $true) | Out-Null
    $ok = Wait-Until { (Get-Prop $b 'pause') -eq $true -and (Get-Prop $c 'pause') -eq $true } 3
    Invoke-Mpv $a @('set_property', 'pause', $false) | Out-Null
    $ok = $ok -and (Wait-Until { (Get-Prop $b 'pause') -eq $false } 3)
    Check 'only host: host still controls' $ok ''
    Invoke-Mpv $a @('script-message', 'watch-together-control', 'all') | Out-Null
    $ok = Wait-Until { (Get-Prop $c 'user-data/watch-together/room').control -eq 'all' } 3
    Check 'control back to everyone' $ok ''

    # Late join from a different episode and time.
    Invoke-Mpv $c @('script-message', 'watch-together-leave') | Out-Null
    $ok = Wait-Until { (Get-Prop $a 'user-data/watch-together/room').members.Count -eq 2 } 5
    Check 'guest leaves, host sees it' $ok ''
    Invoke-Mpv $c @('playlist-next') | Out-Null
    Start-Sleep 1
    Invoke-Mpv $c @('seek', 50, 'absolute') | Out-Null
    Start-Sleep 1
    Invoke-Mpv $c @('script-message', 'watch-together-join') | Out-Null
    $ok = Wait-Until { (Get-Prop $c 'filename') -eq $name1 -and (Get-Spread $all) -lt 0.3 } 8
    Check 'late joiner catches up' $ok ("spread={0:N3}s" -f (Get-Spread $all))

    # No echo loop: with nobody touching anything, nobody should switch, pause or seek.
    $before = Get-Prop $a 'time-pos'
    Start-Sleep 3
    $ok = (Get-Prop $a 'time-pos') -gt $before + 2.5 -and -not (Get-Prop $b 'pause') -and (All-Same $all 'filename') -and (Get-Spread $all) -lt 0.3
    Check 'stable: no ping-pong' $ok ''

    # The clipboard is shared with the user, so put back whatever was there.
    $savedClip = Get-Clipboard -Raw
    try {
        Invoke-Mpv $a @('script-message', 'watch-together-invite') | Out-Null
        $ok = Wait-Until { (Get-Clipboard -Raw) -eq "127.0.0.1:$Port" } 3
        Check 'host copies invite address' $ok ("clipboard={0}" -f (Get-Clipboard -Raw))
    } finally {
        if ($savedClip) { Set-Clipboard -Value $savedClip }
    }

    Invoke-Mpv $b @('script-message', 'watch-together-leave') | Out-Null
    Invoke-Mpv $c @('script-message', 'watch-together-leave') | Out-Null
    $ok = Wait-Until { (Status $a) -eq 'listening' } 5
    Check 'all guests leave -> host waits' $ok ''
} finally {
    $procs | ForEach-Object { if (-not $_.HasExited) { $_.Kill() } }
}
if ($failures) { Write-Host "$failures check(s) failed"; exit 1 }
Write-Host 'All checks passed'
