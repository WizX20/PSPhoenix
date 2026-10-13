# Writing files so that a reader - the scheduled run, a sync client - never sees half a file, or no
# file at all (docs/design.md -> Targets: write to a temporary name, rename into place). The engine
# does the work (engine/src/PSPhoenix.Engine/AtomicFile.cs, FileHash.cs); these are its PowerShell
# face. An exception from the engine reaches the caller as itself, not wrapped in "Exception calling
# ...": a message here can end up in front of the user.

function Write-PhxTextFile {
    # UTF-8 without BOM into a temporary file next to $Path, then one rename over $Path.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )
    try { [PSPhoenix.Engine.AtomicFile]::WriteAllText($Path, $Value) }
    catch [System.Management.Automation.MethodInvocationException] { throw $_.Exception.InnerException }
}

function Copy-PhxFile {
    # $Source to $Path the same way: a copy under a temporary name, then one rename over $Path.
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Path)
    try { [PSPhoenix.Engine.AtomicFile]::Copy($Source, $Path) }
    catch [System.Management.Automation.MethodInvocationException] { throw $_.Exception.InnerException }
}

function Get-PhxFileHash {
    # SHA-256 of a file's content, as upper-case hex.
    param([Parameter(Mandatory)][string]$Path)
    try { [PSPhoenix.Engine.FileHash]::Sha256($Path) }
    catch [System.Management.Automation.MethodInvocationException] { throw $_.Exception.InnerException }
}
