# Staging a provider's files (docs/design.md -> Provider contract, Secrets). A provider stages every
# file through Write-PhxStagedText or Copy-PhxStagedFile, which scan it for secrets first (the
# engine's StagingWriter): a file with a secret in it is staged encrypted to the age recipient in the
# config, as <name>.age - and held back, never written, while there is no key yet (phx init). A
# warning or log line names the file, the line and the kind, never the value. Before publishing,
# Remove-PhxStagedSecret checks the staging folder once more, for whatever reached it another way.
# The run records what was held back; phx status counts it.

function Resolve-PhxStagedPath {
    # The full path of a file in the provider's staging folder. A path that is rooted, or leads out
    # of the staging folder, is refused: a provider writes nowhere else.
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Path)
    if (-not $Context.Staging) { throw 'this context has no staging folder' }
    if ([IO.Path]::IsPathRooted($Path)) { throw "$Path is not a path inside the staging folder" }
    $full = [IO.Path]::GetFullPath([IO.Path]::Combine($Context.Staging, $Path))
    if ([string]::Equals($full.TrimEnd('\', '/'), $Context.Staging.TrimEnd('\', '/'), (Get-PhxPathComparison)) -or -not (Test-PhxPathWithin $full $Context.Staging)) {
        throw "$Path leads out of the staging folder"
    }
    $full
}

function New-PhxSealer {
    # What encrypts a provider's secrets: to the recipient in the config, its last ciphertexts kept
    # in the state folder so an unchanged secret is not a new file every run. Nothing without a key.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config, [Parameter(Mandatory)][string]$Provider)
    $recipient = if ($Config.secrets -is [System.Collections.IDictionary]) { $Config.secrets.recipient }
    if (-not $recipient) { return $null }
    [PSPhoenix.Engine.Sealer]::new($recipient, (Join-PhxPath (Join-PhxPath (Get-PhxStateDir) 'sealed') $Provider))
}

function Format-PhxWithheld {
    # A file with a secret, as warnings and the state name it: <file> line <n>: <kind>, and how
    # many more secrets it holds. Never the secret.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object[]]$Findings)
    $first = $Findings[0]
    # A file secret by its name has no line to point at.
    if ($first.Kind -eq [PSPhoenix.Engine.SecretKind]::SecretFile) { return "$($Path.Replace('\', '/')): $($first.Description)" }
    $more = if ($Findings.Count -gt 1) { " (and $($Findings.Count - 1) more)" } else { '' }
    "$($Path.Replace('\', '/')) line $($first.Line): $($first.Description)$more"
}

function Add-PhxStagedResult {
    # Records what staging a file with a secret did: encrypted, or held back for lack of a key.
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][PSPhoenix.Engine.StagedEntry]$Entry)
    if ($Entry.As -eq [PSPhoenix.Engine.StagedAs]::Plain -or -not $Entry.Findings.Count) { return }
    $line = Format-PhxWithheld -Path $Entry.Path -Findings @($Entry.Findings)
    if ($Entry.As -eq [PSPhoenix.Engine.StagedAs]::Sealed) {
        $Context.Sealed.Add($Entry.Stored)
        & $Context.Log "encrypted $line"
        return
    }
    $Context.Withheld.Add($line)
    & $Context.Log "held back $line - a secret is only stored encrypted, and there is no age key yet: phx init" 'Warn'
}

function Write-PhxStagedText {
    # Stages a text as UTF-8: $Path is relative to the provider's staging folder. With -FailOnSecret
    # a secret fails the provider instead of being encrypted or held back - for a file that must stay
    # readable without a key, such as the repository inventory: its last published copy then stays.
    # -PassThru returns what it became (the stager's StagedEntry: Stored, As).
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [switch]$FailOnSecret,
        [switch]$PassThru
    )
    $target = Resolve-PhxStagedPath -Context $Context -Path $Path
    try { $entry = $Context.Stager.WriteText($target, $Value, -not $FailOnSecret) }
    catch [System.Management.Automation.MethodInvocationException] { throw $_.Exception.InnerException }
    if ($FailOnSecret -and $entry.Findings.Count) { throw "$(Format-PhxWithheld -Path $Path -Findings @($entry.Findings)) - not staged" }
    Add-PhxStagedResult -Context $Context -Entry $entry
    if ($PassThru) { $entry }
}

function Copy-PhxStagedFile {
    # Stages a copy of $Source at $Path, relative to the provider's staging folder. A binary file
    # is copied unscanned: whether it is secret goes by its name, which the provider decides on -
    # -Secret stages it only encrypted, whatever its content (a .env, a .pfx). -Accept: findings
    # (their Signature) the review called no secret. -PassThru returns what it became.
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Path, [switch]$Secret, [string[]]$Accept = @(), [switch]$PassThru)
    $target = Resolve-PhxStagedPath -Context $Context -Path $Path
    try { $entry = $Context.Stager.CopyFile($Source, $target, [bool]$Secret, [string[]]@($Accept | Where-Object { $_ })) }
    catch [System.Management.Automation.MethodInvocationException] { throw $_.Exception.InnerException }
    Add-PhxStagedResult -Context $Context -Entry $entry
    if ($PassThru) { $entry }
}

function Get-PhxStoredName {
    # How a staged file is stored, relative to $Folder of the staging folder: its name, or
    # <name>.age; nothing when it was held back. From the stager's record - never from what happens
    # to be on disk.
    param([Parameter(Mandatory)]$Entry, [string]$Folder = '')
    if (-not $Entry -or -not $Entry.Stored) { return }
    if (-not $Folder) { return $Entry.Stored }
    $Entry.Stored.Substring($Folder.TrimEnd('/').Length + 1)
}

function Assert-PhxSourceGone {
    # A provider whose source is not there - no Claude Code folder, no scan - stages nothing, and
    # publishing that would empty its folder in the snapshot. When the snapshot holds a last backup
    # of it, the provider fails instead, so that backup stays; on a machine that never had the
    # source it is quiet: there is nothing to keep.
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Why)
    $published = try { Join-PhxPath (Get-PhxSnapshotPath $Context.Config) $Context.Provider } catch { $null }
    $hasBackup = $published -and [IO.Directory]::Exists($published) -and [IO.Directory]::EnumerateFiles($published, '*', [IO.SearchOption]::AllDirectories).GetEnumerator().MoveNext()
    if ($hasBackup -and -not $Context.DryRun) { throw "$Why - the last backup in the snapshot stays as it is" }
    & $Context.Log "$Why - nothing to back up"
}

function Remove-PhxStagedSecret {
    # The last check before publishing: a staged file the stager did not write itself - one a
    # provider put there around it - is scanned, and with a secret in it replaced by its encrypted
    # copy, or removed and held back without a key, so it never reaches the snapshot in plain text.
    # What the stager wrote is not scanned again: a decision of the review stands.
    param([Parameter(Mandatory)]$Context)
    if (-not $Context.Stager) { return }
    try { $found = @($Context.Stager.CheckRest()) }
    catch [System.Management.Automation.MethodInvocationException] { throw $_.Exception.InnerException }
    foreach ($entry in $found) { Add-PhxStagedResult -Context $Context -Entry $entry }
}
