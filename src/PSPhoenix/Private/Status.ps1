# phx status (docs/design.md -> Commands): what PSPhoenix knows about this machine and what needs
# attention. Reads only - the config, the last scan, `gh auth status` - and never fails: a problem
# is a warning line, counted at the end.

function Format-PhxAge {
    # "just now", "25 minutes ago", "3 hours ago", "2 days ago".
    param([Parameter(Mandatory)][datetime]$Since)
    $age = [DateTime]::UtcNow - $Since.ToUniversalTime()
    if ($age.TotalMinutes -lt 1) { return 'just now' }
    if ($age.TotalHours -lt 1) { return '{0} minutes ago' -f [int][Math]::Floor($age.TotalMinutes) }
    if ($age.TotalDays -lt 2) { return '{0} hours ago' -f [int][Math]::Floor($age.TotalHours) }
    '{0} days ago' -f [int][Math]::Floor($age.TotalDays)
}

function Get-PhxNeededAccount {
    # The accounts the scanned repositories need, per host: { Host, Login, Count }.
    param([object[]]$Records = @(), [System.Collections.IDictionary]$Accounts = @{})
    $Records | Where-Object { $_.identity -notmatch '^(local|file)/' } | ForEach-Object {
        $login = Get-PhxRepoAccount -Record $_ -Accounts $Accounts
        if ($login) { [pscustomobject]@{ Host = $_.identity.Split('/')[0]; Login = $login } }
    } | Group-Object Host, Login | ForEach-Object {
        [pscustomobject]@{ Host = $_.Group[0].Host; Login = $_.Group[0].Login; Count = $_.Count }
    }
}

function Show-PhxStatus {
    $configPath = Get-PhxConfigPath
    Write-Host "PSPhoenix $(Get-PhxVersion)"
    if (-not [IO.File]::Exists($configPath)) {
        Write-Host 'not set up yet - run: phx init' -ForegroundColor Yellow
        return
    }
    $config = Read-PhxConfig
    $warnings = [Collections.Generic.List[string]]::new()
    $line = { param($Label, $Text, [switch]$Warn)
        $text = '  {0,-10} {1}' -f $Label, $Text
        if ($Warn) { Write-Host $text -ForegroundColor Yellow; $warnings.Add($Label) } else { Write-Host $text }
    }

    & $line 'config' "$configPath (format $($config.version))"
    if (-not $config.target -or -not $config.target.path) { & $line 'target' 'not set - phx init' -Warn }
    elseif (-not [IO.Directory]::Exists($config.target.path)) { & $line 'target' "$($config.target.path) - folder not found (a disconnected drive? phx init changes it)" -Warn }
    else { & $line 'target' $config.target.path }
    & $line 'interval' "$($config.interval) - the background run arrives with M2 (phx schedule)"

    $roots = @($config.roots | Where-Object { $_ })
    $cache = Read-PhxRepoCache
    if (-not $roots) { & $line 'roots' 'none - phx roots add <path>, or phx init' -Warn }
    foreach ($root in $roots) {
        $count = if ($cache) { "$(@(@($cache.repositories) | Where-Object { [string]::Equals($_.root, $root.path, (Get-PhxPathComparison)) }).Count) repositories" } else { 'not scanned' }
        $missing = -not [IO.Directory]::Exists($root.path)
        & $line 'root' "$($root.path)   depth $($root.depth)   $(if ($missing) { 'folder not found' } else { $count })" -Warn:$missing
    }
    if (-not $cache) { & $line 'scan' 'not scanned yet - phx scan' -Warn }
    else {
        # ConvertFrom-Json already turns the ISO timestamp into a DateTime; parse only if it did not.
        $scanned = $cache.scannedAt
        if ($scanned -isnot [datetime]) { $scanned = [datetime]::Parse("$scanned", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
        & $line 'scan' "$(Format-PhxAge $scanned) - phx scan refreshes it"
    }

    # Each provider says what it knows.
    $context = New-PhxContext -Provider 'status' -Config $config
    foreach ($provider in @(Get-PhxProvider)) {
        $lines = @(try { & $provider.Status $context } catch { "status failed: $($_.Exception.Message)" })
        for ($i = 0; $i -lt $lines.Count; $i++) { & $line $(if ($i) { '' } else { $provider.Name }) $lines[$i] }
    }

    # Restore stops when gh lacks an account a repository needs - better to know now.
    if ($cache) {
        $needed = @(Get-PhxNeededAccount -Records @($cache.repositories) -Accounts $config.accounts)
        if ($needed) {
            $logins = @(Get-PhxGhAccount)
            foreach ($need in $needed) {
                $known = @($logins | Where-Object { $_.Host -eq $need.Host -and $_.Login -eq $need.Login }).Count
                if ($known) { & $line 'account' "$($need.Login) on $($need.Host) ($($need.Count) repositories) - logged in to gh" }
                else { & $line 'account' "$($need.Login) on $($need.Host) ($($need.Count) repositories) - not logged in to gh: gh auth login --hostname $($need.Host)" -Warn }
            }
        }
    }

    & $line 'last run' 'arrives with M2 (phx run)'
    & $line 'review' 'gitignored files to decide on - arrives with M3 (phx review)'
    & $line 'wip' 'local-only work - arrives with M4'
    if ($warnings.Count) { Write-Host "$($warnings.Count) thing(s) need attention" -ForegroundColor Yellow }
    else { Write-Host 'nothing needs attention' -ForegroundColor Green }
}
