# update.ps1 against the real GitHub releases (needs the network): the check must find a release newer
# than 0.0.1, and installing a tag must give exactly that tag's files from git.
# Usage: powershell -ExecutionPolicy Bypass -File tests\update.ps1 [-Tag v1.5.2]
param([string]$Tag = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$updater = Join-Path $root 'watch-together\update.ps1'
$failures = 0
function Check([string]$name, [bool]$ok, [string]$detail) {
    $mark = if ($ok) { 'PASS' } else { 'FAIL'; $script:failures++ }
    Write-Host ("[{0}] {1} {2}" -f $mark, $name, $detail)
}

$out = & powershell -NoProfile -ExecutionPolicy Bypass -File $updater -Dir $env:TEMP -Current 0.0.1
Check 'an older version sees a release' ("$out" -match '^available v\d') "$out"
if (-not $Tag) { $Tag = ("$out" -split ' ')[1] }

$dir = Join-Path $env:TEMP ('wt-update-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $dir | Out-Null
try {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $updater -Dir $dir -Current 0.0.1 -Install $Tag
    Check "install $Tag reports success" ("$out" -eq "updated $Tag") "$out"
    # Releases are tagged on GitHub; git show gives the bytes GitHub serves (before checkout conversion).
    git -C $root fetch --quiet --tags origin
    $expected = @(git -C $root ls-tree --name-only "${Tag}:watch-together")
    $got = @(Get-ChildItem $dir -File | ForEach-Object { $_.Name })
    $missing = @($expected | Where-Object { $got -notcontains $_ })
    Check 'every file of the tag is installed' ($expected.Count -gt 0 -and $missing.Count -eq 0) ($missing -join ', ')
    $diff = @(foreach ($n in $expected) {
        $tmp = Join-Path $env:TEMP "wt-update-expected-$n"
        cmd /c "git -C `"$root`" show `"${Tag}:watch-together/$n`" > `"$tmp`""
        $same = (Test-Path (Join-Path $dir $n)) -and (Get-FileHash $tmp).Hash -eq (Get-FileHash (Join-Path $dir $n)).Hash
        Remove-Item -Force $tmp
        if (-not $same) { $n }
    })
    Check 'installed files are byte-identical to the tag' ($expected.Count -gt 0 -and $diff.Count -eq 0) ($diff -join ', ')
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $updater -Dir $dir -Current 0.0.1 -Install 'v1.0;calc'
    Check 'a malformed tag is refused' ("$out" -like 'error bad tag*') "$out"
} finally {
    Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
}
if ($failures) { Write-Host "$failures check(s) failed"; exit 1 }
Write-Host 'All checks passed'
