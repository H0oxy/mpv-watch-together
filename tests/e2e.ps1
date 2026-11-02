# End-to-end check: two mpv instances on this PC, one hosts, one joins over loopback.
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
function Wait-Until([scriptblock]$cond, [double]$seconds = 5) {
    $end = [DateTime]::Now.AddSeconds($seconds)
    while ([DateTime]::Now -lt $end) { if (& $cond) { return $true }; Start-Sleep -Milliseconds 100 }
    & $cond
}
# Both reads back to back; the gap between them is a few ms and is reported as part of the drift.
function Get-Drift { [math]::Abs((Get-Prop $a 'time-pos') - (Get-Prop $b 'time-pos')) }

$procs = foreach ($n in 'a', 'b') {
    Start-Process $Mpv -PassThru -WindowStyle Hidden -ArgumentList @(
        '--no-config', '--vo=null', '--ao=null', "--script=$script",
        "--script-opts=watch_together-port=$Port", "--input-ipc-server=wt-test-$n", "`"$ep1`"", "`"$ep2`"")
}
try {
    $a = Open-Ipc 'wt-test-a'
    $b = Open-Ipc 'wt-test-b'
    [void](Wait-Until { (Get-Prop $a 'time-pos') -gt 0 -and (Get-Prop $b 'time-pos') -gt 0 })

    # Friend starts on another episode, at another position.
    Invoke-Mpv $b @('playlist-next') | Out-Null
    [void](Wait-Until { (Get-Prop $b 'filename') -eq $name2 -and (Get-Prop $b 'time-pos') -gt 0 })
    Invoke-Mpv $b @('seek', 100, 'absolute') | Out-Null
    Invoke-Mpv $a @('script-message', 'watch-together-host') | Out-Null
    Start-Sleep -Milliseconds 500
    Invoke-Mpv $b @('script-message', 'watch-together-join') | Out-Null
    $ok = Wait-Until { (Get-Prop $a 'user-data/watch-together/status') -eq 'connected' -and (Get-Prop $b 'user-data/watch-together/status') -eq 'connected' } 15
    Check 'connect' $ok "a=$(Get-Prop $a 'user-data/watch-together/status') b=$(Get-Prop $b 'user-data/watch-together/status')"

    $ok = Wait-Until { (Get-Prop $b 'filename') -eq $name1 -and (Get-Drift) -lt 0.3 } 8
    Check 'join follows host episode and position' $ok ("b={0} drift={1:N3}s" -f (Get-Prop $b 'filename'), (Get-Drift))
    $ok = Wait-Until { (Get-Prop $a 'user-data/watch-together/peer-file') -eq $name1 -and (Get-Prop $b 'user-data/watch-together/peer-file') -eq $name1 } 3
    Check 'friend file names known' $ok ("a sees {0}, b sees {1}" -f (Get-Prop $a 'user-data/watch-together/peer-file'), (Get-Prop $b 'user-data/watch-together/peer-file'))

    Invoke-Mpv $a @('set_property', 'pause', $true) | Out-Null
    $ok = Wait-Until { (Get-Prop $b 'pause') -eq $true } 3
    Check 'pause A -> B' $ok ("drift={0:N3}s" -f (Get-Drift))

    Invoke-Mpv $a @('seek', 300, 'absolute') | Out-Null
    $ok = Wait-Until { [math]::Abs((Get-Prop $b 'time-pos') - 300) -lt 0.3 } 3
    Check 'seek A -> B (paused)' $ok ("b={0:N3}" -f (Get-Prop $b 'time-pos'))

    Invoke-Mpv $b @('set_property', 'pause', $false) | Out-Null
    $ok = Wait-Until { (Get-Prop $a 'pause') -eq $false } 3
    Check 'play B -> A' $ok ''

    Invoke-Mpv $b @('seek', 450, 'absolute') | Out-Null
    $ok = Wait-Until { [math]::Abs((Get-Prop $a 'time-pos') - (Get-Prop $b 'time-pos')) -lt 0.3 -and (Get-Prop $a 'time-pos') -gt 449 } 3
    Check 'seek B -> A (playing)' $ok ("drift={0:N3}s" -f (Get-Drift))

    Invoke-Mpv $b @('set_property', 'speed', 1.5) | Out-Null
    $ok = Wait-Until { (Get-Prop $a 'speed') -eq 1.5 } 3
    Check 'speed B -> A' $ok ''
    Invoke-Mpv $a @('set_property', 'speed', 1) | Out-Null
    $ok = Wait-Until { (Get-Prop $b 'speed') -eq 1 } 3
    Check 'speed A -> B' $ok ''

    # Joiner seeks at random moments against the host's 1 s ticks: a tick in flight must not undo them.
    $rand = New-Object Random 23
    $lost = foreach ($k in 1..6) {
        Start-Sleep -Milliseconds ($rand.Next(0, 1000))
        $target = 60 + 40 * $k
        Invoke-Mpv $b @('seek', $target, 'absolute') | Out-Null
        Start-Sleep 2.5
        $pa = Get-Prop $a 'time-pos'; $pb = Get-Prop $b 'time-pos'
        if ([math]::Abs($pa - $pb) -ge 0.3 -or $pb -lt $target -or $pb -gt $target + 3) { "$target->a=$pa,b=$pb" }
    }
    Check 'joiner seeks vs ticks (6 random)' (-not $lost) ($lost -join ' ')

    $drifts = foreach ($i in 1..10) { Start-Sleep -Milliseconds 500; Get-Drift }
    $max = ($drifts | Measure-Object -Maximum).Maximum
    Check 'drift while playing 5s' ($max -lt 0.3) ("max={0:N3}s" -f $max)

    Invoke-Mpv $a @('playlist-next') | Out-Null
    $ok = Wait-Until { (Get-Prop $b 'filename') -eq $name2 -and (Get-Prop $b 'user-data/watch-together/peer-file') -eq $name2 } 5
    Check 'next episode A -> B' $ok ("b={0}" -f (Get-Prop $b 'filename'))

    Invoke-Mpv $b @('playlist-prev') | Out-Null
    $ok = Wait-Until { (Get-Prop $a 'filename') -eq $name1 -and (Get-Prop $b 'filename') -eq $name1 } 5
    Check 'previous episode B -> A' $ok ("a={0}" -f (Get-Prop $a 'filename'))
    $ok = Wait-Until { (Get-Drift) -lt 0.3 } 5
    Check 'in sync after episode change' $ok ("drift={0:N3}s" -f (Get-Drift))

    # No echo loop: with nobody touching anything, nobody should switch, pause or seek.
    $p1 = Get-Prop $b 'pause'
    Start-Sleep 3
    Check 'stable: no ping-pong' (-not (Get-Prop $a 'pause') -and -not $p1 -and (Get-Prop $a 'filename') -eq $name1 -and (Get-Prop $b 'filename') -eq $name1) ''

    Invoke-Mpv $b @('script-message', 'watch-together-leave') | Out-Null
    $ok = Wait-Until { (Get-Prop $a 'user-data/watch-together/status') -eq 'disconnected' } 5
    Check 'leave B -> A sees disconnect' $ok ''
} finally {
    $procs | ForEach-Object { if (-not $_.HasExited) { $_.Kill() } }
}
if ($failures) { Write-Host "$failures check(s) failed"; exit 1 }
Write-Host 'All checks passed'
