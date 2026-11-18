# Operations behind the setup.cmd menu (setup.ps1) and status.cmd.
. "$PSScriptRoot\common.ps1"

function Get-RelayDetails {
  Require-Node
  $bridge = Join-Path $Script:ServerDir 'scripts\windows-setup.js'
  if (-not (Test-Path -LiteralPath $bridge -PathType Leaf)) {
    Write-Fail "The backend bundle is incomplete; missing $bridge. Extract the entire ZIP again and wait for extraction to finish."
  }
  $text = & node $bridge
  if ($LASTEXITCODE -ne 0) { Write-Fail 'Could not read backend status.' }
  $details = ($text -join "`n") | ConvertFrom-Json
  return [ordered]@{
    backendRunning = (Test-PidFile $Script:BackendPidFile)
    tunnelRunning = (Test-PidFile $Script:TunnelPidFile)
    url = (Get-EnvValue 'PUBLIC_BASE_URL')
    port = (Get-BackendPort)
    networkMode = (Get-EnvValue 'RELAY_TUNNEL_MODE')
    tunnelName = (Get-EnvValue 'RELAY_TUNNEL_NAME')
    webAvailable = (Test-Path -LiteralPath (Join-Path $Script:RootDir 'app\shell\build\web\index.html'))
    serveWeb = ((Get-EnvValue 'RELAY_SERVE_WEB') -ne '0')
    workspaceRoot = (Get-EnvValue 'RELAY_WORKSPACE_ROOT')
    logs = $Script:LogDir
    agents = @($details.agents)
    tokens = @($details.tokens)
  }
}

function Install-RelayAgentClis {
  param([string[]]$Agents = @())
  foreach ($agent in $Agents) {
    if ($agent -notin @('claude', 'codex', 'cursor', 'opencode', 'agy', 'hermes')) {
      Write-Fail "Unknown agent: $agent"
    }
    $state = (Get-RelayDetails).agents | Where-Object { $_.key -eq $agent }
    if ($state.installed) { Write-Info "$($state.label) is already installed."; continue }
    Write-Info "Installing $($state.label) using its official Windows installer..."
    try {
      switch ($agent) {
        { $_ -in @('codex', 'opencode') } {
          $packageName = if ($agent -eq 'codex') { '@openai/codex' } else { 'opencode-ai' }
          & npm.cmd install --global --prefix (Join-Path $env:APPDATA 'npm') $packageName
          if ($LASTEXITCODE -ne 0) { throw 'npm installation failed.' }
        }
        default {
          $url = switch ($agent) {
            'claude' { 'https://claude.ai/install.ps1' }
            'cursor' { 'https://cursor.com/install?win32=true' }
            'agy' { 'https://antigravity.google/cli/install.ps1' }
            'hermes' { 'https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.ps1' }
          }
          $download = Join-Path ([IO.Path]::GetTempPath()) ("relay-agent-" + [guid]::NewGuid().ToString('N') + '.ps1')
          try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $download
            $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $download)
            if ($agent -eq 'hermes') { $arguments += '-NonInteractive' }
            & powershell.exe @arguments
            if ($LASTEXITCODE -ne 0) { throw 'Official installer failed.' }
          } finally { Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue }
        }
      }
    } catch { Write-Warn "$($state.label): $($_.Exception.Message) Install it manually if needed." }
    # Refresh PATH after an official installer modifies the user's environment.
    $env:PATH = [Environment]::GetEnvironmentVariable('PATH', 'User') + ';' + $env:PATH
    Write-Info "$($state.label) login/configuration command: $($state.login)"
  }
  Sync-RelayUserPath
  Write-Info 'Sign in to agent CLIs yourself in a terminal (choose t in setup.cmd for one with them on PATH). Relay never signs an agent in.'
}

# A PowerShell window with the backend's PATH (bundled Node, every agent CLI
# folder) and the sign-in command of each CLI, for signing in on this host.
function Open-RelayTerminal {
  $lines = @('Relay agent terminal: the agent CLIs and Relay''s Node are on PATH here.', 'Sign in or configure each CLI you use:')
  foreach ($agent in (Get-RelayDetails).agents) {
    $state = if (-not $agent.installed) { 'not installed' } elseif ($null -eq $agent.authed) { 'installed, sign-in managed on host' } elseif ($agent.authed) { 'ready' } else { 'needs sign-in' }
    $lines += "  $($agent.label) ($state): $($agent.login)"
  }
  $script = ($lines | ForEach-Object { "Write-Host '" + ($_ -replace "'", "''") + "'" }) -join '; '
  # -EncodedCommand: Start-Process would split an unquoted -Command on spaces.
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
  Start-Process -FilePath (Get-Command 'powershell.exe').Source -WorkingDirectory $env:USERPROFILE `
    -ArgumentList @('-NoExit', '-NoLogo', '-EncodedCommand', $encoded)
  Write-Info 'Opened a terminal with the agent CLIs on PATH.'
}

function Ensure-Cloudflared {
  if (Test-Command 'cloudflared') { return }
  Write-Info 'Downloading cloudflared for Windows x64...'
  $tools = Join-Path $Script:RootDir 'runtime\tools'
  New-Item -ItemType Directory -Force -Path $tools | Out-Null
  $destination = Join-Path $tools 'cloudflared.exe'
  $temporary = Join-Path $tools ('cloudflared-' + [guid]::NewGuid().ToString('N') + '.download')
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe' -OutFile $temporary
    # Reject a proxy error page instead of installing it as an executable.
    $header = [IO.File]::OpenRead($temporary)
    try { if ($header.ReadByte() -ne 77 -or $header.ReadByte() -ne 90) { throw 'Invalid cloudflared executable.' } }
    finally { $header.Dispose() }
    Move-Item -LiteralPath $temporary -Destination $destination -Force
    & $destination --version
    if ($LASTEXITCODE -ne 0) { Write-Fail 'cloudflared could not run.' }
  } finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
}

function Invoke-RelayCredential {
  param([string[]]$Arguments = @(), [string]$Passphrase = '')
  $previous = $env:RELAY_CREDENTIAL_PASSPHRASE
  try {
    if ($Passphrase) { $env:RELAY_CREDENTIAL_PASSPHRASE = $Passphrase }
    & node (Join-Path $Script:ServerDir 'scripts\create-credential.js') @Arguments
    if ($LASTEXITCODE -ne 0) { Write-Fail 'Credential operation failed.' }
  } finally { $env:RELAY_CREDENTIAL_PASSPHRASE = $previous }
}

function Install-RelayBackend {
  param(
    [int]$Port = 8787,
    [ValidateSet('none', 'cloudflare', 'quick')][string]$NetworkMode = 'quick',
    [string]$PublicUrl = '', [string]$Hostname = '', [string]$TunnelName = '',
    [bool]$ServeWeb = $true, [string[]]$Agents = @(),
    [string]$Passphrase = '', [string]$Label = '',
    [switch]$Reinstall, [switch]$OverwriteDns,
    # Confine workdirs, the file API and agent tiers to <bundle>\workspace.
    [bool]$Isolated = $false,
    [ipaddress]$BindAddress = '0.0.0.0'
  )
  if ($Port -lt 1 -or $Port -gt 65535) { Write-Fail 'Port must be between 1 and 65535.' }
  if ($Passphrase -and $Passphrase.Length -lt 6) { Write-Fail 'Credential password must have at least 6 characters.' }
  if ($NetworkMode -eq 'none') {
    if (-not $PublicUrl) { Write-Fail 'Direct mode requires a public URL.' }
    if ($PublicUrl -notmatch '^https?://') { $PublicUrl = "http://$PublicUrl" }
    $parsed = $null
    if (-not [Uri]::TryCreate($PublicUrl, [UriKind]::Absolute, [ref]$parsed) -or
        $parsed.Scheme -notin @('http', 'https') -or $parsed.UserInfo -or $parsed.Query -or $parsed.Fragment -or $PublicUrl -match '[\r\n]') {
      Write-Fail 'Enter an HTTP(S) address without credentials, query or fragment.'
    }
  }
  if ($NetworkMode -eq 'cloudflare') {
    $Hostname = Get-UrlHostname $Hostname
    if ($Hostname -notmatch '^(?=.{1,253}$)[a-zA-Z0-9]+(?:[a-zA-Z0-9.-]*[a-zA-Z0-9])$') { Write-Fail 'Enter a valid public hostname.' }
    if (-not $TunnelName) { $TunnelName = Get-DefaultTunnelName }
    if ($TunnelName -notmatch '^[a-z0-9][a-z0-9_-]{0,62}$') { Write-Fail 'Tunnel name must use lowercase letters, numbers, hyphens or underscores.' }
  }
  if ((Test-PidFile $Script:BackendPidFile) -and -not $Reinstall) {
    Write-Fail 'Relay is already running. Choose Reinstall to keep its data and reconfigure it.'
  }
  Write-Info 'Step 1/6 - System software and server dependencies'
  Require-Node
  Ensure-EnvFile
  if ($Reinstall) { Stop-RelayServices }
  Install-ServerDeps -Force:$Reinstall
  Test-RelayBrowser
  Write-Info 'Step 2/6 - Agent CLIs'
  Install-RelayAgentClis -Agents $Agents
  Write-Info 'Step 3/6 - Web client'
  $available = Test-Path -LiteralPath (Join-Path $Script:RootDir 'app\shell\build\web\index.html')
  if ($ServeWeb -and -not $available) { Write-Fail 'Web client missing. Extract a complete release bundle or build Web first.' }
  Set-EnvValue 'RELAY_SERVE_WEB' $(if ($ServeWeb) { '1' } else { '0' })
  Write-Info 'Step 4/6 - File access'
  if ($Isolated) {
    $workspace = Join-Path $Script:RootDir 'workspace'
    New-Item -ItemType Directory -Force -Path $workspace | Out-Null
    Set-EnvValue 'RELAY_WORKSPACE_ROOT' $workspace
    Write-Info "Isolated: workspaces and the file browser stay inside $workspace"
  } else {
    Set-EnvValue 'RELAY_WORKSPACE_ROOT' ''
    Write-Info 'Open: agents and the file browser reach every file this Windows user can.'
  }
  Write-Info 'Step 5/6 - Network mode'
  Set-EnvValue 'PORT' ([string]$Port)
  Set-EnvValue 'RELAY_TUNNEL_MODE' $NetworkMode
  Set-EnvValue 'RELAY_TUNNEL_NAME' $TunnelName
  if ($NetworkMode -eq 'none') {
    Set-EnvValue 'HOST' $BindAddress.IPAddressToString
    Set-EnvValue 'PUBLIC_BASE_URL' $PublicUrl
    Set-EnvValue 'CLOUDFLARED_BIN' ''
    Set-EnvValue 'CLOUDFLARED_ARGS' ''
  } else {
    Ensure-Cloudflared
    Set-EnvValue 'HOST' '127.0.0.1'
    Set-EnvValue 'CLOUDFLARED_BIN' (Get-Command cloudflared).Source
    if ($NetworkMode -eq 'quick') {
      Set-EnvValue 'PUBLIC_BASE_URL' ''
      Set-EnvValue 'CLOUDFLARED_ARGS' "tunnel --url http://127.0.0.1:$Port"
    } else {
      $tunnelId = Ensure-NamedTunnel -Name $TunnelName
      & cloudflared tunnel route dns $TunnelName $Hostname
      if ($LASTEXITCODE -ne 0) {
        if (-not $OverwriteDns) { Write-Fail 'DNS route exists or could not be created. Enable overwrite only if you want to replace its DNS record.' }
        & cloudflared tunnel route dns --overwrite-dns $TunnelName $Hostname
        if ($LASTEXITCODE -ne 0) { Write-Fail 'Could not create the DNS route.' }
      }
      $configFile = Join-Path $Script:ServerDir "cloudflared-config\$TunnelName.yml"
      Write-NamedTunnelConfig $tunnelId $Hostname ([string]$Port) $configFile
      $PublicUrl = "https://$Hostname"
      Set-EnvValue 'PUBLIC_BASE_URL' $PublicUrl
      Set-EnvValue 'CLOUDFLARED_ARGS' "tunnel --config `"$configFile`" run $tunnelId"
    }
  }
  Register-RelayStartup
  Start-RelayServices
  if ($NetworkMode -eq 'quick') {
    $PublicUrl = Wait-ForTunnelUrl
    if (-not $PublicUrl) { Write-Fail 'No Quick Tunnel URL detected. Check the tunnel logs and retry.' }
    Set-EnvValue 'PUBLIC_BASE_URL' $PublicUrl
  }
  Write-Info 'Step 6/6 - Device credential'
  $credentialArgs = @('--url', $PublicUrl)
  if ($Label) { $credentialArgs += @('--label', $Label) }
  Invoke-RelayCredential -Arguments $credentialArgs -Passphrase $Passphrase
  Write-Info 'Installed. Import the encrypted credential file or scan its QR code in Relay.'
}

function Remove-RelayWeb {
  $web = [IO.Path]::GetFullPath((Join-Path $Script:RootDir 'app\shell\build\web'))
  $expected = [IO.Path]::GetFullPath($Script:RootDir).TrimEnd('\') + '\app\shell\build\web'
  if ($web -ne $expected) { Write-Fail 'Invalid Web removal path.' }
  if (Test-Path -LiteralPath $web) { Remove-Item -LiteralPath $web -Recurse -Force }
  Set-EnvValue 'RELAY_SERVE_WEB' '0'
}

function Uninstall-RelayBackend {
  param([bool]$RemoveWeb = $true, [switch]$DeleteTunnel, [switch]$RemoveCloudflared)
  Stop-RelayServices
  Unregister-RelayStartup
  Remove-RelayUserPath
  if ($RemoveWeb) { Remove-RelayWeb }
  $name = Get-EnvValue 'RELAY_TUNNEL_NAME'
  if ($DeleteTunnel -and $name -and (Test-Command cloudflared)) {
    & cloudflared tunnel cleanup $name
    & cloudflared tunnel delete $name
    if ($LASTEXITCODE -ne 0) { Write-Fail 'Cloudflare tunnel deletion failed.' }
    Write-Warn 'Delete the remaining DNS record in the Cloudflare dashboard if needed.'
  }
  if ($RemoveCloudflared) {
    $owned = Join-Path $Script:RootDir 'runtime\tools\cloudflared.exe'
    if (Test-Path -LiteralPath $owned) { Remove-Item -LiteralPath $owned -Force }
    Write-Info 'Only the bundle-owned cloudflared was removed; other host software is retained.'
  }
  Write-Info 'Uninstalled services. Configuration, device tokens, credentials, chats, settings and logs are retained. Extract the bundle again to restore a removed Web client.'
}
