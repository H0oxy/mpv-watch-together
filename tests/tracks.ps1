# Self-check of watch-together\tracks.lua (which subtitle and audio files go with which video) on torrent
# layouts; offline, nothing but mpv.
# Usage: powershell -ExecutionPolicy Bypass -File tests\tracks.ps1 -Mpv C:\path\mpv.exe
param([string]$Mpv = 'mpv')
$log = Join-Path $env:TEMP ('wt-tracks-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
$p = Start-Process $Mpv -PassThru -NoNewWindow -RedirectStandardOutput $log -ArgumentList @('--no-config', '--idle=yes',
    '--vo=null', '--ao=null', '--msg-level=all=no,tracks=info', "`"--script=$(Join-Path $PSScriptRoot 'tracks.lua')`"")
# A Lua error leaves mpv idle with no verdict: it is stopped, and only the closing line counts.
if (-not $p.WaitForExit(30000)) { Stop-Process -Id $p.Id -Force }
$out = Get-Content -Raw -Encoding UTF8 $log
Remove-Item $log -ErrorAction SilentlyContinue
Write-Host $out
if ($out -notmatch 'all checks passed') { exit 1 }
