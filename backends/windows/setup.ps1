Set-StrictMode -Version 2.0
. "$PSScriptRoot\lib\common.ps1"

Require-Windows

Write-Info 'Relay Windows backend setup'
Require-Node
Ensure-EnvFile
Install-ServerDeps

$port = Get-BackendPort
$portInput = Read-Host "Backend port [$port]"
if (-not [string]::IsNullOrWhiteSpace($portInput)) {
  $port = $portInput
}
Set-EnvValue -Key 'PORT' -Value $port

Write-Host 'Choose network mode:'
Write-Host '  1) No tunnel / direct public address'
Write-Host '  2) Cloudflare Tunnel / named stable hostname'
Write-Host '  3) Cloudflare Quick Tunnel / temporary trycloudflare.com URL'
$networkMode = Read-Host 'Network mode [1/2/3, default 3]'
if ([string]::IsNullOrWhiteSpace($networkMode)) {
  $networkMode = '3'
}

$publicUrl = ''
switch ($networkMode) {
  '1' {
    Write-Info 'Direct mode'
    $publicUrl = Read-Host "Public address the app will use (e.g. https://agent.example.com or http://1.2.3.4:$port)"
    if ([string]::IsNullOrWhiteSpace($publicUrl)) {
      Write-Fail 'A public address is required in direct mode.'
    }
    if ($publicUrl -notmatch '^https?://') {
      $publicUrl = "http://$publicUrl"
      Write-Warn "No scheme given; assuming $publicUrl"
    }
    Set-EnvValue -Key 'HOST' -Value '0.0.0.0'
    Set-EnvValue -Key 'PUBLIC_BASE_URL' -Value $publicUrl
    Set-EnvValue -Key 'RELAY_TUNNEL_MODE' -Value 'none'
    Set-EnvValue -Key 'CLOUDFLARED_BIN' -Value ''
    Set-EnvValue -Key 'CLOUDFLARED_ARGS' -Value ''
  }
  '2' {
    if (-not (Test-Command 'cloudflared')) {
      Write-Fail 'cloudflared is required for Cloudflare Tunnel mode.'
    }
    Write-Info 'Cloudflare Tunnel mode'
    $publicHostname = Get-UrlHostname (Read-Host 'Public hostname for this backend (e.g. agent.example.com)')
    if ([string]::IsNullOrWhiteSpace($publicHostname)) {
      Write-Fail 'A hostname is required for Cloudflare Tunnel mode.'
    }
    $defaultTunnelName = Get-DefaultTunnelName
    $tunnelName = Read-Host "Cloudflare tunnel name [$defaultTunnelName]"
    if ([string]::IsNullOrWhiteSpace($tunnelName)) {
      $tunnelName = $defaultTunnelName
    }
    $tunnelName = ($tunnelName.ToLowerInvariant() -replace '[^a-z0-9_-]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($tunnelName)) {
      Write-Fail 'A tunnel name is required.'
    }
    $tunnelId = Ensure-NamedTunnel -Name $tunnelName
    Ensure-TunnelDnsRoute -TunnelName $tunnelName -Hostname $publicHostname

    $publicUrl = "https://$publicHostname"
    $configFile = Join-Path $Script:ServerDir "cloudflared-config\$tunnelName.yml"
    Write-NamedTunnelConfig -TunnelId $tunnelId -Hostname $publicHostname -Port $port -ConfigFile $configFile
    $cloudflaredBin = (Get-Command 'cloudflared').Source

    Set-EnvValue -Key 'HOST' -Value '127.0.0.1'
    Set-EnvValue -Key 'PUBLIC_BASE_URL' -Value $publicUrl
    Set-EnvValue -Key 'RELAY_TUNNEL_MODE' -Value 'cloudflare'
    Set-EnvValue -Key 'CLOUDFLARED_BIN' -Value $cloudflaredBin
    Set-EnvValue -Key 'CLOUDFLARED_ARGS' -Value "tunnel --config `"$configFile`" run $tunnelId"
  }
  '3' {
    if (-not (Test-Command 'cloudflared')) {
      Write-Fail 'cloudflared is required for Quick Tunnel mode.'
    }
    Write-Info 'Quick Tunnel mode'
    $cloudflaredBin = (Get-Command 'cloudflared').Source
    Set-EnvValue -Key 'HOST' -Value '127.0.0.1'
    Set-EnvValue -Key 'RELAY_TUNNEL_MODE' -Value 'quick'
    Set-EnvValue -Key 'CLOUDFLARED_BIN' -Value $cloudflaredBin
    Set-EnvValue -Key 'CLOUDFLARED_ARGS' -Value "tunnel --url http://127.0.0.1:$port"
  }
  default {
    Write-Fail "Invalid network mode: $networkMode"
  }
}

Register-RelayStartup
Stop-RelayServices
Start-RelayServices

if ($networkMode -eq '3') {
  Write-Info 'Waiting for the tunnel URL...'
  $publicUrl = Wait-ForTunnelUrl
  if ([string]::IsNullOrWhiteSpace($publicUrl)) {
    Write-Fail "Could not detect a trycloudflare URL. Check logs in $Script:LogDir."
  }
  Set-EnvValue -Key 'PUBLIC_BASE_URL' -Value $publicUrl
  Write-Info "Tunnel URL: $publicUrl"
}

Write-Info 'Generating credential QR'
Push-Location $Script:ServerDir
try {
  if ([string]::IsNullOrWhiteSpace($publicUrl)) {
    & npm run credential
  } else {
    & npm run credential -- --url $publicUrl
  }
} finally {
  Pop-Location
}

Write-Info 'Done. Import the generated credential in Relay and enter the password you just set.'
