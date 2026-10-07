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
    # A missing config is not an error: it is a machine where `phx init` has not run yet.
    $path = Get-PhxConfigPath
    if (-not (Test-Path -LiteralPath $path)) { return New-PhxDefaultConfig }
    $config = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    if ($config.version -gt $script:PhxConfigVersion) {
        throw "config $path has version $($config.version); this PSPhoenix understands up to $script:PhxConfigVersion - update PSPhoenix"
    }
    $config
}

function Save-PhxConfig {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
    # Temp file + rename: a scheduled run reading the config never sees half a file, or none.
    Write-PhxTextFile -Path (Get-PhxConfigPath) -Value ($Config | ConvertTo-Json -Depth 10)
}
