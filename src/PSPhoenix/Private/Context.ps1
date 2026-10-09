# What a provider gets to work with (docs/design.md -> Provider contract). M1 brings the config,
# the staging folder, DryRun, a logger and - for restore - the root mapping and the selection; the
# state store (M2) and the secret writer (M3) join later.

function Write-PhxLog {
    # One line of provider output. Warn is yellow, Action (what a restore does or would do) cyan.
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('Info', 'Warn', 'Action')][string]$Level = 'Info')
    switch ($Level) {
        'Warn' { Write-Host "  $Message" -ForegroundColor Yellow }
        'Action' { Write-Host "  $Message" -ForegroundColor Cyan }
        default { Write-Host "  $Message" }
    }
}

function New-PhxContext {
    param(
        [Parameter(Mandatory)][string]$Provider,
        # Backup writes here; restore reads from here - the provider's folder in a snapshot.
        # Status has none.
        [string]$Staging = '',
        [System.Collections.IDictionary]$Config,
        [switch]$DryRun,
        # Restore: old root -> new root (absent = unchanged).
        [System.Collections.IDictionary]$RootMap = @{},
        # Restore: the repository identities to restore (none = all).
        [string[]]$Select = @()
    )
    if (-not $Config) { $Config = Read-PhxConfig }
    [pscustomobject]@{
        Provider = $Provider
        Config   = $Config
        Staging  = $Staging
        DryRun   = [bool]$DryRun
        RootMap  = $RootMap
        Select   = @($Select)
        Log      = { param([string]$Message, [string]$Level = 'Info') Write-PhxLog -Message $Message -Level $Level }
    }
}
