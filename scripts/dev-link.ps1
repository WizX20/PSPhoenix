<#
.SYNOPSIS
Links src/PSPhoenix into your CurrentUser module path so `Import-Module PSPhoenix` loads the working copy.

.DESCRIPTION
Creates <CurrentUser modules>/PSPhoenix -> <repo>/src/PSPhoenix: a directory junction on Windows
(no admin rights needed), a symbolic link elsewhere. Edits in the checkout are live after
`Import-Module PSPhoenix -Force`. A link that points at another checkout - a removed worktree,
say - is pointed at this one. Refuses to replace a real directory; a Scoop install lives in
~/scoop/modules, so the two do not collide, but the link shadows it while present. -Remove takes
the link away again.

.PARAMETER Remove
Remove the link instead of creating it.

.PARAMETER ModulesPath
The module folder to link into. Defaults to the CurrentUser module path of PowerShell 7
(Documents\PowerShell\Modules on Windows, ~/.local/share/powershell/Modules elsewhere); tests
point it into a scratch folder.
#>
[CmdletBinding()]
param(
    [switch]$Remove,
    [string]$ModulesPath
)
$ErrorActionPreference = 'Stop'
$src = Join-Path (Split-Path $PSScriptRoot -Parent) 'src/PSPhoenix'
if (-not $ModulesPath) {
    $ModulesPath = if ($IsWindows) { Join-Path (Split-Path $PROFILE.CurrentUserAllHosts -Parent) 'Modules' }
    else { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'powershell/Modules' }
}
$link = Join-Path $ModulesPath 'PSPhoenix'
# -Force: Get-Item also finds a link whose target is gone; Test-Path alone says True or False
# for it depending on the platform.
$item = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue

if ($Remove) {
    if (-not $item) { Write-Host "no link at $link" -ForegroundColor DarkGray; return }
    if (-not $item.LinkType) { throw "$link is a real directory, not a link - not touching it" }
    $item.Delete()
    Write-Host "removed $link" -ForegroundColor Green
    return
}
if ($item) {
    if (-not $item.LinkType) { throw "$link already exists as a real directory - remove it first" }
    $target = @($item.Target)[0]
    if ($target -and (Test-Path -LiteralPath $target) -and
        (Resolve-Path -LiteralPath $target).ProviderPath.TrimEnd('\', '/') -eq (Resolve-Path -LiteralPath $src).ProviderPath.TrimEnd('\', '/')) {
        Write-Host "already linked: $link -> $src" -ForegroundColor DarkGray
        return
    }
    # Another checkout, or one that no longer exists: point it here.
    $item.Delete()
    Write-Host "re-pointing $link (was -> $target)" -ForegroundColor Yellow
}
New-Item -ItemType Directory -Force -Path $ModulesPath | Out-Null
New-Item -ItemType ($IsWindows ? 'Junction' : 'SymbolicLink') -Path $link -Target $src | Out-Null
Write-Host "linked $link -> $src" -ForegroundColor Green
Write-Host 'now: Import-Module PSPhoenix -Force' -ForegroundColor DarkGray
