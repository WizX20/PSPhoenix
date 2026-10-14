# What a provider gets to work with (docs/design.md -> Provider contract): the config, the staging
# folder, the state store, DryRun, a logger, what the secret check held back, and - for restore -
# the root mapping, the selection and the age key. Files go into staging through Write-PhxStagedText and
# Copy-PhxStagedFile (Staging.ps1).

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
        # The state (State.ps1), and from it the provider's file tracker for Test-PhxFileChanged
        # ($Context.Files). A fresh one when not given.
        [PSPhoenix.Engine.PhxState]$State,
        [switch]$DryRun,
        # Restore: old root -> new root (absent = unchanged).
        [System.Collections.IDictionary]$RootMap = @{},
        # Restore: the repository identities to restore (none = all).
        [string[]]$Select = @(),
        # Restore: the age identity (AGE-SECRET-KEY-1...) that opens the snapshot's secrets; none
        # skips them. Never logged.
        [string]$Identity
    )
    if (-not $Config) { $Config = Read-PhxConfig }
    if (-not $State) { $State = New-PhxState }
    [pscustomobject]@{
        Provider = $Provider
        Config   = $Config
        Staging  = $Staging
        State    = $State
        Files    = $State.Tracker($Provider)
        DryRun   = [bool]$DryRun
        RootMap  = $RootMap
        Select   = @($Select)
        Identity = $Identity
        Log      = { param([string]$Message, [string]$Level = 'Info') Write-PhxLog -Message $Message -Level $Level }
        # The files the secret check held back in this run, each as '<file> line <n>: <kind>', and
        # those it staged encrypted, as '<file>.age'.
        Withheld = [Collections.Generic.List[string]]::new()
        Sealed   = [Collections.Generic.List[string]]::new()
        # What encrypts its secrets, to the age recipient in the config; nothing without a key.
        Sealer   = $(if ($Staging) { New-PhxSealer -Config $Config -Provider $Provider })
    }
}
