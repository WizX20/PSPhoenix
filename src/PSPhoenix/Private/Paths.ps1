# Where PSPhoenix keeps its own files. The config is part of every snapshot; the state (hashes,
# last-run times, the repository cache) is machine-local and never backed up.

function Get-PhxConfigDir {
    if ($script:OnWindows) { return Join-Path $env:APPDATA 'PSPhoenix' }
    $base = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
    Join-Path $base 'psphoenix'
}

function Get-PhxStateDir {
    if ($script:OnWindows) { return Join-Path $env:LOCALAPPDATA 'PSPhoenix' }
    $base = if ($env:XDG_STATE_HOME) { $env:XDG_STATE_HOME } else { Join-Path $HOME '.local/state' }
    Join-Path $base 'psphoenix'
}

function Get-PhxConfigPath { Join-Path (Get-PhxConfigDir) 'config.json' }
