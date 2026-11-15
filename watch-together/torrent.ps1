# Torrent engine helper for watch-together: makes sure TorrServer is there (downloads the release pinned in
# main.lua and checks its SHA256), runs it on 127.0.0.1, and does the HTTP calls main.lua cannot make.
# The engine's API answers any web page (TorrServer allows all origins), so it runs with its HTTP password on
# a random port; both live in engine.json next to it, so other mpv windows use the same engine.
# Commands from main.lua, as script-message watch-together-torrent-cmd <verb> ...:
#   add <id> <link>   link: magnet, bare hash or file:///path.torrent; answered with files or error
#   probe <hash>      report the torrent's download speed every second; probe-stop ends it
#   preload <hash> <index>   fetch the start of that file ahead (the next episode); answered with preloaded
#   fonts <hash> <i:ext:length;...>   save those font files to %TEMP%\watch-together\fonts\<hash> as <i>.<ext>
#                     (one at a time; ones already there are kept); answered with fonts
# Reports to main.lua: engine <bytes> <total> (downloading the engine) | ready <base url> | restarted |
#   preloaded <hash> <index> | preload-failed <hash> <index> <text> | fonts <hash> <failed count> |
#   files <id> <hash> <json> | stat <hash> <bytes per second> <active peers> <seeders> | error <id> <text>.
# ASCII only, like bridge.ps1.
param(
    [Parameter(Mandatory)][string]$Pipe,
    [Parameter(Mandatory)][string]$Script,
    [string]$Base = '',                    # an engine the user runs (torrent_url): use it, start nothing
    [string]$Exe = '',                     # our engine, when Base is empty
    [string]$Download = '',                # where to get it when Exe is missing or wrong
    [string]$Sha256 = '',
    [int]$Port = 0,                        # our engine's port; 0 = a free one, chosen at its start
    [int]$CacheMB = 256
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

# Free and total physical memory in MB, for main.lua's guard on its stream buffer.
function Send-Ram {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -Property FreePhysicalMemory, TotalVisibleMemorySize
        $cmd = @('script-message-to', $Script, 'watch-together-ram', "$([int64]($os.FreePhysicalMemory / 1024))", "$([int64]($os.TotalVisibleMemorySize / 1024))")
        $mpvOut.WriteLine((ConvertTo-Json -Compress -InputObject @{ command = $cmd }))
    } catch { }
}

$own = -not $Base                          # we start and keep our engine
# main.lua joins paths with "/"; Windows reports process paths with "\". One form, or the watchdog and the
# stray check below would not know our own engine.
if ($own) { $Exe = [IO.Path]::GetFullPath($Exe) }
$data = if ($own) { Split-Path $Exe } else { '' }
$stateFile = if ($own) { Join-Path $data 'engine.json' } else { '' }
$auth = $null                              # Authorization header of our engine

function Invoke-Engine([string]$path, $body, [switch]$NoAuth) {
    $headers = @{}
    if ($auth -and -not $NoAuth) { $headers['Authorization'] = $auth }
    $json = $utf8.GetBytes((ConvertTo-Json -Compress -Depth 10 -InputObject $body))
    Invoke-RestMethod -UseBasicParsing -TimeoutSec 10 -Method Post -Uri ($Base + $path) -Headers $headers -Body $json `
        -ContentType 'application/json; charset=utf-8'
}

function Test-Engine([string]$url) {
    try { [void](Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 -Uri "$url/echo"); $true } catch { $false }
}

# Ours and locked: the API refuses a request without the password and takes one with it. TorrServer runs
# without a password when it cannot read accs.db, so this is checked, not assumed.
function Test-Locked {
    try { [void](Invoke-Engine '/settings' @{ action = 'get' } -NoAuth); return $false } catch {
        $r = $_.Exception.Response
        if (-not $r -or [int]$r.StatusCode -ne 401) { return $false }
    }
    try { [void](Invoke-Engine '/settings' @{ action = 'get' }); $true } catch { $false }
}

function Get-Sha([string]$path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() }

# Download to .part with progress reports; only a file with the pinned hash becomes the engine.
function Get-Engine {
    New-Item -ItemType Directory -Force -Path $data | Out-Null
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
               enableRutorSearch = $false; enableTorznabSearch = $false
               preloadCache = 50 }   # a preload of the next episode fetches this share of cacheSize
    foreach ($k in $want.Keys) { $s | Add-Member -Force -NotePropertyName $k -NotePropertyValue $want[$k] }
    [void](Invoke-Engine '/settings' @{ action = 'set'; sets = $s })
}

function Test-PortFree([int]$p) {
    try { $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $p); $l.Start(); $l.Stop(); $true } catch { $false }
}

function Get-FreePort {
    $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop()
    $p
}

function Use-State($st) {
    $script:Base = "http://127.0.0.1:$($st.port)"
    $script:auth = 'Basic ' + [Convert]::ToBase64String($utf8.GetBytes("wt:$($st.pass)"))
}

# The engine of engine.json if it answers and is locked; else a new one on that port (or Port, or a free
# one) with that password (or a new one). Another mpv window may have started it. -Restart (the engine
# stopped answering): if something still holds its port, that is the engine, slow, so no second one starts.
# Helpers of several mpv windows take turns here (a named mutex), so only one of them starts an engine.
function Connect-Engine([switch]$Restart) {
    $mutex = New-Object System.Threading.Mutex($false, 'Local\watch-together-engine')
    try {
        $got = $false
        try { $got = $mutex.WaitOne(90000) } catch [System.Threading.AbandonedMutexException] { $got = $true }  # its holder died: ours now
        if (-not $got) { throw 'another mpv window is still starting the engine' }
        try { Connect-EngineLocked -Restart:$Restart } finally { $mutex.ReleaseMutex() }
    } finally { $mutex.Dispose() }
}

function Connect-EngineLocked([switch]$Restart) {
    $st = $null
    if (Test-Path -LiteralPath $stateFile) { try { $st = Get-Content -Raw -LiteralPath $stateFile | ConvertFrom-Json } catch { } }
    if ($st -and $st.port -and $st.pass) {
        Use-State $st
        if ((Test-Engine $Base) -and (Test-Locked)) { return }
        if ($Restart -and -not (Test-PortFree ([int]$st.port))) { throw 'the engine does not answer' }
    }
    # Any other engine from our folder is unusable here (an older plugin's, without a password, or hung) and
    # holds config.db, which a new one cannot open ("error open bboltDB ... timeout"). Only our helpers start
    # this exe, and they take turns, so it is not one that is still starting.
    $stray = @(Get-Process -Name TorrServer -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $Exe })
    if ($stray) {
        $stray | Stop-Process -Force
        $stray | Wait-Process -Timeout 5 -ErrorAction SilentlyContinue   # gone, and its lock on config.db with it
    }
    if (-not (Test-Path -LiteralPath $Exe) -or (Get-Sha $Exe) -ne $Sha256.ToLower()) { Get-Engine }
    $pass = if ($st -and $st.pass) { [string]$st.pass } else {
        $b = New-Object byte[] 16
        (New-Object System.Security.Cryptography.RNGCryptoServiceProvider).GetBytes($b)
        -join ($b | ForEach-Object { $_.ToString('x2') })
    }
    $p = if ($Port -gt 0) { $Port } elseif ($st -and $st.port -and (Test-PortFree ([int]$st.port))) { [int]$st.port } else { Get-FreePort }
    $st = [pscustomobject]@{ port = $p; pass = $pass }
    [IO.File]::WriteAllText((Join-Path $data 'accs.db'), (ConvertTo-Json -Compress @{ wt = $pass }))
    [IO.File]::WriteAllText($stateFile, (ConvertTo-Json -Compress $st))
    Use-State $st
    $errLog = Join-Path $data 'engine-errors.log'   # what the engine says when it refuses to start
    $proc = Start-Process -FilePath $Exe -ArgumentList @('-p', "$p", '-i', '127.0.0.1', '-d', "`"$data`"", '-a') -WindowStyle Hidden -PassThru `
        -RedirectStandardError $errLog
    # The engine outlives this helper and the mpv that started it (another window may use it), but not the
    # last helper of this engine: every mpv window that uses it runs one, and a helper ends with its mpv, also
    # a killed one (its IPC pipe breaks). Other mpv windows, without torrents, do not count. The pid is checked
    # against the exe: if the engine is gone by then, Windows may have given its pid to another program.
    $exeQ = $Exe -replace "'", "''"
    $cmd = @'
function Used { @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
    $c = ([string]$_.CommandLine).Replace('/', '\').ToLower(); $c.Contains('torrent.ps1') -and $c.Contains('{EXE}') }).Count -gt 0 }
while (Used) { Start-Sleep -Seconds 5 }
Get-Process -Id {PID} -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq '{EXE}' } | Stop-Process -Force
'@
    $cmd = $cmd.Replace('{PID}', "$($proc.Id)").Replace("Path -eq '{EXE}'", "Path -eq '$exeQ'").Replace('{EXE}', $exeQ.ToLower())
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))  # survives spaces and quotes in the path
    Start-Process -FilePath 'powershell' -ArgumentList @('-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-EncodedCommand', $enc) -WindowStyle Hidden | Out-Null
    for ($i = 0; $i -lt 60; $i++) {
        if (Test-Engine $Base) {
            if (-not (Test-Locked)) {
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                throw 'the engine started without its password, so it is not used'
            }
            Set-EngineSettings
            return
        }
        if ($proc.HasExited) {
            # The last line: TorrServer logs harmless notes first ("ffprobe and avprobe not found").
            $why = @(Get-Content -LiteralPath $errLog -ErrorAction SilentlyContinue | Where-Object { $_.Trim() }) | Select-Object -Last 1
            throw "the engine exited: $why"
        }
        Start-Sleep -Milliseconds 250
    }
    throw 'the engine did not start'
}

try {
    if ($own) { Connect-Engine }
    elseif (-not (Test-Engine $Base)) { throw "no torrent engine at $Base" }
} catch {
    Send-Lua @('error', '', (Clean $_.Exception.Message))
    exit 1
}
Send-Lua @('ready', $Base)

$adding = New-Object System.Collections.ArrayList   # @{ id; hash; until }: added, waiting for the file list
$probe = ''      # hash whose speed is reported
$preload = $null # @{ req; task; hash; index }: the next episode being fetched ahead
$fontJobs = New-Object System.Collections.ArrayList   # @{ hash; dir; queue; failed; wc; task; file }
$mpvTask = $mpvIn.ReadLineAsync()
$clock = [Diagnostics.Stopwatch]::StartNew()
$down = $false   # our engine stopped answering and could not be started again yet
$misses = 0      # health checks in a row that got no answer

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
            # (a guest reaching an episode it lacks, or after an engine restart) brings it back from that list
            # with its trackers.
            $st = Invoke-Engine '/torrents' @{ action = 'add'; link = [string]$a[3]; save_to_db = $true }
            $hash = ([string]$st.hash).ToLower()
            if ($hash -notmatch '^[0-9a-f]{40}$') { throw 'the engine did not take this link' }
            [void]$adding.Add(@{ id = $id; hash = $hash; until = $clock.Elapsed.TotalSeconds + 90 })
        } catch { Send-Lua @('error', $id, (Clean $_.Exception.Message)) }
    } elseif ($verb -eq 'preload') {
        # TorrServer answers /stream?preload only once the start of that file is fetched, so the request
        # runs on its own; a newer one replaces it.
        $h = ([string]$a[2]).ToLower(); $i = [int]$a[3]
        if ($h -match '^[0-9a-f]{40}$' -and $i -ge 1) {
            if ($script:preload) { try { $script:preload.req.Abort() } catch { } }
            $req = [Net.HttpWebRequest]::Create("$Base/stream?link=$h&index=$i&preload")
            if ($auth) { $req.Headers['Authorization'] = $auth }
            $script:preload = @{ req = $req; task = $req.GetResponseAsync(); hash = $h; index = $i }
        }
    } elseif ($verb -eq 'fonts') {
        # Names are ours (<file id>.<ext>), never the torrent's.
        $h = ([string]$a[2]).ToLower()
        if ($h -match '^[0-9a-f]{40}$') {
            $q = New-Object System.Collections.ArrayList
            foreach ($s in ([string]$a[3]).Split(';')) {
                if ($s -match '^(\d{1,6}):(ttf|otf|ttc):(\d{1,12})$') {
                    [void]$q.Add(@{ i = [int]$matches[1]; ext = $matches[2]; len = [int64]$matches[3] })
                }
            }
            $dir = Join-Path $env:TEMP "watch-together\fonts\$h"
            [void]$fontJobs.Add(@{ hash = $h; dir = $dir; queue = $q; failed = 0; task = $null })
        }
    } elseif ($verb -eq 'probe') {
        $script:probe = ([string]$a[2]).ToLower()
    } elseif ($verb -eq 'probe-stop') {
        $script:probe = ''
    }
}

# Font files for ASS subtitles, one download at a time, through a .part file; the answer comes once a
# torrent's list is done. A file of the right size from an earlier run is kept.
function Step-Fonts {
    $j = $fontJobs[0]
    if ($j.task) {
        if (-not $j.task.IsCompleted) { return }
        $ok = $j.task.Status -eq 'RanToCompletion'
        $j.wc.Dispose(); $j.task = $null
        try {
            if (-not $ok) { throw 'download failed' }
            if (Test-Path -LiteralPath $j.file) { Remove-Item -LiteralPath $j.file -Force }
            Move-Item -LiteralPath "$($j.file).part" $j.file
        } catch {
            Remove-Item -LiteralPath "$($j.file).part" -Force -ErrorAction SilentlyContinue
            $j.failed++
        }
    }
    while ($j.queue.Count -gt 0) {
        $f = $j.queue[0]; $j.queue.RemoveAt(0)
        $j.file = Join-Path $j.dir "$($f.i).$($f.ext)"
        $have = Get-Item -LiteralPath $j.file -ErrorAction SilentlyContinue
        if ($have -and $have.Length -eq $f.len) { continue }
        try {
            New-Item -ItemType Directory -Force $j.dir | Out-Null
            $j.wc = New-Object Net.WebClient
            if ($auth) { $j.wc.Headers['Authorization'] = $auth }
            $j.task = $j.wc.DownloadFileTaskAsync("$Base/stream?link=$($j.hash)&index=$($f.i)&play", "$($j.file).part")
            return
        } catch { $j.failed++ }
    }
    $fontJobs.RemoveAt(0)
    Send-Lua @('fonts', $j.hash, "$($j.failed)")
}

$next = 0
$nextRam = 0
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
    if ($now -ge $nextRam) {
        $nextRam = $now + 5
        Send-Ram
        # Our engine died (a crash, or the last mpv closing raced us): start it again, on the same port with
        # the same password if they are still free, so the playlist's stream URLs keep working.
        # Two misses in a row (10 s), so a slow answer under load is not taken for a dead engine.
        if ($own -and (Test-Engine $Base)) {
            $down = $false; $misses = 0   # back, perhaps started by the helper of another mpv window
        } elseif ($own) {
            $misses++
            if ($misses -ge 2) {
                try {
                    $was = $Base
                    Connect-Engine -Restart
                    $down = $false; $misses = 0
                    Send-Lua @('restarted')
                    if ($Base -ne $was) { Send-Lua @('ready', $Base) }
                } catch {
                    if (-not $down) { Send-Lua @('error', '', (Clean $_.Exception.Message)) }
                    $down = $true
                }
            }
        }
    }
    if ($preload -and $preload.task.IsCompleted) {
        $pl = $preload; $preload = $null
        if ($pl.task.Status -eq 'RanToCompletion') {
            $pl.task.Result.Close()
            Send-Lua @('preloaded', $pl.hash, "$($pl.index)")
        } else {
            Send-Lua @('preload-failed', $pl.hash, "$($pl.index)", (Clean $pl.task.Exception.InnerException.Message))
        }
    }
    if ($fontJobs.Count -gt 0) { Step-Fonts }

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
