# Load check: one host and N guests on this PC. Not part of e2e because it starts N+1 mpv instances.
# Usage: powershell -ExecutionPolicy Bypass -File tests\scale.ps1 -Mpv C:\path\mpv.exe [-GuestCount 20]
# Needs the test videos that e2e.ps1 creates in %TEMP%.
param([string]$Mpv = 'mpv', [int]$GuestCount = 10, [int]$Port = 47894)
$ErrorActionPreference = 'Stop'
$script = Join-Path (Split-Path $PSScriptRoot) 'watch-together'
$ep1 = Join-Path $env:TEMP 'watch-together-ep1.mkv'; $ep2 = Join-Path $env:TEMP 'watch-together-ep2.mkv'
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Open-Ipc([string]$pipe) {
    $s = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipe, [System.IO.Pipes.PipeDirection]::InOut)
    for ($i = 0; $i -lt 100; $i++) { try { $s.Connect(200); break } catch { } }
    $w = New-Object System.IO.StreamWriter($s, $utf8); $w.AutoFlush = $true
    @{ r = (New-Object System.IO.StreamReader($s, $utf8)); w = $w; id = 0 }
}
function I($ipc, [object[]]$cmd) {
    $ipc.id++
    $ipc.w.WriteLine((ConvertTo-Json -Compress -InputObject @{ command = $cmd; request_id = $ipc.id }))
    while ($true) { $m = ConvertFrom-Json $ipc.r.ReadLine(); if ($m.request_id -eq $ipc.id) { return $m.data } }
}
function Spread($l) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = foreach ($x in $l) {
        $pos = I $x @('get_property', 'time-pos')
        if (-not (I $x @('get_property', 'pause'))) { $pos -= $sw.Elapsed.TotalSeconds * (I $x @('get_property', 'speed')) }
        $pos
    }
    ($p | Measure-Object -Max).Maximum - ($p | Measure-Object -Min).Minimum
}
function Wait([scriptblock]$c, [double]$s = 5) {
    $e = [DateTime]::Now.AddSeconds($s)
    while ([DateTime]::Now -lt $e) { if (& $c) { return $true }; Start-Sleep -Milliseconds 200 }
    & $c
}
$n = $GuestCount + 1
$procs = foreach ($p in 0..($n - 1)) {
    Start-Process $Mpv -PassThru -WindowStyle Hidden -ArgumentList @('--no-config', '--vo=null', '--ao=null', "--script=$script",
        "--script-opts=watch_together-port=$Port,watch_together-auto_update=no,watch_together-name=P$p",
        "--input-ipc-server=wt-scale-$p", "`"$ep1`"", "`"$ep2`"")
}
try {
    $all = foreach ($p in 0..($n - 1)) { Open-Ipc "wt-scale-$p" }
    $h = $all[0]; $gs = $all[1..($n - 1)]
    Start-Sleep 2
    $null = I $h @('script-message', 'watch-together-host'); Start-Sleep -Milliseconds 500
    $k = 0
    foreach ($g in $gs) { $k += 1; $null = I $g @('seek', (10 * $k), 'absolute'); $null = I $g @('script-message', 'watch-together-join') }
    $t0 = Get-Date
    $ok = Wait { (I $h @('get_property', 'user-data/watch-together/room')).members.Count -eq $n -and (Spread $all) -lt 0.3 } 20
    "connect+sync $n players: $ok in $([math]::Round(((Get-Date) - $t0).TotalSeconds, 1))s spread=$([math]::Round((Spread $all), 3))"
    $null = I $h @('set_property', 'pause', $true)
    $t0 = Get-Date; $ok = Wait { -not ($gs | Where-Object { -not (I $_ @('get_property', 'pause')) }) } 5
    "host pause -> all: $ok in $([math]::Round(((Get-Date) - $t0).TotalSeconds, 2))s"
    $null = I $gs[0] @('set_property', 'pause', $false)
    $null = I $gs[0] @('seek', 250, 'absolute')
    $t0 = Get-Date; $ok = Wait { (I $h @('get_property', 'time-pos')) -gt 249 -and -not (I $h @('get_property', 'pause')) -and (Spread $all) -lt 0.3 } 6
    "guest play+seek -> all: $ok in $([math]::Round(((Get-Date) - $t0).TotalSeconds, 2))s"
    $sp = foreach ($r in 1..10) { Start-Sleep -Milliseconds 500; Spread $all }
    "spread over 5s: max=$([math]::Round(($sp | Measure-Object -Max).Maximum, 3))"
    $null = I $gs[-1] @('playlist-next')
    $ok = Wait { -not ($all | Where-Object { (I $_ @('get_property', 'playlist-pos')) -ne 1 }) -and (Spread $all) -lt 0.3 } 8
    "guest next episode -> all: $ok"
    $bridge = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*bridge.ps1*-Pipe wt-scale-0 *-Mode host*' }
    $cpu1 = (Get-Process -Id $bridge.ProcessId).TotalProcessorTime; Start-Sleep 5; $cpu2 = (Get-Process -Id $bridge.ProcessId).TotalProcessorTime
    "host bridge CPU: $([math]::Round(($cpu2 - $cpu1).TotalMilliseconds / 5000 * 100, 1))% of one core"
} finally {
    $procs | ForEach-Object { if (-not $_.HasExited) { $_.Kill() } }
}
