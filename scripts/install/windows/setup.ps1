# Relay setup for Windows, run as setup.cmd from the extracted backend bundle.
#
# The same menu as scripts/install/unix/setup.sh: install, reinstall or
# uninstall the backend, show its status, install agent CLIs and manage device
# tokens. Installing runs the same six steps (system software, agent CLIs, Web
# client, file access, network mode, device credential); the choices are asked
# first, then Install-RelayBackend applies them. `setup.cmd install` skips the
# menu. `t` opens a terminal with the agent CLIs on PATH, for signing them in.
#
# Network modes:
#   1. No tunnel: for a host with a reachable public IP or domain.
#   2. Cloudflare Tunnel: named tunnel + stable hostname in your Cloudflare zone.
#   3. Cloudflare Quick Tunnel: temporary trycloudflare.com URL for fast trials.
#   4. Tailscale: this machine's tailnet IP; falls back to the menu without one.
[CmdletBinding()]
param([ValidateSet('menu', 'install')][string]$Action = 'menu')
Set-StrictMode -Version 2.0
. "$PSScriptRoot\lib\setup.ps1"
Require-Windows

function Read-AgentChoices {
  $agents = @((Get-RelayDetails).agents)
  for ($i = 0; $i -lt $agents.Count; $i++) {
    $state = if ($agents[$i].installed) { 'installed' } else { 'not installed' }
    Write-Host ('  {0}) {1,-12} {2}' -f ($i + 1), $agents[$i].label, $state)
  }
  $missing = @($agents | Where-Object { -not $_.installed } | ForEach-Object { $_.key })
  if ($missing.Count -eq 0) { Write-Info 'Every agent CLI is installed.'; return @() }
  $picks = Read-Host 'Install which? Numbers separated by spaces, a = all missing, Enter = skip'
  if ($picks -eq 'a') { return $missing }
  $keys = @()
  foreach ($pick in ($picks -split '\s+' | Where-Object { $_ })) {
    $n = 0
    if ([int]::TryParse($pick, [ref]$n) -and $n -ge 1 -and $n -le $agents.Count) { $keys += $agents[$n - 1].key }
    else { Write-Warn "Skipping invalid choice: $pick" }
  }
  return $keys
}

# Asks the install questions in the order of the six steps; nothing changes
# until every answer is in, so a typo leaves the current setup untouched.
function Read-InstallOptions {
  Write-Info 'Agent CLIs'
  $agents = @(Read-AgentChoices)

  Write-Info 'Web client'
  $serve = $false
  if (Test-Path -LiteralPath (Join-Path $Script:RootDir 'app\shell\build\web\index.html')) {
    $serve = (Read-Host 'Serve the Web client at the backend address? [Y/n]') -notmatch '^[Nn]'
  } else {
    Write-Warn 'This copy has no Web client (app\shell\build\web); the backend serves the API only.'
  }

  Write-Info 'File access'
  Write-Host '  1) Open: agents and the file browser reach every file this Windows user can'
  Write-Host "  2) Isolated: workspaces and the file browser stay inside $(Join-Path $Script:RootDir 'workspace')"
  $current = if (Get-EnvValue 'RELAY_WORKSPACE_ROOT') { '2' } else { '1' }
  $access = Read-Host "File access [1/2, default $current]"
  if (-not $access) { $access = $current }
  if ($access -notin @('1', '2')) { Write-Fail "Invalid file access choice: $access" }

  Write-Info 'Network mode'
  $port = Read-Host "Backend port [$(Get-BackendPort)]"
  if (-not $port) { $port = Get-BackendPort }
  $options = @{ Port = [int]$port; ServeWeb = $serve; Agents = $agents; Isolated = ($access -eq '2') }
  while ($true) {
    Write-Host '  1) No tunnel / direct public address'
    Write-Host '  2) Cloudflare Tunnel / named stable hostname'
    Write-Host '  3) Cloudflare Quick Tunnel / temporary trycloudflare.com URL'
    Write-Host "  4) Tailscale / this machine's Tailscale IP, reachable from your tailnet"
    $mode = Read-Host 'Network mode [1/2/3/4, default 3]'
    if ($mode -ne '4') { break }
    $tailscaleIp = Get-TailscaleIPv4
    if ($tailscaleIp) { break }
    Write-Warn 'Tailscale is not installed here, or this machine is not connected to a tailnet.'
    Write-Warn 'Install it from https://tailscale.com/download and sign in, or choose another mode.'
  }
  switch ($mode) {
    '1' {
      $options.NetworkMode = 'none'
      $options.PublicUrl = Read-Host "Public address the app will use (e.g. https://agent.example.com or http://1.2.3.4:$port)"
      if (-not $options.PublicUrl) { Write-Fail 'A public address is required in direct mode.' }
    }
    '2' {
      $options.NetworkMode = 'cloudflare'
      $options.Hostname = Read-Host 'Public hostname for this backend (e.g. agent.example.com)'
      if (-not $options.Hostname) { Write-Fail 'A hostname is required for Cloudflare Tunnel mode.' }
      $options.TunnelName = Read-Host "Cloudflare tunnel name [$(Get-DefaultTunnelName)]"
      $options.OverwriteDns = (Read-Host 'Allow replacing an existing DNS record? [y/N]') -match '^[Yy]'
    }
    { $_ -in @('', '3') } { $options.NetworkMode = 'quick' }
    '4' {
      $options.BindAddress = $tailscaleIp
      $options.NetworkMode = 'none'
      $options.PublicUrl = "http://${tailscaleIp}:$port"
      if ($serve) {
        Write-Info "Native apps can use $($options.PublicUrl). Relay Web needs a trusted HTTPS origin to store credentials."
        Write-Info "For Web, configure an HTTPS reverse proxy to $($options.PublicUrl) and enter its hostname."
        $proxyName = Read-Host 'HTTPS proxy hostname (Enter for native apps only)'
        if ($proxyName) {
          if ($proxyName -notmatch '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$') { Write-Fail 'Enter a hostname without a scheme, port or path.' }
          $options.PublicUrl = "https://$proxyName"
        } else { $options.ServeWeb = $false }
      }
      Write-Info "Tailscale: devices on your tailnet connect to $($options.PublicUrl). Install Tailscale on each of them and sign in to the same tailnet."
    }
    default { Write-Fail "Invalid network mode: $mode" }
  }
  return $options
}

function Test-RelayInstalled {
  return (Test-PidFile $Script:BackendPidFile) -or [bool](Get-ScheduledTask -TaskName $Script:StartupTaskName -ErrorAction SilentlyContinue)
}

function Install-FromMenu {
  param([switch]$Reinstall)
  $options = Read-InstallOptions
  Install-RelayBackend @options -Reinstall:$Reinstall
  Write-Info 'Done. In the app, tap "Scan QR", scan the QR above, and enter the password you just set.'
  Write-Info 'setup.cmd also shows status, manages tokens, reinstalls and uninstalls.'
}

if ($Action -eq 'install') {
  Install-FromMenu
  exit
}

while ($true) {
  Write-Info 'Relay backend - Windows'
  Write-Host @'
  1) Install
  2) Reinstall (keeps tokens, chats and settings)
  3) Uninstall all services
  4) Service status (address, agents, tokens)
  5) Install agent CLIs (Claude Code, Codex, Cursor, OpenCode, Antigravity, Hermes)
  6) Create a new token
  7) Delete a token
  8) List tokens
  9) Show a token's credential QR again
  t) Open a terminal with the agent CLIs on PATH (to sign in)
  0) Exit
'@
  $choice = Read-Host 'Choose [0-9, t]'
  try {
    switch ($choice) {
      '1' {
        if (Test-RelayInstalled) { Write-Warn 'Relay is already installed here. Choose 2 to reinstall.'; break }
        Install-FromMenu
        # A double-clicked setup.cmd closes its window on exit; keep the QR up.
        [void](Read-Host 'Press Enter to return to the menu')
      }
      '2' {
        if ((Read-Host 'Stop Relay, reinstall its dependencies and set up the network again? [y/N]') -notmatch '^[Yy]') { break }
        Install-FromMenu -Reinstall
        [void](Read-Host 'Press Enter to return to the menu')
      }
      '3' {
        if ((Read-Host 'Stop and remove every Relay service, including the Web client? [y/N]') -match '^[Yy]') {
          $delete = (Read-Host 'Also delete the named tunnel from Cloudflare? [y/N]') -match '^[Yy]'
          $remove = (Read-Host 'Remove cloudflared downloaded by this bundle? [y/N]') -match '^[Yy]'
          Uninstall-RelayBackend -DeleteTunnel:$delete -RemoveCloudflared:$remove
        }
      }
      '4' { & "$PSScriptRoot\status.ps1" }
      '5' { Install-RelayAgentClis -Agents @(Read-AgentChoices) }
      { $_ -in @('6', '7', '8', '9') } {
        if (-not (Test-Path -LiteralPath $Script:EnvFile) -or -not (Test-Path -LiteralPath (Join-Path $Script:ServerDir 'node_modules'))) {
          Write-Warn 'Relay is not installed here yet. Choose 1 first.'
          break
        }
        switch ($choice) {
          '6' {
            $label = Read-Host "Label for the device that will use it [$env:COMPUTERNAME]"
            if (-not $label) { $label = $env:COMPUTERNAME }
            Invoke-RelayCredential -Arguments @('--url', (Get-EnvValue 'PUBLIC_BASE_URL'), '--label', $label)
          }
          '7' {
            Invoke-RelayCredential -Arguments @('--list-tokens')
            $id = Read-Host 'Token id'
            if ($id -and (Read-Host "Delete token $id? Devices using it lose access. [y/N]") -match '^[Yy]') {
              Invoke-RelayCredential -Arguments @('--delete', $id)
            }
          }
          '8' { Invoke-RelayCredential -Arguments @('--list-tokens') }
          '9' {
            Invoke-RelayCredential -Arguments @('--list-tokens')
            $id = Read-Host 'Token id'
            if ($id) { Invoke-RelayCredential -Arguments @('--show', $id, '--url', (Get-EnvValue 'PUBLIC_BASE_URL')) }
          }
        }
      }
      't' { Open-RelayTerminal }
      '0' { return }
      default { Write-Warn "Invalid choice: $choice" }
    }
  } catch { Write-Warn $_.Exception.Message }
}
