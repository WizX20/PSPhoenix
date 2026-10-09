# Discovery (docs/design.md -> Concepts): which repositories live under the roots, and who they
# are. A repository is known by its remote, not by its path, so a restore can put it elsewhere.
# `phx scan` writes what it finds to repos.json in the state folder - machine-local, regenerable.

# Never descended into: build output and package caches hold thousands of folders and no
# repository worth finding.
$script:PhxScanSkip = @('node_modules', 'bin', 'obj', 'packages', '.vs', '.idea', '.venv', 'venv',
    '__pycache__', '.gradle', '.dart_tool', '.terraform', '.next', '$RECYCLE.BIN', 'System Volume Information')
# 2: a record holds everything the repos provider records (it held identity and remotes only).
$script:PhxRepoCacheVersion = 2

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

# Repo-local settings that make up who you are in a repository (docs/design.md -> GitHub accounts):
# recorded by the repos provider and re-applied right after a clone, before any fetch or push.
$script:PhxRepoSettingPattern = '^(user\.(name|email|signingkey)|include\.path|includeif\..+\.path|credential\..+|core\.sshcommand|commit\.gpgsign|tag\.gpgsign|gpg\.format|gpg\.ssh\.allowedsignersfile)$'

function Read-PhxRepoConfig {
    # A repository's local config in one git call: its remotes ({ urls, pushUrls } per name, in
    # config order, credentials removed) and its identity settings ({ key, value } in order, repeated
    # keys kept - a reset `credential.helper =` before the real one; a key without a value, which
    # git reads as true, has the value $null). Files the local config includes (`include.path =
    # ../.gitconfig`, tracked in the repository) are read too but kept apart as Included: they come
    # back with the clone, so a restore must not copy them into the local config - yet their
    # credential helper still tells which account the repository uses. An included file outside the
    # work tree (`~/.gitconfig-work`) does not come back with a clone: ExternalIncludes lists it.
    # Read with -z, as origin NUL key LF value NUL, so values keep their newlines. Throws when git
    # cannot read the repository.
    param([Parameter(Mandatory)][string]$Path)
    $remotes = [ordered]@{}
    $settings = [Collections.Generic.List[object]]::new()
    $included = [Collections.Generic.List[object]]::new()
    $external = [Collections.Generic.List[string]]::new()
    $raw = @(Invoke-PhxGit -Repository $Path -Arguments 'config', '-z', '--local', '--includes', '--list', '--show-origin') -join "`n"
    $parts = $raw.Split([char]0)
    for ($i = 0; $i + 1 -lt $parts.Count; $i += 2) {
        $origin = $parts[$i]
        $entry = $parts[$i + 1]
        $newline = $entry.IndexOf("`n")
        $key, $value = if ($newline -ge 0) { $entry.Substring(0, $newline), $entry.Substring($newline + 1) } else { $entry, $null }
        if ($origin -ne 'file:.git/config' -and $origin -like 'file:*') {
            # git names an included file relative to the repository (file:.git/../.gitconfig) or in full.
            $file = [IO.Path]::GetFullPath($origin.Substring(5), $Path)
            if ((-not (Test-PhxPathWithin $file $Path) -or (Test-PhxPathWithin $file (Join-Path $Path '.git'))) -and $external -notcontains $file) { $external.Add($file) }
        }
        if ($key -notmatch $script:PhxRepoSettingPattern -and $key -notmatch '^remote\..+\.(url|pushurl)$') { continue }
        if ($key -like 'credential.*' -and ($reason = Get-PhxCredentialSecret -Key $key -Value $value)) {
            Write-Host "  ${Path}: $(Hide-PhxSecret $key) $reason - not recorded" -ForegroundColor Yellow
            continue
        }
        if ($origin -ne 'file:.git/config') { $included.Add([ordered]@{ key = $key; value = $value }); continue }
        if ($key -match '^remote\.(?<name>.+)\.(?<kind>url|pushurl)$') {
            $name = $Matches.name
            $field = if ($Matches.kind -eq 'url') { 'urls' } else { 'pushUrls' }
            if (-not $value) { continue }
            $url = Remove-PhxUrlSecret $value
            if ($url -cne $value) { Write-Host "  ${Path}: remote $name carries credentials in its URL - recorded without them" -ForegroundColor Yellow }
            if (-not $remotes.Contains($name)) { $remotes[$name] = [ordered]@{ urls = @(); pushUrls = @() } }
            $remotes[$name][$field] += $url
        }
        else { $settings.Add([ordered]@{ key = $key; value = $value }) }
    }
    # A remote with only a push URL is nothing to clone from.
    foreach ($name in @($remotes.Keys)) { if (-not $remotes[$name].urls.Count) { $remotes.Remove($name) } }
    [pscustomobject]@{ Remotes = $remotes; Settings = @($settings); Included = @($included); ExternalIncludes = @($external) }
}

function Get-PhxPrimaryRemote {
    # origin, else the first remote; nothing for a repository without remotes.
    param([System.Collections.IDictionary]$Remotes)
    if ($Remotes.Contains('origin')) { 'origin' } elseif ($Remotes.Count) { @($Remotes.Keys)[0] }
}

function Get-PhxCredentialAccount {
    # The account a repository's own credential helper asks gh for - `gh auth token --user <x>`,
    # `-u <x>` or `--user=<x>`, as a WizX20-style .gitconfig include sets up - or nothing. Only a
    # helper that runs `gh auth`: another tool's --user names nobody gh could give a token for.
    param([object[]]$Settings)
    foreach ($entry in @($Settings)) {
        $value = "$($entry.value)"
        if ($entry.key -like 'credential.*helper' -and $value -match '\bgh(\.exe)?["'']?\s+auth\b' -and
            $value -match '(?:--user[=\s]\s*|\s-u\s+)["'']?(?<login>[A-Za-z0-9][A-Za-z0-9-]*)') { return $Matches.login }
    }
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

function Get-PhxSymbolicRef {
    # The branch a symbolic ref (HEAD, refs/remotes/origin/HEAD) points at, without $Prefix -
    # nothing for a detached HEAD or a missing ref. Read from the file under .git, which saves a git
    # call per repository; a repository on the reftable backend (git 3's default) keeps its refs in
    # no such files - its HEAD file only holds the stub `ref: refs/heads/.invalid` - so git is asked.
    param([Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)][string]$Ref, [Parameter(Mandatory)][string]$Prefix)
    $gitDir = Join-Path $Repository '.git'
    $target = if ([IO.Directory]::Exists((Join-Path $gitDir 'reftable'))) {
        "$(Invoke-PhxGit -Repository $Repository -Arguments 'symbolic-ref', '-q', $Ref -AllowFailure)"
    }
    elseif ([IO.File]::Exists((Join-Path $gitDir $Ref))) {
        $line = [IO.File]::ReadAllText((Join-Path $gitDir $Ref)).Trim()
        if ($line.StartsWith('ref: ', [StringComparison]::Ordinal)) { $line.Substring(5) }
    }
    if ("$target".StartsWith($Prefix, [StringComparison]::Ordinal)) { "$target".Substring($Prefix.Length) }
}

function Get-PhxCloneUrl {
    # The URL a recorded repository is cloned from: its primary remote's first URL.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Record)
    if ($Record.primaryRemote) { @($Record.remotes[$Record.primaryRemote].urls)[0] }
}

function Get-PhxRepoRecord {
    # Everything discovery and the repos provider know about one repository: where it is, its
    # identity, every remote URL and push URL (credentials removed), its branches, the repo-local
    # identity settings, the account its credential helper names, linked worktrees, LFS and
    # submodules, and the files it includes from outside its work tree. The scan cache holds these
    # records, so a repository a later run cannot read - an offline root - is still recorded in
    # full. One git call, two with worktrees; the rest is read from .git. Throws when git cannot
    # read the repository (dubious ownership, a broken .git/config) - recording it as remote-less
    # would quietly lose it.
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Path)
    $relative = [IO.Path]::GetRelativePath($Root, $Path) -replace '\\', '/'
    $gitDir = Join-Path $Path '.git'
    $local = Read-PhxRepoConfig -Path $Path
    $primary = Get-PhxPrimaryRemote $local.Remotes
    $identity = if ($primary) { ConvertTo-PhxRepoIdentity -Url $local.Remotes[$primary].urls[0] -BasePath $Path }
    else { 'local/' + $(if ($relative -eq '.') { [IO.Path]::GetFileName($Root) } else { $relative }) }
    $attributes = Join-Path $Path '.gitattributes'
    [ordered]@{
        identity         = $identity
        root             = $Root
        path             = $relative
        remotes          = $local.Remotes
        primaryRemote    = $primary
        defaultBranch    = if ($primary) { Get-PhxSymbolicRef -Repository $Path -Ref "refs/remotes/$primary/HEAD" -Prefix "refs/remotes/$primary/" }
        branch           = Get-PhxSymbolicRef -Repository $Path -Ref 'HEAD' -Prefix 'refs/heads/'
        settings         = @($local.Settings)
        helperAccount    = Get-PhxCredentialAccount (@($local.Settings) + @($local.Included))
        externalIncludes = @($local.ExternalIncludes)
        worktrees        = @(Get-PhxWorktree -Root $Root -Path $Path)
        lfs              = [IO.Directory]::Exists((Join-Path $gitDir 'lfs')) -or ([IO.File]::Exists($attributes) -and [IO.File]::ReadAllText($attributes) -match 'filter=lfs')
        submodules       = [IO.File]::Exists((Join-Path $Path '.gitmodules'))
    }
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

function Get-PhxScannedRecord {
    # The last scan's repositories under the configured roots. A root removed since, or a scan of
    # other roots, does not count.
    param([System.Collections.IDictionary]$Cache, [System.Collections.IDictionary]$Config)
    $roots = @($Config.roots | Where-Object { $_ } | ForEach-Object { $_.path })
    $comparison = Get-PhxPathComparison
    @($Cache.repositories | Where-Object { $_ }) | Where-Object {
        $root = $_.root
        @($roots | Where-Object { [string]::Equals($_, $root, $comparison) }).Count
    }
}

function Test-PhxScanDue {
    # Whether a run should scan the roots first: there is no scan, a configured root is missing
    # from it, or it is a day old (docs/design.md -> Change detection: discovery refreshed daily).
    param([System.Collections.IDictionary]$Cache, [System.Collections.IDictionary]$Config, [datetime]$Now = [DateTime]::UtcNow)
    if (-not $Cache) { return $true }
    foreach ($root in @($Config.roots)) { if ($null -eq (Get-PhxRootRepoCount -Cache $Cache -Root $root.path)) { return $true } }
    Test-PhxDue -Last $Cache.scannedAt -Every ([TimeSpan]::FromDays(1)) -Now $Now
}

function Get-PhxRepoKey {
    # One repository in one place: identities repeat when the same remote is cloned twice.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Record)
    Get-PhxRepoPath -Root $Record.root -RelativePath $Record.path
}

function Save-PhxRepoCache {
    # Writes what a scan found: the roots it walked and their repositories. -ScannedAt keeps the
    # time of the scan when the cache is only trimmed.
    param([object[]]$Roots = @(), [object[]]$Records = @(), $ScannedAt)
    $stamp = if ($ScannedAt -is [datetime]) { $ScannedAt.ToUniversalTime().ToString('o') } elseif ($ScannedAt) { "$ScannedAt" } else { [DateTime]::UtcNow.ToString('o') }
    $cache = [ordered]@{
        version      = $script:PhxRepoCacheVersion
        scannedAt    = $stamp
        roots        = @($Roots)
        repositories = @($Records)
    }
    Write-PhxTextFile -Path (Get-PhxRepoCachePath) -Value ($cache | ConvertTo-Json -Depth 10)
}

function Invoke-PhxScan {
    # Discovers the repositories under every root, saves the cache and says what changed since the
    # last scan. -Roots scans those instead of the configured ones, and -NoSave leaves the cache as
    # it is: the wizard scans the roots it is offered and saves them only with the config.
    # -PassThru also returns the records.
    #
    # Nothing a scan cannot see is dropped: a root whose folder is gone (an unplugged drive, a
    # disconnected share) keeps the repositories the last scan found there, marked offline; a
    # repository git cannot read keeps its last record. A backup must not lose them because a drive
    # was out for an hour.
    param([object[]]$Roots, [switch]$NoSave, [switch]$PassThru)
    $roots = if ($PSBoundParameters.ContainsKey('Roots')) { @($Roots) } else { Get-PhxRoot }
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
        # An empty root where the last scan found repositories is more likely a drive that is not
        # mounted (Linux keeps the empty mount point) than every repository deleted at once.
        $last = @($before.Values | Where-Object { [string]::Equals($_.root, $root.path, (Get-PhxPathComparison)) })
        if (-not $found.Count -and $last.Count) {
            foreach ($record in $last) { $record.offline = $true; $records.Add($record) }
            Write-Host ('  {0,-48} no repositories where the last scan found {1} - kept them, marked offline (a drive not mounted?); gone for good: phx roots rm, then phx roots add' -f $root.path, $last.Count) -ForegroundColor Yellow
            continue
        }
        foreach ($record in $found) { $records.Add($record) }
        Write-Host ('  {0,-48} {1,4} repositories' -f $root.path, $found.Count)
    }
    if (-not $NoSave) { Save-PhxRepoCache -Roots $roots -Records $records }

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
