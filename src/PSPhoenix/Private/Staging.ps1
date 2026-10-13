# Staging a provider's files (docs/design.md -> Provider contract, Secrets). A provider stages every
# file through Write-PhxStagedText or Copy-PhxStagedFile, which scan it for secrets first (the
# engine's StagingWriter): a text with a secret in it is held back - never written to staging,
# never published - until age (#25) can encrypt it, and the warning names the file, the line and the
# kind, never the value. Before publishing, Remove-PhxStagedSecret scans the staging folder once
# more, for whatever reached it another way. The run records what was held back; phx status counts it.

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

function Format-PhxWithheld {
    # A file held back, as a warning and the state name it: <file> line <n>: <kind>, and how many
    # more secrets it holds. Never the secret.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object[]]$Findings)
    $first = $Findings[0]
    $more = if ($Findings.Count -gt 1) { " (and $($Findings.Count - 1) more)" } else { '' }
    "$($Path.Replace('\', '/')) line $($first.Line): $($first.Description)$more"
}

function Add-PhxWithheld {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object[]]$Findings)
    $entry = Format-PhxWithheld -Path $Path -Findings $Findings
    $Context.Withheld.Add($entry)
    & $Context.Log "held back $entry - a secret is only stored encrypted, with age (#25)" 'Warn'
}

function Write-PhxStagedText {
    # Stages a text as UTF-8: $Path is relative to the provider's staging folder. With -FailOnSecret
    # a secret fails the provider instead of holding the file back - for a file the snapshot cannot
    # do without, such as the repository inventory: its last published copy then stays.
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [switch]$FailOnSecret
    )
    $target = Resolve-PhxStagedPath -Context $Context -Path $Path
    try { $scan = [PSPhoenix.Engine.StagingWriter]::WriteText($target, $Value) }
    catch [System.Management.Automation.MethodInvocationException] { throw $_.Exception.InnerException }
    if (-not $scan.HasSecret) { return }
    if ($FailOnSecret) { throw "$(Format-PhxWithheld -Path $Path -Findings @($scan.Findings)) - not staged" }
    Add-PhxWithheld -Context $Context -Path $Path -Findings @($scan.Findings)
}

function Copy-PhxStagedFile {
    # Stages a copy of $Source at $Path, relative to the provider's staging folder. A binary file
    # is copied unscanned: whether it is secret goes by its name, which the provider decides on.
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Path)
    $target = Resolve-PhxStagedPath -Context $Context -Path $Path
    try { $scan = [PSPhoenix.Engine.StagingWriter]::CopyFile($Source, $target) }
    catch [System.Management.Automation.MethodInvocationException] { throw $_.Exception.InnerException }
    if ($scan.HasSecret) { Add-PhxWithheld -Context $Context -Path $Path -Findings @($scan.Findings) }
}

function Remove-PhxStagedSecret {
    # The last check before publishing: a staged file with a secret in it - one a provider wrote
    # around the writer - is removed from staging and held back, so it never reaches the snapshot.
    param([Parameter(Mandatory)]$Context)
    if (-not $Context.Staging -or -not [IO.Directory]::Exists($Context.Staging)) { return }
    foreach ($file in @([IO.Directory]::EnumerateFiles($Context.Staging, '*', [IO.SearchOption]::AllDirectories))) {
        try { $scan = [PSPhoenix.Engine.SecretScanner]::ScanFile($file) }
        catch [System.Management.Automation.MethodInvocationException] { throw $_.Exception.InnerException }
        if (-not $scan.HasSecret) { continue }
        [IO.File]::Delete($file)
        Add-PhxWithheld -Context $Context -Path ([IO.Path]::GetRelativePath($Context.Staging, $file)) -Findings @($scan.Findings)
    }
}
