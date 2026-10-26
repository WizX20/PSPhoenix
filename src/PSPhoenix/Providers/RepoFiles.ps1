# The repo-files provider (docs/design.md -> Gitignored files: filters and review): the gitignored
# files of each repository that matter - local config, a secret source, IDE user files. Git lists
# them, the engine walks and filters them (IgnoredFiles), and the review's decisions in the config
# (FileRules) say which go into the snapshot: a candidate nobody decided on is pending and is not
# backed up. A file secret by its name or content is stored only as <name>.age. Restore copies them
# back into the repository's new place, decrypting the secrets; a file that differs is never
# overwritten.
#
# Snapshot: repo-files/<identity>/<path>, and files.json - which repository each folder belongs to
# (its root and path) and which files are in it, so a restore needs nothing else.

$script:PhxRepoFilesFormat = [PSPhoenix.Engine.RestoreManifest]::RepoFilesFormat

function Get-PhxRepoFilesStatePath { Join-PhxPath (Get-PhxStateDir) 'repo-files.json' }

function Get-PhxRepoFileRule {
    # The review's decisions for one repository as the engine's FileRules: its own include, secret
    # and exclude patterns, and behind them the ones for every repository (files.include,
    # files.secret, files.exclude) - a repository's own decision on a file comes first.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config, [Parameter(Mandatory)][string]$Identity)
    $files = $Config.files
    $own = if ($files.repos -is [System.Collections.IDictionary]) { $files.repos[$Identity] }
    # A file the review called no secret ("plain") is backed up as it is: included.
    $plain = if ($own.plain -is [System.Collections.IDictionary]) { @($own.plain.Keys) } else { @() }
    $include = [string[]]@(@($own.include) + $plain | Where-Object { $_ })
    $secret = [string[]]@($own.secret | Where-Object { $_ })
    $exclude = [string[]]@($own.exclude | Where-Object { $_ })
    try {
        $every = [PSPhoenix.Engine.FileRules]::new([string[]]@($files.include | Where-Object { $_ }), [string[]]@($files.secret | Where-Object { $_ }), [string[]]@($files.exclude | Where-Object { $_ }), $null)
        [PSPhoenix.Engine.FileRules]::new($include, $secret, $exclude, $every)
    }
    catch [System.Management.Automation.MethodInvocationException] { throw $_.Exception.InnerException }
}

function Get-PhxRepoSecretPattern {
    # The patterns that make a file of one repository secret by its name, on top of the built-in
    # names: its own secret patterns and those for every repository.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config, [Parameter(Mandatory)][string]$Identity)
    $own = if ($Config.files.repos -is [System.Collections.IDictionary]) { $Config.files.repos[$Identity] }
    [string[]]@(@($own.secret) + @($Config.files.secret) | Where-Object { $_ })
}

function Get-PhxIgnoredFile {
    # The gitignored files of one repository's main worktree, through the built-in filters (the
    # engine's IgnoredFiles): git lists them - an ignored folder as one entry - and the engine walks
    # the folders, not entering one the review's -Rules exclude. Returns an IgnoredFileList.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][long]$MaxBytes, [string[]]$SecretPatterns = @(), [PSPhoenix.Engine.FileRules]$Rules)
    $output = @(Invoke-PhxGit -Repository $Path -Arguments 'ls-files', '--others', '--ignored', '--exclude-standard', '--directory', '--no-empty-directory', '-z') -join "`n"
    $entries = [string[]]@($output.Split([char]0) | Where-Object { $_ })
    try { [PSPhoenix.Engine.IgnoredFiles]::List($Path, $entries, $MaxBytes, $Rules, $SecretPatterns) }
    catch [System.Management.Automation.MethodInvocationException] { throw $_.Exception.InnerException }
}

function Get-PhxMaxFileBytes {
    # The size cap: files.maxKB (default 1 MB). A larger file needs an explicit include.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
    $kb = $Config.files.maxKB
    if ($kb -isnot [int] -and $kb -isnot [long]) { $kb = 1024 }
    [long]$kb * 1024
}

function Get-PhxRepoFileCandidate {
    # One repository's gitignored files with the decision on each: { Path, Size, SecretName,
    # Filter, Decision, Accepted }, and whether the walk was cut short. Accepted: the findings the
    # review called no secret. -List reuses a listing (the review decides again after each answer);
    # without it git lists them, and throws when it cannot.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Record, [Parameter(Mandatory)][System.Collections.IDictionary]$Config, $List)
    $own = if ($Config.files.repos -is [System.Collections.IDictionary]) { $Config.files.repos[$Record.identity] }
    $rules = Get-PhxRepoFileRule -Config $Config -Identity $Record.identity
    if (-not $List) { $List = Get-PhxIgnoredFile -Path (Get-PhxRepoKey $Record) -MaxBytes (Get-PhxMaxFileBytes $Config) -SecretPatterns (Get-PhxRepoSecretPattern -Config $Config -Identity $Record.identity) -Rules $rules }
    $plain = @(if ($own.plain -is [System.Collections.IDictionary]) {
            foreach ($key in $own.plain.Keys) { [pscustomobject]@{ Pattern = [PSPhoenix.Engine.PathPattern]::Parse($key); Signatures = @($own.plain[$key]) } }
        })
    [pscustomobject]@{
        Files     = @(foreach ($file in $List.Files) {
                $accepted = [string[]]@($plain | Where-Object { $_.Pattern.IsMatch($file.Path) } | ForEach-Object { $_.Signatures } | Where-Object { $_ })
                [pscustomobject]@{ Path = $file.Path; Size = $file.Size; SecretName = $file.SecretName; Filter = "$($file.Filter)"; Decision = "$($rules.Decide($file))"; Accepted = $accepted }
            })
        Truncated = $List.Truncated
    }
}

function ConvertTo-PhxSnapshotFolder {
    # A repository identity as a folder path in the snapshot: its segments, each a valid file name
    # on every platform.
    param([Parameter(Mandatory)][string]$Identity)
    $segments = foreach ($segment in $Identity.Split('/', [StringSplitOptions]::RemoveEmptyEntries)) {
        $clean = $segment -replace '[<>:"|?*\\\x00-\x1f]', '_'
        if ($clean -in '.', '..') { '_' } else { $clean.TrimEnd('.', ' ') }
    }
    @($segments) -join '/'
}

function Get-PhxRepoFolderMap {
    # The snapshot folder of each repository, by its place on disk: its identity, and for the same
    # remote cloned twice a ~2, ~3 after the second one - in path order, so it stays put.
    param([object[]]$Records = @())
    $map = [ordered]@{}
    $used = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($record in @($Records | Sort-Object { Get-PhxRepoKey $_ })) {
        $base = ConvertTo-PhxSnapshotFolder $record.identity
        $folder = $base
        for ($n = 2; -not $used.Add($folder); $n++) { $folder = "$base~$n" }
        $map[(Get-PhxRepoKey $record)] = $folder
    }
    $map
}

function Read-PhxRepoFilesManifest {
    # files.json of a repo-files folder - staging or snapshot - or nothing.
    param([Parameter(Mandatory)][string]$Folder)
    $file = Join-PhxPath $Folder 'files.json'
    if (-not [IO.File]::Exists($file)) { return }
    $document = ConvertTo-PhxCaseInsensitive (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable)
    if ($document.format -gt $script:PhxRepoFilesFormat) { throw "$file was written by a newer PSPhoenix (format $($document.format)) - update PSPhoenix first" }
    $document
}

function Copy-PhxPublishedRepoFile {
    # A repository this run cannot read (an offline root, git refusing it): what the last backup
    # holds of it goes into staging again, so publishing does not remove it from the snapshot.
    # It goes into $Folder, the folder this run gives the repository - the last backup's may now
    # belong to another clone of the same remote (~2). Returns its manifest entry, or nothing when
    # the last backup has none.
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$Folder)
    $snapshot = try { Join-PhxPath (Get-PhxSnapshotPath $Context.Config) $Context.Provider } catch { return }
    $manifest = try { Read-PhxRepoFilesManifest $snapshot } catch { return }
    $entry = @($manifest.repositories | Where-Object { $_ -and [string]::Equals((Get-PhxRepoPath -Root $_.root -RelativePath $_.path), $Key, (Get-PhxPathComparison)) })[0]
    if (-not $entry) { return }
    foreach ($file in @($entry.files)) {
        $source = Join-PhxPath (Join-PhxPath $snapshot $entry.folder) $file.stored
        if (-not [IO.File]::Exists($source)) { continue }
        # Already as the snapshot needs it: plain, or encrypted.
        Copy-PhxStagedFile -Context $Context -Source $source -Path "$Folder/$($file.stored)"
    }
    $entry.folder = $Folder
    $entry
}

function Backup-PhxRepoFiles {
    # The decided gitignored files of every repository the last scan found, into staging under the
    # repository's folder, and files.json. Pending ones are counted, not copied: the state folder
    # keeps the list for phx status and the review.
    param([Parameter(Mandatory)]$Context)
    $cache = Read-PhxRepoCache
    if (-not $cache) { Assert-PhxSourceGone -Context $Context -Why 'no scan of the roots (phx scan)'; return }
    $records = @(Get-PhxScannedRecord -Cache $cache -Config $Context.Config)
    $folders = Get-PhxRepoFolderMap $records
    $manifest = [Collections.Generic.List[object]]::new()
    $pending = [Collections.Generic.List[object]]::new()
    $copied = 0
    foreach ($record in $records) {
        $key = Get-PhxRepoKey $record
        $folder = $folders[$key]
        $candidates = $null
        if (-not $record.offline -and [IO.Directory]::Exists((Join-PhxPath $key '.git'))) {
            try { $candidates = Get-PhxRepoFileCandidate -Record $record -Config $Context.Config }
            catch { & $Context.Log "could not list the gitignored files of ${key}: $(Hide-PhxSecret $_.Exception.Message)" 'Warn' }
        }
        # A list cut short at the most files a walk looks at is not the whole truth: what is missing
        # from it must not be removed from the snapshot. The last backup stays, as for an offline one.
        if ($candidates -and $candidates.Truncated) {
            & $Context.Log "${key}: more than $([PSPhoenix.Engine.IgnoredFiles]::MaxFiles) gitignored files to look at - kept the last backup of it; exclude the folders that hold them (phx review: x <folder>/)" 'Warn'
            $candidates = $null
            $truncated = $true
        }
        else { $truncated = $false }
        if (-not $candidates) {
            if ($Context.DryRun) { continue }
            $kept = Copy-PhxPublishedRepoFile -Context $Context -Key $key -Folder $folder
            if ($kept) {
                if (-not $truncated) { & $Context.Log "${key}: not readable now - kept the $(@($kept.files).Count) file(s) of the last backup" 'Warn' }
                $manifest.Add($kept)
            }
            continue
        }
        foreach ($big in @($candidates.Files | Where-Object Filter -EQ 'TooMany')) {
            & $Context.Log "${key}: $($big.Path) holds more than $([PSPhoenix.Engine.IgnoredFiles]::FolderCap) files - left out as a whole; a pattern that names files in it brings those in (phx review: i /$($big.Path)<file>)"
        }
        $waiting = @($candidates.Files | Where-Object Decision -EQ 'Pending')
        if ($waiting.Count) {
            $pending.Add([ordered]@{
                    identity = $record.identity
                    path     = $key
                    files    = @($waiting | ForEach-Object { [ordered]@{ path = $_.Path; size = $_.Size; secret = $_.SecretName } })
                })
        }
        $stored = [Collections.Generic.List[object]]::new()
        foreach ($file in @($candidates.Files | Where-Object Decision -In 'Include', 'Secret')) {
            # A name Windows cannot hold (a: on Linux) would fail publishing to a target on such a
            # file system - the whole provider - and could not be restored there.
            if (-not (Test-PhxPortableName $file.Path)) {
                & $Context.Log "${key}: $($file.Path) has a name Windows cannot hold - left out" 'Warn'
                continue
            }
            $target = "$folder/$($file.Path)"
            if ($Context.DryRun) { & $Context.Log "would back up $target" 'Action'; continue }
            # A file can go while the run looks at it: the next run sees it gone.
            try { $staged = Copy-PhxStagedFile -Context $Context -Source ([IO.Path]::GetFullPath((Join-PhxPath $key $file.Path))) -Path $target -Secret:($file.Decision -eq 'Secret') -Accept $file.Accepted -PassThru }
            catch [System.IO.FileNotFoundException], [System.IO.DirectoryNotFoundException] { continue }
            # Plain or encrypted, as the stager recorded it; nothing when held back for lack of a key.
            $name = Get-PhxStoredName -Entry $staged -Folder $folder
            if (-not $name) { continue }
            $stored.Add([ordered]@{ path = $file.Path; stored = $name })
            $copied++
        }
        if ($stored.Count) { $manifest.Add([ordered]@{ identity = $record.identity; root = $record.root; path = $record.path; folder = $folder; files = @($stored) }) }
    }
    $waitingCount = [int]($pending | ForEach-Object { $_.files.Count } | Measure-Object -Sum).Sum
    $note = if ($waitingCount) { ", $waitingCount pending in $($pending.Count) repositories - not backed up until decided" } else { '' }
    if ($Context.DryRun) { & $Context.Log "would back up the decided files$note" 'Action'; return }
    if ($manifest.Count) {
        $document = [ordered]@{ format = $script:PhxRepoFilesFormat; repositories = @($manifest) }
        Write-PhxStagedText -Context $Context -Path 'files.json' -Value ($document | ConvertTo-Json -Depth 6) -FailOnSecret
    }
    Save-PhxRepoFilesPending -Pending @($pending) -Stored $copied -StoredRepositories $manifest.Count
    & $Context.Log "$copied file(s) from $($manifest.Count) repositories$note"
}

function Resolve-PhxRestorePath {
    # The full path of a manifest's relative path below $Folder (`.` is $Folder itself), through the
    # engine: refused when it is not a plain relative path, leads into .git or out of $Folder.
    param([Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][string]$RelativePath)
    try { [PSPhoenix.Engine.RestorePlanner]::Below($Folder, $RelativePath) }
    catch [System.Management.Automation.MethodInvocationException] { throw $_.Exception.InnerException }
}

function Resolve-PhxRestoreRepoPath {
    # Where a recorded repository lives on this machine: under its root, or the new root the
    # restore maps it to. Nothing when the root is no path here (C:\Repos on Linux, unmapped).
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)]$Context)
    $root = if ($Context.RootMap.Contains("$($Entry.root)")) { $Context.RootMap["$($Entry.root)"] } else { "$($Entry.root)" }
    if (-not [IO.Path]::IsPathFullyQualified($root)) { return }
    Resolve-PhxRestorePath -Folder $root -RelativePath "$($Entry.path)"
}

function Restore-PhxManifestFile {
    # One file of a manifest back, through the engine (RestorePlanner): written when it is not
    # there, left alone when it is the same, and when it differs too - with a warning. A secret is
    # decrypted with the age key the restore was given. The outcome is counted; a refused path or a
    # file missing from the snapshot counts as failed.
    param(
        [Parameter(Mandatory)][string]$SourceFolder, [Parameter(Mandatory)]$File, [Parameter(Mandatory)][string]$TargetFolder,
        [string]$Prefix = '', [Parameter(Mandatory)][ValidateSet('Repository', 'ClaudeHome', 'ClaudeProject')][string]$Scope,
        [Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)]$Context, [Parameter(Mandatory)][System.Collections.IDictionary]$Counts
    )
    try { $result = [PSPhoenix.Engine.RestorePlanner]::Restore($SourceFolder, $File, $TargetFolder, $Prefix, $Scope, $Context.Identity, [bool]$Context.DryRun) }
    catch {
        $problem = if ($_.Exception -is [System.Management.Automation.MethodInvocationException]) { $_.Exception.InnerException } else { $_.Exception }
        & $Context.Log "${Label}: $(Hide-PhxSecret $problem.Message)" 'Warn'
        $Counts.failed++
        return
    }
    switch ("$($result.Outcome)") {
        'Restored' { if ($Context.DryRun) { & $Context.Log "would restore $($result.Target)" 'Action' } }
        'Differs' { & $Context.Log "$($result.Target) differs from the backup - left as it is" 'Warn' }
        'Skipped' { & $Context.Log "$($result.Target) is encrypted and this restore has no age key - skipped" 'Warn' }
    }
    $Counts["$($result.Outcome)".ToLowerInvariant()]++
}

function Restore-PhxRepoFiles {
    # The backed-up gitignored files back into each repository's place on this machine - after the
    # repos provider has cloned it. Idempotent: a second run finds every file in place.
    param([Parameter(Mandatory)]$Context)
    $file = Join-PhxPath $Context.Staging 'files.json'
    if (-not [IO.File]::Exists($file)) { & $Context.Log 'no gitignored files in this snapshot'; return }
    try { $manifest = [PSPhoenix.Engine.RestoreManifest]::ReadRepoFiles($file) }
    catch [System.Management.Automation.MethodInvocationException] { throw $_.Exception.InnerException }
    $counts = [ordered]@{ restored = 0; present = 0; differs = 0; skipped = 0; failed = 0 }
    foreach ($entry in $manifest.Repositories) {
        if ($Context.Select.Count -and $Context.Select -notcontains $entry.Identity) { continue }
        $files = @($entry.Files)
        try {
            $repo = Resolve-PhxRestoreRepoPath -Entry $entry -Context $Context
            $folder = Resolve-PhxRestorePath -Folder $Context.Staging -RelativePath $entry.Folder
        }
        catch { & $Context.Log "$($entry.Identity): $($_.Exception.Message)" 'Warn'; $counts.failed += $files.Count; continue }
        if (-not $repo -or -not [IO.Directory]::Exists($repo)) {
            $where = if ($repo) { "$repo not found" } else { "its root $($entry.Root) is not a path on this machine - map it to one" }
            & $Context.Log "$($entry.Identity): $where - its $($files.Count) file(s) skipped; restore the repository first" 'Warn'
            $counts.skipped += $files.Count
            continue
        }
        foreach ($one in $files) {
            Restore-PhxManifestFile -SourceFolder $folder -File $one -TargetFolder $repo -Scope Repository -Label $entry.Identity -Context $Context -Counts $counts
        }
    }
    $verb = if ($Context.DryRun) { 'would be ' } else { '' }
    & $Context.Log ('{0} {1}restored, {2} already in place, {3} differ (left as they are), {4} skipped, {5} failed' -f $counts.restored, $verb, $counts.present, $counts.differs, $counts.skipped, $counts.failed)
    if ($counts.failed) { throw "$($counts.failed) gitignored file(s) could not be restored - see above" }
}

function Save-PhxRepoFilesPending {
    # The pending list in the state folder, for phx status and the review: per repository
    # { identity, path, files }. A backup also records how many files it stored; the review keeps
    # those numbers.
    param([object[]]$Pending = @(), [int]$Stored = -1, [int]$StoredRepositories = 0)
    $document = [ordered]@{ at = [DateTime]::UtcNow.ToString('o'); repositories = @($Pending) }
    if ($Stored -ge 0) { $document.stored = $Stored; $document.storedRepositories = $StoredRepositories }
    else {
        $last = Get-PhxRepoFilesPending
        if ($last -and $null -ne $last.stored) { $document.stored = $last.stored; $document.storedRepositories = $last.storedRepositories }
    }
    Write-PhxTextFile -Path (Get-PhxRepoFilesStatePath) -Value ($document | ConvertTo-Json -Depth 6)
}

function Get-PhxRepoFilesPending {
    # What the last backup left pending, per repository: { identity, path, files }. Nothing before
    # a first backup.
    $path = Get-PhxRepoFilesStatePath
    if (-not [IO.File]::Exists($path)) { return }
    try { ConvertTo-PhxCaseInsensitive (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop) }
    catch { $null = $_ }
}

function Get-PhxRepoFilesStatus {
    # phx status lines: what the last backup stored. The pending count is phx status's own review
    # line - a warning.
    param([Parameter(Mandatory)]$Context)
    $null = $Context
    $state = Get-PhxRepoFilesPending
    if (-not $state -or $null -eq $state.stored) { return 'not backed up yet - phx run' }
    "$($state.stored) file(s) from $($state.storedRepositories) repositories in the last backup"
}

Register-PhxProvider @{
    Name        = 'repo-files'
    Description = 'Gitignored files that matter - local config, secrets (encrypted) - as the review decided'
    Backup      = { param($Context) Backup-PhxRepoFiles -Context $Context }
    Restore     = { param($Context) Restore-PhxRepoFiles -Context $Context }
    Status      = { param($Context) Get-PhxRepoFilesStatus -Context $Context }
}
