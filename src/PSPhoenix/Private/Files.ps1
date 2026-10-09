# Writing files so that a reader - the scheduled run, a sync client - never sees half a file, or
# no file at all (docs/design.md -> Targets: write to a temporary name, rename into place).

function Move-PhxIntoPlace {
    # One rename of $Temporary over $Path. [IO.File]::Move with overwrite replaces the target in
    # place (MoveFileEx on Windows, rename(2) elsewhere); Move-Item -Force deletes the target first,
    # which leaves a moment with no file - a reader then takes "no config" for "not set up yet".
    param([Parameter(Mandatory)][string]$Temporary, [Parameter(Mandatory)][string]$Path)
    for ($attempt = 1; ; $attempt++) {
        try { [IO.File]::Move($Temporary, $Path, $true); return }
        catch [System.UnauthorizedAccessException], [System.IO.IOException] {
            # On Windows a reader that holds the target open (Get-Content, a sync client, a virus
            # scanner) blocks the replace for a moment. Retry for about a second.
            if ($attempt -ge 20) { throw }
            Start-Sleep -Milliseconds 50
        }
    }
}

function Get-PhxTemporaryPath {
    # A uniquely named temporary file next to $Path: two writers never share one.
    param([Parameter(Mandatory)][string]$Path)
    $dir = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    Join-Path $dir ('.{0}.{1}.tmp' -f (Split-Path -Leaf $Path), [guid]::NewGuid().ToString('N').Substring(0, 8))
}

function Write-PhxTextFile {
    # UTF-8 without BOM into a temporary file next to $Path, then one rename over $Path.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )
    $tmp = Get-PhxTemporaryPath $Path
    try {
        [IO.File]::WriteAllText($tmp, $Value, [Text.UTF8Encoding]::new($false))
        Move-PhxIntoPlace -Temporary $tmp -Path $Path
    }
    finally {
        if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) }
    }
}

function Copy-PhxFile {
    # $Source to $Path the same way: a copy under a temporary name, then one rename over $Path.
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Path)
    $tmp = Get-PhxTemporaryPath $Path
    try {
        [IO.File]::Copy($Source, $tmp, $true)
        Move-PhxIntoPlace -Temporary $tmp -Path $Path
    }
    finally {
        if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) }
    }
}

function Get-PhxFileHash {
    # SHA-256 of a file's content, as hex.
    param([Parameter(Mandatory)][string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    try { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)) }
    finally { $stream.Dispose() }
}
