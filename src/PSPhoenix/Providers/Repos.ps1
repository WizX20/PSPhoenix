# The repos provider (docs/design.md -> Providers, GitHub accounts): the repository inventory -
# remotes, branches, repo-local identity, the GitHub account - and on restore the clones back.
# Tracked files are never copied: a clone brings them. Local-only work is the wip provider (M4).

$script:PhxReposFormat = 1

function Read-PhxGitFileRef {
    # The branch a symbolic ref under .git points at (HEAD, refs/remotes/origin/HEAD), read from the
    # file - nothing for a detached HEAD or a missing ref. Saves a git call per repository.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Prefix)
    if (-not [IO.File]::Exists($Path)) { return }
    $line = [IO.File]::ReadAllText($Path).Trim()
    if ($line.StartsWith("ref: $Prefix", [StringComparison]::Ordinal)) { $line.Substring(5 + $Prefix.Length) }
}

function Get-PhxRepoPath {
    # Where a recorded repository lives under a root (`.` is the root itself).
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$RelativePath)
    if ($RelativePath -eq '.') { $Root } else { Join-Path $Root $RelativePath }
}

function Get-PhxRepoInventory {
    # One repository as the snapshot records it: one git call, the rest read from .git.
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Record,
        [System.Collections.IDictionary]$Accounts = @{}
    )
    $path = Get-PhxRepoPath -Root $Record.root -RelativePath $Record.path
    $gitDir = Join-Path $path '.git'
    $local = Read-PhxRepoConfig -Path $path
    $primary = Get-PhxPrimaryRemote $local.Remotes

    # The account: the repository's own credential helper, else the accounts map for its
    # host/owner, else none - the host's default account.
    $account = Get-PhxCredentialAccount (@($local.Settings) + @($local.Included))
    $source = if ($account) { 'credential helper' }
    if (-not $account -and $Record.identity -match '^(?<owner>[^/]+/[^/]+)/' -and $Accounts.Contains($Matches.owner)) {
        $account = $Accounts[$Matches.owner]
        $source = 'accounts'
    }
    $attributes = Join-Path $path '.gitattributes'
    [ordered]@{
        identity      = $Record.identity
        root          = $Record.root
        path          = $Record.path
        remotes       = $local.Remotes
        primaryRemote = $primary
        defaultBranch = if ($primary) { Read-PhxGitFileRef (Join-Path $gitDir "refs/remotes/$primary/HEAD") "refs/remotes/$primary/" }
        branch        = Read-PhxGitFileRef (Join-Path $gitDir 'HEAD') 'refs/heads/'
        settings      = @($local.Settings)
        worktrees     = @($Record.worktrees)
        lfs           = [IO.Directory]::Exists((Join-Path $gitDir 'lfs')) -or ([IO.File]::Exists($attributes) -and [IO.File]::ReadAllText($attributes) -match 'filter=lfs')
        submodules    = [IO.File]::Exists((Join-Path $path '.gitmodules'))
        account       = $account
        accountSource = $source
    }
}

function Backup-PhxRepos {
    # repos.json in the staging folder: every repository of the last scan that still exists.
    param([Parameter(Mandatory)]$Context)
    $cache = Read-PhxRepoCache
    if (-not $cache) {
        & $Context.Log 'no scan yet - scanning the roots first'
        Invoke-PhxScan
        $cache = Read-PhxRepoCache
    }
    $accounts = if ($Context.Config.accounts) { $Context.Config.accounts } else { @{} }
    $inventory = foreach ($record in @($cache.repositories)) {
        $path = Get-PhxRepoPath -Root $record.root -RelativePath $record.path
        if (-not [IO.Directory]::Exists((Join-Path $path '.git'))) {
            & $Context.Log "gone since the last scan, not recorded: $path" 'Warn'
            continue
        }
        Get-PhxRepoInventory -Record $record -Accounts $accounts
    }
    $document = [ordered]@{ format = $script:PhxReposFormat; repositories = @($inventory) }
    if ($Context.DryRun) { & $Context.Log "would record $(@($inventory).Count) repositories" 'Action'; return }
    Write-PhxTextFile -Path (Join-Path $Context.Staging 'repos.json') -Value ($document | ConvertTo-Json -Depth 10)
    & $Context.Log "$(@($inventory).Count) repositories recorded"
}

function Invoke-PhxClone {
    # git clone. When the repository has an account and its remote is https, the clone gets that
    # account's token for this one process: GH_TOKEN plus gh's own credential helper, every other
    # helper switched off for the call. Never a token on disk, never `gh auth switch`.
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$RemoteName,
        [string]$Account
    )
    $parent = Split-Path $Target -Parent
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $options = @()
    $tokenHost = if ($Account -and $Url -match '^https://(?:[^@/]+@)?(?<host>[^/:]+)') { $Matches.host }
    $savedToken = $env:GH_TOKEN
    try {
        if ($tokenHost) {
            $env:GH_TOKEN = Get-PhxGhToken -Account $Account -HostName $tokenHost
            $options = '-c', 'credential.helper=', '-c', 'credential.helper=!gh auth git-credential'
        }
        Invoke-PhxGit -Repository $parent -Arguments ($options + @('clone', '--quiet', '--origin', $RemoteName, $Url, $Target)) | Out-Null
    }
    finally { $env:GH_TOKEN = $savedToken }
}

function Set-PhxRepoSetup {
    # Remotes and repo-local settings as recorded - right after a clone, before any fetch or push;
    # on a repository already in place it is a no-op when nothing changed.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Repo, [Parameter(Mandatory)][string]$Path)
    $current = (Read-PhxRepoConfig -Path $Path).Remotes
    foreach ($name in @($Repo.remotes.Keys)) {
        $remote = $Repo.remotes[$name]
        if (-not $current.Contains($name)) { Invoke-PhxGit -Repository $Path -Arguments 'remote', 'add', $name, $remote.url | Out-Null }
        elseif ($current[$name].url -cne $remote.url) { Invoke-PhxGit -Repository $Path -Arguments 'remote', 'set-url', $name, $remote.url | Out-Null }
        if ($remote.pushUrl -and $current[$name].pushUrl -cne $remote.pushUrl) {
            Invoke-PhxGit -Repository $Path -Arguments 'remote', 'set-url', '--push', $name, $remote.pushUrl | Out-Null
        }
    }
    # Per key: all recorded values in their order, replacing what is there.
    $byKey = [ordered]@{}
    foreach ($entry in @($Repo.settings)) {
        if (-not $byKey.Contains($entry.key)) { $byKey[$entry.key] = [Collections.Generic.List[string]]::new() }
        $byKey[$entry.key].Add($entry.value)
    }
    foreach ($key in $byKey.Keys) {
        $existing = @(Invoke-PhxGit -Repository $Path -Arguments 'config', '--local', '--get-all', $key -AllowFailure)
        if (($existing -join "`n") -ceq ($byKey[$key] -join "`n")) { continue }
        Invoke-PhxGit -Repository $Path -Arguments 'config', '--local', '--unset-all', $key -AllowFailure | Out-Null
        foreach ($value in $byKey[$key]) { Invoke-PhxGit -Repository $Path -Arguments 'config', '--local', '--add', $key, $value | Out-Null }
    }
}

function Restore-PhxRepo {
    # One repository: cloned, or found in place - remotes and settings re-applied either way.
    # Returns cloned, present or skipped.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Repo, [Parameter(Mandatory)][string]$Target, [Parameter(Mandatory)]$Context)
    $log = $Context.Log
    $occupied = [IO.Directory]::Exists($Target) -and @([IO.Directory]::EnumerateFileSystemEntries($Target)).Count
    if ($occupied) {
        if (-not [IO.Directory]::Exists((Join-Path $Target '.git'))) { & $log "$Target exists and is not a repository - $($Repo.identity) skipped" 'Warn'; return 'skipped' }
        $there = (Get-PhxRepoRecord -Root $Target -Path $Target).identity
        if ($there -ne $Repo.identity) { & $log "$Target holds $there, not $($Repo.identity) - skipped" 'Warn'; return 'skipped' }
        if ($Context.DryRun) { & $log "would re-apply remotes and settings: $Target" 'Action'; return 'present' }
        Set-PhxRepoSetup -Repo $Repo -Path $Target
        return 'present'
    }
    $primary = $Repo.primaryRemote
    if (-not $primary) { & $log "$($Repo.identity): no remote to clone from - it comes back from its bundle (M4)" 'Warn'; return 'skipped' }
    $url = $Repo.remotes[$primary].url
    $as = if ($Repo.account) { " as $($Repo.account)" } else { '' }
    if ($Context.DryRun) { & $log "would clone $url -> $Target$as" 'Action'; return 'cloned' }
    & $log "cloning $($Repo.identity) -> $Target$as" 'Action'
    Invoke-PhxClone -Url $url -Target $Target -RemoteName $primary -Account $Repo.account
    Set-PhxRepoSetup -Repo $Repo -Path $Target
    $current = Read-PhxGitFileRef (Join-Path $Target '.git/HEAD') 'refs/heads/'
    if ($Repo.branch -and $Repo.branch -ne $current) {
        if (Invoke-PhxGit -Repository $Target -Arguments 'rev-parse', '--verify', '--quiet', "refs/remotes/$primary/$($Repo.branch)" -AllowFailure) {
            Invoke-PhxGit -Repository $Target -Arguments 'switch', '--quiet', $Repo.branch | Out-Null
        }
        else { & $log "$($Repo.identity): branch $($Repo.branch) is not on $primary - it comes back from its bundle (M4)" 'Warn' }
    }
    'cloned'
}

function Restore-PhxRepos {
    # Every recorded repository (or the selected ones) under its root - mapped to a new root when
    # the context says so. Idempotent: a second run finds them all in place.
    param([Parameter(Mandatory)]$Context)
    $file = Join-Path $Context.Staging 'repos.json'
    if (-not [IO.File]::Exists($file)) { throw "no repository inventory in $($Context.Staging)" }
    $document = ConvertTo-PhxCaseInsensitive (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable)
    if ($document.format -gt $script:PhxReposFormat) { throw "$file was written by a newer PSPhoenix (format $($document.format)) - update PSPhoenix first" }
    $counts = [ordered]@{ cloned = 0; present = 0; skipped = 0; failed = 0 }
    foreach ($repo in @($document.repositories)) {
        if ($Context.Select.Count -and $Context.Select -notcontains $repo.identity) { continue }
        $root = if ($Context.RootMap.Contains($repo.root)) { $Context.RootMap[$repo.root] } else { $repo.root }
        $target = Get-PhxRepoPath -Root $root -RelativePath $repo.path
        # One repository that cannot be cloned (no token for its account, a remote that is gone)
        # must not hold up the others; the summary counts it and the caller sees the failure.
        try { $result = Restore-PhxRepo -Repo $repo -Target $target -Context $Context }
        catch {
            & $Context.Log "$($repo.identity) -> ${target}: $($_.Exception.Message)" 'Warn'
            $result = 'failed'
        }
        $counts[$result]++
        foreach ($worktree in @($repo.worktrees)) { & $Context.Log "$($repo.identity): worktree $worktree is not recreated - worktrees are transient" }
    }
    $verb = if ($Context.DryRun) { 'would be ' } else { '' }
    & $Context.Log ('{0} {1}cloned, {2} already in place, {3} skipped, {4} failed' -f $counts.cloned, $verb, $counts.present, $counts.skipped, $counts.failed)
    if ($counts.failed) { throw "$($counts.failed) repositories could not be restored - see above" }
}

function Get-PhxRepoAccount {
    # The account a scanned repository needs: its credential helper's, else the accounts map's for
    # its host/owner, else none (the host's default).
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Record, [System.Collections.IDictionary]$Accounts = @{})
    if ($Record.account) { return $Record.account }
    if ($Record.identity -match '^(?<owner>[^/]+/[^/]+)/' -and $Accounts.Contains($Matches.owner)) { $Accounts[$Matches.owner] }
}

function Get-PhxReposStatus {
    # phx status lines: what the last scan found, per account.
    param([Parameter(Mandatory)]$Context)
    $cache = Read-PhxRepoCache
    if (-not $cache) { return 'not scanned yet - phx scan' }
    $records = @($cache.repositories)
    $local = @($records | Where-Object { $_.identity -like 'local/*' }).Count
    "$($records.Count) repositories$(if ($local) { ", $local without a remote" })"
    $accounts = if ($Context.Config.accounts) { $Context.Config.accounts } else { @{} }
    $byAccount = $records | Where-Object { $_.identity -notlike 'local/*' } |
        Group-Object { $account = Get-PhxRepoAccount -Record $_ -Accounts $accounts; if ($account) { $account } else { '(host default)' } } |
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
