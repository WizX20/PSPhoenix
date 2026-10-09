# Discovery (docs/design.md -> Concepts): which repositories live under the roots, and who they
# are. A repository is known by its remote, not by its path, so a restore can put it elsewhere.
# `phx scan` writes what it finds to repos.json in the state folder - machine-local, regenerable.

# Never descended into: build output and package caches hold thousands of folders and no
# repository worth finding.
$script:PhxScanSkip = @('node_modules', 'bin', 'obj', 'packages', '.vs', '.idea', '.venv', 'venv',
    '__pycache__', '.gradle', '.dart_tool', '.terraform', '.next', '$RECYCLE.BIN', 'System Volume Information')
$script:PhxRepoCacheVersion = 1

function Test-PhxLinkFolder {
    # True for a junction or symbolic link, which discovery does not follow (a loop, or the same
    # repository twice). A cloud-sync placeholder - OneDrive, Dropbox, Google Drive - carries the
    # ReparsePoint attribute as well but has no link target, and is searched like any folder.
    param([Parameter(Mandatory)][string]$Path)
    $info = [IO.DirectoryInfo]::new($Path)
    [bool](($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $info.LinkTarget)
}

function Find-PhxRepository {
    # The repositories under one root, breadth-first to -Depth levels (a repository directly in the
    # root is level 1). A folder with a .git directory is a repository: recorded, not entered. A
    # .git file marks a linked worktree or a submodule: skipped - a worktree is recorded on its main
    # repository, a submodule comes back with its parent. Links are not followed; folders that
    # cannot be read, or vanish while the walk looks at them, are passed over.
    param([Parameter(Mandatory)][string]$Root, [int]$Depth = 3)
    if ([IO.Directory]::Exists((Join-Path $Root '.git'))) { return $Root }
    $queue = [Collections.Generic.Queue[object]]::new()
    $queue.Enqueue(@($Root, 0))
    while ($queue.Count) {
        $folder, $level = $queue.Dequeue()
        if ($level -ge $Depth) { continue }
        try { $children = [IO.Directory]::GetDirectories($folder) } catch { continue }
        foreach ($child in $children) {
            try {
                if ($script:PhxScanSkip -contains [IO.Path]::GetFileName($child)) { continue }
                if (Test-PhxLinkFolder $child) { continue }
                $git = Join-Path $child '.git'
                if ([IO.Directory]::Exists($git)) { $child; continue }
                if ([IO.File]::Exists($git)) { continue }
                $queue.Enqueue(@($child, ($level + 1)))
            }
            catch { continue }
        }
    }
}

function Test-PhxTokenLike {
    # A user name that is itself a credential: a GitHub, GitLab or Slack token, or a long opaque
    # string such as an Azure DevOps PAT.
    param([string]$Text)
    $Text -match '^(gh[pousr]_|github_pat_|glpat-|xox[abps]-)' -or ($Text.Length -ge 32 -and $Text -match '^[A-Za-z0-9_-]+$')
}

function Remove-PhxUrlSecret {
    # A remote URL as PSPhoenix may record it: the password of `user:password@` is dropped, and so is
    # a user name that is itself a token. Snapshots and logs never carry a credential.
    param([AllowEmptyString()][string]$Url)
    if ($Url -match '^(?<scheme>[A-Za-z][A-Za-z0-9+.-]*://)(?<user>[^/@:]*)(?::[^/@]*)?@(?<rest>.*)$') {
        $user = if (Test-PhxTokenLike $Matches.user) { '' } else { $Matches.user }
        return $Matches.scheme + $(if ($user) { "$user@" } else { '' }) + $Matches.rest
    }
    $Url
}

function Hide-PhxSecret {
    # Text for a log line or an error message, with credentials in any URL inside it masked.
    param([AllowEmptyString()][string]$Text)
    $Text = [regex]::Replace($Text, '(?<=://)(?<user>[^/@:\s]*):[^/@\s]*@', { "$($args[0].Groups['user'].Value):***@" })
    [regex]::Replace($Text, '(?<=://)(?<user>[^/@:\s]+)@', { if (Test-PhxTokenLike $args[0].Groups['user'].Value) { '***@' } else { $args[0].Value } })
}

function Get-PhxIdentityOwner {
    # host/owner of a remote-based identity - what the accounts map is keyed by. Nothing for local/
    # and file/ identities: there is no account to sign in as.
    param([string]$Identity)
    if ($Identity -match '^(?!local/|file/)(?<owner>[^/]+/[^/]+)/') { $Matches.owner }
}

function Get-PhxRepoPath {
    # Where a recorded repository lives under a root (`.` is the root itself), with this platform's
    # separators - the relative path is stored with `/`.
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$RelativePath)
    if ($RelativePath -eq '.') { $Root } else { [IO.Path]::GetFullPath((Join-Path $Root $RelativePath)) }
}

function Format-PhxRepoCount {
    # "26 repositories, 2 without a remote, 3 offline".
    param([object[]]$Records = @())
    $text = "$(@($Records).Count) repositories"
    $local = @($Records | Where-Object { $_.identity -like 'local/*' }).Count
    $offline = @($Records | Where-Object { $_.offline }).Count
    if ($local) { $text += ", $local without a remote" }
    if ($offline) { $text += ", $offline offline" }
    $text
}

function ConvertTo-PhxRepoIdentity {
    # A remote URL as `host/owner/name`: host lower-cased, the path as written, without `.git` or a
    # trailing slash. https, ssh://, git:// and scp-style `git@host:owner/name` all give the same
    # identity; Azure DevOps folds into `dev.azure.com/org/project/repo` whichever URL form it came
    # in. A local path, file:// URL or UNC path becomes `file/<path>`: still something to clone from.
    param([Parameter(Mandatory)][string]$Url, [string]$BasePath)
    $url = $Url.Trim()
    $hostName = ''
    if ($url -match '^(?<scheme>[A-Za-z][A-Za-z0-9+.-]*)://(?:[^@/]*@)?(?<host>[^/:]*)(?::\d*)?(?:/(?<path>.*))?$') {
        if ($Matches.scheme -eq 'file') { $path = (@($Matches.host, $Matches.path) | Where-Object { $_ }) -join '/' }
        else { $hostName = $Matches.host; $path = $Matches.path }
    }
    elseif ($url -match '^\\\\(?<path>.+)$') { $path = $Matches.path }
    elseif ($url -match '^[A-Za-z]:[\\/]' -or $url -match '^[\\/.]' -or $url -notmatch ':') {
        $path = if ($BasePath -and -not [IO.Path]::IsPathRooted($url)) { [IO.Path]::GetFullPath($url, $BasePath) } else { $url }
    }
    elseif ($url -match '^(?:[^@/]+@)?(?<host>[^:/]+):(?<path>.+)$') { $hostName = $Matches.host; $path = $Matches.path }
    else { $path = $url }

    $path = ([uri]::UnescapeDataString("$path") -replace '\\', '/').Trim('/')
    if ($path.EndsWith('.git', [StringComparison]::OrdinalIgnoreCase)) { $path = $path.Substring(0, $path.Length - 4).TrimEnd('/') }
    if (-not $hostName) { return 'file/' + ($path -replace '^([A-Za-z]):', '$1') }

    $hostName = $hostName.ToLowerInvariant()
    if ($hostName -in 'ssh.dev.azure.com', 'vs-ssh.visualstudio.com' -and $path -match '^v3/(?<rest>.+)$') {
        $hostName = 'dev.azure.com'; $path = $Matches.rest
    }
    elseif ($hostName -match '^(?<org>[^.]+)\.visualstudio\.com$') {
        $hostName = 'dev.azure.com'; $path = "$($Matches.org)/" + ($path -replace '^DefaultCollection/', '')
    }
    if ($hostName -eq 'dev.azure.com') { $path = $path -replace '/_git/', '/' }
    "$hostName/$path"
}

function Get-PhxWorktree {
    # The linked worktrees of a repository: { path, branch }, the path relative to the root when it
    # lies under it. Only a repository with .git/worktrees has any - most have none, and every git
    # call costs ~0.1 s on Windows. The first block of the porcelain list is the repository itself.
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Path)
    if (-not [IO.Directory]::Exists((Join-Path $Path '.git/worktrees'))) { return }
    $current = $null
    $blocks = foreach ($line in @(Invoke-PhxGit -Repository $Path -Arguments 'worktree', 'list', '--porcelain') + '') {
        if ($line -like 'worktree *') { $current = [ordered]@{ path = $line.Substring(9); branch = $null } }
        elseif ($line -like 'branch refs/heads/*' -and $current) { $current.branch = $line.Substring(18) }
        elseif (-not $line -and $current) { $current; $current = $null }
    }
    foreach ($worktree in @($blocks | Select-Object -Skip 1)) {
        $full = [IO.Path]::GetFullPath($worktree.path)
        $worktree.path = if (Test-PhxPathWithin $full $Root) { [IO.Path]::GetRelativePath($Root, $full) -replace '\\', '/' } else { $full }
        $worktree
    }
}

function Get-PhxRepoRecord {
    # What discovery knows about one repository: where it is, its remotes (credentials removed), its
    # identity, its linked worktrees. One git call, two with worktrees. Throws when git cannot read
    # the repository (dubious ownership, a broken .git/config) - recording it as remote-less would
    # quietly lose it.
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Path)
    $relative = [IO.Path]::GetRelativePath($Root, $Path) -replace '\\', '/'
    $remotes = [ordered]@{}
    # Exit code 1 only means "no remote".
    foreach ($line in @(Invoke-PhxGit -Repository $Path -Arguments 'config', '--local', '--get-regexp', '^remote\..+\.url$' -AllowExitCode 1)) {
        if ($line -match '^remote\.(?<name>.+?)\.url (?<url>.+)$' -and -not $remotes.Contains($Matches.name)) {
            $url = Remove-PhxUrlSecret $Matches.url
            if ($url -cne $Matches.url) { Write-Host "  ${Path}: remote $($Matches.name) carries credentials in its URL - recorded without them" -ForegroundColor Yellow }
            $remotes[$Matches.name] = $url
        }
    }
    $primary = if ($remotes.Contains('origin')) { 'origin' } elseif ($remotes.Count) { @($remotes.Keys)[0] }
    $identity = if ($primary) { ConvertTo-PhxRepoIdentity -Url $remotes[$primary] -BasePath $Path }
    else { 'local/' + $(if ($relative -eq '.') { [IO.Path]::GetFileName($Root) } else { $relative }) }
    [ordered]@{ identity = $identity; root = $Root; path = $relative; remotes = $remotes; worktrees = @(Get-PhxWorktree -Root $Root -Path $Path) }
}

function Get-PhxRepoCachePath { Join-Path (Get-PhxStateDir) 'repos.json' }

function Read-PhxRepoCache {
    # The last scan, or nothing. The cache is regenerable, so a missing, unreadable or newer one
    # means "not scanned" rather than an error; -Quiet skips saying so.
    param([switch]$Quiet)
    $path = Get-PhxRepoCachePath
    if (-not [IO.File]::Exists($path)) { return }
    try {
        $cache = ConvertTo-PhxCaseInsensitive (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop)
        if ($cache -is [System.Collections.IDictionary] -and $cache.version -eq $script:PhxRepoCacheVersion) { return $cache }
    }
    catch { $null = $_ }
    if (-not $Quiet) { Write-Host "ignoring $path - not a scan this PSPhoenix wrote; phx scan rebuilds it" -ForegroundColor DarkYellow }
}

function Get-PhxRootRepoCount {
    # How many repositories the last scan found under a root; nothing when that scan did not cover
    # the root (added since, or no scan at all).
    param([System.Collections.IDictionary]$Cache, [Parameter(Mandatory)][string]$Root)
    if (-not $Cache) { return }
    $comparison = Get-PhxPathComparison
    if (-not @(@($Cache.roots) | Where-Object { [string]::Equals($_.path, $Root, $comparison) }).Count) { return }
    @(@($Cache.repositories) | Where-Object { [string]::Equals($_.root, $Root, $comparison) }).Count
}

function Get-PhxRepoKey {
    # One repository in one place: identities repeat when the same remote is cloned twice.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Record)
    Get-PhxRepoPath -Root $Record.root -RelativePath $Record.path
}

function Invoke-PhxScan {
    # Discovers the repositories under every root, saves the cache and says what changed since the
    # last scan. -PassThru also returns the records.
    #
    # Nothing a scan cannot see is dropped: a root whose folder is gone (an unplugged drive, a
    # disconnected share) keeps the repositories the last scan found there, marked offline; a
    # repository git cannot read keeps its last record. A backup must not lose them because a drive
    # was out for an hour.
    param([switch]$PassThru)
    $roots = Get-PhxRoot
    if (-not $roots) { throw 'no roots yet - add the folders that hold your repositories: phx roots add <path>' }
    $previous = Read-PhxRepoCache
    $before = [ordered]@{}
    foreach ($record in @($previous.repositories | Where-Object { $_ })) { $before[(Get-PhxRepoKey $record)] = $record }
    $records = [Collections.Generic.List[object]]::new()
    foreach ($root in $roots) {
        if (-not [IO.Directory]::Exists($root.path)) {
            $kept = @($before.Values | Where-Object { [string]::Equals($_.root, $root.path, (Get-PhxPathComparison)) })
            foreach ($record in $kept) { $record.offline = $true; $records.Add($record) }
            Write-Host ('  {0,-48} folder not found - kept {1} repositories from the last scan, marked offline' -f $root.path, $kept.Count) -ForegroundColor Yellow
            continue
        }
        $found = @(foreach ($path in Find-PhxRepository -Root $root.path -Depth $root.depth) {
                try { Get-PhxRepoRecord -Root $root.path -Path $path }
                catch {
                    $last = $before[$path]
                    $note = if ($last) { ' - kept what the last scan recorded' } else { ' - not recorded' }
                    Write-Host "  skipped ${path}: $(Hide-PhxSecret $_.Exception.Message)$note" -ForegroundColor Yellow
                    if ($last) { $last }
                }
            })
        foreach ($record in $found) { $records.Add($record) }
        Write-Host ('  {0,-48} {1,4} repositories' -f $root.path, $found.Count)
    }
    $cache = [ordered]@{
        version      = $script:PhxRepoCacheVersion
        scannedAt    = [DateTime]::UtcNow.ToString('o')
        roots        = @($roots)
        repositories = @($records)
    }
    Write-PhxTextFile -Path (Get-PhxRepoCachePath) -Value ($cache | ConvertTo-Json -Depth 10)

    Write-Host (Format-PhxRepoCount $records) -ForegroundColor Green
    if ($previous) {
        $comparison = Get-PhxPathComparison
        $before = [Collections.Generic.HashSet[string]]::new([StringComparer]::FromComparison($comparison))
        foreach ($record in @($previous.repositories)) { [void]$before.Add((Get-PhxRepoKey $record)) }
        $now = [Collections.Generic.HashSet[string]]::new([StringComparer]::FromComparison($comparison))
        foreach ($record in $records) { [void]$now.Add((Get-PhxRepoKey $record)) }
        $new = @($records | Where-Object { -not $before.Contains((Get-PhxRepoKey $_)) })
        $gone = @(@($previous.repositories) | Where-Object { -not $now.Contains((Get-PhxRepoKey $_)) })
        foreach ($record in $new) { Write-Host "  new:  $($record.identity)   ($(Get-PhxRepoKey $record))" }
        foreach ($record in $gone) { Write-Host "  gone: $($record.identity)   ($(Get-PhxRepoKey $record))" -ForegroundColor DarkYellow }
    }
    # The same remote cloned twice: both are kept, but a restore puts both back - worth knowing.
    foreach ($group in @($records | Where-Object { $_.identity -notlike 'local/*' -and -not $_.offline } | Group-Object { $_.identity } | Where-Object Count -GT 1)) {
        Write-Host "  $($group.Name) is cloned $($group.Count) times: $(($group.Group | ForEach-Object { Get-PhxRepoKey $_ }) -join ', ')" -ForegroundColor Yellow
    }
    if ($PassThru) { $records }
}
