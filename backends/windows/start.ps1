Set-StrictMode -Version 2.0
. "$PSScriptRoot\lib\common.ps1"

Require-Windows
Require-Node
Ensure-EnvFile
Start-AgentDeckServices
