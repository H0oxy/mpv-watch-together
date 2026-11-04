# stream.ps1 against share.ps1 without a room: byte ranges must come back identical, also past 4 GB.
# Uses a 50 MB random file and a sparse 5 GB file with markers (no real disk space), both in %TEMP%.
# Usage: powershell -ExecutionPolicy Bypass -File tests\stream.ps1 -Mpv C:\path\mpv.exe
param([string]$Mpv = 'mpv', [int]$SharePort = 47886)
$ErrorActionPreference = 'Stop'
$plugin = Join-Path (Split-Path $PSScriptRoot) 'watch-together'
$failures = 0
function Check([string]$name, [bool]$ok, [string]$detail) {
    $mark = if ($ok) { 'PASS' } else { 'FAIL'; $script:failures++ }
    Write-Host ("[{0}] {1} {2}" -f $mark, $name, $detail)
}

$small = Join-Path $env:TEMP 'watch-together stream small.bin'
if (-not (Test-Path $small)) {
    $b = New-Object byte[] (50MB + 12345); (New-Object Random 1).NextBytes($b); [IO.File]::WriteAllBytes($small, $b)
}
$orig = [IO.File]::ReadAllBytes($small)
# Sparse, so 5 GB of zeros take no disk space; a marker at each offset that is checked.
$big = Join-Path $env:TEMP 'watch-together stream big.bin'
$marks = @(0, 2147483647, 3508312763, 4294967296, (5GB - 16))
if (-not (Test-Path $big)) {
    [IO.File]::WriteAllBytes($big, [byte[]]@())
    fsutil sparse setflag "$big" | Out-Null
    $fs = [IO.File]::OpenWrite($big)
    $fs.SetLength(5GB)
    foreach ($m in $marks) { [void]$fs.Seek($m, 'Begin'); $fs.Write([BitConverter]::GetBytes([int64]$m), 0, 8) }
    $fs.Close()
}
function Expected-Big([int64]$from, [int]$n) {
    $e = New-Object byte[] $n
    foreach ($m in $marks) {
        $mb = [BitConverter]::GetBytes([int64]$m)
        for ($i = 0; $i -lt 8; $i++) { $at = $m + $i - $from; if ($at -ge 0 -and $at -lt $n) { $e[$at] = $mb[$i] } }
    }
    , $e
}

$pipe = 'wt-stream-test'
$p = Start-Process $Mpv -PassThru -WindowStyle Hidden -ArgumentList @('--no-config', '--idle=yes', '--vo=null', '--ao=null', "--input-ipc-server=$pipe")
$procs = @($p)
try {
    $c = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipe, 'InOut')
    for ($i = 0; $i -lt 50; $i++) { try { $c.Connect(200); break } catch { } }
    $w = New-Object System.IO.StreamWriter($c); $w.AutoFlush = $true
    foreach ($f in @($small, $big)) { $w.WriteLine((ConvertTo-Json -Compress @{ command = @('loadfile', $f, 'append') })) }
    $ps = @('-ExecutionPolicy', 'Bypass', '-File')
    $procs += Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList ($ps + @("`"$plugin\share.ps1`"", '-Pipe', $pipe, '-Script', 'none', '-Port', $SharePort))
    $st = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList ($ps + @("`"$plugin\stream.ps1`"", '-Pipe', $pipe, '-Script', 'none', '-Address', '127.0.0.1', '-Port', $SharePort))
    $procs += $st
    $port = $null
    for ($i = 0; $i -lt 50 -and -not $port; $i++) {
        Start-Sleep -Milliseconds 200
        $port = (Get-NetTCPConnection -OwningProcess $st.Id -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1).LocalPort
    }

    function Get-Range([string]$name, [int64]$from, [int]$max) {
        $r = [Net.HttpWebRequest]::Create("http://127.0.0.1:$port/" + [Uri]::EscapeDataString($name))
        $r.Timeout = 15000
        if ($from -ge 0) { $r.AddRange($from) }
        $resp = $r.GetResponse()
        $s = $resp.GetResponseStream()
        $ms = New-Object IO.MemoryStream
        $buf = New-Object byte[] 65536
        while ($ms.Length -lt $max -and ($n = $s.Read($buf, 0, $buf.Length)) -gt 0) { $ms.Write($buf, 0, $n) }
        $resp.Close()
        @{ code = [int]$resp.StatusCode; len = $resp.ContentLength; data = $ms.ToArray() }
    }

    $bad = @()
    foreach ($from in @(-1, 0, 1, 2097151, 2097152, 5000000, ($orig.Length - 100), ($orig.Length - 1))) {
        $r = try { Get-Range (Split-Path $small -Leaf) $from 3000000 } catch { $null }  # cut short: an IOException
        if (-not $r) { $bad += $from; continue }
        $start = [Math]::Max([int64]$from, 0)
        $n = $r.data.Length
        if (-not ($n -ge [Math]::Min([int64]3000000, $orig.Length - $start) -and $r.len -eq $orig.Length - $start -and [Linq.Enumerable]::SequenceEqual([byte[]]$r.data, [byte[]]$orig[$start..($start + $n - 1)]))) { $bad += $from }
    }
    Check 'ranges of a small file are identical' ($bad.Count -eq 0) ($bad -join ', ')
    $code = try { (Get-Range (Split-Path $small -Leaf) $orig.Length 10).code } catch { [int]$_.Exception.InnerException.Response.StatusCode }
    Check 'a range past the end gets 416' ($code -eq 416) "$code"

    $bad = @()
    foreach ($from in @(0, 2147483640, 3508312700, 4294967290, (5GB - 100))) {
        $r = try { Get-Range (Split-Path $big -Leaf) $from 3000000 } catch { $null }  # cut short: an IOException
        if (-not $r) { $bad += $from; continue }
        $exp = Expected-Big $from $r.data.Length
        # The full amount: an answer cut short after its header would compare equal on zero bytes.
        if (-not ($r.data.Length -ge [Math]::Min([int64]3000000, 5GB - $from) -and $r.len -eq 5GB - $from -and [Linq.Enumerable]::SequenceEqual([byte[]]$r.data, [byte[]]$exp))) { $bad += $from }
    }
    Check 'ranges of a 5 GB file are identical, past 2 and 4 GB too' ($bad.Count -eq 0) ($bad -join ', ')
} finally {
    $procs | ForEach-Object { if (-not $_.HasExited) { $_.Kill() } }
}
if ($failures) { Write-Host "$failures check(s) failed"; exit 1 }
Write-Host 'All checks passed'
