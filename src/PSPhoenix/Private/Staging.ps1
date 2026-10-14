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
    [PSPhoenix.Engine.Sealer]::new($recipient, (Join-Path (Join-Path (Get-PhxStateDir) 'sealed') $Provider))
}

function Format-PhxWithheld {
    # A file with a secret, as warnings and the state name it: <file> line <n>: <kind>, and how
    # many more secrets it holds. Never the secret.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object[]]$Findings)
    $first = $Findings[0]
    $more = if ($Findings.Count -gt 1) { " (and $($Findings.Count - 1) more)" } else { '' }
    "$($Path.Replace('\', '/')) line $($first.Line): $($first.Description)$more"
}

function Add-PhxStagedResult {
    # Records what staging a file with a secret did: encrypted, or held back for lack of a key.
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Staged)
    if (-not $Staged.Scan.HasSecret) { return }
    $entry = Format-PhxWithheld -Path $Path -Findings @($Staged.Scan.Findings)
    if ($Staged.Sealed) {
        $Context.Sealed.Add("$($Path.Replace('\', '/')).age")
        & $Context.Log "encrypted $entry"
        return
    }
    $Context.Withheld.Add($entry)
    & $Context.Log "held back $entry - a secret is only stored encrypted, and there is no age key yet: phx init" 'Warn'
}

function Write-PhxStagedText {
    # Stages a text as UTF-8: $Path is relative to the provider's staging folder. With -FailOnSecret
    # a secret fails the provider instead of being encrypted or held back - for a file that must stay
    # readable without a key, such as the repository inventory: its last published copy then stays.
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [switch]$FailOnSecret
    )
    $target = Resolve-PhxStagedPath -Context $Context -Path $Path
    $sealer = if ($FailOnSecret) { $null } else { $Context.Sealer }
    try { $staged = [PSPhoenix.Engine.StagingWriter]::WriteText($target, $Value, $sealer) }
    catch [System.Management.Automation.MethodInvocationException] { throw $_.Exception.InnerException }
    if ($FailOnSecret -and $staged.Scan.HasSecret) { throw "$(Format-PhxWithheld -Path $Path -Findings @($staged.Scan.Findings)) - not staged" }
    Add-PhxStagedResult -Context $Context -Path $Path -Staged $staged
}

function Copy-PhxStagedFile {
    # Stages a copy of $Source at $Path, relative to the provider's staging folder. A binary file
    # is copied unscanned: whether it is secret goes by its name, which the provider decides on.
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Path)
    $target = Resolve-PhxStagedPath -Context $Context -Path $Path
    try { $staged = [PSPhoenix.Engine.StagingWriter]::CopyFile($Source, $target, $Context.Sealer) }
    catch [System.Management.Automation.MethodInvocationException] { throw $_.Exception.InnerException }
    Add-PhxStagedResult -Context $Context -Path $Path -Staged $staged
}

function Remove-PhxStagedSecret {
    # The last check before publishing: a staged file with a secret in it - one a provider wrote
    # around the writer - is replaced by its encrypted copy, or removed and held back without a key,
    # so it never reaches the snapshot in plain text.
    param([Parameter(Mandatory)]$Context)
    if (-not $Context.Staging -or -not [IO.Directory]::Exists($Context.Staging)) { return }
    foreach ($file in @([IO.Directory]::EnumerateFiles($Context.Staging, '*', [IO.SearchOption]::AllDirectories))) {
        try { $staged = [PSPhoenix.Engine.StagingWriter]::CheckStaged($file, $Context.Sealer) }
        catch [System.Management.Automation.MethodInvocationException] { throw $_.Exception.InnerException }
        Add-PhxStagedResult -Context $Context -Path ([IO.Path]::GetRelativePath($Context.Staging, $file)) -Staged $staged
    }
}
