# Watching from the host without downloading (guest): a local HTTP server for mpv.
# mpv opens http://127.0.0.1:<port>/<file name> and asks for a byte range. Each answer is fetched from
# the host's share.ps1 in pieces over several connections at once (the tunnel gives one connection
# only part of its speed) and sent on to mpv in order. A new request from mpv (a seek) drops the old one.
# Reports to main.lua: ready <port> | error <text>. ASCII only, like bridge.ps1.
param(
    [Parameter(Mandatory)][string]$Pipe,
    [Parameter(Mandatory)][string]$Script,
    [Parameter(Mandatory)][string]$Address,
    [Parameter(Mandatory)][int]$Port,
    [string]$Who = '',
    [int]$Connections = 4,
    [int]$Chunk = 2MB
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$ascii = [Text.Encoding]::ASCII

$mpv = New-Object System.IO.Pipes.NamedPipeClientStream('.', $Pipe, [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
$mpv.Connect(5000)
$mpvIn = New-Object System.IO.StreamReader($mpv, $utf8)
$mpvOut = New-Object System.IO.StreamWriter($mpv, $utf8)
$mpvOut.AutoFlush = $true
$mpvTask = $mpvIn.ReadLineAsync()

function Send-Lua([string[]]$msg) {
    $cmd = @('script-message-to', $Script, 'watch-together-stream') + $msg
    $mpvOut.WriteLine((ConvertTo-Json -Compress -InputObject @{ command = $cmd }))
}

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
Send-Lua @('ready', "$($listener.LocalEndpoint.Port)")

$sizes = @{}     # file name -> size, from the host's answers
$cur = $null     # the mpv request being answered: one at a time

function Ok([object]$t) { $t.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion }

# One piece of the file over its own connection; the header line of the host's answer is cut out of buf.
function New-Piece([int64]$start, [int64]$len) {
    $p = @{ start = $start; len = $len; buf = (New-Object byte[] ($len + 4096)); filled = 0; sent = 0; tries = 0 }
    Connect-Piece $p
    $p
}

function Connect-Piece($p) {
    $p.client = New-Object System.Net.Sockets.TcpClient
    $p.client.NoDelay = $true
    $p.phase = 'connect'
    $p.hlen = 0
    $p.task = $p.client.ConnectAsync($Address, $Port)
}

function Close-Piece($p) {
    if ($p.client) { $p.client.Close(); $p.client = $null }
    $p.task = $null
}

function Read-Piece($p) {
    $at = $p.filled + $p.hlen
    $count = if ($p.phase -eq 'head') { [Math]::Min(4096, $p.buf.Length - $at) } else { [Math]::Min(262144, $p.len - $p.filled) }
    $p.task = $p.stream.ReadAsync($p.buf, $at, $count)
}

# The connection broke: ask again for what is still missing, a few times.
function Retry-Piece($p) {
    Close-Piece $p
    $p.tries++
    if ($p.tries -gt 3) { throw 'the connection to the host keeps dropping' }
    Connect-Piece $p
}

# mpv may have closed the request already (a quick second seek): then it is simply dropped.
function Send-Head([string]$text) {
    $b = $ascii.GetBytes($text)
    try {
        $cur.stream.Write($b, 0, $b.Length)
        $cur.headSent = $true
    } catch { Drop-Current }
}

function Drop-Current {
    if (-not $script:cur) { return }
    foreach ($p in $script:cur.pieces) { Close-Piece $p }
    $script:cur.client.Close()
    $script:cur = $null
}

# Now that the size is known: answer mpv's request, or refuse a range past the end.
function Start-Answer([int64]$size) {
    $c = $script:cur
    $c.size = $size
    if ($c.from -ge $size) {
        Send-Head "HTTP/1.1 416 Range Not Satisfiable`r`nContent-Range: bytes */$size`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
        Drop-Current
        return
    }
    $first = $c.pieces[0]
    $first.len = [Math]::Min($first.len, $size - $first.start)
    $c.next = $first.start + $first.len
    $status = if ($c.ranged) { "206 Partial Content`r`nContent-Range: bytes $($c.from)-$($size - 1)/$size" } else { '200 OK' }
    Send-Head ("HTTP/1.1 $status`r`nContent-Length: $($size - $c.from)`r`nAccept-Ranges: bytes`r`n" +
               "Content-Type: application/octet-stream`r`nConnection: close`r`n`r`n")
}

function Step-Piece($p) {
    if ($p.phase -eq 'connect') {
        if (-not (Ok $p.task)) { Retry-Piece $p; return }
        $p.stream = $p.client.GetStream()
        $req = @{ file = $cur.name; offset = $p.start + $p.filled; length = $p.len - $p.filled; who = $Who }
        $b = $utf8.GetBytes((ConvertTo-Json -Compress -InputObject $req) + "`n")
        try { $p.stream.Write($b, 0, $b.Length) } catch { Retry-Piece $p; return }
        $p.phase = 'head'
        Read-Piece $p
        return
    }
    if (-not (Ok $p.task) -or $p.task.Result -le 0) { Retry-Piece $p; return }
    $n = $p.task.Result
    if ($p.phase -eq 'head') {
        $p.hlen += $n
        $nl = [Array]::IndexOf($p.buf, [byte]10, [int]$p.filled, [int]$p.hlen)
        if ($nl -lt 0) {
            if ($p.hlen -ge 4096) { throw 'bad answer from the host' }
            Read-Piece $p
            return
        }
        $head = ConvertFrom-Json $utf8.GetString($p.buf, $p.filled, $nl - $p.filled)
        $rest = $p.filled + $p.hlen - ($nl + 1)
        [Array]::Copy($p.buf, $nl + 1, $p.buf, $p.filled, $rest)
        $p.hlen = 0
        if ($head.size) { $sizes[$cur.name] = [int64]$head.size }
        if (-not $cur.size -and $head.size) { Start-Answer ([int64]$head.size); if (-not $script:cur) { return } }
        if ($head.error) { throw "host: $($head.error)" }
        # An old host ignores "length" and restarts from 0 on a bad offset.
        if ([int64]$head.offset -ne $p.start + $p.filled) { throw 'the host sent another part of the file' }
        $p.phase = 'data'
        $p.filled += [Math]::Min($rest, $p.len - $p.filled)
    } else {
        $p.filled += $n
    }
    if ($p.filled -ge $p.len) { Close-Piece $p } else { Read-Piece $p }
}

# Keep the connections busy and send mpv whatever has arrived of the first piece.
function Pump {
    $c = $script:cur
    if (-not $c -or -not $c.size) { return }
    while ($true) {
        while ($c.pieces.Count -lt $Connections -and $c.next -lt $c.size) {
            $len = [Math]::Min($Chunk, $c.size - $c.next)
            [void]$c.pieces.Add((New-Piece $c.next $len))
            $c.next += $len
        }
        if ($c.write) {
            if (-not $c.write.IsCompleted) { return }
            if (-not (Ok $c.write)) { Drop-Current; return }   # mpv closed it: a seek or the end of playback
            $c.pieces[0].sent += $c.wlen
            $c.write = $null
        }
        if ($c.pieces.Count -eq 0) { Drop-Current; return }   # all sent
        $p = $c.pieces[0]
        if ($p.sent -ge $p.len) {
            Close-Piece $p
            $c.pieces.RemoveAt(0)
            continue
        }
        if ($p.filled -le $p.sent) { return }
        $c.wlen = $p.filled - $p.sent
        $c.write = $c.stream.WriteAsync($p.buf, $p.sent, $c.wlen)
    }
}

# mpv's request: GET /<name> with an optional Range. Read at once, it is small and comes in one go.
function Open-Request($client) {
    $s = $client.GetStream()
    $s.ReadTimeout = 3000
    $buf = New-Object System.Collections.Generic.List[byte]
    while ($buf.Count -lt 4 -or $buf[$buf.Count - 1] -ne 10 -or $buf[$buf.Count - 3] -ne 10) {
        $b = $s.ReadByte()
        if ($b -lt 0 -or $buf.Count -gt 8192) { throw 'bad request' }
        $buf.Add([byte]$b)
    }
    $lines = $ascii.GetString($buf.ToArray()) -split "`r`n"
    $c = @{ client = $client; stream = $s; from = [int64]0; ranged = $false; pieces = (New-Object System.Collections.ArrayList); write = $null }
    $script:cur = $c
    if ($lines[0] -notmatch '^GET /(\S*) HTTP/1\.[01]$') {
        Send-Head "HTTP/1.1 405 Method Not Allowed`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
        Drop-Current
        return
    }
    $c.name = [Uri]::UnescapeDataString($matches[1])
    if (-not $c.name -or $c.name -match '[\\/:*?"<>|]') {
        Send-Head "HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
        Drop-Current
        return
    }
    foreach ($l in $lines) { if ($l -match '^Range:\s*bytes=(\d+)-') { $c.from = [int64]$matches[1]; $c.ranged = $true } }
    $c.next = $c.from + $Chunk
    [void]$c.pieces.Add((New-Piece $c.from $Chunk))
    if ($sizes.ContainsKey($c.name)) { Start-Answer $sizes[$c.name] }
}

$accept = $listener.AcceptTcpClientAsync()
while ($true) {
    $tasks = @($mpvTask, $accept)
    if ($cur) {
        if ($cur.write) { $tasks += $cur.write }
        foreach ($p in $cur.pieces) { if ($p.task) { $tasks += $p.task } }
    }
    [void][System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]$tasks, 1000)

    if ($mpvTask.IsCompleted) {
        if (-not (Ok $mpvTask) -or $null -eq $mpvTask.Result) { break }  # mpv quit
        $mpvTask = $mpvIn.ReadLineAsync()                               # an event: not for us
    }

    try {
        if ($accept.IsCompleted) {
            $client = if (Ok $accept) { $accept.Result } else { $null }
            $accept = $listener.AcceptTcpClientAsync()
            if ($client) {
                Drop-Current
                try { Open-Request $client } catch { $client.Close(); $cur = $null }  # not a request from mpv
            }
        }
        if ($cur) {
            foreach ($p in @($cur.pieces)) {
                if ($p.task -and $p.task.IsCompleted -and $cur) { Step-Piece $p }
            }
        }
        Pump
    } catch {
        $msg = $_.Exception.Message -replace '\s+', ' '
        if ($cur -and -not $cur.headSent) {
            try { Send-Head "HTTP/1.1 502 Bad Gateway`r`nContent-Length: 0`r`nConnection: close`r`n`r`n" } catch { }
        }
        Drop-Current
        Send-Lua @('error', $msg)
    }
}

Drop-Current
$listener.Stop()
