# The state (docs/design.md -> Change detection and resource use): machine-local, never backed up,
# and never needed for correctness - a missing or broken state only means "everything changed",
# never an error. It holds the last run (when, which providers, which failed, its log); per
# provider when it last ran; per source file its size, mtime and SHA-256 (per provider: two
# providers reading one file each keep their own view); per published snapshot file the SHA-256 it
# was published with, and into which snapshot, so publishing need not
# read the target back; and per repository a hash of its refs, for the wip provider (M4).

$script:PhxStateVersion = 1

function Get-PhxStatePath { Join-Path (Get-PhxStateDir) 'state.json' }

function New-PhxPathDictionary {
    # A dictionary keyed by path, compared as the platform compares paths.
    [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::FromComparison((Get-PhxPathComparison)))
}

function New-PhxState {
    [ordered]@{
        version   = $script:PhxStateVersion
        lastRun   = $null
        providers = [ordered]@{}
        files     = [ordered]@{}
        published = [ordered]@{}
        # The snapshot folder the published hashes are of: another one (a new target, a renamed
        # machine) starts without any.
        publishedTo = $null
        refs      = New-PhxPathDictionary
    }
}

function ConvertTo-PhxPathDictionary {
    # A JSON object of path -> value as a path dictionary; anything else as an empty one.
    param($Value)
    $dictionary = New-PhxPathDictionary
    if ($Value -is [System.Collections.IDictionary]) { foreach ($key in $Value.Keys) { $dictionary[$key] = $Value[$key] } }
    , $dictionary
}

function Read-PhxState {
    # The state, or a fresh one when there is none, it cannot be read, or a newer PSPhoenix wrote it.
    param([switch]$Quiet)
    $path = Get-PhxStatePath
    if (-not [IO.File]::Exists($path)) { return New-PhxState }
    try {
        $read = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($read -is [System.Collections.IDictionary] -and $read['version'] -eq $script:PhxStateVersion) {
            $state = New-PhxState
            if ($read['lastRun'] -is [System.Collections.IDictionary]) { $state.lastRun = $read['lastRun'] }
            if ($read['providers'] -is [System.Collections.IDictionary]) { foreach ($name in $read['providers'].Keys) { $state.providers[$name] = $read['providers'][$name] } }
            if ($read['files'] -is [System.Collections.IDictionary]) {
                foreach ($name in $read['files'].Keys) { $state.files[$name] = ConvertTo-PhxPathDictionary $read['files'][$name] }
            }
            if ($read['publishedTo'] -is [string]) { $state.publishedTo = $read['publishedTo'] }
            $state.refs = ConvertTo-PhxPathDictionary $read['refs']
            if ($read['published'] -is [System.Collections.IDictionary]) {
                foreach ($name in $read['published'].Keys) { $state.published[$name] = ConvertTo-PhxPathDictionary $read['published'][$name] }
            }
            return $state
        }
    }
    catch { $null = $_ }
    if (-not $Quiet) { Write-Host "ignoring $path - not a state this PSPhoenix wrote; the next run takes everything as changed" -ForegroundColor DarkYellow }
    New-PhxState
}

function Save-PhxState {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State)
    Write-PhxTextFile -Path (Get-PhxStatePath) -Value ($State | ConvertTo-Json -Depth 10 -Compress)
}

function ConvertTo-PhxDateTime {
    # A time from the state or a cache - a DateTime once ConvertFrom-Json has read it, else ISO
    # text - as a UTC DateTime; nothing when it is neither.
    param($Value)
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse("$Value", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) { $parsed.ToUniversalTime() }
}

function New-PhxFileTracker {
    # What one provider's Test-PhxFileChanged works on: the files as its last successful run saw
    # them (Known), and what this run sees (Seen). The run keeps Seen only when the provider
    # succeeds - a run that failed half-way must not make a change look handled the next time - and
    # a file the provider no longer looks at drops out by itself.
    param([System.Collections.IDictionary]$Known)
    [pscustomobject]@{ Known = $(if ($Known) { $Known } else { New-PhxPathDictionary }); Seen = New-PhxPathDictionary }
}

function Test-PhxFileChanged {
    # True when $Path is new, or its content differs from what the provider's last run saw. Size
    # and mtime first - a stat, the cheap part - and the SHA-256 only when either differs, so a file
    # touched but not changed (a tool rewriting the same bytes) is hashed once but does not count as
    # changed. A file that is gone counts as changed. $Files is the provider's tracker
    # ($Context.Files).
    param([Parameter(Mandatory)]$Files, [Parameter(Mandatory)][string]$Path)
    $info = [IO.FileInfo]::new($Path)
    if (-not $info.Exists) { return $true }
    $size = $info.Length
    $mtime = $info.LastWriteTimeUtc.Ticks
    $known = if ($Files.Known.ContainsKey($Path)) { $Files.Known[$Path] }
    if ($known -and $known.size -eq $size -and $known.mtime -eq $mtime) { $Files.Seen[$Path] = $known; return $false }
    $hash = Get-PhxFileHash $Path
    $Files.Seen[$Path] = [ordered]@{ size = $size; mtime = $mtime; sha256 = $hash }
    -not $known -or $known.sha256 -ne $hash
}

function Get-PhxRefsHash {
    # One hash over a repository's refs - branches, tags, remote branches, the stash - and HEAD:
    # unchanged refs mean no local-only work can have changed, so the wip provider (M4) skips the
    # repository. One git call.
    param([Parameter(Mandatory)][string]$Path)
    $refs = @(Invoke-PhxGit -Repository $Path -Arguments 'for-each-ref', '--format=%(refname) %(objectname)')
    $head = @(Invoke-PhxGit -Repository $Path -Arguments 'rev-parse', '--symbolic-full-name', 'HEAD', 'HEAD' -AllowFailure)
    $bytes = [Text.Encoding]::UTF8.GetBytes((@($refs) + @($head)) -join "`n")
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
}
