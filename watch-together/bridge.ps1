# Network bridge for watch-together: relays JSON lines between mpv (JSON IPC pipe) and TCP peers.
# Host mode accepts several guests (ids p1, p2, ...); join mode keeps one link with id "host".
# All sync logic lives in main.lua; this file only moves lines. Keep it ASCII: PowerShell 5.1 reads BOM-less files as ANSI.
param(
    [Parameter(Mandatory)][string]$Pipe,
    [Parameter(Mandatory)][ValidateSet('host', 'join')][string]$Mode,
    [Parameter(Mandatory)][string]$Script,
    [string]$Address = '127.0.0.1',
    [string]$Bind = '127.0.0.1',
    [int]$Port = 47800,
    [int]$MaxPeers = 16
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$MaxLine = 1048576  # the room list grows with the number of guests

$mpv = New-Object System.IO.Pipes.NamedPipeClientStream('.', $Pipe, [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
$mpv.Connect(5000)
$mpvIn = New-Object System.IO.StreamReader($mpv, $utf8)
$mpvOut = New-Object System.IO.StreamWriter($mpv, $utf8)
$mpvOut.AutoFlush = $true

function Send-Lua([string[]]$msg) {
    $cmd = @('script-message-to', $Script, 'watch-together-net') + $msg
    $mpvOut.WriteLine((ConvertTo-Json -Compress -InputObject @{ command = $cmd }))
}

$listener = $null
$peers = @{}          # id -> @{ c = TcpClient; r = reader; w = writer; t = pending ReadLineAsync }
$nextId = 1
$netTask = $null      # pending AcceptTcpClientAsync / ConnectAsync
$joinClient = $null
$retryAt = [DateTime]::MinValue

function Close-Peer([string]$id) {
    $p = $script:peers[$id]
    if ($p) { $p.c.Close(); $script:peers.Remove($id); Send-Lua @('disconnected', $id) }
}

function Add-Peer($client) {
    if ($Mode -eq 'host' -and $script:peers.Count -ge $MaxPeers) { $client.Close(); return }
    $id = 'host'
    if ($Mode -eq 'host') { $id = "p$script:nextId"; $script:nextId++ }
    $client.NoDelay = $true
    $s = $client.GetStream()
    $r = New-Object System.IO.StreamReader($s, $utf8)
    $w = New-Object System.IO.StreamWriter($s, $utf8)
    $w.AutoFlush = $true
    $script:peers[$id] = @{ c = $client; r = $r; w = $w; t = $r.ReadLineAsync() }
    Send-Lua @('connected', $id)
}

if ($Mode -eq 'host') {
    try {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse($Bind), $Port)
        $listener.Start()
    } catch {
        Send-Lua @('error', "cannot listen on ${Bind}:${Port}")
        exit 1
    }
    Send-Lua @('listening')
} else {
    Send-Lua @('connecting')
}

$mpvTask = $mpvIn.ReadLineAsync()
while ($true) {
    if (-not $netTask) {
        if ($Mode -eq 'host') {
            $netTask = $listener.AcceptTcpClientAsync()
        } elseif ($peers.Count -eq 0 -and [DateTime]::Now -ge $retryAt) {
            $joinClient = New-Object System.Net.Sockets.TcpClient
            $netTask = $joinClient.ConnectAsync($Address, $Port)
        }
    }

    $tasks = @($mpvTask)
    foreach ($p in $peers.Values) { $tasks += $p.t }
    if ($netTask) { $tasks += $netTask }
    [void][System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]$tasks, 500)

    if ($mpvTask.IsCompleted) {
        if ($mpvTask.IsFaulted -or $null -eq $mpvTask.Result) { break }  # mpv quit
        $line = $mpvTask.Result
        $mpvTask = $mpvIn.ReadLineAsync()
        # Cheap pre-filter: mpv sends every property/event to IPC clients.
        if ($line.Contains('watch-together-out')) {
            $ev = ConvertFrom-Json $line
            if ($ev.event -eq 'client-message' -and $ev.args[0] -eq 'watch-together-out') {
                $target = [string]$ev.args[1]
                $ids = if ($target -eq '*') { @($peers.Keys) } else { @($target) }
                foreach ($id in $ids) {
                    $p = $peers[$id]
                    if ($p) { try { $p.w.WriteLine([string]$ev.args[2]) } catch { Close-Peer $id } }
                }
            }
        }
    }

    if ($netTask -and $netTask.IsCompleted) {
        $t = $netTask; $netTask = $null
        if ($Mode -eq 'host') {
            if (-not $t.IsFaulted) { Add-Peer $t.Result }
        } elseif ($t.IsFaulted) {
            $joinClient.Close()
            $retryAt = [DateTime]::Now.AddSeconds(2)
        } else {
            Add-Peer $joinClient
        }
    }

    foreach ($id in @($peers.Keys)) {
        $p = $peers[$id]
        if (-not $p.t.IsCompleted) { continue }
        $line = if ($p.t.IsFaulted) { $null } else { $p.t.Result }
        if ($null -eq $line) {
            Close-Peer $id
            $retryAt = [DateTime]::Now.AddSeconds(2)
        } else {
            $p.t = $p.r.ReadLineAsync()
            if ($line.Length -le $MaxLine) { Send-Lua @('in', $id, $line) }
        }
    }
}

foreach ($id in @($peers.Keys)) { $peers[$id].c.Close() }
if ($listener) { $listener.Stop() }
