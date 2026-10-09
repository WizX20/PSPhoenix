# Roots: the folders that hold repositories (docs/design.md -> Concepts). config.roots holds
# { path, depth }; discovery (`phx scan`) walks each root to its depth, a repository directly in
# the root being depth 1.

$script:PhxDefaultRootDepth = 3

function Get-PhxPathComparison {
    # Windows paths compare case-insensitively, everything else exactly.
    if ($script:OnWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
}

function ConvertTo-PhxFullPath {
    # The full form of a path as typed: `~` expanded, relative to the current location, without a
    # trailing separator (a drive or file-system root keeps its own). Does not require it to exist.
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -eq '~' -or $Path -match '^~[\\/]') { $Path = $HOME + $Path.Substring(1) }
    $full = [IO.Path]::GetFullPath($Path, (Get-Location -PSProvider FileSystem).ProviderPath)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) }
    $full
}

function Test-PhxPathWithin {
    # True when $Path is $Parent or lies below it.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Parent)
    $comparison = Get-PhxPathComparison
    if ([string]::Equals($Path, $Parent, $comparison)) { return $true }
    $prefix = $Parent.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $Path.StartsWith($prefix, $comparison)
}

function Get-PhxRoot {
    # The configured roots, in config order.
    @((Read-PhxConfig).roots | Where-Object { $_ })
}

function Add-PhxRoot {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [int]$Depth
    )
    if (-not $Path) { throw 'usage: phx roots add <path> [-Depth <n>]' }
    $full = ConvertTo-PhxFullPath $Path
    if (-not [IO.Directory]::Exists($full)) { throw "no such folder: $full" }

    $config = Read-PhxConfig
    # An existing root with an explicit -Depth: change its depth.
    $existing = @($config.roots | Where-Object { $_ -and [string]::Equals($_.path, $full, (Get-PhxPathComparison)) })[0]
    if ($existing) {
        if (-not $Depth) { throw "$full is a root already (depth $($existing.depth)) - add -Depth <n> to change its depth" }
        $existing.depth = $Depth
        Save-PhxConfig $config
        Write-Host "root $($existing.path) now has depth $Depth - phx scan picks it up" -ForegroundColor Green
        return
    }
    if (-not $Depth) { $Depth = $script:PhxDefaultRootDepth }
    foreach ($root in @($config.roots | Where-Object { $_ })) {
        # Overlapping roots would make discovery see the same repositories twice.
        if (Test-PhxPathWithin $full $root.path) { throw "$full lies inside the root $($root.path) - raise that root's depth instead (phx roots add $($root.path) -Depth <n>)" }
        if (Test-PhxPathWithin $root.path $full) { throw "$full contains the root $($root.path) - remove that one first (phx roots rm $($root.path))" }
    }
    $config.roots = @($config.roots | Where-Object { $_ }) + @([ordered]@{ path = $full; depth = $Depth })
    Save-PhxConfig $config
    Write-Host "added root $full (depth $Depth) - phx scan finds its repositories" -ForegroundColor Green
}

function Remove-PhxRoot {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if (-not $Path) { throw 'usage: phx roots rm <path>' }
    # No existence check: a root whose folder is gone must still be removable.
    $full = ConvertTo-PhxFullPath $Path
    $config = Read-PhxConfig
    $roots = @($config.roots | Where-Object { $_ })
    $keep = @($roots | Where-Object { -not [string]::Equals($_.path, $full, (Get-PhxPathComparison)) })
    if ($keep.Count -eq $roots.Count) { throw "$full is not a root - see: phx roots list" }
    $config.roots = $keep
    Save-PhxConfig $config
    Write-Host "removed root $full" -ForegroundColor Green
}

function Invoke-PhxRootsCommand {
    # phx roots add <path> [-Depth <n>] | rm <path> | list
    param([string]$Action, [string]$Path, [int]$Depth)
    switch ($Action) {
        { $_ -in '', 'list' } { Show-PhxRoots; return }
        'add' { Add-PhxRoot -Path $Path -Depth $Depth; return }
        { $_ -in 'rm', 'remove' } { Remove-PhxRoot -Path $Path; return }
        default { throw "unknown action '$Action' - use: phx roots add <path> | rm <path> | list" }
    }
}

function Show-PhxRoots {
    $roots = Get-PhxRoot
    if (-not $roots) {
        Write-Host 'no roots yet - add the folders that hold your repositories: phx roots add <path>' -ForegroundColor Yellow
        return
    }
    $cache = Read-PhxRepoCache
    foreach ($root in $roots) {
        $count = Get-PhxRootRepoCount -Cache $cache -Root $root.path
        $found = if ($null -eq $count) { 'not scanned yet' } else { "$count repositories" }
        $missing = if ([IO.Directory]::Exists($root.path)) { '' } else { '   (folder not found)' }
        Write-Host ('  {0}   depth {1}   {2}{3}' -f $root.path, $root.depth, $found, $missing)
    }
}
