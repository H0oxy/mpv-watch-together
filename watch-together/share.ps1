# Episode sharing for watch-together (host): serves files of mpv's current playlist, by exact name, over TCP.
# Request: one JSON line {"file": "<name>", "offset": <bytes already there>, "who": "<guest>"}.
# Answer: one JSON line {"size": <total>, "offset": <start>} or {"error": "<text>"}, then the bytes from offset.
# With "length" (stream.ps1, watching without downloading) only that many bytes, and a bad offset is an error.
# Several downloads run at once through async copies. ASCII only, like bridge.ps1.
param(
    [Parameter(Mandatory)][string]$Pipe,
    [Parameter(Mandatory)][string]$Script,
    [string]$Bind = '127.0.0.1',
    [int]$Port = 47801
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)

$mpv = New-Object System.IO.Pipes.NamedPipeClientStream('.', $Pipe, [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
$mpv.Connect(5000)
$mpvIn = New-Object System.IO.StreamReader($mpv, $utf8)
$mpvOut = New-Object System.IO.StreamWriter($mpv, $utf8)
$mpvOut.AutoFlush = $true
$mpvTask = $mpvIn.ReadLineAsync()
$requestId = 0

function Send-Lua([string[]]$msg) {
    $cmd = @('script-message-to', $Script, 'watch-together-share') + $msg
    $mpvOut.WriteLine((ConvertTo-Json -Compress -InputObject @{ command = $cmd }))
}

# Ask mpv for a property; other lines (events) that arrive meanwhile are skipped.
function Get-Mpv([string]$prop) {
    $script:requestId++
    $mpvOut.WriteLine((ConvertTo-Json -Compress -InputObject @{ command = @('get_property', $prop); request_id = $script:requestId }))
    while ($true) {
        [void]$script:mpvTask.Wait()
        $line = $script:mpvTask.Result
        if ($null -eq $line) { exit 0 }
        $script:mpvTask = $mpvIn.ReadLineAsync()
        if ($line.Contains('"request_id"')) {
            $m = ConvertFrom-Json $line
            if ($m.request_id -eq $script:requestId) { return $m.data }
        }
    }
}

# Full path of a local playlist entry with exactly this file name, or $null.
function Find-Shared([string]$name) {
    if (-not $name -or $name -match '[\\/:*?"<>|]') { return $null }
    $wd = [string](Get-Mpv 'working-directory')
    foreach ($e in @(Get-Mpv 'playlist')) {
        $f = [string]$e.filename
        if ($f -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') { continue }
        $full = if ([IO.Path]::IsPathRooted($f)) { $f } else { Join-Path $wd $f }
        if ([IO.Path]::GetFileName($full) -eq $name -and (Test-Path -LiteralPath $full -PathType Leaf)) { return $full }
    }
    $null
}

function Write-Line($stream, $obj) {
    $bytes = $utf8.GetBytes((ConvertTo-Json -Compress -InputObject $obj) + "`n")
    $stream.Write($bytes, 0, $bytes.Length)
}

try {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse($Bind), $Port)
    $listener.Start()
} catch {
    Send-Lua @('error', "cannot listen on ${Bind}:${Port}")
    exit 1
}

$transfers = New-Object System.Collections.ArrayList
$watchers = New-Object 'System.Collections.Generic.HashSet[string]'  # "who|file" already announced: a stream asks for many pieces
$accept = $listener.AcceptTcpClientAsync()
while ($true) {
    $tasks = @($mpvTask, $accept)
    foreach ($t in $transfers) { $tasks += $t.task }
    [void][System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]$tasks, 1000)

    if ($mpvTask.IsCompleted) {
        if ($mpvTask.IsFaulted -or $null -eq $mpvTask.Result) { break }  # mpv quit
        $mpvTask = $mpvIn.ReadLineAsync()                               # an event: not for us
    }

    if ($accept.IsCompleted) {
        $client = if ($accept.IsFaulted) { $null } else { $accept.Result }
        $accept = $listener.AcceptTcpClientAsync()
        if ($client) {
            try {
                $client.NoDelay = $true
                $s = $client.GetStream()
                $s.ReadTimeout = 5000
                # Read the request byte by byte, so no file bytes or later data get buffered away.
                $buf = New-Object System.Collections.Generic.List[byte]
                while ($true) {
                    $b = $s.ReadByte()
                    if ($b -lt 0 -or $buf.Count -gt 4096) { throw 'bad request' }
                    if ($b -eq 10) { break }
                    $buf.Add([byte]$b)
                }
                $req = ConvertFrom-Json $utf8.GetString($buf.ToArray())
                $name = [string]$req.file
                $path = Find-Shared $name
                if (-not $path) {
                    Write-Line $s @{ error = 'not shared' }
                    $client.Close()
                } elseif ($req.length) {
                    # A piece for watching without downloading (stream.ps1): exactly these bytes, from memory.
                    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
                    try {
                        $size = $fs.Length
                        $offset = [int64]$req.offset
                        $len = [int64]$req.length
                        if ($offset -lt 0 -or $offset -ge $size -or $len -le 0 -or $len -gt 16MB) {
                            Write-Line $s @{ error = 'bad range'; size = $size }
                            $client.Close()
                        } else {
                            $data = New-Object byte[] ([Math]::Min($len, $size - $offset))
                            [void]$fs.Seek($offset, 'Begin')
                            $got = 0
                            while ($got -lt $data.Length) {
                                $n = $fs.Read($data, $got, $data.Length - $got)
                                if ($n -le 0) { break }
                                $got += $n
                            }
                            Write-Line $s @{ size = $size; offset = $offset }
                            [void]$transfers.Add(@{ client = $client; task = $s.WriteAsync($data, 0, $got) })
                            $who = ([string]$req.who) -replace '[^\w .()\-]', ''
                            if ($watchers.Add("$who|$name")) { Send-Lua @('watching', $who, $name) }
                        }
                    } finally { $fs.Close() }
                } else {
                    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
                    $offset = [int64]0
                    if ($req.offset -and [int64]$req.offset -gt 0 -and [int64]$req.offset -le $fs.Length) { $offset = [int64]$req.offset }
                    Write-Line $s @{ size = $fs.Length; offset = $offset }
                    [void]$fs.Seek($offset, 'Begin')
                    $who = ([string]$req.who) -replace '[^\w .()\-]', ''
                    [void]$transfers.Add(@{ client = $client; file = $fs; task = $fs.CopyToAsync($s, 262144) })
                    Send-Lua @('sending', $who, $name)
                }
            } catch {
                $client.Close()
            }
        }
    }

    foreach ($t in @($transfers)) {
        if ($t.task.IsCompleted) {
            if ($t.file) { $t.file.Close() }
            $t.client.Close()
            $transfers.Remove($t)
        }
    }
}

foreach ($t in $transfers) { if ($t.file) { $t.file.Close() }; $t.client.Close() }
$listener.Stop()
