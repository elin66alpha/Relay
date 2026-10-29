# Private JSON-over-stdin bridge used by Setup.exe; passwords never enter argv
# or a temporary file. The console menu calls the same operations directly.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
. "$PSScriptRoot\lib\setup.ps1"

try {
  Require-Windows
  $request = [Console]::In.ReadToEnd() | ConvertFrom-Json
  switch ($request.action) {
    { $_ -in @('install', 'reinstall') } {
      $options = @{
        Port = [int]$request.port; NetworkMode = [string]$request.networkMode
        PublicUrl = [string]$request.url; Hostname = [string]$request.hostname
        TunnelName = [string]$request.tunnelName; ServeWeb = [bool]$request.serveWeb
        Agents = [string[]]$request.agents; Passphrase = [string]$request.passphrase
        Label = [string]$request.label; Reinstall = ($request.action -eq 'reinstall')
        OverwriteDns = [bool]$request.overwriteDns
      }
      if ($options.Passphrase.Length -lt 6) { throw 'Password must have at least 6 characters.' }
      Install-RelayBackend @options
    }
    'agents' { Install-RelayAgentClis -Agents ([string[]]$request.agents) }
    'start' { Require-Node; Ensure-EnvFile; Start-RelayServices }
    'stop' { Stop-RelayServices }
    'uninstall' { Uninstall-RelayBackend -RemoveWeb ([bool]$request.removeWeb) -DeleteTunnel:([bool]$request.deleteTunnel) -RemoveCloudflared:([bool]$request.removeCloudflared) }
    { $_ -in @('create-token', 'show-token') } {
      if ($request.passphrase.Length -lt 6) { throw 'Password must have at least 6 characters.' }
      $arguments = @('--url', [string]$request.url, '--label', [string]$request.label)
      if ($request.action -eq 'show-token') { $arguments += @('--show', [string]$request.tokenId) }
      Invoke-RelayCredential -Arguments $arguments -Passphrase ([string]$request.passphrase)
    }
    'delete-token' { Invoke-RelayCredential -Arguments @('--delete', [string]$request.tokenId) }
    'status' { }
    default { throw 'Unknown setup action.' }
  }
  $details = Get-RelayDetails
  Write-Output ('RELAY_RESULT:' + ($details | ConvertTo-Json -Depth 8 -Compress))
} catch {
  [Console]::Error.WriteLine($_.Exception.Message)
  exit 1
}
