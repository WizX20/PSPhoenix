# The claude provider (docs/design.md -> Providers, Snapshot layout): Claude Code's memory per
# project, the user's settings, CLAUDE.md, skills, commands, agents, status line and key bindings,
# and from ~/.claude.json only the MCP servers. Never .credentials.json; session transcripts only
# when the config asks (providers.claude.transcripts). A file with a secret in it - a token pasted
# into memory, an MCP server's API key - is stored only as <name>.age.
#
# Claude Code names a project's folder after its path (C:\Repos\App becomes C--Repos-App), which
# loses information. The snapshot keys a project's memory by its repository's identity instead, and
# restore derives the folder name from the repository's new path; a project without a repository
# keeps its folder name.
#
# Snapshot: claude/home/<file>, claude/projects/<identity>/memory/..., claude/claude.json (the MCP
# servers), and claude/claude-files.json - what is where, so a restore needs nothing else.

$script:PhxClaudeFormat = 1
# What the user wrote in ~/.claude: files at the top, and folders.
$script:PhxClaudeHomeFiles = @('settings.json', 'CLAUDE.md', 'keybindings.json')
$script:PhxClaudeHomeFolders = @('skills', 'commands', 'agents')
# Folders a tool fills inside a skill, never the user's own work.
$script:PhxClaudeSkip = @('node_modules', '.git', '.venv', 'venv', '__pycache__')

function Get-PhxClaudeDir {
    # Claude Code's folder: CLAUDE_CONFIG_DIR when set, as Claude Code reads it, else ~/.claude.
    $dir = [Environment]::GetEnvironmentVariable('CLAUDE_CONFIG_DIR')
    if ($dir -and [IO.Path]::IsPathFullyQualified($dir)) { return $dir }
    Join-PhxPath $HOME '.claude'
}

function Get-PhxClaudeJsonPath {
    # ~/.claude.json - inside CLAUDE_CONFIG_DIR when that is set.
    $dir = [Environment]::GetEnvironmentVariable('CLAUDE_CONFIG_DIR')
    if ($dir -and [IO.Path]::IsPathFullyQualified($dir)) { return Join-PhxPath $dir '.claude.json' }
    Join-PhxPath $HOME '.claude.json'
}

function ConvertTo-PhxClaudeProjectName {
    # The folder Claude Code keeps a project's memory and transcripts in, under ~/.claude/projects:
    # its path with every character but a letter or digit made a dash. C:\Repos\App: C--Repos-App.
    param([Parameter(Mandatory)][string]$Path)
    $Path -replace '[^A-Za-z0-9]', '-'
}

function ConvertTo-PhxClaudeJsonKey {
    # How ~/.claude.json keys a project: its path with forward slashes.
    param([Parameter(Mandatory)][string]$Path)
    $Path.Replace('\', '/')
}

function Get-PhxClaudeFile {
    # The files below a folder, relative to it with /, without following links and without what a
    # tool put there (node_modules, a virtual environment, a .git). Not the build-output denylist of
    # repo-files: a skill may well be called build or publish.
    param([Parameter(Mandatory)][string]$Folder)
    if (-not [IO.Directory]::Exists($Folder)) { return }
    $options = [IO.EnumerationOptions]::new()
    $options.RecurseSubdirectories = $true
    $options.AttributesToSkip = [IO.FileAttributes]::ReparsePoint
    $options.IgnoreInaccessible = $true
    foreach ($file in [IO.Directory]::EnumerateFiles($Folder, '*', $options)) {
        $relative = [IO.Path]::GetRelativePath($Folder, $file).Replace('\', '/')
        if (-not @($relative.Split('/') | Where-Object { $_ -in $script:PhxClaudeSkip }).Count) { $relative }
    }
}

function Copy-PhxClaudeStaged {
    # Stages one file; returns how it is stored - its path, or <path>.age - or nothing when it was
    # held back (a secret, no key yet) or went away while the run looked.
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    try { $staged = Copy-PhxStagedFile -Context $Context -Source $Source -Path $Path -PassThru }
    catch [System.IO.FileNotFoundException], [System.IO.DirectoryNotFoundException] { return }
    if (-not $staged.Stored) { return }
    # The stored name is the path's, with .age when encrypted.
    $Name + $staged.Stored.Substring($Path.Length)
}

function Get-PhxClaudeProject {
    # The project folders under ~/.claude/projects with the repository each belongs to: { Name,
    # Folder, Record }, Record empty for a project without one (or a repository no scan found).
    # A repository is matched by the name Claude Code derives from its path, ignoring case - the
    # drive letter comes either way.
    param([object[]]$Records = @())
    $projects = Join-PhxPath (Get-PhxClaudeDir) 'projects'
    if (-not [IO.Directory]::Exists($projects)) { return }
    $byName = @{}
    foreach ($record in $Records) {
        $name = (ConvertTo-PhxClaudeProjectName (Get-PhxRepoKey $record)).ToLowerInvariant()
        if (-not $byName.ContainsKey($name)) { $byName[$name] = $record }
    }
    foreach ($folder in [IO.Directory]::GetDirectories($projects) | Sort-Object) {
        $name = [IO.Path]::GetFileName($folder)
        [pscustomobject]@{ Name = $name; Folder = $folder; Record = $byName[$name.ToLowerInvariant()] }
    }
}

function Backup-PhxClaude {
    # Claude Code's state into staging: the home selection, each project's memory (and transcripts
    # when asked for), the MCP servers, and claude-files.json saying what is where.
    param([Parameter(Mandatory)]$Context)
    $claude = Get-PhxClaudeDir
    if (-not [IO.Directory]::Exists($claude)) { Assert-PhxSourceGone -Context $Context -Why "no Claude Code folder ($claude; CLAUDE_CONFIG_DIR is read from the environment of the run)"; return }
    $settings = $Context.Config.providers['claude']
    $transcripts = $settings -is [System.Collections.IDictionary] -and $settings.transcripts -eq $true
    $cache = Read-PhxRepoCache -Quiet
    $records = if ($cache) { @(Get-PhxScannedRecord -Cache $cache -Config $Context.Config) } else { @() }
    $folders = Get-PhxRepoFolderMap $records

    # The home selection: never .credentials.json, history or caches - only what the user wrote.
    $homeFiles = [Collections.Generic.List[object]]::new()
    $sources = @(
        foreach ($name in $script:PhxClaudeHomeFiles) { $name }
        foreach ($file in [IO.Directory]::GetFiles($claude, 'statusline*')) { [IO.Path]::GetFileName($file) }
        foreach ($folder in $script:PhxClaudeHomeFolders) { foreach ($file in @(Get-PhxClaudeFile (Join-PhxPath $claude $folder))) { "$folder/$file" } }
    )
    foreach ($relative in $sources) {
        $source = Join-PhxPath $claude $relative
        if (-not [IO.File]::Exists($source)) { continue }
        if ($Context.DryRun) { & $Context.Log "would back up ~/.claude/$relative" 'Action'; continue }
        $stored = Copy-PhxClaudeStaged -Context $Context -Source $source -Path "home/$relative" -Name $relative
        if ($stored) { $homeFiles.Add([ordered]@{ path = $relative; stored = $stored }) }
    }

    # Memory per project, by repository where there is one.
    $projects = [Collections.Generic.List[object]]::new()
    $matched = 0
    foreach ($project in @(Get-PhxClaudeProject -Records $records)) {
        $files = @(foreach ($file in @(Get-PhxClaudeFile (Join-PhxPath $project.Folder 'memory'))) { "memory/$file" })
        if ($transcripts) { $files += @([IO.Directory]::GetFiles($project.Folder, '*.jsonl') | ForEach-Object { [IO.Path]::GetFileName($_) }) }
        if (-not $files.Count) { continue }
        $entry = [ordered]@{ name = $project.Name }
        if ($project.Record) {
            $entry.identity = $project.Record.identity
            $entry.root = $project.Record.root
            $entry.path = $project.Record.path
            $entry.folder = $folders[(Get-PhxRepoKey $project.Record)]
            $matched++
        }
        else { $entry.folder = "path/$($project.Name)" }
        if ($Context.DryRun) { & $Context.Log "would back up $($files.Count) file(s) of $(if ($project.Record) { $project.Record.identity } else { $project.Name })" 'Action'; continue }
        $stored = [Collections.Generic.List[object]]::new()
        foreach ($file in $files) {
            $name = Copy-PhxClaudeStaged -Context $Context -Source (Join-PhxPath $project.Folder $file) -Path "projects/$($entry.folder)/$file" -Name $file
            if ($name) { $stored.Add([ordered]@{ path = $file; stored = $name }) }
        }
        if (-not $stored.Count) { continue }
        $entry.files = @($stored)
        $projects.Add($entry)
    }

    # The MCP servers, read as JSON by the engine - keys exact, nothing else of the file; a secret in
    # one (an API key in env) has the whole file encrypted.
    $repositories = [PSPhoenix.Engine.McpRepository[]]@($records | ForEach-Object { [PSPhoenix.Engine.McpRepository]::new($_.identity, $_.root, $_.path, (Get-PhxRepoKey $_)) })
    try { $mcp = [PSPhoenix.Engine.ClaudeMcp]::Backup((Get-PhxClaudeJsonPath), $repositories) }
    catch [System.Management.Automation.MethodInvocationException] { throw $_.Exception.InnerException }
    $mcpStored = $null
    $mcpCount = if ($mcp) { $mcp.Servers } else { 0 }
    if ($mcp) {
        if ($Context.DryRun) { & $Context.Log "would back up $mcpCount MCP server(s)" 'Action' }
        else {
            $staged = Write-PhxStagedText -Context $Context -Path 'claude.json' -Value $mcp.Json -PassThru
            $mcpStored = Get-PhxStoredName -Entry $staged
        }
    }
    if ($Context.DryRun) { return }
    $document = [ordered]@{ format = $script:PhxClaudeFormat; home = @($homeFiles); projects = @($projects); claudeJson = $mcpStored }
    Write-PhxStagedText -Context $Context -Path 'claude-files.json' -Value ($document | ConvertTo-Json -Depth 8) -FailOnSecret
    $note = if ($transcripts) { ', transcripts included' } else { '' }
    & $Context.Log "$($homeFiles.Count) file(s) of ~/.claude, memory of $($projects.Count) project(s) ($matched by repository), $mcpCount MCP server(s)$note"
}

function Restore-PhxClaudeEntry {
    # One project's files into ~/.claude/projects/<name>: the name from the repository's new path,
    # or the one it had.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Entry, [Parameter(Mandatory)]$Context, [Parameter(Mandatory)][System.Collections.IDictionary]$Counts)
    $files = @($Entry.files | Where-Object { $_ })
    $name = "$($Entry.name)"
    if ($Entry.identity) {
        if ($Context.Select.Count -and $Context.Select -notcontains $Entry.identity) { return }
        $repo = Resolve-PhxRestoreRepoPath -Entry $Entry -Context $Context
        if (-not $repo) {
            & $Context.Log "$($Entry.identity): its root $($Entry.root) is not a path on this machine - map it to one; its memory is skipped" 'Warn'
            $Counts.skipped += $files.Count
            return
        }
        $name = ConvertTo-PhxClaudeProjectName $repo
    }
    elseif ($Context.Select.Count) { return }
    if ($name -notmatch '^[A-Za-z0-9-]+$') { throw "project folder $name is not one Claude Code makes - refused" }
    $target = Join-PhxPath (Join-PhxPath (Get-PhxClaudeDir) 'projects') $name
    $source = [IO.Path]::GetFullPath((Join-PhxPath (Join-PhxPath $Context.Staging 'projects') "$($Entry.folder)"))
    if (-not (Test-PhxPathWithin $source (Join-PhxPath $Context.Staging 'projects'))) { throw "its folder $($Entry.folder) leads out of the snapshot - refused" }
    foreach ($file in $files) {
        Restore-PhxClaudeFile -Source (Join-PhxPath $source "$($file.stored)") -Target (Join-PhxPath $target "$($file.path)") -Within $target -SourceWithin $source -Encrypted:("$($file.stored)" -cne "$($file.path)") -Context $Context -Counts $Counts
    }
}

function Restore-PhxClaudeFile {
    # One file back, as repo-files does it: written when missing, left alone when the same or when
    # it differs (with a warning), a secret decrypted with the restore's age key.
    param(
        [Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Within, [Parameter(Mandatory)][string]$SourceWithin,
        [switch]$Encrypted, [Parameter(Mandatory)]$Context, [Parameter(Mandatory)][System.Collections.IDictionary]$Counts
    )
    $Target = [IO.Path]::GetFullPath($Target)
    $Source = [IO.Path]::GetFullPath($Source)
    if (-not (Test-PhxPathWithin $Target $Within) -or -not (Test-PhxPathWithin $Source $SourceWithin)) {
        & $Context.Log "$Target leads out of where it belongs - refused" 'Warn'
        $Counts.failed++
        return
    }
    if (-not [IO.File]::Exists($Source)) { & $Context.Log "$Source is missing from the snapshot" 'Warn'; $Counts.failed++; return }
    try { $result = Restore-PhxRepoFile -Source $Source -Target $Target -Encrypted:$Encrypted -Context $Context }
    catch { & $Context.Log "${Target}: $(Hide-PhxSecret $_.Exception.Message)" 'Warn'; $result = 'failed' }
    $Counts[$result]++
}

function Restore-PhxClaudeMcp {
    # The MCP servers into ~/.claude.json, through the engine (ClaudeMcp): one that is missing is
    # added - for a project under its new path - one that is there is left as it is, with a warning
    # when it differs. The rest of the file stays as Claude Code wrote it.
    param([Parameter(Mandatory)][string]$Source, [switch]$Encrypted, [Parameter(Mandatory)]$Context, [Parameter(Mandatory)][System.Collections.IDictionary]$Counts)
    $bytes = [IO.File]::ReadAllBytes($Source)
    if ($Encrypted) {
        if (-not $Context.Identity) { & $Context.Log 'the MCP servers are encrypted and this restore has no age key - skipped' 'Warn'; $Counts.skipped++; return }
        try { $bytes = [PSPhoenix.Engine.Age]::Decrypt($bytes, $Context.Identity) }
        catch [System.Management.Automation.MethodInvocationException] { throw $_.Exception.InnerException }
    }
    $backup = [Text.Encoding]::UTF8.GetString($bytes)
    # Where each project's servers go: the key of the repository's new path, the old key for a
    # project without one, nothing for one the restore does not do.
    $keys = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    try { $projects = @([PSPhoenix.Engine.ClaudeMcp]::Projects($backup)) }
    catch [System.Management.Automation.MethodInvocationException] { throw $_.Exception.InnerException }
    foreach ($project in $projects) {
        $target = $project.Key
        if ($project.Identity) {
            if ($Context.Select.Count -and $Context.Select -notcontains $project.Identity) { $target = $null }
            else {
                $repo = Resolve-PhxRestoreRepoPath -Entry ([ordered]@{ root = $project.Root; path = $project.Path }) -Context $Context
                if ($repo) { $target = ConvertTo-PhxClaudeJsonKey $repo }
                else {
                    & $Context.Log "$($project.Identity): its root $($project.Root) is not a path on this machine - its MCP servers are skipped" 'Warn'
                    $Counts.skipped++
                    $target = $null
                }
            }
        }
        elseif ($Context.Select.Count) { $target = $null }
        $keys[$project.Key] = $target
    }
    try { $changes = @([PSPhoenix.Engine.ClaudeMcp]::Merge((Get-PhxClaudeJsonPath), $backup, $keys, $Context.DryRun)) }
    catch [System.Management.Automation.MethodInvocationException] { throw $_.Exception.InnerException }
    foreach ($change in $changes) {
        switch ("$($change.Outcome)") {
            'Added' { if ($Context.DryRun) { & $Context.Log "would add MCP server $($change.Server) ($($change.Where))" 'Action' }; $Counts.restored++ }
            'Present' { $Counts.present++ }
            'Differs' { & $Context.Log "MCP server $($change.Server) ($($change.Where)) differs from the backup - left as it is" 'Warn'; $Counts.differs++ }
        }
    }
}

function Restore-PhxClaude {
    # Claude Code's state back: the home selection into ~/.claude, each project's memory into the
    # folder Claude Code derives from the repository's new path, the MCP servers into
    # ~/.claude.json. Nothing that is there is overwritten. Idempotent.
    param([Parameter(Mandatory)]$Context)
    $file = Join-PhxPath $Context.Staging 'claude-files.json'
    if (-not [IO.File]::Exists($file)) { & $Context.Log 'no Claude Code state in this snapshot'; return }
    $manifest = ConvertTo-PhxCaseInsensitive (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable)
    if ($manifest.format -gt $script:PhxClaudeFormat) { throw "$file was written by a newer PSPhoenix (format $($manifest.format)) - update PSPhoenix first" }
    $claude = Get-PhxClaudeDir
    $counts = [ordered]@{ restored = 0; present = 0; differs = 0; skipped = 0; failed = 0 }
    if (-not $Context.Select.Count) {
        $homeSource = Join-PhxPath $Context.Staging 'home'
        foreach ($entry in @($manifest.home | Where-Object { $_ })) {
            Restore-PhxClaudeFile -Source (Join-PhxPath $homeSource "$($entry.stored)") -Target (Join-PhxPath $claude "$($entry.path)") -Within $claude -SourceWithin $homeSource -Encrypted:("$($entry.stored)" -cne "$($entry.path)") -Context $Context -Counts $counts
        }
    }
    foreach ($entry in @($manifest.projects | Where-Object { $_ })) {
        try { Restore-PhxClaudeEntry -Entry $entry -Context $Context -Counts $counts }
        catch { & $Context.Log "$(if ($entry.identity) { $entry.identity } else { $entry.name }): $($_.Exception.Message)" 'Warn'; $counts.failed += @($entry.files).Count }
    }
    if ($manifest.claudeJson) {
        $source = [IO.Path]::GetFullPath((Join-PhxPath $Context.Staging "$($manifest.claudeJson)"))
        if ($manifest.claudeJson -notin 'claude.json', 'claude.json.age' -or -not [IO.File]::Exists($source)) { & $Context.Log "the MCP servers ($($manifest.claudeJson)) are missing from the snapshot" 'Warn'; $counts.failed++ }
        else {
            try { Restore-PhxClaudeMcp -Source $source -Encrypted:($manifest.claudeJson -eq 'claude.json.age') -Context $Context -Counts $counts }
            catch { & $Context.Log "MCP servers: $(Hide-PhxSecret $_.Exception.Message)" 'Warn'; $counts.failed++ }
        }
    }
    $verb = if ($Context.DryRun) { 'would be ' } else { '' }
    & $Context.Log ('{0} {1}restored, {2} already in place, {3} differ (left as they are), {4} skipped, {5} failed' -f $counts.restored, $verb, $counts.present, $counts.differs, $counts.skipped, $counts.failed)
    if ($counts.failed) { throw "$($counts.failed) Claude Code item(s) could not be restored - see above" }
}

function Get-PhxClaudeStatus {
    # phx status lines: what there is to back up of Claude Code, and whether transcripts are in.
    param([Parameter(Mandatory)]$Context)
    $claude = Get-PhxClaudeDir
    if (-not [IO.Directory]::Exists($claude)) { return "no Claude Code folder ($claude)" }
    $cache = Read-PhxRepoCache -Quiet
    $records = if ($cache) { @(Get-PhxScannedRecord -Cache $cache -Config $Context.Config) } else { @() }
    $withMemory = @(Get-PhxClaudeProject -Records $records | Where-Object { @(Get-PhxClaudeFile (Join-PhxPath $_.Folder 'memory')).Count })
    $matched = @($withMemory | Where-Object Record).Count
    $settings = $Context.Config.providers['claude']
    $transcripts = if ($settings -is [System.Collections.IDictionary] -and $settings.transcripts -eq $true) { 'session transcripts included' } else { 'session transcripts not (providers.claude.transcripts)' }
    "memory of $($withMemory.Count) project(s), $matched by repository; $transcripts"
}

Register-PhxProvider @{
    Name        = 'claude'
    Description = 'Claude Code: memory per project (by repository), settings, skills, commands, agents, MCP servers'
    Backup      = { param($Context) Backup-PhxClaude -Context $Context }
    Restore     = { param($Context) Restore-PhxClaude -Context $Context }
    Status      = { param($Context) Get-PhxClaudeStatus -Context $Context }
}
