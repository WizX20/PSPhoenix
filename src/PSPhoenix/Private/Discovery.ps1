# Discovery (docs/design.md -> Concepts): which repositories live under the roots, and who they
# are. A repository is known by its remote, not by its path, so a restore can put it elsewhere.
# `phx scan` writes what it finds to repos.json in the state folder - machine-local, regenerable.

# Never descended into: build output and package caches hold thousands of folders and no
# repository worth finding.
$script:PhxScanSkip = @('node_modules', 'bin', 'obj', 'packages', '.vs', '.idea', '.venv', 'venv',
    '__pycache__', '.gradle', '.dart_tool', '.terraform', '.next', '$RECYCLE.BIN', 'System Volume Information')
$script:PhxRepoCacheVersion = 1

function Find-PhxRepository {
    # The repositories under one root, breadth-first to -Depth levels (a repository directly in the
    # root is level 1). A folder with a .git directory is a repository: recorded, not entered. A
    # .git file marks a linked worktree or a submodule: skipped - a worktree is recorded on its main
    # repository, a submodule comes back with its parent. Junctions and symbolic links are not
    # followed (a loop, or the same repository twice); unreadable folders are passed over.
    param([Parameter(Mandatory)][string]$Root, [int]$Depth = 3)
    if ([IO.Directory]::Exists((Join-Path $Root '.git'))) { return $Root }
    $queue = [Collections.Generic.Queue[object]]::new()
    $queue.Enqueue(@($Root, 0))
    while ($queue.Count) {
        $folder, $level = $queue.Dequeue()
        if ($level -ge $Depth) { continue }
        try { $children = [IO.Directory]::GetDirectories($folder) } catch { continue }
        foreach ($child in $children) {
            if ($script:PhxScanSkip -contains [IO.Path]::GetFileName($child)) { continue }
            if ([IO.File]::GetAttributes($child) -band [IO.FileAttributes]::ReparsePoint) { continue }
            $git = Join-Path $child '.git'
            if ([IO.Directory]::Exists($git)) { $child; continue }
            if ([IO.File]::Exists($git)) { continue }
            $queue.Enqueue(@($child, ($level + 1)))
        }
    }
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

function Get-PhxRepoRecord {
    # What discovery knows about one repository: where it is, its remotes, its identity, its linked
    # worktrees. Two git calls.
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Path)
    $relative = [IO.Path]::GetRelativePath($Root, $Path) -replace '\\', '/'
    $remotes = [ordered]@{}
    foreach ($line in @(Invoke-PhxGit -Repository $Path -Arguments 'config', '--local', '--get-regexp', '^remote\..+\.url$' -AllowFailure)) {
        if ($line -match '^remote\.(?<name>.+)\.url (?<url>.+)$' -and -not $remotes.Contains($Matches.name)) {
            $remotes[$Matches.name] = $Matches.url
        }
    }
    $primary = if ($remotes.Contains('origin')) { $remotes['origin'] } elseif ($remotes.Count) { @($remotes.Values)[0] }
    $identity = if ($primary) { ConvertTo-PhxRepoIdentity -Url $primary -BasePath $Path }
    else { 'local/' + $(if ($relative -eq '.') { [IO.Path]::GetFileName($Root) } else { $relative }) }
    # Only a repository with .git/worktrees has linked worktrees - most have none, and every git
    # call costs ~0.1 s on Windows. The first entry of `git worktree list` is the repository itself.
    $worktrees = @()
    if ([IO.Directory]::Exists((Join-Path $Path '.git/worktrees'))) {
        $worktrees = @(Invoke-PhxGit -Repository $Path -Arguments 'worktree', 'list', '--porcelain' -AllowFailure |
                Where-Object { $_ -like 'worktree *' } | ForEach-Object { $_.Substring(9) } | Select-Object -Skip 1)
    }
    [ordered]@{ identity = $identity; root = $Root; path = $relative; remotes = $remotes; worktrees = $worktrees }
}

function Get-PhxRepoCachePath { Join-Path (Get-PhxStateDir) 'repos.json' }

function Read-PhxRepoCache {
    # The last scan, or nothing. The cache is regenerable, so a missing, unreadable or newer one
    # means "not scanned" rather than an error.
    $path = Get-PhxRepoCachePath
    if (-not [IO.File]::Exists($path)) { return }
    try {
        $cache = ConvertTo-PhxCaseInsensitive (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop)
        if ($cache -is [System.Collections.IDictionary] -and $cache.version -eq $script:PhxRepoCacheVersion) { return $cache }
    }
    catch { $null = $_ }
    Write-Host "ignoring $path - not a scan this PSPhoenix wrote; phx scan rebuilds it" -ForegroundColor DarkYellow
}

function Get-PhxRepoKey {
    # One repository in one place: identities repeat when the same remote is cloned twice.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Record)
    (Join-Path $Record.root $Record.path)
}

function Invoke-PhxScan {
    # Discovers the repositories under every root, saves the cache and says what changed since the
    # last scan. -PassThru also returns the records.
    param([switch]$PassThru)
    $roots = Get-PhxRoot
    if (-not $roots) { throw 'no roots yet - add the folders that hold your repositories: phx roots add <path>' }
    $previous = Read-PhxRepoCache
    $records = [Collections.Generic.List[object]]::new()
    foreach ($root in $roots) {
        if (-not [IO.Directory]::Exists($root.path)) {
            Write-Host ('  {0,-48} folder not found - skipped' -f $root.path) -ForegroundColor Yellow
            continue
        }
        $found = @(Find-PhxRepository -Root $root.path -Depth $root.depth | ForEach-Object { Get-PhxRepoRecord -Root $root.path -Path $_ })
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

    $local = @($records | Where-Object { $_.identity -like 'local/*' }).Count
    Write-Host "$($records.Count) repositories$(if ($local) { ", $local without a remote" })" -ForegroundColor Green
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
    foreach ($group in @($records | Where-Object { $_.identity -notlike 'local/*' } | Group-Object { $_.identity } | Where-Object Count -GT 1)) {
        Write-Host "  $($group.Name) is cloned $($group.Count) times: $(($group.Group | ForEach-Object { Get-PhxRepoKey $_ }) -join ', ')" -ForegroundColor Yellow
    }
    if ($PassThru) { $records }
}
