# The state (docs/design.md -> Change detection and resource use): machine-local, never backed up,
# and never needed for correctness - a missing or broken state only means "everything changed",
# never an error. The engine holds it (PhxState.cs, which lists what is in it) and does the change
# detection (FileTracker.cs); these are their PowerShell face.

function Get-PhxStatePath { Join-PhxPath (Get-PhxStateDir) 'state.json' }

function New-PhxState { [PSPhoenix.Engine.PhxState]::new() }

function Read-PhxState {
    # The state, or a fresh one when there is none, it cannot be read, or a newer PSPhoenix wrote it.
    param([switch]$Quiet)
    $path = Get-PhxStatePath
    try { return [PSPhoenix.Engine.PhxState]::Load($path) }
    catch {
        $why = $_.Exception.InnerException.Message ?? $_.Exception.Message
        if (-not $Quiet) { Write-Host "ignoring $path ($why) - the next run takes everything as changed" -ForegroundColor DarkYellow }
    }
    New-PhxState
}

function Save-PhxState {
    param([Parameter(Mandatory)][PSPhoenix.Engine.PhxState]$State)
    try { $State.Save((Get-PhxStatePath)) }
    catch [System.Management.Automation.MethodInvocationException] { throw $_.Exception.InnerException }
}

function ConvertTo-PhxDateTime {
    # A time from the state or a cache - a DateTime once ConvertFrom-Json has read it, else ISO
    # text - as a UTC DateTime; nothing when it is neither.
    param($Value)
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse("$Value", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) { $parsed.ToUniversalTime() }
}

function New-PhxFileTracker {
    # Change detection for one provider's run (the engine's FileTracker): Known is what its last
    # successful run saw, Seen what this run sees. The state keeps Seen only when the provider
    # succeeds.
    param([System.Collections.Generic.IReadOnlyDictionary[string, PSPhoenix.Engine.FileStamp]]$Known)
    [PSPhoenix.Engine.FileTracker]::new($Known)
}

function Test-PhxFileChanged {
    # True when $Path is new, or its content differs from what the provider's last run saw: size
    # and mtime first, the SHA-256 only when either differs. A file that is gone counts as changed.
    # $Files is the provider's tracker ($Context.Files).
    param([Parameter(Mandatory)][PSPhoenix.Engine.FileTracker]$Files, [Parameter(Mandatory)][string]$Path)
    try { $Files.HasChanged($Path) }
    catch [System.Management.Automation.MethodInvocationException] { throw $_.Exception.InnerException }
}

function Get-PhxRefsHash {
    # One hash over a repository's refs - branches, tags, remote branches, the stash - and HEAD:
    # unchanged refs mean no local-only work can have changed, so the wip provider (M4) skips the
    # repository. One git call.
    param([Parameter(Mandatory)][string]$Path)
    $refs = @(Invoke-PhxGit -Repository $Path -Arguments 'for-each-ref', '--format=%(refname) %(objectname)')
    $head = @(Invoke-PhxGit -Repository $Path -Arguments 'rev-parse', '--symbolic-full-name', 'HEAD', 'HEAD' -AllowFailure)
    [PSPhoenix.Engine.FileHash]::Sha256Text((@($refs) + @($head)) -join "`n")
}
