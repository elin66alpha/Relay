# Upgrades this installation in place to the latest release and restarts the
# backend. server\.env, tokens, chats and settings are not part of a release, so
# they stay. The tunnel keeps running: restarting a Quick Tunnel changes its URL.
#
#   update.cmd                 latest release from GitHub, checked against SHA256SUMS
#   update.cmd -Archive <zip>  a backend ZIP downloaded by hand
[CmdletBinding()]
param([string]$Archive = '')

Set-StrictMode -Version 2.0
. "$PSScriptRoot\lib\common.ps1"

Require-Windows
if (Test-Path -LiteralPath (Join-Path $Script:RootDir '.git')) {
  Write-Fail 'This is a source checkout; update it with git.'
}
$current = (Get-Content -LiteralPath (Join-Path $Script:ServerDir 'package.json') -Raw | ConvertFrom-Json).version
$stage = Join-Path ([IO.Path]::GetTempPath()) ('relay-update-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
try {
  if (-not $Archive) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    $base = 'https://github.com/elin66alpha/Relay/releases/latest/download'
    # One file names the latest version and the checksum of its bundle.
    $sums = (Invoke-WebRequest -UseBasicParsing -Uri "$base/SHA256SUMS").Content
    if ($sums -is [byte[]]) { $sums = [Text.Encoding]::ASCII.GetString($sums) }
    if ($sums -notmatch '(?m)^([0-9a-f]{64})\s+\*?(relay-backend-windows-x64-v(\d+(?:\.\d+)*)\.zip)\s*$') {
      Write-Fail 'The latest release has no Windows backend bundle.'
    }
    $hash = $Matches[1]; $name = $Matches[2]; $latest = $Matches[3]
    if ([version]$latest -le [version]$current) {
      Write-Info "Relay $current is already the latest version."
      return
    }
    Write-Info "Downloading Relay $latest..."
    $Archive = Join-Path $stage $name
    Invoke-WebRequest -UseBasicParsing -Uri "$base/$name" -OutFile $Archive
    if ((Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hash) {
      Write-Fail 'The download does not match the release checksum. Nothing was changed.'
    }
  }
  # Unpack completely before touching the installation.
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $unpacked = Join-Path $stage 'bundle'
  [IO.Compression.ZipFile]::ExtractToDirectory((Resolve-Path -LiteralPath $Archive).Path, $unpacked)
  $source = @(Get-ChildItem -LiteralPath $unpacked -Directory)[0].FullName
  if (-not (Test-Path -LiteralPath (Join-Path $source 'server\server.js'))) {
    Write-Fail 'The archive is not a Relay backend bundle. Nothing was changed.'
  }

  Stop-RelayProcess -Name 'backend' -PidFile $Script:BackendPidFile
  try {
    # Windows releases a stopped process's files a moment after it exits.
    Start-Sleep -Seconds 2
    # These trees change file names between releases; replace them whole.
    foreach ($tree in @('server\node_modules', 'runtime\node', 'app\shell\build\web')) {
      $target = Join-Path $Script:RootDir $tree
      if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    }
    & robocopy.exe $source $Script:RootDir /E /NFL /NDL /NJH /NJS /NP /R:5 /W:1 | Out-Null
    if ($LASTEXITCODE -ge 8) { Write-Fail "Copying the new version failed (robocopy $LASTEXITCODE)." }
    # Releases up to 0.1.12 shipped a graphical Setup.exe; setup.cmd replaces it.
    foreach ($stale in @('Setup.exe', 'scripts\install\windows\Setup.cs', 'scripts\install\windows\setup-action.ps1')) {
      Remove-Item -LiteralPath (Join-Path $Script:RootDir $stale) -Force -ErrorAction SilentlyContinue
    }
    $new = (Get-Content -LiteralPath (Join-Path $Script:ServerDir 'package.json') -Raw | ConvertFrom-Json).version
    Write-Info "Upgraded from $current to $new. Tokens, chats and settings are unchanged."
  } finally {
    # Whatever happened, do not leave the backend stopped.
    Start-RelayBackend
  }
} finally {
  Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
