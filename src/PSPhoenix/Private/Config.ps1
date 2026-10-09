# The user config (docs/design.md -> Config). Read as a hashtable so providers can add their own
# sections without a schema change here; `version` guards future migrations.

$script:PhxConfigVersion = 1

function New-PhxDefaultConfig {
    [ordered]@{
        version   = $script:PhxConfigVersion
        roots     = @()
        target    = $null
        # This machine's folder in the target (the computer name when empty), and the id of this
        # installation, which phx init makes: see Snapshot.ps1.
        machine   = [ordered]@{ name = $null; id = $null }
        interval  = '1h'
        providers = [ordered]@{}
        accounts  = [ordered]@{}
        secrets   = [ordered]@{ recipient = $null }
        files     = [ordered]@{ maxKB = 1024; exclude = @(); repos = [ordered]@{} }
    }
}

function Read-PhxConfig {
    # A missing config is not an error: it is a machine where `phx init` has not run yet. Anything
    # else that is not a valid config is - falling back to the defaults would let a run back up an
    # empty config over the real one.
    $path = Get-PhxConfigPath
    if (-not (Test-Path -LiteralPath $path)) { return New-PhxDefaultConfig }
    $text = Get-Content -LiteralPath $path -Raw
    if ([string]::IsNullOrWhiteSpace($text)) { throw "config $path is empty - restore it from a snapshot, or delete it and run phx init" }
    try { $parsed = $text | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { throw "config $path is not valid JSON: $($_.Exception.Message)" }
    if ($parsed -isnot [System.Collections.IDictionary]) { throw "config $path is not a JSON object" }
    try { $config = ConvertTo-PhxCaseInsensitive $parsed }
    catch { throw "config ${path}: $($_.Exception.Message)" }

    $version = $config['version']
    if ($version -isnot [long] -and $version -isnot [int]) { throw "config $path has no whole-number 'version'" }
    if ($version -gt $script:PhxConfigVersion) {
        throw "config $path has version $version; this PSPhoenix understands up to $script:PhxConfigVersion - update PSPhoenix"
    }
    if ($version -lt 1) { throw "config $path has version $version, which no PSPhoenix writes" }
    $merged = Merge-PhxConfig -Default (New-PhxDefaultConfig) -Config $config
    $merged.roots = @(ConvertTo-PhxConfigRoot -Roots $merged.roots -ConfigPath $path)
    $merged
}

function ConvertTo-PhxConfigRoot {
    # config.roots as every caller may rely on it: { path, depth } each, a full path, a depth from 1
    # to 10 - the default when a hand-edited root leaves it out (depth 0 would find nothing and
    # report every repository gone). Empty entries are dropped; anything else is an error.
    param($Roots, [Parameter(Mandatory)][string]$ConfigPath)
    foreach ($root in @($Roots)) {
        if ($null -eq $root) { continue }
        if ($root -isnot [System.Collections.IDictionary] -or $root.path -isnot [string] -or -not $root.path) { throw "config ${ConfigPath}: every root needs a path" }
        if (-not [IO.Path]::IsPathFullyQualified($root.path)) { throw "config ${ConfigPath}: root $($root.path) is not a full path" }
        if ($null -eq $root.depth) { $root.depth = $script:PhxDefaultRootDepth }
        if (($root.depth -isnot [int] -and $root.depth -isnot [long]) -or $root.depth -lt 1 -or $root.depth -gt 10) {
            throw "config ${ConfigPath}: root $($root.path) has depth $($root.depth) - a whole number from 1 to 10"
        }
        $root.depth = [int]$root.depth
        $root
    }
}

function ConvertTo-PhxCaseInsensitive {
    # ConvertFrom-Json -AsHashtable returns case-sensitive dictionaries, while the defaults - like
    # every hashtable literal - are case-insensitive. Normalised once here, $config.files.maxKB
    # means the same on a loaded config as on the defaults. Two keys that differ only in case
    # are an error rather than a coin toss.
    param($Value)
    if ($Value -is [System.Collections.IDictionary]) {
        $out = [ordered]@{}
        foreach ($key in $Value.Keys) {
            if ($out.Contains($key)) { throw "duplicate key '$key' (keys are case-insensitive)" }
            $out[$key] = ConvertTo-PhxCaseInsensitive $Value[$key]
        }
        return $out
    }
    if ($Value -is [System.Collections.IList]) {
        return , @(foreach ($item in $Value) { ConvertTo-PhxCaseInsensitive $item })
    }
    $Value
}

function Merge-PhxConfig {
    # Fills in what an older or hand-edited config leaves out, so every caller can rely on every
    # section being there: values from the file win, nested sections merge key by key, and the
    # result keeps the default's spelling of each key.
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Default,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config
    )
    foreach ($key in $Config.Keys) {
        if ($Default[$key] -is [System.Collections.IDictionary] -and $Config[$key] -is [System.Collections.IDictionary]) {
            Merge-PhxConfig -Default $Default[$key] -Config $Config[$key] | Out-Null
        }
        else { $Default[$key] = $Config[$key] }
    }
    $Default
}

function Save-PhxConfig {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
    # Temp file + rename: a scheduled run reading the config never sees half a file, or none.
    Write-PhxTextFile -Path (Get-PhxConfigPath) -Value ($Config | ConvertTo-Json -Depth 10)
}
