# Provider registry (docs/design.md -> Provider contract). Each file in Providers/ calls
# Register-PhxProvider once at import; the dispatcher only ever talks to providers through here.

$script:PhxProviders = [ordered]@{}
$script:PhxPlatforms = @('Windows', 'Linux', 'macOS')

function Register-PhxProvider {
    param([Parameter(Mandatory)][hashtable]$Provider)
    foreach ($key in 'Name', 'Description', 'Backup', 'Restore', 'Status') {
        if (-not $Provider.ContainsKey($key) -or -not $Provider[$key]) { throw "provider is missing '$key'" }
    }
    foreach ($key in 'Backup', 'Restore', 'Status') {
        if ($Provider[$key] -isnot [scriptblock]) { throw "provider '$($Provider.Name)': '$key' must be a scriptblock" }
    }
    if (-not $Provider.ContainsKey('Platforms')) { $Provider.Platforms = $script:PhxPlatforms }
    $unknown = @($Provider.Platforms | Where-Object { $script:PhxPlatforms -notcontains $_ })
    if ($unknown) { throw "provider '$($Provider.Name)': unknown platform(s) $($unknown -join ', ')" }
    if (-not $Provider.ContainsKey('Cadence')) { $Provider.Cadence = $null }
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
