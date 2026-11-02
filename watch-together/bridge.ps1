# Network bridge for watch-together: relays JSON lines between mpv (JSON IPC pipe) and one TCP peer.
# All sync logic lives in main.lua; this file only moves lines. Keep it ASCII: PowerShell 5.1 reads BOM-less files as ANSI.
param(
    [Parameter(Mandatory)][string]$Pipe,
    [Parameter(Mandatory)][ValidateSet('host', 'join')][string]$Mode,
    [Parameter(Mandatory)][string]$Script,
    [string]$Address = '127.0.0.1',
    [string]$Bind = '127.0.0.1',
    [int]$Port = 47800
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$MaxLine = 4096

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
$peer = $null; $peerIn = $null; $peerOut = $null; $peerTask = $null
$netTask = $null       # pending AcceptTcpClientAsync / ConnectAsync
$joinClient = $null
$retryAt = [DateTime]::MinValue

function Close-Peer {
    if ($script:peer) { $script:peer.Close() }
    $script:peer = $null; $script:peerIn = $null; $script:peerOut = $null; $script:peerTask = $null
}

function Use-Peer($client) {
    Close-Peer
    $client.NoDelay = $true
    $script:peer = $client
    $s = $client.GetStream()
    $script:peerIn = New-Object System.IO.StreamReader($s, $utf8)
    $script:peerOut = New-Object System.IO.StreamWriter($s, $utf8)
    $script:peerOut.AutoFlush = $true
    $script:peerTask = $script:peerIn.ReadLineAsync()
    Send-Lua @('connected')
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
        } elseif (-not $peer -and [DateTime]::Now -ge $retryAt) {
            $joinClient = New-Object System.Net.Sockets.TcpClient
            $netTask = $joinClient.ConnectAsync($Address, $Port)
        }
    }

    $tasks = @($mpvTask)
    if ($peerTask) { $tasks += $peerTask }
    if ($netTask) { $tasks += $netTask }
    [void][System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]$tasks, 500)

    if ($mpvTask.IsCompleted) {
        if ($mpvTask.IsFaulted -or $null -eq $mpvTask.Result) { break }  # mpv quit
        $line = $mpvTask.Result
        $mpvTask = $mpvIn.ReadLineAsync()
        # Cheap pre-filter: mpv sends every property/event to IPC clients.
        if ($line.Contains('watch-together-out')) {
            $ev = ConvertFrom-Json $line
            if ($ev.event -eq 'client-message' -and $ev.args[0] -eq 'watch-together-out' -and $peerOut) {
                try { $peerOut.WriteLine([string]$ev.args[1]) } catch { Close-Peer; Send-Lua @('disconnected') }
            }
        }
    }

    if ($netTask -and $netTask.IsCompleted) {
        $t = $netTask; $netTask = $null
        if ($Mode -eq 'host') {
            if (-not $t.IsFaulted) { Use-Peer $t.Result }  # a reconnecting friend replaces the old connection
        } elseif ($t.IsFaulted) {
            $joinClient.Close()
            $retryAt = [DateTime]::Now.AddSeconds(2)
        } else {
            Use-Peer $joinClient
        }
    }

    if ($peerTask -and $peerTask.IsCompleted) {
        $line = if ($peerTask.IsFaulted) { $null } else { $peerTask.Result }
        if ($null -eq $line) {
            Close-Peer
            Send-Lua @('disconnected')
            $retryAt = [DateTime]::Now.AddSeconds(2)
        } else {
            $peerTask = $peerIn.ReadLineAsync()
            if ($line.Length -le $MaxLine) { Send-Lua @('in', $line) }
        }
    }
}

Close-Peer
if ($listener) { $listener.Stop() }
