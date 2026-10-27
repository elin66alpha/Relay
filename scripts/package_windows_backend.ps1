[CmdletBinding()]
param(
  [string]$NodeDirectory = '',
  [string]$OutputDirectory = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
  throw 'Build this bundle on Windows so native dependencies match the target.'
}
if (-not $NodeDirectory) {
  $NodeDirectory = Split-Path -Parent (Get-Command node.exe -ErrorAction Stop).Source
}
$NodeDirectory = (Resolve-Path -LiteralPath $NodeDirectory).Path
$node = Join-Path $NodeDirectory 'node.exe'
$npm = Join-Path $NodeDirectory 'npm.cmd'
foreach ($required in @($node, $npm, (Join-Path $NodeDirectory 'LICENSE'),
    (Join-Path $NodeDirectory 'node_modules\npm\bin\npm-cli.js'))) {
  if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
    throw "Missing Node.js distribution file: $required"
  }
}
$runtimeInfo = & $node -p 'JSON.stringify({version:process.versions.node,arch:process.arch,platform:process.platform})'
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the Node.js runtime.' }
$runtimeInfo = $runtimeInfo | ConvertFrom-Json
if ($runtimeInfo.platform -ne 'win32' -or $runtimeInfo.arch -ne 'x64' -or
    [int]($runtimeInfo.version.Split('.')[0]) -lt 18) {
  throw 'The bundle requires a Windows x64 Node.js 18+ distribution.'
}
$package = Get-Content -LiteralPath (Join-Path $root 'server\package.json') -Raw | ConvertFrom-Json
$lockVersion = & $node -p 'require(process.argv[1]).version' (Join-Path $root 'server\package-lock.json')
if ($LASTEXITCODE -ne 0 -or $package.version -ne $lockVersion) {
  throw 'Backend package/lock versions differ.'
}
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'build\release' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$name = "relay-backend-windows-x64-v$($package.version)"
$archive = Join-Path $OutputDirectory "$name.zip"
if (Test-Path -LiteralPath $archive) { throw "Archive already exists: $archive" }
# A fresh staging directory prevents deployment state or a developer's installed
# node_modules from entering the release. Use an explicit source allowlist.
$stage = Join-Path $OutputDirectory ("stage-" + [guid]::NewGuid().ToString('N'))
$bundle = Join-Path $stage $name
New-Item -ItemType Directory -Path $bundle -Force | Out-Null
$tracked = & git -C $root ls-files -- server backends/windows
if ($LASTEXITCODE -ne 0) { throw 'Could not list tracked backend source files.' }
$sources = @($tracked | Where-Object {
  $_ -match '^server/(server\.js|package(-lock)?\.json|\.env\.example|\.gitignore)$' -or
  $_ -match '^server/(lib|routes|scripts|test)/.*\.js$' -or
  $_ -match '^backends/windows/(lib/)?[^/]+\.ps1$'
})
foreach ($relative in $sources) {
  $destination = Join-Path $bundle $relative
  New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $root $relative) -Destination $destination
}
foreach ($relative in @('LICENSE', 'SECURITY.md', 'CHANGELOG.md',
    'backends/README.md', 'backends/README.zh-CN.md', 'docs/handbook.md')) {
  $destination = Join-Path $bundle $relative
  New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $root $relative) -Destination $destination
}
Copy-Item -LiteralPath (Join-Path $root 'backends\windows\PACKAGE.md') -Destination (Join-Path $bundle 'README.md')
$runtime = Join-Path $bundle 'runtime\node'
New-Item -ItemType Directory -Path (Join-Path $runtime 'node_modules') -Force | Out-Null
foreach ($file in @('node.exe', 'LICENSE', 'npm.cmd', 'npm.ps1', 'npx.cmd', 'npx.ps1')) {
  Copy-Item -LiteralPath (Join-Path $NodeDirectory $file) -Destination $runtime
}
Copy-Item -LiteralPath (Join-Path $NodeDirectory 'node_modules\npm') -Destination (Join-Path $runtime 'node_modules') -Recurse
$oldPath = $env:PATH
try {
  $env:PATH = "$runtime;$oldPath"
  & (Join-Path $runtime 'npm.cmd') --prefix (Join-Path $bundle 'server') ci --omit=dev --no-audit --no-fund
  if ($LASTEXITCODE -ne 0) { throw 'Installing locked production dependencies failed.' }
  Push-Location (Join-Path $bundle 'server')
  try {
    & (Join-Path $runtime 'node.exe') -e 'require("node-pty"); require("ws"); require("firebase-admin"); console.log("Runtime dependencies load successfully")'
    if ($LASTEXITCODE -ne 0) { throw 'Packaged runtime dependency check failed.' }
  } finally { Pop-Location }
} finally { $env:PATH = $oldPath }

$ascii = New-Object Text.ASCIIEncoding
foreach ($command in @('setup', 'start', 'stop', 'status', 'uninstall')) {
  $commandLine = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0backends\windows\' + $command + '.ps1" %*'
  $lines = @('@echo off', $commandLine, 'exit /b %errorlevel%')
  [IO.File]::WriteAllLines((Join-Path $bundle "$command.cmd"), $lines, $ascii)
}
[IO.File]::WriteAllLines((Join-Path $bundle 'credential.cmd'), @(
  '@echo off', 'setlocal', 'set "PATH=%~dp0runtime\node;%PATH%"',
  '"%~dp0runtime\node\node.exe" "%~dp0server\scripts\create-credential.js" %*',
  'exit /b %errorlevel%'
), $ascii)
$commit = & git -C $root rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Could not read the source revision.' }
$manifest = [ordered]@{
  version = $package.version
  sourceCommit = [string]$commit
  nodeVersion = $runtimeInfo.version
  platform = 'win32'
  architecture = 'x64'
  packageLockSha256 = (Get-FileHash -LiteralPath (Join-Path $bundle 'server\package-lock.json') -Algorithm SHA256).Hash.ToLowerInvariant()
}
[IO.File]::WriteAllText((Join-Path $bundle 'bundle-info.json'), ($manifest | ConvertTo-Json) + "`n", (New-Object Text.UTF8Encoding($false)))

# Audit Relay's own tree separately: dependency packages legitimately ship JSON
# files with names that resemble application state. No local config is copied.
$allowed = @($sources) + @('LICENSE', 'SECURITY.md', 'CHANGELOG.md', 'README.md',
  'backends/README.md', 'backends/README.zh-CN.md', 'docs/handbook.md',
  'setup.cmd', 'start.cmd', 'stop.cmd', 'status.cmd', 'uninstall.cmd',
  'credential.cmd', 'bundle-info.json')
foreach ($file in Get-ChildItem -LiteralPath $bundle -Recurse -File -Force) {
  $relative = $file.FullName.Substring($bundle.Length + 1).Replace('\', '/')
  if ($relative.StartsWith('runtime/node/') -or $relative.StartsWith('server/node_modules/')) { continue }
  if ($relative -notin $allowed) { throw "Unexpected file in the release: $relative" }
}
# ZipFile includes .env.example, unlike Compress-Archive's hidden-file filtering.
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $archive, [IO.Compression.CompressionLevel]::Optimal, $false)
$hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText((Join-Path $OutputDirectory "$name.sha256"), "$hash  $name.zip`n", $ascii)
Write-Host "Archive: $archive"
Write-Host "SHA256:  $hash"
Write-Host "Staging: $bundle"
