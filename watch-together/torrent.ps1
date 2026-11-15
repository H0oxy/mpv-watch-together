# Torrent engine helper for watch-together: makes sure TorrServer is there (downloads the release pinned in
# main.lua and checks its SHA256), starts it on 127.0.0.1, and does the HTTP calls main.lua cannot make.
# Commands from main.lua, as script-message watch-together-torrent-cmd <verb> ...:
#   add <id> <link>   link: magnet, bare hash or file:///path.torrent; answered with files or error
#   probe <hash>      report the torrent's download speed every second; probe-stop ends it
# Reports to main.lua: engine <bytes> <total> (downloading the engine) | ready | files <id> <hash> <json> |
#   stat <hash> <bytes per second> <active peers> <seeders> | error <id> <text>. ASCII only, like bridge.ps1.
param(
    [Parameter(Mandatory)][string]$Pipe,
    [Parameter(Mandatory)][string]$Script,
    [Parameter(Mandatory)][string]$Base,   # http://127.0.0.1:<port> of the engine
    [string]$Exe = '',                     # empty: use the engine that already runs at Base, start nothing
    [string]$Download = '',                # where to get the engine when Exe is missing or wrong
    [string]$Sha256 = '',
    [int]$CacheMB = 256,
    [int]$WatchPid = 0                     # mpv: the engine started here goes away when mpv does
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$mpv = New-Object System.IO.Pipes.NamedPipeClientStream('.', $Pipe, [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
$mpv.Connect(5000)
$mpvIn = New-Object System.IO.StreamReader($mpv, $utf8)
$mpvOut = New-Object System.IO.StreamWriter($mpv, $utf8)
$mpvOut.AutoFlush = $true

function Send-Lua([string[]]$msg) {
    $cmd = @('script-message-to', $Script, 'watch-together-torrent') + $msg
    $mpvOut.WriteLine((ConvertTo-Json -Compress -InputObject @{ command = $cmd }))
}
function Clean([string]$text) { $text -replace '\s+', ' ' }

function Invoke-Engine([string]$path, $body) {
    $uri = $Base + $path
    if ($null -eq $body) { return Invoke-RestMethod -UseBasicParsing -TimeoutSec 10 -Uri $uri }
    $json = $utf8.GetBytes((ConvertTo-Json -Compress -Depth 10 -InputObject $body))
    Invoke-RestMethod -UseBasicParsing -TimeoutSec 10 -Method Post -Uri $uri -Body $json -ContentType 'application/json; charset=utf-8'
}

function Test-Engine {
    try { [void](Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 -Uri "$Base/echo"); $true } catch { $false }
}

function Get-Sha([string]$path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() }

# Download to .part with progress reports; only a file with the pinned hash becomes the engine.
function Get-Engine {
    $dir = Split-Path $Exe
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $part = "$Exe.part"
    $req = [Net.HttpWebRequest]::Create($Download)
    $req.UserAgent = 'watch-together'
    $res = $req.GetResponse()
    try {
        $total = $res.ContentLength
        $in = $res.GetResponseStream()
        $out = [IO.File]::Open($part, 'Create', 'Write', 'None')
        try {
            $buf = New-Object byte[] 262144
            $done = [int64]0
            $clock = [Diagnostics.Stopwatch]::StartNew()
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                $out.Write($buf, 0, $n)
                $done += $n
                if ($clock.ElapsedMilliseconds -ge 500) { Send-Lua @('engine', "$done", "$total"); $clock.Restart() }
            }
        } finally { $out.Close() }
    } finally { $res.Close() }
    if ((Get-Sha $part) -ne $Sha256.ToLower()) {
        Remove-Item -LiteralPath $part -Force
        throw 'the downloaded engine has a wrong checksum'
    }
    if (Test-Path -LiteralPath $Exe) { Remove-Item -LiteralPath $Exe -Force }
    Move-Item -LiteralPath $part -Destination $Exe
}

# Settings are replaced as a whole, so read them, change ours, write them back.
function Set-EngineSettings {
    $s = Invoke-Engine '/settings' @{ action = 'get' }
    $want = @{ cacheSize = [int64]$CacheMB * 1MB; useDisk = $false; enableBonjour = $false; enableDLNA = $false;
               enableRutorSearch = $false; enableTorznabSearch = $false }
    foreach ($k in $want.Keys) { $s | Add-Member -Force -NotePropertyName $k -NotePropertyValue $want[$k] }
    [void](Invoke-Engine '/settings' @{ action = 'set'; sets = $s })
}

function Start-Engine {
    if (-not (Test-Path -LiteralPath $Exe) -or (Get-Sha $Exe) -ne $Sha256.ToLower()) { Get-Engine }
    $port = ([Uri]$Base).Port
    $data = Split-Path $Exe
    $errLog = Join-Path $data 'engine-errors.log'   # what the engine says when it refuses to start
    $p = Start-Process -FilePath $Exe -ArgumentList @('-p', "$port", '-i', '127.0.0.1', '-d', "`"$data`"") -WindowStyle Hidden -PassThru `
        -RedirectStandardError $errLog
    # The engine outlives this helper (mpv may stop it) but not mpv itself. The pid is checked against
    # the exe first: if the engine is gone by then, Windows may have given its pid to another program.
    if ($WatchPid -gt 0) {
        $exeQ = $Exe -replace "'", "''"
        $cmd = "try { Wait-Process -Id $WatchPid } catch { }; " +
               "Get-Process -Id $($p.Id) -ErrorAction SilentlyContinue | Where-Object { `$_.Path -eq '$exeQ' } | Stop-Process -Force"
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))  # survives spaces and quotes in the path
        Start-Process -FilePath 'powershell' -ArgumentList @('-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-EncodedCommand', $enc) -WindowStyle Hidden | Out-Null
    }
    for ($i = 0; $i -lt 60; $i++) {
        if (Test-Engine) { return }
        if ($p.HasExited) {
            $why = @(Get-Content -LiteralPath $errLog -ErrorAction SilentlyContinue | Where-Object { $_.Trim() }) | Select-Object -First 1
            throw "the engine exited: $why"
        }
        Start-Sleep -Milliseconds 250
    }
    throw 'the engine did not start'
}

try {
    if (-not (Test-Engine)) {
        if (-not $Exe) { throw "no torrent engine at $Base" }
        Start-Engine
    }
    if ($Exe) { Set-EngineSettings }
} catch {
    Send-Lua @('error', '', (Clean $_.Exception.Message))
    exit 1
}
Send-Lua @('ready')

$adding = New-Object System.Collections.ArrayList   # @{ id; hash; until }: added, waiting for the file list
$probe = ''      # hash whose speed is reported
$mpvTask = $mpvIn.ReadLineAsync()
$clock = [Diagnostics.Stopwatch]::StartNew()

function File-List($st) {
    $list = @()
    foreach ($f in @($st.file_stats)) {
        if ($null -ne $f.id) { $list += @{ i = [int]$f.id; path = [string]$f.path; length = [int64]$f.length } }
    }
    , $list
}

function On-Command($a) {
    $verb = [string]$a[1]
    if ($verb -eq 'add') {
        $id = [string]$a[2]
        try {
            # Kept in the engine's list: it closes an idle torrent after a minute, and a stream asked for later
            # (a guest reaching an episode it lacks) brings it back from that list with its trackers.
            $st = Invoke-Engine '/torrents' @{ action = 'add'; link = [string]$a[3]; save_to_db = $true }
            $hash = ([string]$st.hash).ToLower()
            if ($hash -notmatch '^[0-9a-f]{40}$') { throw 'the engine did not take this link' }
            [void]$adding.Add(@{ id = $id; hash = $hash; until = $clock.Elapsed.TotalSeconds + 90 })
        } catch { Send-Lua @('error', $id, (Clean $_.Exception.Message)) }
    } elseif ($verb -eq 'probe') {
        $script:probe = ([string]$a[2]).ToLower()
    } elseif ($verb -eq 'probe-stop') {
        $script:probe = ''
    }
}

$next = 0
while ($true) {
    [void]$mpvTask.Wait(250)
    if ($mpvTask.IsCompleted) {
        if ($mpvTask.IsFaulted -or $null -eq $mpvTask.Result) { break }  # mpv quit
        $line = $mpvTask.Result
        $mpvTask = $mpvIn.ReadLineAsync()
        if ($line.Contains('watch-together-torrent-cmd')) {
            $ev = ConvertFrom-Json $line
            if ($ev.event -eq 'client-message' -and $ev.args[0] -eq 'watch-together-torrent-cmd') { On-Command $ev.args }
        }
    }

    $now = $clock.Elapsed.TotalSeconds
    if ($now -lt $next) { continue }
    $next = $now + 1

    # The file list comes once the engine has the torrent's metadata from its peers.
    foreach ($job in @($adding)) {
        try {
            $st = Invoke-Engine '/torrents' @{ action = 'get'; hash = $job.hash }
            $files = File-List $st
            if ($files.Count -gt 0) {
                $adding.Remove($job)
                Send-Lua @('files', $job.id, $job.hash, (ConvertTo-Json -Compress -Depth 4 -InputObject $files))
                continue
            }
        } catch { }
        if ($now -gt $job.until) {
            $adding.Remove($job)
            Send-Lua @('error', $job.id, 'no file list from the swarm after 90 s')
        }
    }

    if ($probe) {
        try {
            $st = Invoke-Engine '/torrents' @{ action = 'get'; hash = $probe }
            Send-Lua @('stat', $probe, "$([int64]$st.download_speed)", "$([int]$st.active_peers)", "$([int]$st.connected_seeders)")
        } catch { }
    }
}
