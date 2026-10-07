<#
.SYNOPSIS
Builds the release zip: dist/PSPhoenix-<version>.zip with a single top-level PSPhoenix/ folder inside.

.DESCRIPTION
The zip is what a GitHub Release carries and what the Scoop manifest downloads. Scoop's
`extract_dir: "PSPhoenix"` strips the top-level folder, so the install dir IS the module folder
(PSPhoenix.psd1 at its root) and the `psmodule` junction ~/scoop/modules/PSPhoenix points straight at it.
The version comes from src/PSPhoenix/PSPhoenix.psd1 - stamp it first with scripts/set-version.ps1.
Prints the zip path and its SHA256 (the value bucket/psphoenix.json needs).
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$src = Join-Path $root 'src/PSPhoenix'
$version = (Import-PowerShellDataFile -LiteralPath (Join-Path $src 'PSPhoenix.psd1')).ModuleVersion

$dist = Join-Path $root 'dist'
$stage = Join-Path $dist 'PSPhoenix'
# Literal paths throughout: a checkout under a folder with [ or ] in its name would otherwise be
# read as a wildcard pattern - an incomplete zip, or none.
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
# The module spans Private/ and Providers/; .gitkeep only exists to keep an empty folder in git.
Get-ChildItem -LiteralPath $src -Force | Copy-Item -Destination $stage -Recurse
Get-ChildItem -LiteralPath $stage -Recurse -Force -Filter '.gitkeep' | Remove-Item -Force
Copy-Item -LiteralPath (Join-Path $root 'LICENSE'), (Join-Path $root 'NOTICE') -Destination $stage

$zip = Join-Path $dist "PSPhoenix-$version.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
# Not Compress-Archive: it reads -DestinationPath as a wildcard pattern. The base directory goes
# in, so the zip holds one PSPhoenix/ folder - what the manifest's extract_dir expects.
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, [IO.Compression.CompressionLevel]::Optimal, $true)
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
Write-Host "packed $zip" -ForegroundColor Green
Write-Host "sha256 $hash"
[pscustomobject]@{ Version = $version; Zip = $zip; Sha256 = $hash }
