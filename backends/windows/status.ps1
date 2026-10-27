Set-StrictMode -Version 2.0
. "$PSScriptRoot\lib\setup.ps1"

Require-Windows
Show-RelayStatus
Get-RelayDetails | ConvertTo-Json -Depth 6 | Write-Host
