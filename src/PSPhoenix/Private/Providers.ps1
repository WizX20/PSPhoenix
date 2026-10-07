# Provider registry (docs/design.md -> Provider contract). Each file in Providers/ calls
# Register-PhxProvider once at import; the dispatcher only ever talks to providers through here.

$script:PhxProviders = [ordered]@{}
$script:PhxPlatforms = @('Windows', 'Linux', 'macOS')
$script:PhxProviderKeys = @('Name', 'Description', 'Platforms', 'Cadence', 'Backup', 'Restore', 'Status')

function Register-PhxProvider {
    # Strict on purpose: a provider is registered once at import, so a mistake here should stop
    # the module loading in a test rather than surface as a provider that quietly never runs.
    param([Parameter(Mandatory)][hashtable]$Provider)
    foreach ($key in 'Name', 'Description', 'Backup', 'Restore', 'Status') {
        if (-not $Provider.ContainsKey($key) -or -not $Provider[$key]) { throw "provider is missing '$key'" }
    }
    $name = $Provider.Name
    # The name becomes a folder in the snapshot and a -Provider value on the command line.
    if ($name -isnot [string] -or $name -cnotmatch '^[a-z][a-z0-9-]*$') {
        throw "provider name '$name' must be lowercase letters, digits and dashes, starting with a letter"
    }
    # A typo such as 'Platform' would otherwise be ignored and the provider run everywhere.
    $unknownKeys = @($Provider.Keys | Where-Object { $script:PhxProviderKeys -notcontains $_ })
    if ($unknownKeys) { throw "provider '$name': unknown key(s) $($unknownKeys -join ', ') - expected $($script:PhxProviderKeys -join ', ')" }
    foreach ($key in 'Backup', 'Restore', 'Status') {
        if ($Provider[$key] -isnot [scriptblock]) { throw "provider '$name': '$key' must be a scriptblock" }
    }
    if (-not $Provider.ContainsKey('Platforms')) { $Provider.Platforms = $script:PhxPlatforms }
    if (-not @($Provider.Platforms).Count) { throw "provider '$name': Platforms is empty - leave it out to run on every platform" }
    $unknown = @($Provider.Platforms | Where-Object { $script:PhxPlatforms -notcontains $_ })
    if ($unknown) { throw "provider '$name': unknown platform(s) $($unknown -join ', ')" }
    if (-not $Provider.ContainsKey('Cadence')) { $Provider.Cadence = $null }
    # Same notation as the config's interval: a whole number of minutes, hours or days.
    if ($null -ne $Provider.Cadence -and "$($Provider.Cadence)" -cnotmatch '^[1-9][0-9]*[mhd]$') {
        throw "provider '$name': Cadence '$($Provider.Cadence)' must look like 30m, 1h or 1d"
    }
    if ($script:PhxProviders.Contains($Provider.Name)) { throw "provider '$($Provider.Name)' is registered twice" }
    $script:PhxProviders[$Provider.Name] = $Provider
}

function Get-PhxCurrentPlatform {
    if ($script:OnWindows) { return 'Windows' }
    if ($IsMacOS) { return 'macOS' }
    'Linux'
}

function Get-PhxProvider {
    # All providers for this platform, or one by name (also when it does not apply here, so the
    # caller can say why it will not run).
    param([string]$Name)
    if ($Name) { return $script:PhxProviders[$Name] }
    $platform = Get-PhxCurrentPlatform
    $script:PhxProviders.Values | Where-Object { $_.Platforms -contains $platform }
}
