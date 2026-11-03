# Download speed from a host's share.ps1 with 1, 2, 4... parallel connections. Run it on the guest PC
# while the host has a room with sharing on; through Porthole the address is usually 127.0.0.1.
# Data is read and dropped, nothing is written. Tells whether more connections would speed downloads up.
#   powershell -ExecutionPolicy Bypass -File tests\speed.ps1 -Name "01.mkv"
param(
    [Parameter(Mandatory)][string]$Name,   # exact file name from the host's playlist
    [string]$Address = '127.0.0.1',
    [int]$Port = 47801,
    [int[]]$Connections = @(1, 2, 4, 8),
    [int]$Seconds = 10
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)

# Connect, ask for the file from offset, read the header line; returns @{client; stream; size}.
function Open-Share([int64]$offset) {
    $c = New-Object System.Net.Sockets.TcpClient
    if (-not $c.ConnectAsync($Address, $Port).Wait(10000)) { throw "no answer from ${Address}:${Port}" }
    $s = $c.GetStream()
    $req = $utf8.GetBytes((ConvertTo-Json -Compress -InputObject @{ file = $Name; offset = $offset; who = 'speed test' }) + "`n")
    $s.Write($req, 0, $req.Length)
    $s.ReadTimeout = 15000
    $buf = New-Object System.Collections.Generic.List[byte]
    while ($true) {
        $b = $s.ReadByte()
        if ($b -lt 0) { throw 'the host closed the connection' }
        if ($b -eq 10) { break }
        $buf.Add([byte]$b)
    }
    $head = ConvertFrom-Json $utf8.GetString($buf.ToArray())
    if ($head.error) { throw [string]$head.error }
    @{ client = $c; stream = $s; size = [int64]$head.size; offset = $offset }
}

$probe = Open-Share 0
$size = $probe.size
$probe.client.Close()
"{0}: {1:N1} MB" -f $Name, ($size / 1MB)

foreach ($n in $Connections) {
    # Each connection starts in its own part of the file and starts over there when it reaches the end.
    $conns = @(for ($i = 0; $i -lt $n; $i++) {
        $c = Open-Share ([int64]($size * $i / $n))
        $c.chunk = New-Object byte[] 262144
        $c.task = $c.stream.ReadAsync($c.chunk, 0, $c.chunk.Length)
        $c
    })
    $total = [int64]0
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.Elapsed.TotalSeconds -lt $Seconds) {
        [void][System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]@($conns | ForEach-Object { $_.task }), 1000)
        for ($i = 0; $i -lt $conns.Count; $i++) {
            $c = $conns[$i]
            if (-not $c.task.IsCompleted) { continue }
            $got = if ($c.task.IsFaulted) { 0 } else { $c.task.Result }
            if ($got -le 0) {
                $c.client.Close()
                $c = Open-Share $c.offset
                $c.chunk = New-Object byte[] 262144
                $conns[$i] = $c
            }
            $total += $got
            $c.task = $c.stream.ReadAsync($c.chunk, 0, $c.chunk.Length)
        }
    }
    $secs = $clock.Elapsed.TotalSeconds
    foreach ($c in $conns) { $c.client.Close() }
    "{0} connection(s): {1,8:N2} MB/s  ({2,6:N1} Mbit/s)" -f $n, ($total / 1MB / $secs), ($total * 8 / 1e6 / $secs)
}
