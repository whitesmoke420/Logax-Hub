# Tiny local web server for the LOGAX Hub (only reachable from this PC).
# It serves the hub page and passes the hub's Shopify requests to Shopify,
# because a web page isn't allowed to talk to the Shopify Admin API directly.
# The Shopify keys are kept in shopify.json in the LOGAX-Hub folder on this
# PC only. They are never sent anywhere except to Shopify.
param([int]$Port = 8787)

$HubDir = Split-Path -Parent $PSScriptRoot
$ShopFile = Join-Path $HubDir "shopify.json"
$ApiVersion = "2026-10"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
try { $listener.Start() } catch { exit 0 }  # already running

$types = @{ ".html" = "text/html; charset=utf-8"; ".json" = "application/json" }
$allowed = @("index.html", "hub-config.json")
$utf8 = New-Object System.Text.UTF8Encoding($false)
$script:token = $null
# For testing only: LOGAX_SHOP_BASE points the hub at a pretend Shopify.
function Shop-Base($cfg) { if ($env:LOGAX_SHOP_BASE) { return $env:LOGAX_SHOP_BASE } return "https://$($cfg.shop)" }
$script:tokenUntil = [datetime]::MinValue

function Send-Text($res, [int]$code, [string]$type, [string]$text) {
    $bytes = $utf8.GetBytes($text)
    $res.StatusCode = $code
    $res.ContentType = $type
    $res.Headers.Add("Cache-Control", "no-store")
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
}
function Send-Json($res, [int]$code, $obj) { Send-Text $res $code "application/json; charset=utf-8" ($obj | ConvertTo-Json -Depth 6 -Compress) }

function Read-Body($req) {
    $reader = New-Object System.IO.StreamReader($req.InputStream, $utf8)
    try { return $reader.ReadToEnd() } finally { $reader.Close() }
}

function Read-Shop {
    if (-not (Test-Path $ShopFile)) { return $null }
    try { return Get-Content $ShopFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Clean-Shop([string]$shop) {
    $s = ("" + $shop).Trim().ToLower() -replace '^https?://', '' -replace '/.*$', ''
    if ($s -notmatch '\.myshopify\.com$') { $s = $s + ".myshopify.com" }
    if ($s -notmatch '^[a-z0-9][a-z0-9-]*\.myshopify\.com$') { return $null }
    return $s
}

# Shopify gives a key that lasts about a day. Get a new one when it runs out.
function Get-ShopToken($cfg, [switch]$Fresh) {
    if (-not $Fresh -and $script:token -and (Get-Date) -lt $script:tokenUntil) { return $script:token }
    $body = "grant_type=client_credentials&client_id=" + [uri]::EscapeDataString($cfg.clientId) + "&client_secret=" + [uri]::EscapeDataString($cfg.clientSecret)
    $r = Invoke-RestMethod -Method Post -Uri ((Shop-Base $cfg) + "/admin/oauth/access_token") -ContentType "application/x-www-form-urlencoded" -Body $body -TimeoutSec 20
    if (-not $r.access_token) { throw "No key came back from Shopify." }
    $seconds = 86399
    if ($r.expires_in) { $seconds = [int]$r.expires_in }
    $script:token = $r.access_token
    $script:tokenUntil = (Get-Date).AddSeconds([Math]::Max(60, $seconds - 300))
    return $script:token
}

function Invoke-Shop($cfg, [string]$json) {
    $uri = (Shop-Base $cfg) + "/admin/api/$ApiVersion/graphql.json"
    $bytes = $utf8.GetBytes($json)
    for ($try = 0; $try -lt 2; $try++) {
        $tok = Get-ShopToken $cfg -Fresh:($try -gt 0)
        try {
            $r = Invoke-WebRequest -Method Post -Uri $uri -UseBasicParsing -TimeoutSec 30 -ContentType "application/json; charset=utf-8" -Headers @{ "X-Shopify-Access-Token" = $tok } -Body $bytes
            $stream = $r.RawContentStream
            $stream.Position = 0
            return (New-Object System.IO.StreamReader($stream, $utf8)).ReadToEnd()
        } catch {
            $status = 0
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            if ($status -eq 401 -and $try -eq 0) { continue }  # key ran out: get a new one and try again
            throw
        }
    }
}

# Pass the hub's AI requests to the local AI (Ollama) on this PC, so the page
# only ever talks to this server.
$AiBase = "http://127.0.0.1:11434"
function Send-Ai($res, [string]$method, [string]$path, [string]$body) {
    try {
        if ($method -eq "GET") {
            $r = Invoke-WebRequest -Uri ($AiBase + $path) -UseBasicParsing -TimeoutSec 10
        } else {
            $r = Invoke-WebRequest -Method Post -Uri ($AiBase + $path) -UseBasicParsing -TimeoutSec 900 -ContentType "application/json; charset=utf-8" -Body $utf8.GetBytes($body)
        }
        $stream = $r.RawContentStream
        $stream.Position = 0
        Send-Text $res 200 "application/json; charset=utf-8" ((New-Object System.IO.StreamReader($stream, $utf8)).ReadToEnd())
    } catch {
        $status = 0
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        if ($status -eq 404) { Send-Json $res 404 @{ error = "no_model" } }
        elseif ($status -gt 0) { Send-Json $res 502 @{ error = "ai_error" } }
        else { Send-Json $res 502 @{ error = "no_ai" } }
    }
}

function Handle-Api($ctx, [string]$name) {
    $req = $ctx.Request; $res = $ctx.Response
    # Only the hub page itself may use these. Other websites are turned away.
    $origin = $req.Headers["Origin"]
    if ($origin -and $origin -ne "http://localhost:$Port") { Send-Json $res 403 @{ error = "Not allowed." }; return }
    if ($req.HttpMethod -ne "GET" -and $req.ContentType -notmatch '^application/json') { Send-Json $res 415 @{ error = "Not allowed." }; return }

    switch ($name) {
        "api/shopify/status" {
            $cfg = Read-Shop
            if ($cfg) { Send-Json $res 200 @{ connected = $true; shop = $cfg.shop } } else { Send-Json $res 200 @{ connected = $false } }
        }
        "api/shopify/connect" {
            $in = (Read-Body $req) | ConvertFrom-Json
            $shop = Clean-Shop $in.shop
            if (-not $shop) { Send-Json $res 400 @{ ok = $false; error = "That store address doesn't look right. It should end in .myshopify.com." }; return }
            if (-not $in.clientId -or -not $in.clientSecret) { Send-Json $res 400 @{ ok = $false; error = "Paste both the Client ID and the Secret." }; return }
            $cfg = [pscustomobject]@{ shop = $shop; clientId = ("" + $in.clientId).Trim(); clientSecret = ("" + $in.clientSecret).Trim() }
            try {
                $script:token = $null
                Get-ShopToken $cfg -Fresh | Out-Null
                ($cfg | ConvertTo-Json) | Set-Content -Path $ShopFile -Encoding UTF8
                Send-Json $res 200 @{ ok = $true; shop = $shop }
            } catch {
                $script:token = $null
                Send-Json $res 200 @{ ok = $false; error = "Shopify didn't accept those details. Check the store address, Client ID and Secret, and that the app is installed on the store." }
            }
        }
        "api/shopify/disconnect" {
            if (Test-Path $ShopFile) { Remove-Item $ShopFile -Force }
            $script:token = $null
            Send-Json $res 200 @{ ok = $true }
        }
        "api/shopify/graphql" {
            $cfg = Read-Shop
            if (-not $cfg) { Send-Json $res 400 @{ error = "not_connected" }; return }
            $json = Read-Body $req
            # The hub only reads from the store. It never changes anything.
            if ($json -match '(?i)\bmutation\b') { Send-Json $res 403 @{ error = "The hub only reads from the store." }; return }
            try { Send-Text $res 200 "application/json; charset=utf-8" (Invoke-Shop $cfg $json) }
            catch { Send-Json $res 502 @{ error = "shopify_unreachable" } }
        }
        "api/ai/tags" { Send-Ai $res "GET" "/api/tags" $null }
        "api/ai/chat" { Send-Ai $res "POST" "/api/chat" (Read-Body $req) }
        default { Send-Json $res 404 @{ error = "Not found." } }
    }
}

while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    $res = $ctx.Response
    try {
        $name = $ctx.Request.Url.AbsolutePath.TrimStart("/")
        if ($name -eq "") { $name = "index.html" }
        if ($name.StartsWith("api/")) {
            Handle-Api $ctx $name
        } else {
            $path = Join-Path $HubDir $name
            if (($allowed -contains $name) -and (Test-Path $path)) {
                $bytes = [System.IO.File]::ReadAllBytes($path)
                $ext = [System.IO.Path]::GetExtension($path)
                $res.ContentType = $types[$ext]
                $res.Headers.Add("Cache-Control", "no-store")
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
            } else {
                $res.StatusCode = 404
            }
        }
    } catch {
        try { $res.StatusCode = 500 } catch { }
    }
    try { $res.Close() } catch { }
}
