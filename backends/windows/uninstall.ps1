Set-StrictMode -Version 2.0
. "$PSScriptRoot\lib\common.ps1"

Require-Windows
Stop-RelayServices
Unregister-RelayStartup
Write-Info 'Windows startup task removed.'
