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
$version = (Test-ModuleManifest (Join-Path $src 'PSPhoenix.psd1')).Version.ToString()

$dist = Join-Path $root 'dist'
$stage = Join-Path $dist 'PSPhoenix'
if (Test-Path $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
# The module spans Private/ and Providers/; .gitkeep only exists to keep an empty folder in git.
Copy-Item (Join-Path $src '*') $stage -Recurse
Get-ChildItem $stage -Recurse -Force -Filter '.gitkeep' | Remove-Item -Force
Copy-Item (Join-Path $root 'LICENSE'), (Join-Path $root 'NOTICE') $stage

$zip = Join-Path $dist "PSPhoenix-$version.zip"
if (Test-Path $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path $stage -DestinationPath $zip
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash
Write-Host "packed $zip" -ForegroundColor Green
Write-Host "sha256 $hash"
[pscustomobject]@{ Version = $version; Zip = $zip; Sha256 = $hash }
