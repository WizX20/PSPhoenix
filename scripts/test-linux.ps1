<#
.SYNOPSIS
Runs the Pester suite in a Linux container, as the pwsh-linux CI job does.

.DESCRIPTION
Needs Docker. Starts a throwaway PowerShell container, mounts the working copy read-only at
/src, installs git (and, through scripts/test.ps1, Pester) inside it and runs the suite there.
Nothing on the host changes. Exits with the suite's exit code.

.PARAMETER Path
Test file(s) or folder(s), as for scripts/test.ps1 - relative to the current folder or full
paths, inside the working copy. Defaults to the whole tests/ folder.

.PARAMETER Image
The container image: a PowerShell 7 image with apt-get.

.EXAMPLE
task test:linux

.EXAMPLE
task test:linux -- tests/Scripts.Tests.ps1
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments)][string[]]$Path,
    [string]$Image = 'mcr.microsoft.com/powershell:7.5-ubuntu-24.04'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not (Get-Command docker -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'docker is not on PATH - install Docker Desktop (or run task test on a Linux machine)'
}

# The paths as the container sees them.
$inside = foreach ($item in $Path) {
    $relative = [IO.Path]::GetRelativePath($root, [IO.Path]::GetFullPath($item, (Get-Location -PSProvider FileSystem).ProviderPath))
    if ($relative -eq '..' -or $relative.StartsWith('..' + [IO.Path]::DirectorySeparatorChar) -or [IO.Path]::IsPathRooted($relative)) {
        throw "$item is outside the working copy $root"
    }
    "'/src/$($relative.Replace('\', '/').Replace("'", "''"))'"
}
$test = if ($inside) { "& /src/scripts/test.ps1 -Path $($inside -join ',')" } else { '& /src/scripts/test.ps1' }

# safe.directory: the mounted working copy belongs to another user inside the container.
$steps = @(
    'apt-get update -qq >/dev/null'
    'apt-get install -y -qq git >/dev/null 2>&1'
    "git config --global --add safe.directory '*'"
    "pwsh -NoProfile -Command `"$test`""
) -join ' && '
Write-Host "Linux: $Image" -ForegroundColor DarkGray
docker run --rm -e CI=true -v "${root}:/src:ro" $Image bash -c $steps
exit $LASTEXITCODE
