# End-to-end check: mpv with the plugin, screen grabs with NR on and off, both must differ.
# powershell -ExecutionPolicy Bypass -File test-mpv.ps1 -Mpv C:\programs\mpv\mpv.exe -Video clip.mp4 -RuntimeDir <folder with nvngx_dlssnr.dll>
param([string]$Mpv = "C:\programs\mpv\mpv.exe", [Parameter(Mandatory)][string]$Video, [Parameter(Mandatory)][string]$RuntimeDir)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$out = Join-Path $here "test"
New-Item -ItemType Directory -Force $out | Out-Null
$pipe = "dlssnr-test-" + $PID
$log = Join-Path $env:TEMP "dlssnr.log"

function Send([string]$json) {
    $c = New-Object System.IO.Pipes.NamedPipeClientStream(".", $pipe, [System.IO.Pipes.PipeDirection]::InOut)
    $c.Connect(3000)
    $w = New-Object System.IO.StreamWriter($c); $w.AutoFlush = $true
    $r = New-Object System.IO.StreamReader($c)
    $w.WriteLine($json)
    $line = $r.ReadLine()
    $c.Dispose()
    return $line
}
Add-Type -Name Dpi -Namespace W -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[W.Dpi]::SetProcessDPIAware() | Out-Null  # screen coordinates in physical pixels, like mpv's window
function Grab([string]$name) {
    $bmp = New-Object System.Drawing.Bitmap 640, 360
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen(100, 100, 0, 0, $bmp.Size)
    $g.Dispose()
    $bmp.Save((Join-Path $out $name))
    $bmp.Dispose()
}

$mpvArgs = @("--no-config", "--script=$here\out\dlssnr.dll", "--d3d11-output-format=rgba8",
    "--script-opts=dlssnr-dir=$RuntimeDir", "--input-ipc-server=$pipe", "--geometry=640x360+100+100",
    "--hidpi-window-scale=no", "--auto-window-resize=no", "--no-border", "--ontop", "--pause", "--keep-open=always", $Video)
$p = Start-Process -FilePath $Mpv -ArgumentList $mpvArgs -PassThru
try {
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline -and -not (Test-Path "\\.\pipe\$pipe")) { Start-Sleep -Milliseconds 200 }
    Start-Sleep -Seconds 5  # NR runtime load (~3 s) and its OSD message
    Send '{"command":["seek",1,"absolute+exact"]}' | Out-Null
    Start-Sleep -Seconds 1
    Grab "mpv-nr-on.png"
    Send '{"command":["script-message","dlssnr-toggle"]}' | Out-Null
    Start-Sleep -Milliseconds 3500  # toggle OSD message goes away
    Send '{"command":["seek",1,"absolute+exact"]}' | Out-Null  # paused mpv only presents on a new frame
    Start-Sleep -Seconds 1
    Grab "mpv-nr-off.png"
    Send '{"command":["script-message","dlssnr-toggle"]}' | Out-Null
    Send '{"command":["set_property","pause",false]}' | Out-Null
    Start-Sleep -Seconds 3  # playing: frames keep flowing through NR
    $alive = Send '{"command":["get_property","time-pos"]}'
    Write-Output "playback after toggling: $alive"
} finally {
    try { Send '{"command":["quit"]}' | Out-Null } catch {}
    if (-not $p.WaitForExit(10000)) { Stop-Process -Id $p.Id -Force }
}
$ErrorActionPreference = "Continue"  # ffmpeg writes its report to stderr
$stats = & ffmpeg -hide_banner -i (Join-Path $out "mpv-nr-on.png") -i (Join-Path $out "mpv-nr-off.png") -filter_complex "[0][1]blend=all_mode=difference,format=gray,signalstats,metadata=print:key=lavfi.signalstats.YAVG" -f null - 2>&1
$d = [double](($stats | Select-String -Pattern 'YAVG=([0-9.]+)').Matches[0].Groups[1].Value)
Write-Output ("mean difference NR on/off: {0:N2} of 255" -f $d)
Write-Output "--- dlssnr.log"
Get-Content $log
if ($d -lt 1) { Write-Output "FAIL: picture did not change"; exit 1 }
if (Select-String -Path $log -Pattern 'failed|FAILED|SEH' -Quiet) { Write-Output "FAIL: errors in log"; exit 1 }
Write-Output "PASS"
