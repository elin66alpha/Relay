# Upgrades this installation in place to the latest release and restarts the
# backend. server\.env, tokens, chats and settings are not part of a release, so
# they stay. The tunnel keeps running: restarting a Quick Tunnel changes its URL.
# It refuses while another Relay process holds the folder or the port, and puts
# the previous version back when the new one fails to install or to listen.
#
#   update.cmd                 latest release from GitHub, checked against SHA256SUMS
#   update.cmd -Archive <zip>  a backend ZIP downloaded by hand
[CmdletBinding()]
param([string]$Archive = '')

Set-StrictMode -Version 2.0
. "$PSScriptRoot\lib\common.ps1"

# These trees change file names between releases; they are replaced whole.
$Script:ReleaseTrees = @('server\node_modules', 'runtime\node', 'app\shell\build\web')
# Folders holding only release files: a file a release no longer ships is
# removed from them, so a deleted module cannot keep loading.
$Script:ReleaseDirs = @('server\lib', 'server\routes', 'server\scripts', 'server\test', 'scripts\install\windows')
# Releases up to 0.1.12 shipped a graphical Setup.exe; setup.cmd replaces it.
$Script:RetiredFiles = @('Setup.exe', 'scripts\install\windows\Setup.cs', 'scripts\install\windows\setup-action.ps1')

function Save-PreviousFile {
  param([string]$Relative, [string]$Backup, $Previous, [switch]$Move)
  $target = Join-Path $Script:RootDir $Relative
  $saved = Join-Path $Backup "files\$Relative"
  New-Item -ItemType Directory -Path (Split-Path -Parent $saved) -Force | Out-Null
  if ($Move) { Move-Item -LiteralPath $target -Destination $saved } else { Copy-Item -LiteralPath $target -Destination $saved }
  [void]$Previous.Files.Add($Relative)
}

# Replaces the installation with $Source, recording in $Previous what it
# moved, saved and added so Restore-Release can undo every step.
function Install-Release {
  param([string]$Source, [string]$Backup, $Previous)
  foreach ($tree in $Script:ReleaseTrees) {
    $target = Join-Path $Script:RootDir $tree
    if (-not (Test-Path -LiteralPath $target)) { continue }
    $saved = Join-Path $Backup "trees\$tree"
    New-Item -ItemType Directory -Path (Split-Path -Parent $saved) -Force | Out-Null
    # Windows releases a stopped process's files a moment after it exits.
    for ($attempt = 1; ; $attempt++) {
      try { Move-Item -LiteralPath $target -Destination $saved -ErrorAction Stop; break }
      catch { if ($attempt -ge 5) { throw "Cannot replace $tree, a file in it is in use: $($_.Exception.Message)" }; Start-Sleep -Seconds 1 }
    }
    [void]$Previous.Trees.Add($tree)
  }
  $shipped = @{}
  foreach ($file in Get-ChildItem -LiteralPath $Source -Recurse -File -Force) {
    $relative = $file.FullName.Substring($Source.Length + 1)
    if (@($Script:ReleaseTrees | Where-Object { $relative.StartsWith("$_\", [StringComparison]::OrdinalIgnoreCase) }).Count) { continue }
    $shipped[$relative.ToLowerInvariant()] = $true
    if (Test-Path -LiteralPath (Join-Path $Script:RootDir $relative) -PathType Leaf) {
      Save-PreviousFile -Relative $relative -Backup $Backup -Previous $Previous
    } else {
      [void]$Previous.Added.Add($relative)
    }
  }
  $retired = @($Script:RetiredFiles | Where-Object { Test-Path -LiteralPath (Join-Path $Script:RootDir $_) -PathType Leaf })
  foreach ($dir in $Script:ReleaseDirs) {
    $full = Join-Path $Script:RootDir $dir
    if (-not (Test-Path -LiteralPath $full)) { continue }
    foreach ($file in Get-ChildItem -LiteralPath $full -Recurse -File -Force -Include '*.js', '*.ps1') {
      $relative = $file.FullName.Substring($Script:RootDir.TrimEnd('\').Length + 1)
      if (-not $shipped.ContainsKey($relative.ToLowerInvariant())) { $retired += $relative }
    }
  }
  foreach ($relative in $retired) { Save-PreviousFile -Relative $relative -Backup $Backup -Previous $Previous -Move }
  $Previous.Copied = $true
  & robocopy.exe $Source $Script:RootDir /E /NFL /NDL /NJH /NJS /NP /R:5 /W:1 | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "Copying the new version failed (robocopy $LASTEXITCODE)." }
}

function Restore-Release {
  param([string]$Backup, $Previous)
  Stop-RelayProcess -Name 'backend' -PidFile $Script:BackendPidFile
  foreach ($tree in $Script:ReleaseTrees) {
    # A tree that was never moved aside is still the previous version.
    if (-not ($Previous.Copied -or $Previous.Trees.Contains($tree))) { continue }
    $target = Join-Path $Script:RootDir $tree
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
  }
  foreach ($tree in $Previous.Trees) {
    Move-Item -LiteralPath (Join-Path $Backup "trees\$tree") -Destination (Join-Path $Script:RootDir $tree)
  }
  foreach ($relative in $Previous.Added) {
    Remove-Item -LiteralPath (Join-Path $Script:RootDir $relative) -Force -ErrorAction SilentlyContinue
  }
  foreach ($relative in $Previous.Files) {
    $target = Join-Path $Script:RootDir $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $Backup "files\$relative") -Destination $target -Force
  }
}

function Show-BackendErrors {
  $log = Join-Path $Script:LogDir 'backend.err.log'
  if (Test-Path -LiteralPath $log) {
    Write-Warn "Last lines of ${log}:"
    Get-Content -LiteralPath $log -Tail 15 | ForEach-Object { Write-Warn "  $_" }
  }
}

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
  # A backend started some other way (npm start, a second copy) holds files
  # and the port; replacing node_modules under it would leave half a tree.
  $deadline = (Get-Date).AddSeconds(15)
  do {
    $blockers = @(Get-RelayBlockers)
    if ($blockers.Count -eq 0) { break }
    Start-Sleep -Seconds 1
  } while ((Get-Date) -lt $deadline)
  if ($blockers.Count -gt 0) {
    # Nothing was replaced, so the stopped version can run again.
    Start-RelayBackend
    Write-Fail ("Relay is still running outside this installation's control:`n  " + ($blockers -join "`n  ") +
      "`nStop it (or close the agent it started), then run update again. Nothing was changed.")
  }

  # The previous version is kept on the same drive so it can be put back by
  # renaming; a rename also fails cleanly when a file is still in use.
  $backup = Join-Path $Script:RootDir ('.relay-update-' + [guid]::NewGuid().ToString('N'))
  $previous = @{ Trees = New-Object Collections.ArrayList; Files = New-Object Collections.ArrayList; Added = New-Object Collections.ArrayList; Copied = $false }
  try {
    New-Item -ItemType Directory -Path (Join-Path $backup 'trees'), (Join-Path $backup 'files') -Force | Out-Null
    Install-Release -Source $source -Backup $backup -Previous $previous
    Start-RelayBackend
    if (-not (Wait-RelayBackendReady)) {
      Show-BackendErrors
      Write-Fail 'The new version did not start.'
    }
    $new = (Get-Content -LiteralPath (Join-Path $Script:ServerDir 'package.json') -Raw | ConvertFrom-Json).version
    Write-Info "Upgraded from $current to $new. Tokens, chats and settings are unchanged."
    Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
  } catch {
    $failure = $_
    Write-Warn "Update failed: $($failure.Exception.Message)"
    Write-Warn "Restoring Relay $current..."
    try {
      Restore-Release -Backup $backup -Previous $previous
      Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
      Write-Warn "Restoring failed: $($_.Exception.Message). The previous files are in $backup."
    }
    # Whatever happened, do not leave the backend stopped.
    Start-RelayBackend
    if (Wait-RelayBackendReady) { Write-Info "Relay $current is running again." }
    else { Show-BackendErrors; Write-Warn "Relay $current did not start either; see $Script:LogDir." }
    throw $failure
  }
} finally {
  Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
