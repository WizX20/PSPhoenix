# The repos provider (docs/design.md -> Providers, GitHub accounts): the repository inventory -
# remotes, branches, repo-local identity, the GitHub account - and on restore the clones back.
# Tracked files are never copied: a clone brings them. Local-only work is the wip provider (M4).

$script:PhxReposFormat = 1

function Resolve-PhxRepoAccount {
    # The account a repository needs, and where that comes from: its own credential helper (in its
    # local config or a file it includes), else the accounts map for its host/owner, else none -
    # the host's default account.
    param([string]$Identity, [string]$HelperAccount, [System.Collections.IDictionary]$Accounts)
    if ($HelperAccount) { return [pscustomobject]@{ Account = $HelperAccount; Source = 'credential helper' } }
    $owner = Get-PhxIdentityOwner $Identity
    if ($owner -and $Accounts -and $Accounts.Contains($owner)) { return [pscustomobject]@{ Account = $Accounts[$owner]; Source = 'accounts' } }
    [pscustomobject]@{ Account = $null; Source = $null }
}

function Get-PhxRepoAccount {
    # The account a scanned repository needs (see Resolve-PhxRepoAccount).
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Record, [System.Collections.IDictionary]$Accounts)
    (Resolve-PhxRepoAccount -Identity $Record.identity -HelperAccount $Record.helperAccount -Accounts $Accounts).Account
}

function ConvertTo-PhxRepoInventory {
    # A repository record as the snapshot holds it, its account resolved against the accounts map.
    # -FromScan marks a record this run could not read again (offline, unreadable): recorded in
    # full as the last scan saw it, rather than left out of the backup.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Record, [System.Collections.IDictionary]$Accounts, [string]$FromScan)
    $resolved = Resolve-PhxRepoAccount -Identity $Record.identity -HelperAccount $Record.helperAccount -Accounts $Accounts
    $inventory = [ordered]@{
        identity      = $Record.identity
        root          = $Record.root
        path          = $Record.path
        remotes       = $Record.remotes
        primaryRemote = $Record.primaryRemote
        defaultBranch = $Record.defaultBranch
        branch        = $Record.branch
        settings      = @($Record.settings)
        worktrees     = @($Record.worktrees)
        lfs           = [bool]$Record.lfs
        submodules    = [bool]$Record.submodules
        account       = $resolved.Account
        accountSource = $resolved.Source
    }
    if ($FromScan) { $inventory.fromScan = $FromScan }
    $inventory
}

function Backup-PhxRepos {
    # repos.json in the staging folder: every repository the last scan found under the configured
    # roots, read again now. One the run cannot read (an offline root, a repository git refuses) is
    # recorded as the scan saw it; one deleted since the scan is not. With no scan, or a configured
    # root the last scan did not cover, it scans first - only in memory on a -DryRun.
    param([Parameter(Mandatory)]$Context)
    $cache = Read-PhxRepoCache
    $uncovered = @(@($Context.Config.roots | Where-Object { $_ }) | Where-Object { $null -eq (Get-PhxRootRepoCount -Cache $cache -Root $_.path) })
    $records = if (-not $cache -or $uncovered) {
        $why = if (-not $cache) { 'no scan yet' } else { "not scanned yet: $(($uncovered | ForEach-Object path) -join ', ')" }
        & $Context.Log "$why - scanning the roots first"
        @(Invoke-PhxScan -NoSave:$Context.DryRun -PassThru)
    }
    else { @(Get-PhxScannedRecord -Cache $cache -Config $Context.Config) }
    $accounts = $Context.Config.accounts
    $inventory = foreach ($record in $records) {
        $path = Get-PhxRepoKey $record
        if ($record.offline) {
            & $Context.Log "offline - recorded from the last scan: $path" 'Warn'
            ConvertTo-PhxRepoInventory -Record $record -Accounts $accounts -FromScan 'offline'
            continue
        }
        if (-not [IO.Directory]::Exists((Join-Path $path '.git'))) {
            & $Context.Log "gone since the last scan, not recorded: $path" 'Warn'
            continue
        }
        try { $now = Get-PhxRepoRecord -Root $record.root -Path $path }
        catch {
            & $Context.Log "could not read ${path}: $(Hide-PhxSecret $_.Exception.Message) - recorded from the last scan" 'Warn'
            ConvertTo-PhxRepoInventory -Record $record -Accounts $accounts -FromScan 'unreadable'
            continue
        }
        foreach ($file in @($now.externalIncludes)) {
            & $Context.Log "${path}: includes $file from outside the repository - a clone does not bring it back, and this snapshot does not hold it (the git provider, M5, will)" 'Warn'
        }
        ConvertTo-PhxRepoInventory -Record $now -Accounts $accounts
    }
    $document = [ordered]@{ format = $script:PhxReposFormat; repositories = @($inventory) }
    if ($Context.DryRun) { & $Context.Log "would record $(@($inventory).Count) repositories" 'Action'; return }
    Write-PhxTextFile -Path (Join-Path $Context.Staging 'repos.json') -Value ($document | ConvertTo-Json -Depth 10)
    & $Context.Log "$(@($inventory).Count) repositories recorded"
}

function Invoke-PhxClone {
    # git clone. When the repository has an account and its remote is https on a host gh is logged
    # in to, the clone gets that account's token for this one process - GH_TOKEN for github.com,
    # GH_ENTERPRISE_TOKEN for a GitHub Enterprise host - plus gh's own credential helper, every other
    # helper switched off for the call. Never a token on disk, never `gh auth switch`. Other hosts
    # (Azure DevOps, GitLab) go through Git Credential Manager as usual.
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$RemoteName,
        [string]$Account,
        [string[]]$TokenHosts = @('github.com')
    )
    $parent = Split-Path $Target -Parent
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $options = @()
    $tokenHost = if ($Account -and $Url -match '^https://(?:[^@/]+@)?(?<host>[^/:]+)' -and $TokenHosts -contains $Matches.host) { $Matches.host }
    $variable = if ($tokenHost -eq 'github.com') { 'GH_TOKEN' } else { 'GH_ENTERPRISE_TOKEN' }
    $saved = [Environment]::GetEnvironmentVariable($variable)
    try {
        if ($tokenHost) {
            [Environment]::SetEnvironmentVariable($variable, (Get-PhxGhToken -Account $Account -HostName $tokenHost))
            $options = '-c', 'credential.helper=', '-c', 'credential.helper=!gh auth git-credential'
        }
        Invoke-PhxGit -Repository $parent -Arguments ($options + @('clone', '--quiet', '--origin', $RemoteName, '--', $Url, $Target)) | Out-Null
    }
    finally { [Environment]::SetEnvironmentVariable($variable, $saved) }
}

function Set-PhxRepoValues {
    # Makes a multi-valued config key hold exactly these values, in order; untouched when it does.
    # -Url compares the values as PSPhoenix records URLs - without credentials - so a remote in
    # place that carries a working token keeps it.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Key, [AllowEmptyString()][string[]]$Values = @(), [switch]$Url)
    # -z: values end in NUL, so a value with a newline reads back as one value, not two.
    $raw = @(Invoke-PhxGit -Repository $Path -Arguments 'config', '-z', '--local', '--get-all', $Key -AllowExitCode 1) -join "`n"
    $existing = if ($raw) { @($raw.Split([char]0) | Select-Object -SkipLast 1) } else { @() }
    if ($Url) { $existing = @($existing | ForEach-Object { Remove-PhxUrlSecret $_ }) }
    # Count and text: "absent" and "one empty value" both join to ''.
    if ($existing.Count -eq $Values.Count -and ($existing -join "`n") -ceq ($Values -join "`n")) { return }
    Invoke-PhxGit -Repository $Path -Arguments 'config', '--local', '--unset-all', $Key -AllowExitCode 5 | Out-Null
    foreach ($value in $Values) { Invoke-PhxGit -Repository $Path -Arguments 'config', '--local', '--add', $Key, $value | Out-Null }
}

function Set-PhxRepoSetup {
    # Remotes and repo-local settings as recorded - right after a clone, before any fetch or push;
    # a no-op on a repository in place when nothing changed. The inventory is not trusted blindly:
    # only setting keys PSPhoenix records are written, and no URL that git could read as an option.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Repo, [Parameter(Mandatory)][string]$Path)
    $current = (Read-PhxRepoConfig -Path $Path).Remotes
    foreach ($name in @($Repo.remotes.Keys)) {
        $urls = @($Repo.remotes[$name].urls)
        $pushUrls = @($Repo.remotes[$name].pushUrls)
        if (@($urls + $pushUrls | Where-Object { "$_" -like '-*' }).Count) { throw "remote $name has a URL starting with '-' - refused" }
        if (-not $current.Contains($name)) { Invoke-PhxGit -Repository $Path -Arguments 'remote', 'add', '--', $name, $urls[0] | Out-Null }
        Set-PhxRepoValues -Path $Path -Key "remote.$name.url" -Values $urls -Url
        Set-PhxRepoValues -Path $Path -Key "remote.$name.pushurl" -Values $pushUrls -Url
    }
    $byKey = [ordered]@{}
    foreach ($entry in @($Repo.settings)) {
        if ($entry.key -notmatch $script:PhxRepoSettingPattern) { throw "$($entry.key) is not a setting PSPhoenix records - refused" }
        if (-not $byKey.Contains($entry.key)) { $byKey[$entry.key] = [Collections.Generic.List[string]]::new() }
        # A key without a value is git's "true".
        $byKey[$entry.key].Add($(if ($null -eq $entry.value) { 'true' } else { $entry.value }))
    }
    foreach ($key in $byKey.Keys) { Set-PhxRepoValues -Path $Path -Key $key -Values $byKey[$key] }
}

function Restore-PhxRepo {
    # One repository: cloned, or found in place - remotes and settings re-applied either way.
    # Returns cloned, present or skipped.
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Repo,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)]$Context,
        [string[]]$TokenHosts = @('github.com')
    )
    $log = $Context.Log
    $target = Get-PhxRepoPath -Root $Root -RelativePath $Repo.path
    $occupied = [IO.Directory]::Exists($target) -and @([IO.Directory]::EnumerateFileSystemEntries($target)).Count
    if ($occupied) {
        if (-not [IO.Directory]::Exists((Join-Path $target '.git'))) { & $log "$target exists and is not a repository - $($Repo.identity) skipped" 'Warn'; return 'skipped' }
        $there = (Get-PhxRepoRecord -Root $Root -Path $target).identity
        if ($there -ne $Repo.identity) { & $log "$target holds $there, not $($Repo.identity) - skipped" 'Warn'; return 'skipped' }
        if ($Context.DryRun) { & $log "would re-apply remotes and settings: $target" 'Action'; return 'present' }
        Set-PhxRepoSetup -Repo $Repo -Path $target
        return 'present'
    }
    $primary = $Repo.primaryRemote
    if (-not $primary) { & $log "$($Repo.identity): no remote to clone from - it comes back from its bundle (M4)" 'Warn'; return 'skipped' }
    $url = @($Repo.remotes[$primary].urls)[0]
    $as = if ($Repo.account) { " as $($Repo.account)" } else { '' }
    if ($Context.DryRun) { & $log "would clone $url -> $target$as" 'Action'; return 'cloned' }
    & $log "cloning $($Repo.identity) -> $target$as" 'Action'
    Invoke-PhxClone -Url $url -Target $target -RemoteName $primary -Account $Repo.account -TokenHosts $TokenHosts
    Set-PhxRepoSetup -Repo $Repo -Path $target
    $current = Read-PhxGitFileRef (Join-Path $target '.git/HEAD') 'refs/heads/'
    if ($Repo.branch -and $Repo.branch -cne $current) {
        if (Invoke-PhxGit -Repository $target -Arguments 'rev-parse', '--verify', '--quiet', "refs/remotes/$primary/$($Repo.branch)" -AllowExitCode 1) {
            Invoke-PhxGit -Repository $target -Arguments 'switch', '--quiet', $Repo.branch | Out-Null
        }
        else { & $log "$($Repo.identity): branch $($Repo.branch) is not on $primary - it comes back from its bundle (M4)" 'Warn' }
    }
    'cloned'
}

function Restore-PhxRepos {
    # Every recorded repository (or the selected ones) under its root - mapped to a new root when
    # the context says so. Idempotent: a second run finds them all in place. A root that is not a
    # path on this platform (C:\Repos on Linux) must be mapped.
    param([Parameter(Mandatory)]$Context)
    $file = Join-Path $Context.Staging 'repos.json'
    if (-not [IO.File]::Exists($file)) { throw "no repository inventory in $($Context.Staging)" }
    $document = ConvertTo-PhxCaseInsensitive (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable)
    if ($document.format -gt $script:PhxReposFormat) { throw "$file was written by a newer PSPhoenix (format $($document.format)) - update PSPhoenix first" }
    # The hosts a token can come from: github.com, and whatever else gh is logged in to.
    $tokenHosts = @(@('github.com') + @(Get-PhxGhAccount | ForEach-Object Host) | Select-Object -Unique)
    $counts = [ordered]@{ cloned = 0; present = 0; skipped = 0; failed = 0 }
    foreach ($repo in @($document.repositories)) {
        if ($Context.Select.Count -and $Context.Select -notcontains $repo.identity) { continue }
        $root = if ($Context.RootMap.Contains($repo.root)) { $Context.RootMap[$repo.root] } else { $repo.root }
        if (-not [IO.Path]::IsPathFullyQualified($root)) {
            & $Context.Log "$($repo.identity): its root $root is not a path on this machine - map it to one" 'Warn'
            $counts.skipped++
            continue
        }
        # One repository that cannot be cloned (no token for its account, a remote that is gone)
        # must not hold up the others; the summary counts it and the caller sees the failure.
        try { $result = Restore-PhxRepo -Repo $repo -Root $root -Context $Context -TokenHosts $tokenHosts }
        catch {
            & $Context.Log "$($repo.identity) -> $(Get-PhxRepoPath -Root $root -RelativePath $repo.path): $(Hide-PhxSecret $_.Exception.Message)" 'Warn'
            $result = 'failed'
        }
        $counts[$result]++
        foreach ($worktree in @($repo.worktrees)) {
            $branch = if ($worktree.branch) { $worktree.branch } else { 'detached' }
            & $Context.Log "$($repo.identity): worktree $($worktree.path) ($branch) is not recreated - worktrees are transient"
        }
    }
    $verb = if ($Context.DryRun) { 'would be ' } else { '' }
    & $Context.Log ('{0} {1}cloned, {2} already in place, {3} skipped, {4} failed' -f $counts.cloned, $verb, $counts.present, $counts.skipped, $counts.failed)
    if ($counts.failed) { throw "$($counts.failed) repositories could not be restored - see above" }
}

function Get-PhxReposStatus {
    # phx status lines: what the last scan found under the configured roots, per account.
    param([Parameter(Mandatory)]$Context)
    $cache = Read-PhxRepoCache -Quiet
    if (-not $cache) { return 'not scanned yet - phx scan' }
    $records = @(Get-PhxScannedRecord -Cache $cache -Config $Context.Config)
    Format-PhxRepoCount $records
    $byAccount = $records | Where-Object { Get-PhxIdentityOwner $_.identity } |
        Group-Object { $account = Get-PhxRepoAccount -Record $_ -Accounts $Context.Config.accounts; if ($account) { $account } else { '(host default)' } } |
        Sort-Object Name
    foreach ($group in $byAccount) { "  $($group.Name): $($group.Count)" }
}

Register-PhxProvider @{
    Name        = 'repos'
    Description = 'Repositories: remotes, branch, repo-local identity and GitHub account (restore clones them)'
    Backup      = { param($Context) Backup-PhxRepos -Context $Context }
    Restore     = { param($Context) Restore-PhxRepos -Context $Context }
    Status      = { param($Context) Get-PhxReposStatus -Context $Context }
}
