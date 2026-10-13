# The snapshot (docs/design.md -> Targets, Snapshot layout): one folder per machine in the target,
# and in it one folder per provider, which that provider alone fills. A run stages each provider's
# files in the state folder, then publishes them (the engine's FolderPublisher): a file whose
# content changed is written through a temporary name and a rename, an unchanged one is left alone,
# one the provider no longer produced is removed. A sync client never sees half a file, and a run
# with nothing changed writes nothing - OneDrive uploads nothing.
#
# phoenix.json names the installation that writes the folder (a machine id made by phx init): a
# new installation under the same computer name must not overwrite the snapshot it is about to be
# restored from.

$script:PhxSnapshotFormat = 1

function Get-PhxMachineName {
    # This machine's folder in the target: the configured name, else the computer name.
    param([System.Collections.IDictionary]$Config)
    if ($Config.machine -and $Config.machine.name) { "$($Config.machine.name)" } else { [Environment]::MachineName }
}

function Test-PhxMachineName {
    # A name that is a folder name on every platform: letters, digits, dot, dash, underscore; no
    # trailing dot (Windows drops it).
    param([string]$Name)
    $Name -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$' -and -not $Name.EndsWith('.')
}

function Get-PhxSnapshotPath {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
    if (-not $Config.target -or -not $Config.target.path) { throw 'no target yet - run phx init' }
    Join-Path $Config.target.path (Get-PhxMachineName $Config)
}

function Get-PhxStagingPath {
    # Where a run stages a provider's files: in the state folder, never in the target.
    param([Parameter(Mandatory)][string]$Provider)
    Join-Path (Join-Path (Get-PhxStateDir) 'staging') $Provider
}

function Read-PhxSnapshotInfo {
    # phoenix.json of a snapshot folder, or nothing when it has none. One that cannot be read is an
    # error: a folder that may hold somebody's backup is not overwritten on a guess.
    param([Parameter(Mandatory)][string]$Path)
    $file = Join-Path $Path 'phoenix.json'
    if (-not [IO.File]::Exists($file)) { return }
    try { $info = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { throw "$file cannot be read: $($_.Exception.Message)" }
    if ($info -isnot [System.Collections.IDictionary]) { throw "$file does not describe a snapshot" }
    ConvertTo-PhxCaseInsensitive $info
}

function Get-PhxSnapshotProblem {
    # Why the installation with id $Id may not write the snapshot folder $Path - nothing when it
    # may: a phoenix.json that cannot be read, one of a newer PSPhoenix or of another installation,
    # or no phoenix.json in a folder that holds files - somebody's folder, which publishing would
    # empty. phx init, phx run and phx status all ask here.
    param([Parameter(Mandatory)][string]$Path, [string]$Id)
    try { $info = Read-PhxSnapshotInfo $Path }
    catch { return $_.Exception.Message }
    if (-not $info) {
        if ([IO.Directory]::Exists($Path) -and @([IO.Directory]::EnumerateFileSystemEntries($Path)).Count) {
            return "$Path holds files but no phoenix.json - it is not a PSPhoenix snapshot; give this machine another name (phx init) or empty the folder"
        }
        return
    }
    if ($info.format -gt $script:PhxSnapshotFormat) { return "$Path was written by a newer PSPhoenix (format $($info.format)) - update PSPhoenix first" }
    if ($info.machine.id -and $info.machine.id -ne $Id) {
        return "$Path holds the snapshot of another installation (last written $(ConvertTo-PhxTimestamp $info.updatedAt)) - restore from it first, or give this machine another name: phx init"
    }
}

function Assert-PhxSnapshotWritable {
    # Returns the folder's phoenix.json (nothing for a new folder) when this installation may write
    # it; throws why when it may not (Get-PhxSnapshotProblem).
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][System.Collections.IDictionary]$Config)
    $problem = Get-PhxSnapshotProblem -Path $Path -Id $Config.machine.id
    if ($problem) { throw $problem }
    Read-PhxSnapshotInfo $Path
}

function ConvertTo-PhxTimestamp {
    # A time as phoenix.json stores it: ISO 8601 in UTC. ConvertFrom-Json turns such text into a
    # DateTime; this turns it back, so a rewrite does not change the times it only carries along.
    param($Value)
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('o') }
    "$Value"
}

function Publish-PhxFolder {
    # Makes $Destination hold exactly the files of $Source, and returns the counts (Written,
    # Unchanged, Removed, Files) - the engine does it (FolderPublisher.cs, which says how). A file
    # that cannot be published fails it with a message that names the file.
    #
    # -Published (relative path -> SHA-256 as last published, from the state) spares reading the
    # target back: reading a file in a OneDrive folder can mean downloading it first. It is updated
    # to what the destination holds afterwards, also when publishing failed half-way.
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [System.Collections.Generic.IDictionary[string, string]]$Published
    )
    try { [PSPhoenix.Engine.FolderPublisher]::Publish($Source, $Destination, $Published) }
    catch [System.Management.Automation.MethodInvocationException] { throw $_.Exception.InnerException }
}

function Publish-PhxSnapshot {
    # Publishes the staged files of these providers, and the config, into this machine's snapshot
    # folder. phoenix.json records when each provider's files last changed; it is rewritten only
    # when something was. With -State, the hashes it last published come from there and go back
    # there. Returns the result per provider.
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Provider,
        [PSPhoenix.Engine.PhxState]$State
    )
    if (-not $Config.machine -or -not $Config.machine.id) { throw 'this machine has no id yet - run phx init' }
    $snapshot = Get-PhxSnapshotPath $Config
    $info = Assert-PhxSnapshotWritable -Path $snapshot -Config $Config
    $now = [DateTime]::UtcNow.ToString('o')
    if (-not $info) {
        # A new folder is claimed before anything else goes in: a run that dies half-way must not
        # leave files without the phoenix.json that says whose they are.
        Write-PhxTextFile -Path (Join-Path $snapshot 'phoenix.json') -Value ([ordered]@{
                format = $script:PhxSnapshotFormat; machine = [ordered]@{ name = Get-PhxMachineName $Config; id = $Config.machine.id }; createdAt = $now
            } | ConvertTo-Json -Depth 5)
        $info = Read-PhxSnapshotInfo $snapshot
    }
    # Temporary files of a write to phoenix.json or config.json that died half-way.
    foreach ($stale in @([IO.Directory]::EnumerateFiles($snapshot, '.*.tmp') | Where-Object { [IO.Path]::GetFileName($_) -match '^\.(phoenix|config)\.json\.[0-9a-f]{8}\.tmp$' })) {
        [IO.File]::Delete($stale)
    }
    $providers = [ordered]@{}
    if ($info.providers -is [System.Collections.IDictionary]) {
        foreach ($name in $info.providers.Keys) {
            $providers[$name] = [ordered]@{ changedAt = ConvertTo-PhxTimestamp $info.providers[$name].changedAt; files = $info.providers[$name].files }
        }
    }
    # The published hashes belong to one snapshot folder: after a move to another target, or a
    # renamed machine, an older copy there must not pass for what was published.
    if ($State) { $State.PublishInto($snapshot) }
    $changed = $false
    $results = [ordered]@{}
    foreach ($name in $Provider) {
        $published = if ($State) { $State.PublishedHashes($name) }
        # One provider that cannot be published (a file held open in the target) does not stop the
        # others; its result carries the error.
        try { $result = Publish-PhxFolder -Source (Get-PhxStagingPath $name) -Destination (Join-Path $snapshot $name) -Published $published }
        catch {
            $results[$name] = [pscustomobject]@{ Error = Hide-PhxSecret $_.Exception.Message }
            continue
        }
        $results[$name] = $result
        if ($result.Written -or $result.Removed -or -not $providers.Contains($name)) {
            $providers[$name] = [ordered]@{ changedAt = $now; files = $result.Files }
            $changed = $true
        }
    }
    # The config travels along: a restore reads the roots, accounts and decisions from it.
    $configText = $Config | ConvertTo-Json -Depth 10
    $configFile = Join-Path $snapshot 'config.json'
    if (-not [IO.File]::Exists($configFile) -or [IO.File]::ReadAllText($configFile) -cne $configText) {
        Write-PhxTextFile -Path $configFile -Value $configText
        $changed = $true
    }
    if ($changed) {
        $document = [ordered]@{
            format    = $script:PhxSnapshotFormat
            machine   = [ordered]@{ name = Get-PhxMachineName $Config; id = $Config.machine.id }
            user      = [Environment]::UserName
            platform  = Get-PhxCurrentPlatform
            psphoenix = "$(Get-PhxVersion)"
            createdAt = if ($info.createdAt) { ConvertTo-PhxTimestamp $info.createdAt } else { $now }
            updatedAt = $now
            providers = $providers
        }
        Write-PhxTextFile -Path (Join-Path $snapshot 'phoenix.json') -Value ($document | ConvertTo-Json -Depth 10)
    }
    $results
}
