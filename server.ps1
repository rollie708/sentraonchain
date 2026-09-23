# SENTRA server — static hosting + secure API layer.
# Run: powershell -ExecutionPolicy Bypass -File server.ps1  (serves ./ on http://localhost:8080/)
# Env: SENTRA_TOKEN_ADDRESS, SENTRA_X_URL, SENTRA_LAUNCH_AT, SENTRA_ADMIN_TOKEN,
#      ALCHEMY_API_KEY, MORALIS_API_KEY, OPENAI_API_KEY, SUPABASE_URL, SUPABASE_ANON_KEY
param([int]$Port = 8080)
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$dataDir = Join-Path $root "data"
if (!(Test-Path $dataDir)) { New-Item -ItemType Directory $dataDir | Out-Null }
$overridesFile = Join-Path $dataDir "overrides.json"
if (!(Test-Path $overridesFile)) { '{}' | Out-File $overridesFile -Encoding utf8 }

$mime = @{ ".html"="text/html; charset=utf-8"; ".css"="text/css"; ".js"="application/javascript";
  ".json"="application/json"; ".svg"="image/svg+xml"; ".png"="image/png"; ".ico"="image/x-icon" }
$rates = @{}   # ip -> [DateTime[]]
function Test-Rate($ip) {
  $now = Get-Date; $win = New-TimeSpan -Minutes 1
  if (!$rates.ContainsKey($ip)) { $rates[$ip] = @() }
  $rates[$ip] = @($rates[$ip] | Where-Object { ($now - $_) -lt $win })
  if ($rates[$ip].Count -ge 120) { return $false }
  $rates[$ip] += $now; return $true
}
function Send-Json($ctx, $code, $obj) {
  $bytes = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 8 -Compress))
  $ctx.Response.StatusCode = $code; $ctx.Response.ContentType = "application/json"
  $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length); $ctx.Response.Close()
}
function Get-Body($ctx) {
  $sr = New-Object IO.StreamReader($ctx.Request.InputStream); $t = $sr.ReadToEnd(); $sr.Close()
  if ([string]::IsNullOrWhiteSpace($t)) { return @{} }
  try { return ($t | ConvertFrom-Json) } catch { return @{} }
}
function Get-Overrides() {
  try { return (Get-Content $overridesFile -Raw | ConvertFrom-Json) } catch { return (New-Object PSObject) }
}

$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "SENTRA live on http://localhost:$Port/  (root: $root)"
while ($listener.IsListening) {
  $ctx = $listener.GetContext()
  try {
    $req = $ctx.Request; $ip = $req.RemoteEndPoint.Address.ToString()
    $path = $req.Url.LocalPath; $method = $req.HttpMethod
    if ($path -like "/api/*" -and !(Test-Rate $ip)) { Send-Json $ctx 429 @{error="rate-limited"; message="Too many requests. Slow down."}; continue }

    if ($path -eq "/api/health") { Send-Json $ctx 200 @{ok=$true; time=(Get-Date).ToUniversalTime().ToString("o")}; continue }

    if ($path -eq "/api/config" -and $method -eq "GET") {
      $ov = Get-Overrides
      Send-Json $ctx 200 @{
        tokenAddress = if ($env:SENTRA_TOKEN_ADDRESS) { $env:SENTRA_TOKEN_ADDRESS } elseif ($ov.tokenAddress) { $ov.tokenAddress } else { "" }
        xUrl = if ($env:SENTRA_X_URL) { $env:SENTRA_X_URL } elseif ($ov.xUrl) { $ov.xUrl } else { "" }
        launchAt = if ($env:SENTRA_LAUNCH_AT) { $env:SENTRA_LAUNCH_AT } elseif ($ov.launchAt) { $ov.launchAt } else { "2026-09-25T13:00:00Z" }
        telegramUrl = "https://t.me/sentraonchain"
        keyed = @{ alchemy = ![string]::IsNullOrEmpty($env:ALCHEMY_API_KEY); moralis = ![string]::IsNullOrEmpty($env:MORALIS_API_KEY); openai = ![string]::IsNullOrEmpty($env:OPENAI_API_KEY) }
      }; continue
    }

    if ($path -like "/api/keyed/*" -and $method -eq "POST") {
      $provider = ($path -split "/")[-1]; $body = Get-Body $ctx
      if ($provider -eq "alchemy") {
        if ([string]::IsNullOrEmpty($env:ALCHEMY_API_KEY)) { Send-Json $ctx 501 @{error="not-configured"; message="Alchemy key not set (ALCHEMY_API_KEY)."}; continue }
        $net = if ($body.network) { $body.network } else { "eth-mainnet" }
        $wc = New-Object Net.WebClient; $wc.Headers["Content-Type"] = "application/json"
        try { $out = $wc.UploadString("https://$net.g.alchemy.com/v2/$($env:ALCHEMY_API_KEY)", ($body.payload | ConvertTo-Json -Depth 8 -Compress)); Send-Json $ctx 200 @{data=($out|ConvertFrom-Json)} }
        catch { Send-Json $ctx 502 @{error="unavailable"; message="Alchemy request failed."} }
        continue
      }
      if ($provider -eq "moralis") {
        if ([string]::IsNullOrEmpty($env:MORALIS_API_KEY)) { Send-Json $ctx 501 @{error="not-configured"; message="Moralis key not set (MORALIS_API_KEY)."}; continue }
        $target = $body.path
        if (!$target -or $target -notmatch "^[a-zA-Z0-9/_\-?=&.]+$") { Send-Json $ctx 400 @{error="invalid"; message="Invalid Moralis path."}; continue }
        $wc = New-Object Net.WebClient; $wc.Headers["X-API-Key"] = $env:MORALIS_API_KEY
        try { $out = $wc.DownloadString("https://deep-index.moralis.io/api/v2.2/$target"); Send-Json $ctx 200 @{data=($out|ConvertFrom-Json)} }
        catch { Send-Json $ctx 502 @{error="unavailable"; message="Moralis request failed."} }
        continue
      }
      if ($provider -eq "openai") {
        if ([string]::IsNullOrEmpty($env:OPENAI_API_KEY)) { Send-Json $ctx 501 @{error="not-configured"; message="OpenAI key not set (OPENAI_API_KEY)."}; continue }
        Send-Json $ctx 501 @{error="unsupported"; message="LLM-assisted parsing is stubbed: facts must come from providers. Wire prompts in README step 4."}
        continue
      }
      Send-Json $ctx 404 @{error="not-found"; message="Unknown provider."}; continue
    }

    if ($path -eq "/api/admin/config" -and $method -eq "POST") {
      $tok = $req.Headers["x-admin-token"]
      $required = $env:SENTRA_ADMIN_TOKEN
      if ($required -and $tok -ne $required) { Send-Json $ctx 403 @{error="forbidden"; message="Bad admin token."}; continue }
      $body = Get-Body $ctx; $ov = Get-Overrides
      foreach ($k in @("tokenAddress","xUrl","launchAt")) { if ($body.$k -ne $null) { $ov | Add-Member -NotePropertyName $k -NotePropertyValue ([string]$body.$k) -Force } }
      ($ov | ConvertTo-Json -Compress) | Out-File $overridesFile -Encoding utf8
      Send-Json $ctx 200 @{ok=$true}; continue
    }

    if ($path -eq "/api/analytics" -and $method -eq "POST") {
      $body = Get-Body $ctx
      $line = (@{t=(Get-Date).ToUniversalTime().ToString("o"); ip=$ip; type=$body.type; data=$body.data} | ConvertTo-Json -Compress -Depth 5)
      Add-Content (Join-Path $dataDir "analytics.jsonl") $line
      Send-Json $ctx 200 @{ok=$true}; continue
    }

    # ---- static ----
    $rel = $path.TrimStart("/")
    if ([string]::IsNullOrEmpty($rel)) { $rel = "index.html" }
    $file = Join-Path $root $rel
    if (!(Test-Path $file -PathType Leaf) -and $path -notlike "/api/*") {
      $ext = [IO.Path]::GetExtension($file)
      if ([string]::IsNullOrEmpty($ext)) { $file = Join-Path $root "index.html" }  # SPA fallback
    }
    if (Test-Path $file -PathType Leaf) {
      $bytes = [IO.File]::ReadAllBytes($file)
      $ctx.Response.ContentType = $mime[[IO.Path]::GetExtension($file).ToLower()]
      if (!$ctx.Response.ContentType) { $ctx.Response.ContentType = "application/octet-stream" }
      $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length); $ctx.Response.Close()
    } else { Send-Json $ctx 404 @{error="not-found"} }
  } catch { try { Send-Json $ctx 500 @{error="unavailable"} } catch {} }
}
