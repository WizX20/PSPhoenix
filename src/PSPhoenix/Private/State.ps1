# The state (docs/design.md -> Change detection and resource use): machine-local, never backed up,
# and never needed for correctness - a missing or broken state only means "everything changed",
# never an error. It holds, per provider, when it last ran; per source file its size, mtime and
# SHA-256; per published snapshot file the SHA-256 it was published with, so publishing need not
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
        providers = [ordered]@{}
        files     = New-PhxPathDictionary
        published = [ordered]@{}
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
            if ($read['providers'] -is [System.Collections.IDictionary]) { foreach ($name in $read['providers'].Keys) { $state.providers[$name] = $read['providers'][$name] } }
            $state.files = ConvertTo-PhxPathDictionary $read['files']
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

function Test-PhxFileChanged {
    # True when $Path is new, or its content differs from what the state last recorded for it. Size
    # and mtime first - a stat, the cheap part - and the SHA-256 only when either differs, so a file
    # touched but not changed (a tool rewriting the same bytes) is hashed once but does not count as
    # changed. Records what it finds; a file that is gone is forgotten and counts as changed.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State, [Parameter(Mandatory)][string]$Path)
    $info = [IO.FileInfo]::new($Path)
    if (-not $info.Exists) { [void]$State.files.Remove($Path); return $true }
    $size = $info.Length
    $mtime = $info.LastWriteTimeUtc.Ticks
    $known = if ($State.files.ContainsKey($Path)) { $State.files[$Path] }
    if ($known -and $known.size -eq $size -and $known.mtime -eq $mtime) { return $false }
    $hash = Get-PhxFileHash $Path
    $State.files[$Path] = [ordered]@{ size = $size; mtime = $mtime; sha256 = $hash }
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
