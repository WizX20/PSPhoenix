# Writing files so that a reader - the scheduled run, a sync client - never sees half a file, or
# no file at all (docs/design.md -> Targets: write to a temporary name, rename into place).

function Write-PhxTextFile {
    # UTF-8 without BOM into a uniquely named temporary file next to $Path, then one rename over
    # $Path. [IO.File]::Move with overwrite replaces the target in place (MoveFileEx on Windows,
    # rename(2) elsewhere); Move-Item -Force deletes the target first, which leaves a moment with
    # no file - a reader then takes "no config" for "not set up yet". The unique name keeps two
    # writers from sharing one temporary file.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )
    $dir = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    $tmp = Join-Path $dir ('.{0}.{1}.tmp' -f (Split-Path -Leaf $Path), [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        [IO.File]::WriteAllText($tmp, $Value, [Text.UTF8Encoding]::new($false))
        for ($attempt = 1; ; $attempt++) {
            try { [IO.File]::Move($tmp, $Path, $true); break }
            catch [System.UnauthorizedAccessException], [System.IO.IOException] {
                # On Windows a reader that holds the target open (Get-Content, a sync client, a
                # virus scanner) blocks the replace for a moment. Retry for about a second.
                if ($attempt -ge 20) { throw }
                Start-Sleep -Milliseconds 50
            }
        }
    }
    finally {
        if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) }
    }
}
