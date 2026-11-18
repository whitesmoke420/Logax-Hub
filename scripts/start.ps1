# Opens the LOGAX Hub: makes sure the local AI is running, grabs the latest
# version of the hub if an update address is set, then opens it in the browser.

$HubDir = Split-Path -Parent $PSScriptRoot
$Port = 8787
$ConfigPath = Join-Path $HubDir "hub-config.json"

function Test-Url($url) { try { Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 3 | Out-Null; return $true } catch { return $false } }

# 1. Start the local AI if it isn't running
if (-not (Test-Url "http://localhost:11434/api/tags")) {
    $ollama = Get-Command ollama -ErrorAction SilentlyContinue
    $exe = if ($ollama) { $ollama.Source } else { Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama.exe" }
    if (Test-Path $exe) {
        Start-Process $exe -ArgumentList "serve" -WindowStyle Hidden
        for ($i = 0; $i -lt 20 -and -not (Test-Url "http://localhost:11434/api/tags"); $i++) { Start-Sleep -Seconds 1 }
    }
}

# 2. Get the newest hub, if an update address is set. Each file is only
#    replaced if it downloaded completely, so a bad connection can't break it.
try {
    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    if ($cfg.updateUrl) {
        $base = $cfg.updateUrl -replace 'index\.html$', ''
        $files = @(
            @{ Name = "index.html";        Check = "</html>" },
            @{ Name = "scripts/server.ps1"; Check = "HttpListener" },
            @{ Name = "scripts/start.ps1";  Check = "# 4. Open it" }
        )
        foreach ($f in $files) {
            try {
                $tmp = Join-Path $env:TEMP ("logax-" + ($f.Name -replace '/', '-'))
                Invoke-WebRequest ($base + $f.Name) -UseBasicParsing -OutFile $tmp -TimeoutSec 15
                $text = Get-Content $tmp -Raw
                if ((Get-Item $tmp).Length -gt 500 -and $text -match "LOGAX" -and $text.Contains($f.Check)) {
                    Copy-Item $tmp (Join-Path $HubDir ($f.Name -replace '/', '\')) -Force
                }
            } catch { }  # this file didn't come through: keep the current copy
        }
    }
} catch { }  # no internet or no update: keep the current copy

# 3. Start the little local web server for the hub. Any copy left running from
#    before (maybe from an older LOGAX-Hub folder) is closed first, so the hub
#    always shows the files in this folder.
try {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop |
        Where-Object { $_.CommandLine -match 'server\.ps1' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
} catch { }
if (-not (Test-Url "http://localhost:$Port/index.html")) {
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSScriptRoot\server.ps1`" -Port $Port" -WindowStyle Hidden
    for ($i = 0; $i -lt 10 -and -not (Test-Url "http://localhost:$Port/index.html"); $i++) { Start-Sleep -Milliseconds 500 }
}

# 4. Open it in its own app window (Edge app mode: no tabs or address bar).
#    Falls back to the normal browser if Edge isn't found.
$url = "http://localhost:$Port/"
$edge = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($edge) {
    Start-Process $edge -ArgumentList "--app=$url", "--window-size=1320,900"
} else {
    Start-Process $url
}
