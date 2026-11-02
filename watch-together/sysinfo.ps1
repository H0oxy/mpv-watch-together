# Prints one JSON line for main.lua. ASCII only.
# Default: the Windows display language and the Steam name of the account that signed in last
# (from Steam's loginusers.vdf), so the room shows Steam names.
# -Addresses: this PC's IPv4 addresses on active interfaces, for the host's invite.
param([switch]$Addresses)
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

if ($Addresses) {
    $ips = @(foreach ($nic in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.OperationalStatus -ne 'Up' -or $nic.NetworkInterfaceType -eq 'Loopback') { continue }
        foreach ($a in $nic.GetIPProperties().UnicastAddresses) {
            if ($a.Address.AddressFamily -eq 'InterNetwork') { $a.Address.ToString() }
        }
    })
    ConvertTo-Json -Compress @{ ips = $ips }
    exit
}

$steam = ''
$root = (Get-ItemProperty 'HKCU:\Software\Valve\Steam').SteamPath
if ($root) {
    $vdf = Join-Path $root 'config\loginusers.vdf'
    if (Test-Path $vdf) {
        $text = [IO.File]::ReadAllText($vdf, [Text.Encoding]::UTF8)
        foreach ($m in [regex]::Matches($text, '"\d{17}"\s*\{([^}]*)\}')) {
            $body = $m.Groups[1].Value
            $name = [regex]::Match($body, '"PersonaName"\s*"((?:[^"\\]|\\.)*)"').Groups[1].Value
            if (-not $steam) { $steam = $name }  # fallback: first account listed
            if ($body -match '"MostRecent"\s*"1"') { $steam = $name; break }
        }
    }
}

ConvertTo-Json -Compress @{ lang = [Globalization.CultureInfo]::CurrentUICulture.Name; steam = ($steam -replace '\\(.)', '$1') }
