# Waiting for a buffering or loading member: a host (A) and a guest (C) play local files, a guest (B)
# plays the same files over a throttled local HTTP server (tests\slow_server.py, needs python).
# Usage: powershell -ExecutionPolicy Bypass -File tests\buffering.ps1 -Mpv C:\path\mpv.exe
# Needs the test videos that e2e.ps1 creates in %TEMP%.
param([string]$Mpv = 'mpv', [int]$Port = 47888, [int]$HttpPort = 47887)
$ErrorActionPreference = 'Stop'
$script = Join-Path (Split-Path $PSScriptRoot) 'watch-together'
$ep1 = Join-Path $env:TEMP 'watch-together-ep1.mkv'; $ep2 = Join-Path $env:TEMP 'watch-together-ep2.mkv'
$rateFile = Join-Path $env:TEMP 'watch-together-rate.txt'
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
function Set-Rate([int]$bytesPerSecond) { [IO.File]::WriteAllText($rateFile, "$bytesPerSecond") }
# What the host knows about guest B's waiting.
function B-Wait($a) { ((I $a @('get_property', 'user-data/watch-together/room')).members | Where-Object { $_.name -eq 'B' }).wait }

# One room: A hosts with the given wait timeout, B streams from the throttled server, C plays locally.
# B starts at a rate a bit above the video's ~34 KB/s: unthrottled, the server would fill the TCP
# buffers with megabytes ahead of mpv, and a later slowdown would take minutes to show.
function Start-Room([int]$timeout) {
    $common = @('--no-config', '--vo=null', '--ao=null', "--script=$script")
    $opts = "watch_together-port=$Port,watch_together-auto_update=no,watch_together-lang=en,watch_together-wait_timeout=$timeout"
    $url = "http://127.0.0.1:$HttpPort"
    $p = @(
        (Start-Process $Mpv -PassThru -WindowStyle Hidden -ArgumentList ($common + @("--script-opts=$opts,watch_together-name=A", '--input-ipc-server=wt-buf-a', "`"$ep1`"", "`"$ep2`""))),
        (Start-Process $Mpv -PassThru -WindowStyle Hidden -ArgumentList ($common + @("--script-opts=$opts,watch_together-name=B", '--input-ipc-server=wt-buf-b', '--cache=yes', '--cache-secs=5', "$url/watch-together-ep1.mkv", "$url/watch-together-ep2.mkv"))),
        (Start-Process $Mpv -PassThru -WindowStyle Hidden -ArgumentList ($common + @("--script-opts=$opts,watch_together-name=C", '--input-ipc-server=wt-buf-c', "`"$ep1`"", "`"$ep2`"")))
    )
    $script:a = Open-Ipc 'wt-buf-a'; $script:b = Open-Ipc 'wt-buf-b'; $script:c = Open-Ipc 'wt-buf-c'
    [void](Wait-Until { (I $script:b @('get_property', 'time-pos')) -gt 0 } 20)
    $null = I $script:a @('script-message', 'watch-together-host'); Start-Sleep -Milliseconds 500
    $null = I $script:b @('script-message', 'watch-together-join'); $null = I $script:c @('script-message', 'watch-together-join')
    [void](Wait-Until { (I $script:a @('get_property', 'user-data/watch-together/room')).members.Count -eq 3 } 10)
    $p
}

Set-Rate 0
$server = Start-Process python -PassThru -WindowStyle Hidden -ArgumentList @((Join-Path $PSScriptRoot 'slow_server.py'), "`"$env:TEMP`"", $HttpPort, "`"$rateFile`"")
try {
    # 1. B buffers: the room holds, play is refused meanwhile, and everyone resumes once B is ready.
    Set-Rate 45000
    $procs = Start-Room 30
    try {
        Set-Rate 6000   # far below the test video's ~34 KB/s
        $ok = Wait-Until { (B-Wait $a) -eq 'buffering' -and (I $a @('get_property', 'pause')) -and (I $c @('get_property', 'pause')) } 30
        Check 'B buffers -> host and C pause, reason known' $ok ("B wait={0}" -f (B-Wait $a))
        $null = I $c @('set_property', 'pause', $false)
        Start-Sleep 1.5
        Check 'play pressed while waiting is held back' ((I $a @('get_property', 'pause')) -and (I $c @('get_property', 'pause'))) ''
        Set-Rate 0
        $ok = Wait-Until { -not (B-Wait $a) -and -not (I $a @('get_property', 'pause')) -and -not (I $b @('get_property', 'pause')) -and -not (I $c @('get_property', 'pause')) } 20
        Check 'B ready -> everyone plays again' $ok ''
        $p = foreach ($x in $a, $b, $c) { I $x @('get_property', 'time-pos') }
        $spread = ($p | Measure-Object -Max).Maximum - ($p | Measure-Object -Min).Minimum
        $ok = Wait-Until { $p = foreach ($x in $a, $b, $c) { I $x @('get_property', 'time-pos') }; (($p | Measure-Object -Max).Maximum - ($p | Measure-Object -Min).Minimum) -lt 0.5 } 5
        Check 'in sync after the wait' $ok ''

        # 3. Episode change while B opens files slowly: the room waits with reason "loading".
        Set-Rate 3000
        $null = I $a @('playlist-next')
        $ok = Wait-Until { (B-Wait $a) -eq 'loading' -and (I $a @('get_property', 'pause')) } 15
        Check 'slow episode load -> room waits, reason loading' $ok ("B wait={0}" -f (B-Wait $a))
        Set-Rate 0
        $ok = Wait-Until { -not (B-Wait $a) -and -not (I $a @('get_property', 'pause')) -and (I $b @('get_property', 'filename')) -eq 'watch-together-ep2.mkv' } 20
        Check 'B loaded -> everyone plays episode 2' $ok ''
    } finally { $procs | ForEach-Object { if (-not $_.HasExited) { $_.Kill() } } }

    # 2. B never catches up: after the timeout the room plays on without B.
    Set-Rate 45000
    $procs = Start-Room 6
    try {
        Set-Rate 4000
        $ok = Wait-Until { (B-Wait $a) -eq 'buffering' -and (I $a @('get_property', 'pause')) } 30
        Check 'B buffers -> hold (timeout 6 s)' $ok ''
        $t0 = Get-Date
        $ok = Wait-Until { -not (I $a @('get_property', 'pause')) -and -not (I $c @('get_property', 'pause')) } 15
        Check 'host gives up after the timeout' $ok ("after {0:N1}s" -f ((Get-Date) - $t0).TotalSeconds)
    } finally { $procs | ForEach-Object { if (-not $_.HasExited) { $_.Kill() } } }
} finally {
    Set-Rate 0
    if (-not $server.HasExited) { $server.Kill() }
}
if ($failures) { Write-Host "$failures check(s) failed"; exit 1 }
Write-Host 'All checks passed'
