# Installs the Anime4K shaders (https://github.com/bloc97/Anime4K) for mpv and two hotkeys. Called by install.bat.
# Prints "installed <dir>" or "error <text>". The release zip is checked against the pinned SHA256 before use.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Url = 'https://github.com/bloc97/Anime4K/releases/download/v4.0.1/Anime4K_v4.0.zip'
$Sha = '139CD282086457C5ADC79CAF7B75B8B825091D71C9B54958C18745FEA62D7ED7'
$conf = Join-Path $env:APPDATA 'mpv'
$dir = Join-Path $conf 'shaders'
try {
    $tmp = Join-Path $env:TEMP ('anime4k-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $tmp | Out-Null
    try {
        $zip = Join-Path $tmp 'a.zip'
        Invoke-WebRequest -UseBasicParsing $Url -OutFile $zip
        if ((Get-FileHash $zip -Algorithm SHA256).Hash -ne $Sha) { throw 'download is damaged (SHA256 differs)' }
        Expand-Archive $zip -DestinationPath (Join-Path $tmp 'x')
        New-Item -ItemType Directory -Force $dir | Out-Null
        Copy-Item (Join-Path $tmp 'x\*.glsl') $dir -Force
    } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }

    # Anime4K's own "Mode A (Fast)" chain. Ctrl+1 turns it on, Ctrl+0 off; the user's other lines stay untouched.
    $chain = 'Clamp_Highlights', 'Restore_CNN_M', 'Upscale_CNN_x2_M', 'AutoDownscalePre_x2', 'AutoDownscalePre_x4', 'Upscale_CNN_x2_S' |
        ForEach-Object { "~~/shaders/Anime4K_$_.glsl" }
    $input = Join-Path $conf 'input.conf'
    $old = if (Test-Path $input) { [IO.File]::ReadAllText($input) } else { '' }
    if ($old -notmatch 'Anime4K_') {  # also skips a setup the user made by hand
        $block = "`r`n# watch-together anime4k begin`r`n" +
            'CTRL+1 no-osd change-list glsl-shaders set "' + ($chain -join ';') + '"; show-text "Anime4K: on"' + "`r`n" +
            'CTRL+0 no-osd change-list glsl-shaders clr ""; show-text "Anime4K: off"' + "`r`n" +
            "# watch-together anime4k end`r`n"
        New-Item -ItemType Directory -Force $conf | Out-Null
        [IO.File]::AppendAllText($input, $block)  # append only: the user's bytes stay as they are
    }
    "installed $dir"
} catch { "error $($_.Exception.Message)" }
