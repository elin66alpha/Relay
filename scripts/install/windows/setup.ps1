[CmdletBinding()]
param([ValidateSet('menu', 'install')][string]$Action = 'menu')
Set-StrictMode -Version 2.0
. "$PSScriptRoot\lib\setup.ps1"
Require-Windows

function Read-AgentChoices {
  $details = Get-RelayDetails
  for ($i = 0; $i -lt $details.agents.Count; $i++) {
    $agent = $details.agents[$i]
    Write-Host "$($i + 1)) $($agent.label): $(if ($agent.installed) { 'installed' } else { 'not installed' }) - $($agent.login)"
  }
  $picks = Read-Host 'Install which CLIs? Space-separated numbers, a = all missing, Enter = skip'
  if ($picks -eq 'a') { return @($details.agents | Where-Object { -not $_.installed } | ForEach-Object { $_.key }) }
  return @($picks -split '\s+' | Where-Object { $_ -match '^[1-5]$' } | ForEach-Object { $details.agents[[int]$_ - 1].key })
}

function Read-InstallOptions {
  $agents = @(Read-AgentChoices)
  $serve = (Read-Host 'Serve the bundled Web client at the backend address? [Y/n]') -notmatch '^[Nn]'
  $value = Read-Host "Backend port [$(Get-BackendPort)]"
  if (-not $value) { $value = Get-BackendPort }
  Write-Host '1) Direct address   2) Named Cloudflare Tunnel   3) Quick Tunnel'
  $mode = Read-Host 'Network mode [3]'
  $options = @{ Port = [int]$value; ServeWeb = $serve; Agents = $agents }
  switch ($mode) {
    '1' { $options.NetworkMode = 'none'; $options.PublicUrl = Read-Host 'Public HTTP(S) address' }
    '2' {
      $options.NetworkMode = 'cloudflare'
      $options.Hostname = Read-Host 'Public Cloudflare hostname'
      $options.TunnelName = Read-Host "Tunnel name [$(Get-DefaultTunnelName)]"
      $options.OverwriteDns = (Read-Host 'Allow replacing an existing DNS record? [y/N]') -match '^[Yy]'
    }
    { $_ -in @('', '3') } { $options.NetworkMode = 'quick' }
    default { Write-Fail 'Invalid network mode.' }
  }
  return $options
}

if ($Action -eq 'install') {
  $options = Read-InstallOptions
  Install-RelayBackend @options
  exit
}

while ($true) {
  Write-Info 'Relay Windows backend'
  Write-Host @'
1) Install
2) Reinstall (keeps tokens, chats and settings)
3) Uninstall all services
4) Service status (address, agents, tokens)
5) Install agent CLIs
6) Create a new token
7) Delete a token
8) List tokens
9) Show a token's credential QR again
0) Exit
'@
  try {
    switch (Read-Host 'Choose [0-9]') {
      { $_ -in @('1', '2') } {
        $reinstall = $_ -eq '2'
        if ($reinstall -and (Read-Host 'Stop and reconfigure Relay, keeping its data? [y/N]') -notmatch '^[Yy]') { break }
        $options = Read-InstallOptions
        Install-RelayBackend @options -Reinstall:$reinstall
      }
      '3' {
        if ((Read-Host 'Stop Relay and remove its login task and Web client? [y/N]') -match '^[Yy]') {
          $delete = (Read-Host 'Also delete the named tunnel from Cloudflare? [y/N]') -match '^[Yy]'
          $remove = (Read-Host 'Remove cloudflared downloaded by this bundle? [y/N]') -match '^[Yy]'
          Uninstall-RelayBackend -DeleteTunnel:$delete -RemoveCloudflared:$remove
        }
      }
      '4' { Get-RelayDetails | ConvertTo-Json -Depth 6 | Write-Host }
      '5' { Install-RelayAgentClis -Agents @(Read-AgentChoices) }
      '6' {
        $label = Read-Host 'Device label'
        Invoke-RelayCredential -Arguments @('--url', (Get-EnvValue 'PUBLIC_BASE_URL'), '--label', $label)
      }
      '7' {
        Invoke-RelayCredential -Arguments @('--list-tokens')
        $id = Read-Host 'Token ID'
        if ($id -and (Read-Host 'Delete this token? Devices using it lose access. [y/N]') -match '^[Yy]') {
          Invoke-RelayCredential -Arguments @('--delete', $id)
        }
      }
      '8' { Invoke-RelayCredential -Arguments @('--list-tokens') }
      '9' {
        Invoke-RelayCredential -Arguments @('--list-tokens')
        $id = Read-Host 'Token ID'
        if ($id) { Invoke-RelayCredential -Arguments @('--show', $id, '--url', (Get-EnvValue 'PUBLIC_BASE_URL')) }
      }
      '0' { return }
      default { Write-Warn 'Invalid choice.' }
    }
  } catch { Write-Warn $_.Exception.Message }
}
