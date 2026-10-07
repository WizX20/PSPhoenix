# Where PSPhoenix keeps its own files. The config is part of every snapshot; the state (hashes,
# last-run times, the repository cache) is machine-local and never backed up.

function Get-PhxConfigDir {
    if ($script:OnWindows) { return Join-Path (Get-PhxWindowsFolder 'APPDATA' 'ApplicationData') 'PSPhoenix' }
    Join-Path (Get-PhxXdgDir 'XDG_CONFIG_HOME' '.config') 'psphoenix'
}

function Get-PhxStateDir {
    if ($script:OnWindows) { return Join-Path (Get-PhxWindowsFolder 'LOCALAPPDATA' 'LocalApplicationData') 'PSPhoenix' }
    Join-Path (Get-PhxXdgDir 'XDG_STATE_HOME' '.local/state') 'psphoenix'
}

function Get-PhxConfigPath { Join-Path (Get-PhxConfigDir) 'config.json' }

function Get-PhxWindowsFolder {
    # The environment variable first - tests redirect it - else the known folder itself: a process
    # started with a stripped environment (Start-Process -UseNewEnvironment, some schedulers) has
    # no APPDATA, and Join-Path on $null throws.
    param([string]$Variable, [Environment+SpecialFolder]$Folder)
    $value = [Environment]::GetEnvironmentVariable($Variable)
    if ($value) { return $value }
    $value = [Environment]::GetFolderPath($Folder)
    if (-not $value) { throw "cannot locate the $Folder folder: $Variable is not set" }
    $value
}

function Get-PhxXdgDir {
    # An XDG base directory: the variable when it holds an absolute path - the spec says to
    # ignore a relative one - else its default under $HOME.
    param([string]$Variable, [string]$Default)
    $value = [Environment]::GetEnvironmentVariable($Variable)
    if ($value -and [IO.Path]::IsPathRooted($value)) { return $value }
    Join-Path $HOME $Default
}
