# torrent.ps1 with its own engine, offline: a stand-in TorrServer (compiled here from C#) takes the same
# flags (-p -i -d -a) and, like the real one, wants the password from accs.db only with -a and only if that
# file reads. The helper reports to a probe script in an idle mpv.
# Usage: powershell -ExecutionPolicy Bypass -File tests\engine.ps1 -Mpv C:\path\mpv.exe
param([string]$Mpv = 'mpv')
$ErrorActionPreference = 'Stop'
$helper = Join-Path (Split-Path $PSScriptRoot) 'watch-together\torrent.ps1'
$run = Join-Path $env:TEMP ('wt-engine-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$eng = Join-Path $run 'engine'
New-Item -ItemType Directory -Force $run, $eng | Out-Null
$exe = Join-Path $eng 'TorrServer.exe'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$failures = 0
function Check([string]$name, [bool]$ok, [string]$detail) {
    $mark = if ($ok) { 'PASS' } else { 'FAIL'; $script:failures++ }
    Write-Host ("[{0}] {1} {2}" -f $mark, $name, $detail)
}
function Wait-Until([scriptblock]$cond, [double]$s = 5) {
    $e = [DateTime]::Now.AddSeconds($s)
    while ([DateTime]::Now -lt $e) { if (& $cond) { return $true }; Start-Sleep -Milliseconds 200 }
    & $cond
}

Add-Type -OutputAssembly $exe -OutputType ConsoleApplication -TypeDefinition @'
using System; using System.IO; using System.Net; using System.Net.Sockets; using System.Text;
using System.Text.RegularExpressions; using System.Threading;
public static class FakeTorrServer {
    static string expect;
    public static int Main(string[] args) {
        int port = 8090; string dir = "."; bool auth = false;
        for (int i = 0; i < args.Length; i++) {
            if (args[i] == "-p") port = int.Parse(args[++i]);
            else if (args[i] == "-d") dir = args[++i].Trim('"');
            else if (args[i] == "-i") i++;
            else if (args[i] == "-a") auth = true;
        }
        string accs = Path.Combine(dir, "accs.db");
        if (auth && File.Exists(accs) && Environment.GetEnvironmentVariable("FAKE_IGNORE_AUTH") == null) {
            Match m = Regex.Match(File.ReadAllText(accs), "\"([^\"]+)\"\\s*:\\s*\"([^\"]+)\"");
            if (m.Success) expect = "Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes(m.Groups[1].Value + ":" + m.Groups[2].Value));
        }
        TcpListener l = new TcpListener(IPAddress.Loopback, port);
        try { l.Start(); } catch (Exception e) { Console.Error.WriteLine("listen failed: " + e.Message); return 1; }
        while (true) { TcpClient c = l.AcceptTcpClient(); ThreadPool.QueueUserWorkItem(delegate { Serve(c); }); }
    }
    static void Serve(TcpClient c) {
        try {
            using (c) {
                NetworkStream s = c.GetStream();
                StreamReader r = new StreamReader(s, Encoding.ASCII);
                string first = r.ReadLine(); if (first == null) return;
                string path = first.Split(' ')[1]; string authz = null; int len = 0; string line;
                while (!string.IsNullOrEmpty(line = r.ReadLine())) {
                    if (line.StartsWith("Authorization:", StringComparison.OrdinalIgnoreCase)) authz = line.Substring(14).Trim();
                    if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase)) len = int.Parse(line.Substring(15).Trim());
                }
                char[] body = new char[len]; int got = 0;
                while (got < len) { int n = r.Read(body, got, len - got); if (n <= 0) break; got += n; }
                int code = 200; string resp = "{}";
                if (path == "/echo") resp = "fake";
                else if (expect != null && authz != expect) { code = 401; resp = ""; }
                else if (path == "/settings") resp = new string(body, 0, got).Contains("\"get\"") ? "{\"cacheSize\":67108864}" : "{}";
                else code = 404;
                byte[] b = Encoding.UTF8.GetBytes(resp);
                byte[] h = Encoding.ASCII.GetBytes("HTTP/1.1 " + code + " X\r\nContent-Type: application/json\r\nContent-Length: " + b.Length + "\r\nConnection: close\r\n\r\n");
                s.Write(h, 0, h.Length); s.Write(b, 0, b.Length);
            }
        } catch { }
    }
}
'@
$sha = (Get-FileHash $exe -Algorithm SHA256).Hash.ToLower()

# An idle mpv whose probe script keeps every report of the helper in user-data/probe.
$probe = Join-Path $run 'wtprobe.lua'
[IO.File]::WriteAllText($probe, @'
local got = {}
mp.register_script_message("watch-together-torrent", function(...)
    got[#got + 1] = table.concat({ ... }, " ")
    mp.set_property_native("user-data/probe", got)
end)
'@)
$procs = New-Object System.Collections.ArrayList
function Start-Mpv([string]$n) {
    [void]$procs.Add((Start-Process $Mpv -PassThru -WindowStyle Hidden -ArgumentList @('--no-config', '--idle=yes', '--vo=null', '--ao=null',
        "--script=`"$probe`"", "--input-ipc-server=wt-eng-$n")))
    $s = New-Object System.IO.Pipes.NamedPipeClientStream('.', "wt-eng-$n", [System.IO.Pipes.PipeDirection]::InOut)
    for ($i = 0; $i -lt 50; $i++) { try { $s.Connect(200); break } catch { } }
    $w = New-Object System.IO.StreamWriter($s, $utf8); $w.AutoFlush = $true
    @{ r = (New-Object System.IO.StreamReader($s, $utf8)); w = $w; id = 0 }
}
function Reports($ipc) {
    $ipc.id++
    $ipc.w.WriteLine((ConvertTo-Json -Compress -InputObject @{ command = @('get_property', 'user-data/probe'); request_id = $ipc.id }))
    while ($true) { $m = ConvertFrom-Json $ipc.r.ReadLine(); if ($m.request_id -eq $ipc.id) { return @($m.data) } }
}
# The exe path as main.lua gives it: utils.join_path puts "/" between the config folder and the file, so
# the helper must still know its engine by Windows' "\" path (it once did not, and left engines running).
$luaExe = "$run/engine/TorrServer.exe"
function Start-Helper([string]$n) {
    $p = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$helper`"",
        '-Pipe', "wt-eng-$n", '-Script', 'wtprobe', '-Exe', "`"$luaExe`"", '-Download', 'http://127.0.0.1:9/none', '-Sha256', $sha,
        '-Port', '0')
    [void]$procs.Add($p)
    $p
}
function Engines { @(Get-Process -Name TorrServer -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe }) }
function Base($reports) { ($reports | Where-Object { $_ -like 'ready *' } | Select-Object -Last 1) -replace '^ready ', '' }
function Post([string]$url, [string]$authz) {
    $h = @{}; if ($authz) { $h['Authorization'] = $authz }
    try { [void](Invoke-RestMethod -UseBasicParsing -TimeoutSec 3 -Method Post -Uri "$url/settings" -Headers $h -Body '{"action":"get"}' -ContentType 'application/json'); 200 }
    catch { if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { -1 } }
}

try {
    # 0. An engine of an older plugin still runs from our folder, without a password (the real one would
    #    hold config.db, and a new engine could not open it): the helper stops it before starting its own.
    $old = Start-Process $exe -PassThru -WindowStyle Hidden -ArgumentList @('-p', '47869', '-i', '127.0.0.1', '-d', "`"$eng`"")
    [void](Wait-Until { try { [void](Invoke-WebRequest -UseBasicParsing -TimeoutSec 1 'http://127.0.0.1:47869/echo'); $true } catch { $false } } 5)

    # 1. A new engine: a free port, a password in accs.db and engine.json, the API locked without it.
    $a = Start-Mpv 'a'
    $ha = Start-Helper 'a'
    $ok = Wait-Until { (Base (Reports $a)) -match '^http://127\.0\.0\.1:\d+$' } 20
    Check 'an older engine left in our folder is stopped first' ($ok -and $old.HasExited -and (Engines).Count -eq 1) ("old exited={0} engines={1}" -f $old.HasExited, (Engines).Count)
    $base = Base (Reports $a)
    $state = Get-Content -Raw (Join-Path $eng 'engine.json') | ConvertFrom-Json
    $authz = 'Basic ' + [Convert]::ToBase64String($utf8.GetBytes("wt:$($state.pass)"))
    Check 'own engine on a free port, password in engine.json' ($ok -and $base -eq "http://127.0.0.1:$($state.port)" -and $state.pass.Length -eq 32) "$base"
    Check 'its API refuses a request without the password' ((Post $base '') -eq 401 -and (Post $base $authz) -eq 200) ''

    # 2. A second mpv window uses the same engine.
    $b = Start-Mpv 'b'
    $null = Start-Helper 'b'
    $ok = Wait-Until { (Base (Reports $b)) -eq $base } 20
    Check 'a second mpv window uses the running engine' ($ok -and (Engines).Count -eq 1) ("engines={0}" -f (Engines).Count)

    # 3. The engine dies: a helper starts it again, on the same port with the same password.
    Engines | Stop-Process -Force
    $dead = Wait-Until { (Engines).Count -eq 0 -and (Post $base $authz) -ne 200 } 5
    # The engine answers before the helper has written its settings and said "restarted": wait for both.
    $ok = $dead -and (Wait-Until { (Engines).Count -eq 1 -and (Post $base $authz) -eq 200 -and
                                   (@((Reports $a) + (Reports $b)) -contains 'restarted') } 25)
    Check 'a dead engine starts again on the same port' $ok ("dead={0} engines={1} a: {2} || b: {3}" -f $dead, (Engines).Count, ((Reports $a) -join ' | '), ((Reports $b) -join ' | '))

    # 4. An engine that comes up without its password is refused and stopped.
    foreach ($p in $procs) { if (-not $p.HasExited -and $p.ProcessName -eq 'powershell') { Stop-Process -Id $p.Id -Force } }
    Engines | Stop-Process -Force
    Remove-Item (Join-Path $eng 'engine.json'), (Join-Path $eng 'accs.db') -ErrorAction SilentlyContinue
    $c = Start-Mpv 'c'
    $env:FAKE_IGNORE_AUTH = '1'
    try { $null = Start-Helper 'c' } finally { Remove-Item Env:FAKE_IGNORE_AUTH }
    $ok = Wait-Until { (Reports $c) -match 'without its password' } 20
    Start-Sleep 1
    Check 'an engine without its password is refused and stopped' ($ok -and (Engines).Count -eq 0) ("reports: {0}; engines={1}" -f ((Reports $c) -join ' | '), (Engines).Count)

    # 5. The watchdog: the engine goes once no player uses it, even when that player is killed and other mpv
    #    windows (a, b, c, idle, no helper any more) stay open. Only d's helper uses it; killing mpv d ends the
    #    helper (its IPC pipe breaks), and then the watchdog stops the engine.
    $d = Start-Mpv 'd'
    $dp = Get-CimInstance Win32_Process -Filter "Name='mpv.exe'" | Where-Object { $_.CommandLine -match 'wt-eng-d' }
    $hd = Start-Helper 'd'
    $ok = Wait-Until { (Base (Reports $d)) -and (Engines).Count -eq 1 } 20
    Stop-Process -Id $dp.ProcessId -Force
    $helperGone = Wait-Until { $hd.HasExited } 10
    $gone = Wait-Until { (Engines).Count -eq 0 } 30
    $others = @(Get-CimInstance Win32_Process -Filter "Name='mpv.exe'" | Where-Object { $_.CommandLine -match 'wt-eng-[abc]' }).Count
    Check 'a killed player: its helper ends, the engine goes, other mpv windows do not hold it' ($ok -and $helperGone -and $gone -and $others -eq 3) ("helper exited={0} engines={1} other mpv={2}" -f $hd.HasExited, (Engines).Count, $others)
} finally {
    foreach ($p in $procs) { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
    Get-CimInstance Win32_Process -Filter "Name='mpv.exe'" | Where-Object { $_.CommandLine -match 'wt-eng-' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Engines | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep 1
    Remove-Item -Recurse -Force $run -ErrorAction SilentlyContinue
}
if ($failures) { Write-Host "$failures check(s) failed"; exit 1 }
Write-Host 'All checks passed'
