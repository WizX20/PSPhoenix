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

# Repo-local settings that make up who you are in a repository (docs/design.md -> GitHub accounts):
# recorded by the repos provider and re-applied right after a clone, before any fetch or push.
$script:PhxRepoSettingPattern = '^(user\.(name|email|signingkey)|include\.path|includeif\..+\.path|credential\..+|core\.sshcommand|commit\.gpgsign|tag\.gpgsign|gpg\.format|gpg\.ssh\.allowedsignersfile)$'

function Read-PhxRepoConfig {
    # A repository's local config in one git call: its remotes ({ url, pushUrl } per name, in config
    # order) and its identity settings ({ key, value } in order - multi-valued keys such as a reset
    # `credential.helper =` followed by the real one keep their order). Files the local config
    # includes (`include.path = ../.gitconfig`, tracked in the repository) are read too, but kept
    # apart as Included: they come back with the clone, so a restore must not copy them into the
    # local config - yet their credential helper still tells which account the repository uses.
    param([Parameter(Mandatory)][string]$Path)
    $remotes = [ordered]@{}
    $settings = [Collections.Generic.List[object]]::new()
    $included = [Collections.Generic.List[object]]::new()
    foreach ($line in @(Invoke-PhxGit -Repository $Path -Arguments 'config', '--local', '--includes', '--list', '--show-origin' -AllowFailure)) {
        $origin, $entry = $line -split "`t", 2
        $key, $value = "$entry" -split '=', 2
        if ($origin -ne 'file:.git/config') {
            if ($key -match $script:PhxRepoSettingPattern) { $included.Add([ordered]@{ key = $key; value = "$value" }) }
            continue
        }
        if ($key -match '^remote\.(?<name>.+)\.(?<kind>url|pushurl)$') {
            $name = $Matches.name
            $field = if ($Matches.kind -eq 'url') { 'url' } else { 'pushUrl' }
            if (-not $remotes.Contains($name)) { $remotes[$name] = [ordered]@{ url = $null; pushUrl = $null } }
            if (-not $remotes[$name][$field]) { $remotes[$name][$field] = "$value" }
        }
        elseif ($key -match $script:PhxRepoSettingPattern) { $settings.Add([ordered]@{ key = $key; value = "$value" }) }
    }
    [pscustomobject]@{ Remotes = $remotes; Settings = @($settings); Included = @($included) }
}

function Get-PhxPrimaryRemote {
    # origin, else the first remote; nothing for a repository without remotes.
    param([System.Collections.IDictionary]$Remotes)
    if ($Remotes.Contains('origin')) { 'origin' } elseif ($Remotes.Count) { @($Remotes.Keys)[0] }
}

function Get-PhxCredentialAccount {
    # The account a repository's own credential helper asks gh for (`gh auth token --user <x>`, as
    # a WizX20-style .gitconfig include sets up), or nothing.
    param([object[]]$Settings)
    foreach ($entry in @($Settings)) {
        if ($entry.key -like 'credential.*helper' -and $entry.value -match '--user\s+["'']?(?<login>[A-Za-z0-9][A-Za-z0-9-]*)') { return $Matches.login }
    }
}

function Get-PhxRepoRecord {
    # What discovery knows about one repository: where it is, its remotes, its identity, the account
    # its credential helper names, its linked worktrees. One git call, two with worktrees.
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Path)
    $relative = [IO.Path]::GetRelativePath($Root, $Path) -replace '\\', '/'
    $local = Read-PhxRepoConfig -Path $Path
    $remotes = [ordered]@{}
    foreach ($name in $local.Remotes.Keys) { $remotes[$name] = $local.Remotes[$name].url }
    $primary = Get-PhxPrimaryRemote $remotes
    $identity = if ($primary) { ConvertTo-PhxRepoIdentity -Url $remotes[$primary] -BasePath $Path }
    else { 'local/' + $(if ($relative -eq '.') { [IO.Path]::GetFileName($Root) } else { $relative }) }
    # Only a repository with .git/worktrees has linked worktrees - most have none, and every git
    # call costs ~0.1 s on Windows. The first entry of `git worktree list` is the repository itself.
    $worktrees = @()
    if ([IO.Directory]::Exists((Join-Path $Path '.git/worktrees'))) {
        $worktrees = @(Invoke-PhxGit -Repository $Path -Arguments 'worktree', 'list', '--porcelain' -AllowFailure |
                Where-Object { $_ -like 'worktree *' } | ForEach-Object { $_.Substring(9) } | Select-Object -Skip 1)
    }
    [ordered]@{
        identity  = $identity
        root      = $Root
        path      = $relative
        remotes   = $remotes
        account   = Get-PhxCredentialAccount (@($local.Settings) + @($local.Included))
        worktrees = $worktrees
    }
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
    # last scan. -Roots scans those instead of the configured ones (the wizard, before it saves);
    # -PassThru also returns the records.
    param([object[]]$Roots, [switch]$PassThru)
    $roots = if ($PSBoundParameters.ContainsKey('Roots')) { @($Roots) } else { Get-PhxRoot }
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
