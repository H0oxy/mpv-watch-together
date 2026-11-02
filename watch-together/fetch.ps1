# Episode download for watch-together (guest): fetches one file from the host's share.ps1.
# Writes <name>.part next to the other episodes and renames it when complete; an existing .part is
# continued. Reports to main.lua: progress <name> <bytes> <total> | done <name> <path> | error <name> <text>.
# ASCII only, like bridge.ps1.
param(
    [Parameter(Mandatory)][string]$Pipe,
    [Parameter(Mandatory)][string]$Script,
    [Parameter(Mandatory)][string]$Address,
    [Parameter(Mandatory)][int]$Port,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Dir,
    [string]$Who = ''
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)

$mpv = New-Object System.IO.Pipes.NamedPipeClientStream('.', $Pipe, [System.IO.Pipes.PipeDirection]::Out)
$mpv.Connect(5000)
$mpvOut = New-Object System.IO.StreamWriter($mpv, $utf8)
$mpvOut.AutoFlush = $true
function Send-Lua([string[]]$msg) {
    $cmd = @('script-message-to', $Script, 'watch-together-dl-event') + $msg
    $mpvOut.WriteLine((ConvertTo-Json -Compress -InputObject @{ command = $cmd }))
}

$client = $null; $out = $null
try {
    if ($Name -match '[\\/:*?"<>|]' -or $Name -eq '.' -or $Name -eq '..') { throw 'bad file name' }
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $target = Join-Path $Dir $Name
    $part = "$target.part"
    $offset = [int64]0
    if (Test-Path -LiteralPath $part) { $offset = (Get-Item -LiteralPath $part).Length }

    $client = New-Object System.Net.Sockets.TcpClient
    if (-not $client.ConnectAsync($Address, $Port).Wait(10000)) { throw "no answer from ${Address}:${Port}" }
    $s = $client.GetStream()
    $req = $utf8.GetBytes((ConvertTo-Json -Compress -InputObject @{ file = $Name; offset = $offset; who = $Who }) + "`n")
    $s.Write($req, 0, $req.Length)

    # Header line byte by byte: a buffered reader would swallow the start of the file.
    $s.ReadTimeout = 15000
    $buf = New-Object System.Collections.Generic.List[byte]
    while ($true) {
        $b = $s.ReadByte()
        if ($b -lt 0) { throw 'the host closed the connection' }
        if ($b -eq 10) { break }
        if ($buf.Count -gt 4096) { throw 'bad answer' }
        $buf.Add([byte]$b)
    }
    $head = ConvertFrom-Json $utf8.GetString($buf.ToArray())
    if ($head.error) { throw [string]$head.error }
    $total = [int64]$head.size
    $start = [int64]$head.offset
    # The host restarts from 0 when our .part does not fit its file.
    $mode = if ($start -gt 0 -and $start -eq $offset) { 'Append' } else { 'Create' }
    $out = [IO.File]::Open($part, $mode, 'Write', 'None')

    $done = $start
    $chunk = New-Object byte[] 262144
    $s.ReadTimeout = 30000
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($done -lt $total) {
        $n = $s.Read($chunk, 0, $chunk.Length)
        if ($n -le 0) { throw 'the connection dropped; downloading it again continues from here' }
        $out.Write($chunk, 0, $n)
        $done += $n
        if ($clock.ElapsedMilliseconds -ge 1000) {
            Send-Lua @('progress', $Name, "$done", "$total")
            $clock.Restart()
        }
    }
    $out.Close(); $out = $null
    Move-Item -LiteralPath $part -Destination $target -Force
    Send-Lua @('done', $Name, $target)
} catch {
    Send-Lua @('error', $Name, ($_.Exception.Message -replace '\s+', ' '))
} finally {
    if ($out) { $out.Close() }
    if ($client) { $client.Close() }
}
