# Platform adapter contract; runs without administrator rights, network or tasks.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\install\windows\lib\setup.ps1"
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('relay-setup-test-' + [guid]::NewGuid().ToString('N'))
$Script:RootDir = Join-Path $scratch 'bundle with spaces'
$Script:ServerDir = Join-Path $Script:RootDir 'server'
$Script:EnvFile = Join-Path $Script:ServerDir '.env'
$Script:EnvExample = Join-Path $Script:ServerDir '.env.example'
$Script:BackendPidFile = Join-Path $scratch 'backend.pid'
$Script:LogDir = Join-Path $scratch 'logs'
New-Item -ItemType Directory -Path $Script:ServerDir, (Join-Path $Script:RootDir 'app\shell\build\web') -Force | Out-Null
# Non-ASCII comments (as in the real .env.example) must survive every rewrite.
$unicodeComment = '# Agent binary ' + [char]0x2014 + ' ' + [char]0x9ED8 + [char]0x8BA4
[IO.File]::WriteAllText($Script:EnvExample, "$unicodeComment`nPORT=8787`nKEEP_ME=original`n", (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $Script:RootDir 'app\shell\build\web\index.html'), 'fixture')
$script:started = 0; $script:stopped = 0; $script:registered = 0; $script:forceDeps = $false
$script:dnsArgs = @(); $script:credentialArgs = @()
function Require-Node { }
function Install-ServerDeps { param([switch]$Force); $script:forceDeps = [bool]$Force }
function Test-RelayBrowser { }
function Install-RelayAgentClis { param([string[]]$Agents); }
function Register-RelayStartup { $script:registered++ }
function Unregister-RelayStartup { $script:registered-- }
function Start-RelayServices { $script:started++ }
function Stop-RelayServices { $script:stopped++ }
function Ensure-Cloudflared { }
function Ensure-NamedTunnel { param([string]$Name); return 'fixture-tunnel-id' }
function Wait-ForTunnelUrl { return 'https://fresh-fixture.trycloudflare.com' }
function cloudflared { $script:dnsArgs = @($args); $global:LASTEXITCODE = 0 }
function Invoke-RelayCredential { param([string[]]$Arguments, [string]$Passphrase); $script:credentialArgs = $Arguments; if ($Passphrase -ne 'fixture-password') { throw 'Password was not passed securely.' } }
# The user PATH lives in memory here; the test never writes the registry.
$script:userPath = '%USERPROFILE%\existing;C:\Tools'; $script:userPathWrites = 0; $script:hostNode = $false
function Get-UserPathRaw { return $script:userPath }
function Set-UserPathRaw { param([string]$Value); $script:userPath = $Value; $script:userPathWrites++ }
function Test-HostNode { param([string[]]$UserEntries); return $script:hostNode }
function Assert-That { param([bool]$Condition, [string]$Message); if (-not $Condition) { throw $Message } }
function Expect-Failure { param([scriptblock]$Operation); $failed = $false; try { & $Operation } catch { $failed = $true }; Assert-That $failed 'Expected validation failure.' }
try {
  Install-RelayBackend -NetworkMode none -PublicUrl 'http://127.0.0.1:18787' -Port 18787 -Passphrase 'fixture-password'
  Assert-That ((Get-EnvValue 'HOST') -eq '0.0.0.0') 'Direct mode binding.'
  Assert-That ((Get-EnvValue 'RELAY_SERVE_WEB') -eq '1') 'Web should be enabled.'
  Assert-That ((Get-EnvValue 'KEEP_ME') -eq 'original') 'Existing configuration must survive.'
  Assert-That (([IO.File]::ReadAllLines($Script:EnvFile, [Text.Encoding]::UTF8))[0] -eq $unicodeComment) 'Rewriting .env must keep UTF-8 comments intact.'
  Assert-That ((Get-EnvValue 'RELAY_WORKSPACE_ROOT') -eq '') 'File access is open unless isolation is chosen.'
  Assert-That ($script:registered -eq 1 -and $script:started -eq 1) 'Register and start services.'
  [IO.File]::WriteAllText((Join-Path $Script:ServerDir 'tokens.json'), 'retained fixture')
  Install-RelayBackend -Reinstall -NetworkMode quick -ServeWeb $false -Passphrase 'fixture-password'
  Assert-That ($script:forceDeps -and $script:stopped -eq 1) 'Reinstall must stop services and reinstall dependencies.'
  Assert-That ((Get-EnvValue 'PUBLIC_BASE_URL') -eq 'https://fresh-fixture.trycloudflare.com') 'Quick mode must use the new URL.'
  Assert-That ((Get-EnvValue 'HOST') -eq '127.0.0.1') 'Tunnel should bind loopback.'
  Install-RelayBackend -Reinstall -NetworkMode quick -Isolated $true -Passphrase 'fixture-password'
  $workspace = Join-Path $Script:RootDir 'workspace'
  Assert-That ((Get-EnvValue 'RELAY_WORKSPACE_ROOT') -eq $workspace) 'Isolation must confine file access to the bundle workspace.'
  Assert-That (Test-Path -LiteralPath $workspace -PathType Container) 'Isolation must create the workspace folder.'
  Install-RelayBackend -Reinstall -NetworkMode quick -Passphrase 'fixture-password'
  Assert-That ((Get-EnvValue 'RELAY_WORKSPACE_ROOT') -eq '') 'Reinstalling as open must lift isolation.'
  Assert-That (Test-Path -LiteralPath $workspace -PathType Container) 'Lifting isolation must keep the workspace files.'
  Install-RelayBackend -Reinstall -NetworkMode cloudflare -Hostname 'agent.example.com' -TunnelName 'relay-fixture' -Passphrase 'fixture-password'
  $config = Join-Path $Script:ServerDir 'cloudflared-config\relay-fixture.yml'
  Assert-That ((Get-EnvValue 'CLOUDFLARED_ARGS').Contains('"' + $config + '"')) 'Tunnel config paths with spaces must stay quoted.'
  Assert-That ($script:dnsArgs[0] -eq 'tunnel' -and $script:dnsArgs[2] -eq 'dns') 'Named DNS route.'
  Install-RelayBackend -Reinstall -NetworkMode none -BindAddress '100.101.102.103' -PublicUrl 'https://relay.example.test' -Passphrase 'fixture-password'
  Assert-That ((Get-EnvValue 'HOST') -eq '100.101.102.103') 'Bind only the Tailscale address.'
  Assert-That ((Get-EnvValue 'PUBLIC_BASE_URL') -eq 'https://relay.example.test') 'Use HTTPS for Web credentials.'
  Assert-That ($script:credentialArgs[1] -eq 'https://relay.example.test') 'The device credential uses the proxy origin.'
  Install-RelayBackend -Reinstall -NetworkMode none -BindAddress '100.101.102.103' -ServeWeb $false -PublicUrl 'http://100.101.102.103:8787' -Passphrase 'fixture-password'
  Assert-That ((Get-EnvValue 'RELAY_SERVE_WEB') -eq '0') 'Native-only Tailscale disables Web.'
  Assert-That ($script:credentialArgs[1] -eq 'http://100.101.102.103:8787') 'Native-only credentials use the tailnet IP.'
  $before = Get-Content -LiteralPath $Script:EnvFile -Raw
  Expect-Failure { Install-RelayBackend -Port 0 -NetworkMode none -PublicUrl 'http://example.com' }
  Expect-Failure { Install-RelayBackend -NetworkMode none -PublicUrl "http://example.com`nBAD=1" }
  Expect-Failure { Install-RelayBackend -NetworkMode cloudflare -Hostname 'bad"host' }
  Expect-Failure { Set-EnvValue 'PORT' "123`nBAD=1" }
  Assert-That ((Get-Content -LiteralPath $Script:EnvFile -Raw) -eq $before) 'Invalid input must not change configuration.'
  Assert-That (([IO.File]::ReadAllLines($Script:EnvFile, [Text.Encoding]::UTF8))[0] -eq $unicodeComment) 'Repeated reinstalls must not re-encode .env.'
  # New terminals must find the agent CLIs: folders holding one, plus the
  # bundled Node when the host has none, are appended to the user PATH.
  $original = $script:userPath
  $npmDir = Join-Path $scratch 'npm'; $emptyDir = Join-Path $scratch 'empty'; $localBin = Join-Path $scratch 'local bin'
  New-Item -ItemType Directory -Path $npmDir, $emptyDir, $localBin -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $npmDir 'codex.cmd'), ''); [IO.File]::WriteAllText((Join-Path $localBin 'claude.exe'), '')
  $Script:AgentCliDirs = @($localBin, $emptyDir, $npmDir)
  $Script:BundledNodeDir = Join-Path $scratch 'runtime\node'
  New-Item -ItemType Directory -Path $Script:BundledNodeDir -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $Script:BundledNodeDir 'node.exe'), '')
  $Script:UserPathRecord = Join-Path $scratch 'user-path.json'
  $script:userPath = "$original;$localBin\"
  $original = $script:userPath
  Sync-RelayUserPath
  Assert-That ($script:userPath -eq "$original;$npmDir;$($Script:BundledNodeDir)") "CLI folders and bundled Node must be appended once, got: $($script:userPath)"
  Assert-That ($script:userPath.StartsWith('%USERPROFILE%\existing;')) 'Unexpanded user PATH entries must stay unexpanded.'
  $writes = $script:userPathWrites
  Sync-RelayUserPath
  Assert-That ($script:userPathWrites -eq $writes) 'An unchanged sync must not rewrite the user PATH.'
  $script:hostNode = $true
  Sync-RelayUserPath
  Assert-That ($script:userPath -eq "$original;$npmDir") 'A host Node makes the bundled one unnecessary.'
  Uninstall-RelayBackend
  Assert-That ($script:userPath -eq $original) 'Uninstall must remove only the PATH entries Setup added.'
  Assert-That (-not (Test-Path -LiteralPath $Script:UserPathRecord)) 'Uninstall must clear the PATH record.'
  Assert-That (-not (Test-Path -LiteralPath (Join-Path $Script:RootDir 'app\shell\build\web'))) 'Uninstall removes Web.'
  Assert-That ((Get-Content -LiteralPath (Join-Path $Script:ServerDir 'tokens.json') -Raw) -eq 'retained fixture') 'Uninstall must keep device tokens.'
  Assert-That ((Get-EnvValue 'KEEP_ME') -eq 'original') 'Uninstall must keep custom configuration.'
  $incomplete = ''; try { Get-RelayDetails | Out-Null } catch { $incomplete = $_.Exception.Message }
  Assert-That ($incomplete -like '*bundle is incomplete*windows-setup.js*') 'A partly extracted bundle must name the missing status bridge.'
  # A host Node on the user PATH must not shadow the bundle's own runtime.
  $fakeLib = Join-Path $scratch 'bundle\scripts\install\windows\lib'
  $fakeNodeDir = Join-Path $scratch 'bundle\runtime\node'
  New-Item -ItemType Directory -Path $fakeLib, $fakeNodeDir -Force | Out-Null
  Copy-Item -LiteralPath "$PSScriptRoot\..\install\windows\lib\common.ps1" -Destination $fakeLib
  [IO.File]::WriteAllText((Join-Path $fakeNodeDir 'node.exe'), '')
  $firstPath = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ". '$(Join-Path $fakeLib 'common.ps1')'; (`$env:PATH -split ';')[0]"
  Assert-That ($firstPath -eq $fakeNodeDir) "Bundled Node must lead PATH, got: $firstPath"
  # Test-RelayBrowser warns instead of throwing when check-browser fails or writes stderr, and Get-TailscaleIPv4 validates 100.64.0.0/10.
  $fakeServerScripts = Join-Path $scratch 'bundle\server\scripts'
  $fakeBin = Join-Path $scratch 'fake-bin'
  New-Item -ItemType Directory -Path $fakeServerScripts, $fakeBin -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $fakeServerScripts 'check-browser.js'), "console.error('stderr noise'); process.exitCode = 1;")
  [IO.File]::WriteAllText((Join-Path $fakeBin 'tailscale.cmd'), "@echo off`r`nif `"%RELAY_FAKE_TS%`"==`"bad`" (`r`n  echo 100.200.1.2`r`n  exit /b 0`r`n)`r`nif `"%RELAY_FAKE_TS%`"==`"fail`" (`r`n  echo 100.101.102.103`r`n  exit /b 1`r`n)`r`necho 100.101.102.103`r`n")
  $tsResult = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Set-StrictMode -Version 2.0; `$env:PATH = '$fakeBin;' + `$env:PATH; . '$(Join-Path $fakeLib 'common.ps1')'; Test-RelayBrowser; `$env:RELAY_FAKE_TS='ok'; `$a = Get-TailscaleIPv4; `$env:RELAY_FAKE_TS='bad'; `$b = Get-TailscaleIPv4; `$env:RELAY_FAKE_TS='fail'; `$c = Get-TailscaleIPv4; if (`$a -ne '100.101.102.103' -or `$b -ne `$null -or `$c -ne `$null) { throw 'Tailscale contract failed' }; 'ok'"
  Assert-That (($tsResult | Select-Object -Last 1) -eq 'ok') 'Test-RelayBrowser and Get-TailscaleIPv4 contract.'
  Write-Host 'Windows setup contract passed: direct / quick / named tunnel, open / isolated file access, reinstall, input validation, UTF-8 .env rewrites, bundled Node first, user PATH sync, browser/Tailscale checks, uninstall, retained state and incomplete bundles.'
} finally {
  $resolved = [IO.Path]::GetFullPath($scratch)
  $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
  if (-not $resolved.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'relay-setup-test-*') { throw 'Refusing unsafe cleanup path.' }
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
