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
    if ($null -ne $Provider.Cadence -and -not (ConvertTo-PhxTimeSpan "$($Provider.Cadence)")) {
        throw "provider '$name': Cadence '$($Provider.Cadence)' must look like 30m, 1h or 1d"
    }
    if ($script:PhxProviders.Contains($Provider.Name)) { throw "provider '$($Provider.Name)' is registered twice" }
    $script:PhxProviders[$Provider.Name] = $Provider
}

function Get-PhxProviderCadence {
    # How often a provider runs at most: the config's providers.<name>.cadence, else its own;
    # nothing means every run.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Provider, [System.Collections.IDictionary]$Config)
    $override = if ($Config -and $Config.providers -and $Config.providers[$Provider.Name] -is [System.Collections.IDictionary]) { $Config.providers[$Provider.Name].cadence }
    $cadence = if ($override) { $override } else { $Provider.Cadence }
    if ($cadence) { ConvertTo-PhxTimeSpan "$cadence" }
}

function Test-PhxDue {
    # True when $Every has passed since $Last - or $Last is unknown. A little early counts: a
    # scheduled run never starts on the second, and a provider due every hour that misses its hour
    # by three seconds must not wait for the next one. The slack is a tenth of the interval, at
    # most five minutes.
    param($Last, $Every, [datetime]$Now = [DateTime]::UtcNow)
    if ($Every -isnot [TimeSpan] -or $Every -le [TimeSpan]::Zero) { return $true }
    $when = ConvertTo-PhxDateTime $Last
    if (-not $when) { return $true }
    $slack = [TimeSpan]::FromTicks([Math]::Min($Every.Ticks / 10, [TimeSpan]::FromMinutes(5).Ticks))
    ($Now.ToUniversalTime() - $when) -ge ($Every - $slack)
}

function Test-PhxProviderDue {
    # Whether a run should run this provider now: its cadence has passed since it last ran.
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Provider,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [System.Collections.IDictionary]$Config,
        [datetime]$Now = [DateTime]::UtcNow
    )
    $last = if ($State.providers[$Provider.Name] -is [System.Collections.IDictionary]) { $State.providers[$Provider.Name].lastRun }
    Test-PhxDue -Last $last -Every (Get-PhxProviderCadence -Provider $Provider -Config $Config) -Now $Now
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
