$ErrorActionPreference = 'Stop'

$Script:WindowsDir = Split-Path -Parent $PSScriptRoot
$Script:RootDir = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $Script:WindowsDir))
$Script:ServerDir = Join-Path $Script:RootDir 'server'
$Script:EnvFile = Join-Path $Script:ServerDir '.env'
$Script:EnvExample = Join-Path $Script:ServerDir '.env.example'

# Per-user folders the agent CLI installers and `npm --global` write commands to.
$Script:AgentCliDirs = @(
  (Join-Path $env:USERPROFILE '.local\bin'),
  (Join-Path $env:USERPROFILE '.opencode\bin'),
  (Join-Path $env:LOCALAPPDATA 'agy\bin'),
  (Join-Path $env:APPDATA 'npm')
)
# Installers update the user PATH after this process has already started.
$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
$env:PATH = "$(Join-Path $Script:RootDir 'runtime\tools');$($Script:AgentCliDirs -join ';');$userPath;$env:PATH"
# Release bundles carry their own runtime; source checkouts still use PATH.
# It goes first, ahead of the user PATH, so a host Node of another major
# version cannot run the backend against the bundle's native node-pty build.
$Script:BundledNodeDir = Join-Path $Script:RootDir 'runtime\node'
if (Test-Path -LiteralPath (Join-Path $Script:BundledNodeDir 'node.exe')) {
  $env:PATH = "$Script:BundledNodeDir;$env:PATH"
}

$Script:AppDataDir = if ($env:LOCALAPPDATA) {
  Join-Path $env:LOCALAPPDATA 'Relay'
} else {
  Join-Path $env:USERPROFILE 'AppData\Local\Relay'
}
# Logs sit with the installation, next to server\.env and the credentials, so
# they are found where Relay was extracted. PID files stay per user.
$Script:LogDir = Join-Path $Script:RootDir 'logs'
$Script:RuntimeDir = Join-Path $Script:AppDataDir 'runtime'
$Script:BackendPidFile = Join-Path $Script:RuntimeDir 'backend.pid'
$Script:TunnelPidFile = Join-Path $Script:RuntimeDir 'tunnel.pid'
$Script:StartupTaskName = if ($env:RELAY_WINDOWS_TASK_NAME) { $env:RELAY_WINDOWS_TASK_NAME } else { 'Relay Backend' }
# User PATH entries Setup added, so a later sync or uninstall removes only them.
$Script:UserPathRecord = Join-Path $Script:AppDataDir 'user-path.json'

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
  throw "Relay: $Message"
}

# The Browser page drives a host Chrome, Chromium or Edge. Without one the rest
# of Relay works, so this only reminds. The check is the backend's own.
function Test-RelayBrowser {
  try {
    $found = (& node (Join-Path $Script:ServerDir 'scripts\check-browser.js') 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -eq 0 -and $found) {
      Write-Info "Browser page will use: $found"
      return
    }
  } catch {
    # Missing browser or check failure only warns; the rest of Relay works without it.
  }
  Write-Warn "No Chrome, Chromium or Edge found. Relay's Browser page needs one; everything else works without it."
  Write-Warn 'Install one, for example Microsoft Edge (https://www.microsoft.com/edge) or Google Chrome (https://www.google.com/chrome/).'
  Write-Warn 'Relay finds it once installed, without a restart. Or set RELAY_BROWSER in server\.env to its path, then restart Relay.'
}

# This machine's tailnet IPv4, or $null when Tailscale is missing or not up.
function Get-TailscaleIPv4 {
  $command = Get-Command tailscale -ErrorAction SilentlyContinue
  $bin = if ($command) { $command.Source } else { Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe' }
  if (-not (Test-Path -LiteralPath $bin)) { return $null }
  try {
    $ip = (& $bin ip -4 2>$null | Select-Object -First 1)
  } catch {
    return $null
  }
  if ($LASTEXITCODE -eq 0 -and "$ip".Trim() -match '^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}$') {
    $address = $null
    if ([ipaddress]::TryParse("$ip".Trim(), [ref]$address) -and $address.IPAddressToString -eq "$ip".Trim()) { return $address.IPAddressToString }
  }
  return $null
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

# Windows PowerShell 5.1's Get-Content reads a BOM-less file in the ANSI code
# page; pairing that with Write-Utf8NoBom re-encoded every non-ASCII character
# on each rewrite, so .env comments doubled in size per Set-EnvValue call.
function Read-Utf8Lines {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    return @()
  }
  return @([System.IO.File]::ReadAllLines($Path, (New-Object System.Text.UTF8Encoding($false))))
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
  if ($Key -notmatch '^[A-Z][A-Z0-9_]*$' -or $Value -match '[\r\n]') {
    Write-Fail 'Invalid environment key or multiline value.'
  }
  Ensure-EnvFile
  $lines = Read-Utf8Lines $Script:EnvFile
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
  foreach ($line in Read-Utf8Lines $Script:EnvFile) {
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
  return "relay-$name"
}

function Get-TunnelIdForName {
  param([string]$Name)
  $json = & cloudflared tunnel list --name $Name --output json 2>$null
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
    return ''
  }
  $items = @(($json -join "`n") | ConvertFrom-Json)
  $item = $items | Where-Object {
    $_.name -eq $Name -and (-not $_.PSObject.Properties['deletedAt'] -or -not $_.deletedAt)
  } | Select-Object -First 1
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
    & cloudflared tunnel login | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-Fail 'Cloudflare login failed.' }
  }

  $tunnelId = Get-TunnelIdForName -Name $Name
  if ([string]::IsNullOrWhiteSpace($tunnelId)) {
    Write-Info "Creating Cloudflare Tunnel: $Name"
    & cloudflared tunnel create $Name | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-Fail 'Cloudflare tunnel creation failed.' }
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
    Write-Fail 'Node.js 22+ is required. Install it from https://nodejs.org/.'
  }
  if (-not (Test-Command 'npm')) {
    Write-Fail 'npm is required.'
  }
  $major = [int]((& node -p "Number(process.versions.node.split('.')[0])").Trim())
  if ($major -lt 22) {
    Write-Fail "Node.js 22+ is required. Current version: $(& node -v)"
  }
}

function Install-ServerDeps {
  param([switch]$Force)
  Push-Location $Script:ServerDir
  try {
    $nodeModules = Join-Path $Script:ServerDir 'node_modules'
    & node -e "try { require('node-pty'); } catch (_) { process.exit(1); }"
    $ptyReady = $LASTEXITCODE -eq 0
    if ($Force -or (-not (Test-Path -LiteralPath $nodeModules)) -or
        (-not $ptyReady) -or
        (-not (Test-Path -LiteralPath (Join-Path $nodeModules 'ws')))) {
      Write-Info 'Installing backend dependencies...'
      & npm.cmd ci --omit=dev --no-audit --no-fund
      if ($LASTEXITCODE -ne 0) {
        Write-Fail 'Backend dependency installation failed.'
      }
      & node -e "require('node-pty')"
      if ($LASTEXITCODE -ne 0) {
        Write-Fail 'Backend PTY dependency failed to load.'
      }
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

function Start-RelayProcess {
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

function Stop-RelayProcess {
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

function Start-RelayBackend {
  $nodePath = (Get-Command 'node').Source
  Start-RelayProcess -Name 'backend' `
    -FilePath $nodePath `
    -ArgumentList @('server.js') `
    -WorkingDirectory $Script:ServerDir `
    -PidFile $Script:BackendPidFile `
    -OutLog (Join-Path $Script:LogDir 'backend.out.log') `
    -ErrLog (Join-Path $Script:LogDir 'backend.err.log')
}

function Start-RelayTunnel {
  $mode = Get-EnvValue 'RELAY_TUNNEL_MODE'
  if ([string]::IsNullOrWhiteSpace($mode) -or $mode -eq 'none') {
    Write-Info 'Tunnel mode is none; not starting cloudflared.'
    return
  }
  if (Test-PidFile $Script:TunnelPidFile) { Write-Info 'Tunnel is already running.'; return }
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
  # Start-Process joins its arguments; preserve quotes around config paths.
  foreach ($log in @('tunnel.out.log', 'tunnel.err.log')) {
    [IO.File]::WriteAllText((Join-Path $Script:LogDir $log), '')
  }
  Start-RelayProcess -Name 'tunnel' `
    -FilePath $cloudflaredBin `
    -ArgumentList @($argsText) `
    -WorkingDirectory $Script:ServerDir `
    -PidFile $Script:TunnelPidFile `
    -OutLog (Join-Path $Script:LogDir 'tunnel.out.log') `
    -ErrLog (Join-Path $Script:LogDir 'tunnel.err.log')
}

function Start-RelayServices {
  Start-RelayBackend
  Start-RelayTunnel
}

function Stop-RelayServices {
  Stop-RelayProcess -Name 'tunnel' -PidFile $Script:TunnelPidFile
  Stop-RelayProcess -Name 'backend' -PidFile $Script:BackendPidFile
}

function Register-RelayStartup {
  $script = Join-Path $Script:WindowsDir 'start.ps1'
  $powershell = (Get-Command 'powershell.exe').Source
  $action = New-ScheduledTaskAction -Execute $powershell -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`""
  $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  # A logon trigger for any user needs administrator rights ("Access is denied");
  # one limited to the current user does not.
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
  $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
  $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
  try {
    Register-ScheduledTask -TaskName $Script:StartupTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Start Relay backend for the current user.' -Force -ErrorAction Stop | Out-Null
  } catch {
    # Starting at logon is a convenience; the backend still starts now.
    Write-Warn "Could not register the startup task ($($_.Exception.Message)). Relay will not start at logon; run start.cmd after signing in."
    return
  }
  Write-Info "Startup task registered: $Script:StartupTaskName"
}

function Unregister-RelayStartup {
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

function Show-RelayStatus {
  $backendStatus = if (Test-PidFile -PidFile $Script:BackendPidFile) { 'running' } else { 'stopped' }
  $tunnelStatus = if (Test-PidFile -PidFile $Script:TunnelPidFile) { 'running' } else { 'stopped' }
  Write-Host "Backend: $backendStatus"
  Write-Host "Tunnel:  $tunnelStatus"
  Write-Host "Logs:    $Script:LogDir"
}

# --- user PATH ----------------------------------------------------------------
#
# Relay's own processes find the agent CLIs through the folders added to PATH
# above, but a terminal the user opens does not, so signing a CLI in was hard.
# Setup appends to the user PATH every folder in $Script:AgentCliDirs that holds
# an agent CLI, plus the bundled Node when the host has none (npm's .cmd shims
# run `node`). Entries the user already had are never touched; the ones Setup
# added are recorded, re-evaluated on each sync and removed on uninstall.

$Script:AgentCliNames = @('claude', 'codex', 'agent', 'cursor-agent', 'opencode', 'agy', 'hermes')

function Get-UserPathRaw {
  $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
  if (-not $key) { return '' }
  try {
    # Keep %VARIABLES% unexpanded so rewriting the value does not freeze them.
    return [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
  } finally { $key.Close() }
}

function Set-UserPathRaw {
  param([string]$Value)
  $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
  try { $key.SetValue('Path', $Value, [Microsoft.Win32.RegistryValueKind]::ExpandString) } finally { $key.Close() }
  # Setting a user variable through .NET broadcasts WM_SETTINGCHANGE, so
  # terminals opened from Explorer or the Start menu pick up the new PATH.
  [Environment]::SetEnvironmentVariable('RELAY_PATH_REFRESH', '1', 'User')
  [Environment]::SetEnvironmentVariable('RELAY_PATH_REFRESH', $null, 'User')
}

function Get-PathKey {
  param([string]$Entry)
  return [Environment]::ExpandEnvironmentVariables($Entry).Trim().TrimEnd('\').ToLowerInvariant()
}

function Test-AgentCliDir {
  param([string]$Dir)
  foreach ($name in $Script:AgentCliNames) {
    foreach ($ext in @('.exe', '.cmd', '.bat')) {
      if (Test-Path -LiteralPath (Join-Path $Dir "$name$ext") -PathType Leaf) { return $true }
    }
  }
  return $false
}

# Whether a Node outside this bundle is on the machine PATH or the given user entries.
function Test-HostNode {
  param([string[]]$UserEntries)
  $machine = @([Environment]::GetEnvironmentVariable('PATH', 'Machine') -split ';')
  foreach ($entry in @($machine + $UserEntries)) {
    if (-not $entry) { continue }
    $dir = [Environment]::ExpandEnvironmentVariables($entry)
    if ((Get-PathKey $dir) -eq (Get-PathKey $Script:BundledNodeDir)) { continue }
    if (Test-Path -LiteralPath (Join-Path $dir 'node.exe') -PathType Leaf) { return $true }
  }
  return $false
}

function Read-UserPathRecord {
  if (-not (Test-Path -LiteralPath $Script:UserPathRecord)) { return @() }
  try { return @((Get-Content -LiteralPath $Script:UserPathRecord -Raw -Encoding UTF8 | ConvertFrom-Json) | Where-Object { $_ }) }
  catch { return @() }
}

function Write-UserPathRecord {
  param([string[]]$Entries)
  if (-not $Entries -or $Entries.Count -eq 0) {
    Remove-Item -LiteralPath $Script:UserPathRecord -Force -ErrorAction SilentlyContinue
    return
  }
  Write-Utf8NoBom -Path $Script:UserPathRecord -Lines @(ConvertTo-Json -InputObject @($Entries) -Compress)
}

# The user PATH entries left after removing what Setup added earlier.
function Get-UserPathWithoutRelay {
  $recorded = @(Read-UserPathRecord | ForEach-Object { Get-PathKey $_ })
  return @((Get-UserPathRaw) -split ';' | Where-Object { $_ -and ($recorded -notcontains (Get-PathKey $_)) })
}

function Sync-RelayUserPath {
  $raw = Get-UserPathRaw
  $before = @($raw -split ';' | Where-Object { $_ } | ForEach-Object { Get-PathKey $_ })
  $kept = Get-UserPathWithoutRelay
  $keys = @($kept | ForEach-Object { Get-PathKey $_ })
  $wanted = @($Script:AgentCliDirs | Where-Object { Test-AgentCliDir $_ })
  if ((Test-Path -LiteralPath (Join-Path $Script:BundledNodeDir 'node.exe') -PathType Leaf) -and -not (Test-HostNode $kept)) {
    $wanted += $Script:BundledNodeDir
  }
  $added = @($wanted | Where-Object { $keys -notcontains (Get-PathKey $_) })
  $next = (@($kept) + $added) -join ';'
  if ($next -ne $raw) { Set-UserPathRaw $next }
  Write-UserPathRecord $added
  $new = @($added | Where-Object { $before -notcontains (Get-PathKey $_) })
  if ($new.Count -gt 0) {
    Write-Info "Added to your user PATH for new terminals: $($new -join '; ')"
  }
}

function Remove-RelayUserPath {
  $raw = Get-UserPathRaw
  $next = (Get-UserPathWithoutRelay) -join ';'
  if ($next -ne $raw) {
    Set-UserPathRaw $next
    Write-Info 'Removed the folders setup had added to your user PATH.'
  }
  Write-UserPathRecord @()
}
