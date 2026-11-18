# LOGAX Hub setup (Windows)
# Installs the free local AI (Ollama), downloads an AI model that fits this PC,
# and puts a "LOGAX Hub" shortcut on the desktop. Safe to run again.

$ErrorActionPreference = "Stop"
$HubDir = Split-Path -Parent $PSScriptRoot
$ConfigPath = Join-Path $HubDir "hub-config.json"
# The LOGAX Hub.exe launcher sits one folder up from the "app" folder.
$Root = Split-Path -Parent $HubDir
$Launcher = Join-Path $Root "LOGAX Hub.exe"
if (-not (Test-Path $Launcher)) { $Root = $HubDir; $Launcher = Join-Path $HubDir "Start LOGAX Hub.bat" }

# Files from a downloaded zip are marked "from the internet", which makes Windows
# warn every time they open. Clear that mark so the hub opens without warnings.
Get-ChildItem -Path $Root -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
# Tuck the behind-the-scenes files out of sight.
if ($Root -ne $HubDir) { try { (Get-Item $HubDir -Force).Attributes = "Directory, Hidden" } catch { } }

function Say($msg, $color = "White") { Write-Host $msg -ForegroundColor $color }

Say ""
Say "=== LOGAX Hub setup ===" "Yellow"
Say ""

# 1. Install Ollama if it isn't here yet
$ollama = Get-Command ollama -ErrorAction SilentlyContinue
if (-not $ollama) {
    $localOllama = Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama.exe"
    if (Test-Path $localOllama) { $ollama = $localOllama }
}
if (-not $ollama) {
    Say "Step 1 of 3: Installing the free local AI (Ollama)..." "Cyan"
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install -e --id Ollama.Ollama --accept-package-agreements --accept-source-agreements
        $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
        $ollama = Get-Command ollama -ErrorAction SilentlyContinue
        if (-not $ollama) {
            $localOllama = Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama.exe"
            if (Test-Path $localOllama) { $ollama = $localOllama }
        }
    }
    if (-not $ollama) {
        Say "Couldn't install Ollama automatically." "Red"
        Say "Opening the download page. Install it, then run this setup again."
        Start-Process "https://ollama.com/download/windows"
        Read-Host "Press Enter to close"
        exit 1
    }
} else {
    Say "Step 1 of 3: Local AI (Ollama) is already installed." "Green"
}
$OllamaExe = if ($ollama -is [string]) { $ollama } else { $ollama.Source }

# Make sure Ollama is running
function Test-Ollama { try { Invoke-RestMethod "http://localhost:11434/api/tags" -TimeoutSec 3 | Out-Null; return $true } catch { return $false } }
if (-not (Test-Ollama)) {
    Start-Process $OllamaExe -ArgumentList "serve" -WindowStyle Hidden
    for ($i = 0; $i -lt 20 -and -not (Test-Ollama); $i++) { Start-Sleep -Seconds 1 }
}

# 2. Pick a model that fits this PC
Say ""
Say "Step 2 of 3: Checking this PC to pick the right AI size..." "Cyan"
$vramMB = 0
$smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if ($smi) {
    try { $vramMB = [int](& nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | Select-Object -First 1) } catch {}
}
$ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)

if ($vramMB -ge 6000 -or $ramGB -ge 16) {
    $model = "llama3.1:8b"
    $sizeNote = "about 5 GB"
} else {
    $model = "llama3.2:3b"
    $sizeNote = "about 2 GB"
}
Say ("   Graphics memory: " + $(if ($vramMB) { "$vramMB MB" } else { "no NVIDIA card found" }) + ",  RAM: $ramGB GB")
Say "   Using model: $model ($sizeNote download)" "Green"
Say ""
Say "   Downloading the AI model. This is a one-time download and can take a while." "Yellow"
& $OllamaExe pull $model

# Save the choice for the hub
$config = @{ model = $model; updateUrl = "" }
if (Test-Path $ConfigPath) {
    try {
        $old = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        if ($old.updateUrl) { $config.updateUrl = $old.updateUrl }
    } catch {}
}
$config | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8

# 3. Desktop shortcut
Say ""
Say "Step 3 of 3: Adding a LOGAX Hub shortcut to the desktop..." "Cyan"
$shell = New-Object -ComObject WScript.Shell
$places = @([Environment]::GetFolderPath("Desktop"), [Environment]::GetFolderPath("Programs"))
foreach ($place in $places) {
    if (-not $place) { continue }
    $lnk = $shell.CreateShortcut((Join-Path $place "LOGAX Hub.lnk"))
    $lnk.TargetPath = $Launcher
    $lnk.WorkingDirectory = $Root
    $lnk.WindowStyle = 7
    $lnk.IconLocation = (Join-Path $HubDir "logax.ico") + ",0"
    $lnk.Description = "Open the LOGAX Hub"
    $lnk.Save()
}

Say ""
Say "All set! Double-click 'LOGAX Hub' on your desktop to open it." "Green"
Say ""
Read-Host "Press Enter to open the hub now"
Start-Process $Launcher
