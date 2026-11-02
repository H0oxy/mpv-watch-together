# Updater for watch-together: checks the latest GitHub release and installs it into the script folder.
# Prints one line for main.lua: "available <tag>", "latest", "updated <tag>" or "error <text>". ASCII only.
param(
    [Parameter(Mandatory)][string]$Dir,
    [Parameter(Mandatory)][string]$Current,
    [string]$Install = ''   # tag to install; empty means only check
)
$ErrorActionPreference = 'Stop'
$Repo = 'H0oxy/mpv-watch-together'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-Version([string]$tag) { [version]($tag -replace '^v', '') }

try {
    if (-not $Install) {
        $release = Invoke-RestMethod -UseBasicParsing "https://api.github.com/repos/$Repo/releases/latest"
        $tag = [string]$release.tag_name
        if ((Get-Version $tag) -gt (Get-Version $Current)) { "available $tag" } else { 'latest' }
        exit 0
    }

    if ($Install -notmatch '^v?\d+(\.\d+){1,3}$') { throw "bad tag $Install" }
    $files = Invoke-RestMethod -UseBasicParsing "https://api.github.com/repos/$Repo/contents/watch-together?ref=$Install"
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("watch-together-update-" + [guid]::NewGuid())
    New-Item -ItemType Directory $tmp | Out-Null
    try {
        # Download everything first, so a failed download never leaves a half-updated plugin.
        $names = @()
        foreach ($f in $files) {
            if ($f.type -ne 'file' -or $f.name -notmatch '^[\w.\-]+$') { continue }
            Invoke-WebRequest -UseBasicParsing $f.download_url -OutFile (Join-Path $tmp $f.name)
            $names += $f.name
        }
        $main = Join-Path $tmp 'main.lua'
        if (-not (Test-Path $main) -or -not (Select-String -Quiet -Path $main -Pattern 'watch-together')) {
            throw 'downloaded release has no valid main.lua'
        }
        foreach ($n in $names) { Copy-Item -Force (Join-Path $tmp $n) (Join-Path $Dir $n) }
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
    "updated $Install"
} catch {
    "error $($_.Exception.Message -replace '\s+', ' ')"
}
