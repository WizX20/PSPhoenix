<#
.SYNOPSIS
Builds the engine (engine/) and puts PSPhoenix.Engine.dll into the module: src/PSPhoenix/lib/.

.DESCRIPTION
The module loads the engine from lib/ and does not import without it, so scripts/test.ps1,
scripts/pack.ps1, `task help` and `task link` build first. Needs the .NET SDK 10 or newer
(engine/global.json); the engine itself targets .NET 8, what PowerShell 7.4 runs on. The DLL is
build output: git ignores it, the release zip carries it. It gets the module's version.

The module loads the engine from its bytes, so a session that imported it does not hold the DLL
open - but it keeps running the engine it loaded: start a new session to use a new build. An
unchanged build is not copied at all.

.PARAMETER Configuration
Release (the default, what the zip ships) or Debug.
#>
[CmdletBinding()]
param([ValidateSet('Release', 'Debug')][string]$Configuration = 'Release')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not (Get-Command dotnet -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'dotnet is not on PATH - install the .NET SDK 10 or newer: winget install Microsoft.DotNet.SDK.10 (or https://dot.net)'
}
$version = (Import-PowerShellDataFile -LiteralPath (Join-Path $root 'src/PSPhoenix/PSPhoenix.psd1')).ModuleVersion
$project = Join-Path $root 'engine/src/PSPhoenix.Engine'

# From engine/, so its global.json picks the SDK.
Push-Location -LiteralPath (Join-Path $root 'engine')
try { dotnet build $project --configuration $Configuration --nologo --verbosity quiet -clp:NoSummary "-p:Version=$version" }
finally { Pop-Location }
if ($LASTEXITCODE) { throw "dotnet build failed (exit code $LASTEXITCODE)" }

$built = Join-Path $project "bin/$Configuration/net8.0/PSPhoenix.Engine.dll"
$lib = Join-Path $root 'src/PSPhoenix/lib'
$target = Join-Path $lib 'PSPhoenix.Engine.dll'
[IO.Directory]::CreateDirectory($lib) | Out-Null
if ([IO.File]::Exists($target) -and (Get-FileHash -LiteralPath $built).Hash -eq (Get-FileHash -LiteralPath $target).Hash) {
    Write-Host "engine up to date: $target" -ForegroundColor DarkGray
    return
}
try { [IO.File]::Copy($built, $target, $true) }
catch {
    throw "cannot replace ${target}: $($_.Exception.InnerException.Message ?? $_.Exception.Message)"
}
Write-Host "built $target ($version, $Configuration)" -ForegroundColor Green
