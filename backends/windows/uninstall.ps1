Set-StrictMode -Version 2.0
. "$PSScriptRoot\lib\common.ps1"

Require-Windows
Stop-AgentDeckServices
Unregister-AgentDeckStartup
Write-Info 'Windows startup task removed.'
