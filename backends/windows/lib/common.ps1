$ErrorActionPreference = 'Stop'

$Script:WindowsDir = Split-Path -Parent $PSScriptRoot
$Script:RootDir = Split-Path -Parent (Split-Path -Parent $Script:WindowsDir)
$Script:ServerDir = Join-Path $Script:RootDir 'server'
$Script:EnvFile = Join-Path $Script:ServerDir '.env'
$Script:EnvExample = Join-Path $Script:ServerDir '.env.example'

$Script:AppDataDir = if ($env:LOCALAPPDATA) {
  Join-Path $env:LOCALAPPDATA 'AgentDeck'
} else {
  Join-Path $env:USERPROFILE 'AppData\Local\AgentDeck'
}
$Script:LogDir = Join-Path $Script:AppDataDir 'logs'
$Script:RuntimeDir = Join-Path $Script:AppDataDir 'runtime'
$Script:BackendPidFile = Join-Path $Script:RuntimeDir 'backend.pid'
$Script:TunnelPidFile = Join-Path $Script:RuntimeDir 'tunnel.pid'
$Script:StartupTaskName = 'AgentDeck Backend'

function Write-Info {
  param([string]$Message)
  Write-Host ""
  Write-Host "==> $Message" -ForegroundColor Blue
}

function Write-Warn {
  param([string]$Message)
  Write-Host $Message -ForegroundColor Yellow
}

function Write-Fail {
  param([string]$Message)
  throw "AgentDeck: $Message"
}

function Test-Command {
  param([string]$Name)
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Require-Windows {
  if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Write-Fail 'This backend target must be run on Windows.'
  }
}

function Ensure-Dirs {
  New-Item -ItemType Directory -Force -Path $Script:LogDir, $Script:RuntimeDir | Out-Null
}

function Write-Utf8NoBom {
  param(
    [string]$Path,
    [string[]]$Lines
  )
  $encoding = New-Object System.Text.UTF8Encoding($false)
  $parent = Split-Path -Parent $Path
  if ($parent) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  [System.IO.File]::WriteAllLines($Path, $Lines, $encoding)
}

function Ensure-EnvFile {
  if (-not (Test-Path -LiteralPath $Script:EnvFile)) {
    Copy-Item -LiteralPath $Script:EnvExample -Destination $Script:EnvFile
    Write-Info 'Created server\.env from .env.example'
  }
}

function Set-EnvValue {
  param(
    [string]$Key,
    [string]$Value
  )
  Ensure-EnvFile
  $lines = @()
  if (Test-Path -LiteralPath $Script:EnvFile) {
    $lines = @(Get-Content -LiteralPath $Script:EnvFile)
  }
  $found = $false
  $next = foreach ($line in $lines) {
    if ($line -like "$Key=*") {
      $found = $true
      "$Key=$Value"
    } else {
      $line
    }
  }
  if (-not $found) {
    $next += "$Key=$Value"
  }
  Write-Utf8NoBom -Path $Script:EnvFile -Lines $next
}

function Get-EnvValue {
  param([string]$Key)
  if (-not (Test-Path -LiteralPath $Script:EnvFile)) {
    return ''
  }
  foreach ($line in Get-Content -LiteralPath $Script:EnvFile) {
    if ($line -like "$Key=*") {
      return $line.Substring($Key.Length + 1).Trim()
    }
  }
  return ''
}

function Get-BackendPort {
  $port = Get-EnvValue 'PORT'
  if ([string]::IsNullOrWhiteSpace($port)) {
    return '8787'
  }
  return $port
}

function Get-UrlHostname {
  param([string]$Value)
  $result = $Value.Trim()
  $result = $result -replace '^https?://', ''
  $result = ($result -split '/')[0]
  $result = ($result -split ':')[0]
  return $result
}

function Get-DefaultTunnelName {
  $name = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { 'windows' }
  $name = $name.ToLowerInvariant() -replace '[^a-z0-9_-]+', '-'
  $name = $name.Trim('-')
  if ([string]::IsNullOrWhiteSpace($name)) {
    $name = 'windows'
  }
  return "agentdeck-$name"
}

function Get-TunnelIdForName {
  param([string]$Name)
  $json = & cloudflared tunnel list --name $Name --output json 2>$null
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
    return ''
  }
  $items = @($json | ConvertFrom-Json)
  $item = $items | Where-Object { $_.name -eq $Name -and -not $_.deletedAt } | Select-Object -First 1
  if ($item) {
    return [string]$item.id
  }
  return ''
}

function Ensure-NamedTunnel {
  param([string]$Name)
  $certFile = Join-Path $env:USERPROFILE '.cloudflared\cert.pem'
  if (-not (Test-Path -LiteralPath $certFile)) {
    Write-Info 'Cloudflare login is required before creating a named tunnel.'
    & cloudflared tunnel login
  }

  $tunnelId = Get-TunnelIdForName -Name $Name
  if ([string]::IsNullOrWhiteSpace($tunnelId)) {
    Write-Info "Creating Cloudflare Tunnel: $Name"
    & cloudflared tunnel create $Name
    $tunnelId = Get-TunnelIdForName -Name $Name
  } else {
    Write-Info "Using existing Cloudflare Tunnel: $Name ($tunnelId)"
  }

  if ([string]::IsNullOrWhiteSpace($tunnelId)) {
    Write-Fail "Could not determine the Cloudflare Tunnel ID for $Name."
  }
  $credentialsFile = Join-Path $env:USERPROFILE ".cloudflared\$tunnelId.json"
  if (-not (Test-Path -LiteralPath $credentialsFile)) {
    Write-Fail "Missing tunnel credentials file: $credentialsFile"
  }
  return $tunnelId
}

function Ensure-TunnelDnsRoute {
  param(
    [string]$TunnelName,
    [string]$Hostname
  )
  & cloudflared tunnel route dns $TunnelName $Hostname
  if ($LASTEXITCODE -eq 0) {
    Write-Info "DNS route ensured: $Hostname -> $TunnelName"
    return
  }

  Write-Warn 'Cloudflare could not create the DNS route automatically.'
  Write-Warn "This usually means an A, AAAA, or CNAME record already exists for $Hostname."
  $overwrite = Read-Host "Overwrite the existing DNS record for $Hostname? [y/N]"
  if ($overwrite -in @('y', 'Y', 'yes', 'YES')) {
    & cloudflared tunnel route dns --overwrite-dns $TunnelName $Hostname
    if ($LASTEXITCODE -ne 0) {
      Write-Fail "Could not overwrite the DNS route for $Hostname."
    }
    Write-Info "DNS route overwritten: $Hostname -> $TunnelName"
  } else {
    Write-Warn 'Keeping the existing DNS record. The hostname may not reach this tunnel until you fix it in Cloudflare DNS.'
  }
}

function Write-NamedTunnelConfig {
  param(
    [string]$TunnelId,
    [string]$Hostname,
    [string]$Port,
    [string]$ConfigFile
  )
  $credentialsFile = (Join-Path $env:USERPROFILE ".cloudflared\$TunnelId.json") -replace '\\', '/'
  $lines = @(
    "tunnel: $TunnelId",
    "credentials-file: `"$credentialsFile`"",
    'ingress:',
    "  - hostname: $Hostname",
    "    service: http://127.0.0.1:$Port",
    '  - service: http_status:404'
  )
  Write-Utf8NoBom -Path $ConfigFile -Lines $lines
}

function Require-Node {
  if (-not (Test-Command 'node')) {
    Write-Fail 'Node.js 18+ is required. Install it from https://nodejs.org/.'
  }
  if (-not (Test-Command 'npm')) {
    Write-Fail 'npm is required.'
  }
  $major = [int]((& node -p "Number(process.versions.node.split('.')[0])").Trim())
  if ($major -lt 18) {
    Write-Fail "Node.js 18+ is required. Current version: $(& node -v)"
  }
}

function Install-ServerDeps {
  Push-Location $Script:ServerDir
  try {
    if (-not (Test-Path -LiteralPath (Join-Path $Script:ServerDir 'node_modules'))) {
      Write-Info 'Installing backend dependencies...'
      & npm install
    }
  } finally {
    Pop-Location
  }
}

function Split-CommandLine {
  param([string]$CommandLine)
  if ([string]::IsNullOrWhiteSpace($CommandLine)) {
    return @()
  }
  $matches = [regex]::Matches($CommandLine, '("[^"]*"|''[^'']*''|\S+)')
  $parts = @()
  foreach ($match in $matches) {
    $value = $match.Value
    if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
      $value = $value.Substring(1, $value.Length - 2)
    }
    $parts += $value
  }
  return $parts
}

function Test-PidFile {
  param([string]$PidFile)
  if (-not (Test-Path -LiteralPath $PidFile)) {
    return $false
  }
  $pidValue = (Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
  if (-not ($pidValue -match '^\d+$')) {
    return $false
  }
  return [bool](Get-Process -Id ([int]$pidValue) -ErrorAction SilentlyContinue)
}

function Start-AgentDeckProcess {
  param(
    [string]$Name,
    [string]$FilePath,
    [string[]]$ArgumentList,
    [string]$WorkingDirectory,
    [string]$PidFile,
    [string]$OutLog,
    [string]$ErrLog
  )
  Ensure-Dirs
  if (Test-PidFile -PidFile $PidFile) {
    Write-Info "$Name is already running."
    return
  }
  Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
  $process = Start-Process -FilePath $FilePath `
    -ArgumentList $ArgumentList `
    -WorkingDirectory $WorkingDirectory `
    -RedirectStandardOutput $OutLog `
    -RedirectStandardError $ErrLog `
    -WindowStyle Hidden `
    -PassThru
  Write-Utf8NoBom -Path $PidFile -Lines @([string]$process.Id)
  Write-Info "$Name started (PID $($process.Id))."
}

function Stop-AgentDeckProcess {
  param(
    [string]$Name,
    [string]$PidFile
  )
  if (-not (Test-Path -LiteralPath $PidFile)) {
    Write-Info "$Name is not running."
    return
  }
  $pidValue = (Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
  if ($pidValue -match '^\d+$') {
    & taskkill.exe /PID $pidValue /T /F | Out-Null
  }
  Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
  Write-Info "$Name stopped."
}

function Start-AgentDeckBackend {
  $nodePath = (Get-Command 'node').Source
  Start-AgentDeckProcess -Name 'backend' `
    -FilePath $nodePath `
    -ArgumentList @('server.js') `
    -WorkingDirectory $Script:ServerDir `
    -PidFile $Script:BackendPidFile `
    -OutLog (Join-Path $Script:LogDir 'backend.out.log') `
    -ErrLog (Join-Path $Script:LogDir 'backend.err.log')
}

function Start-AgentDeckTunnel {
  $mode = Get-EnvValue 'AGENTDECK_TUNNEL_MODE'
  if ([string]::IsNullOrWhiteSpace($mode) -or $mode -eq 'none') {
    Write-Info 'Tunnel mode is none; not starting cloudflared.'
    return
  }
  if (-not (Test-Command 'cloudflared')) {
    Write-Fail 'cloudflared is required for Cloudflare Tunnel mode.'
  }
  $cloudflaredBin = Get-EnvValue 'CLOUDFLARED_BIN'
  if ([string]::IsNullOrWhiteSpace($cloudflaredBin)) {
    $cloudflaredBin = (Get-Command 'cloudflared').Source
  }
  $argsText = Get-EnvValue 'CLOUDFLARED_ARGS'
  if ([string]::IsNullOrWhiteSpace($argsText)) {
    $port = Get-BackendPort
    $argsText = "tunnel --url http://127.0.0.1:$port"
  }
  $args = Split-CommandLine -CommandLine $argsText
  Start-AgentDeckProcess -Name 'tunnel' `
    -FilePath $cloudflaredBin `
    -ArgumentList $args `
    -WorkingDirectory $Script:ServerDir `
    -PidFile $Script:TunnelPidFile `
    -OutLog (Join-Path $Script:LogDir 'tunnel.out.log') `
    -ErrLog (Join-Path $Script:LogDir 'tunnel.err.log')
}

function Start-AgentDeckServices {
  Start-AgentDeckBackend
  Start-AgentDeckTunnel
}

function Stop-AgentDeckServices {
  Stop-AgentDeckProcess -Name 'tunnel' -PidFile $Script:TunnelPidFile
  Stop-AgentDeckProcess -Name 'backend' -PidFile $Script:BackendPidFile
}

function Register-AgentDeckStartup {
  $script = Join-Path $Script:WindowsDir 'start.ps1'
  $powershell = (Get-Command 'powershell.exe').Source
  $action = New-ScheduledTaskAction -Execute $powershell -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`""
  $trigger = New-ScheduledTaskTrigger -AtLogOn
  Register-ScheduledTask -TaskName $Script:StartupTaskName -Action $action -Trigger $trigger -Description 'Start AgentDeck backend for the current user.' -Force | Out-Null
  Write-Info "Startup task registered: $Script:StartupTaskName"
}

function Unregister-AgentDeckStartup {
  Unregister-ScheduledTask -TaskName $Script:StartupTaskName -Confirm:$false -ErrorAction SilentlyContinue
}

function Wait-ForTunnelUrl {
  $outLog = Join-Path $Script:LogDir 'tunnel.out.log'
  $errLog = Join-Path $Script:LogDir 'tunnel.err.log'
  for ($i = 0; $i -lt 45; $i++) {
    $text = ''
    foreach ($log in @($outLog, $errLog)) {
      if (Test-Path -LiteralPath $log) {
        $text += "`n" + (Get-Content -LiteralPath $log -Raw -ErrorAction SilentlyContinue)
      }
    }
    $match = [regex]::Matches($text, 'https://[a-z0-9-]+\.trycloudflare\.com') | Select-Object -Last 1
    if ($match) {
      return $match.Value
    }
    Start-Sleep -Seconds 1
  }
  return ''
}

function Show-AgentDeckStatus {
  $backendStatus = if (Test-PidFile -PidFile $Script:BackendPidFile) { 'running' } else { 'stopped' }
  $tunnelStatus = if (Test-PidFile -PidFile $Script:TunnelPidFile) { 'running' } else { 'stopped' }
  Write-Host "Backend: $backendStatus"
  Write-Host "Tunnel:  $tunnelStatus"
  Write-Host "Logs:    $Script:LogDir"
}
