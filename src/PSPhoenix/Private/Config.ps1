# The user config (docs/design.md -> Config). Read as a hashtable so providers can add their own
# sections without a schema change here; `version` guards future migrations.

$script:PhxConfigVersion = 1

function New-PhxDefaultConfig {
    [ordered]@{
        version   = $script:PhxConfigVersion
        roots     = @()
        target    = $null
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
    Merge-PhxConfig -Default (New-PhxDefaultConfig) -Config $config
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
