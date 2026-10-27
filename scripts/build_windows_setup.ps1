[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$OutputPath)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw '.NET Framework 4.x C# compiler is required to build Setup.exe.' }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))) | Out-Null
& $compiler /nologo /target:winexe /platform:x64 /optimize+ "/out:$OutputPath" `
  /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll `
  "/win32icon:$(Join-Path $root 'windows\runner\resources\app_icon.ico')" `
  (Join-Path $root 'backends\windows\Setup.cs')
if ($LASTEXITCODE -ne 0) { throw 'Building Setup.exe failed.' }
Write-Host "Setup: $OutputPath"
