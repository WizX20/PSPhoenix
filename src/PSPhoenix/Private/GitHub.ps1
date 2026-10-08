# The GitHub CLI, behind two thin wrappers the tests replace (docs/design.md -> GitHub accounts).
# Tokens are read per call and handed to one child process through GH_TOKEN; never written down,
# never logged, never `gh auth switch`.

function Get-PhxGhAccount {
    # The accounts `gh` is logged in with: { host, login, active }. Nothing when gh is missing or
    # reports nothing usable - callers then treat every account as missing.
    try {
        $json = & gh auth status --json hosts 2>$null
        $status = ($json -join "`n") | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    catch { return }   # gh not installed, or output this version cannot read
    if ($status -isnot [System.Collections.IDictionary] -or $status.hosts -isnot [System.Collections.IDictionary]) { return }
    foreach ($hostName in @($status.hosts.Keys)) {
        foreach ($entry in @($status.hosts[$hostName])) {
            if ($entry.login -and $entry.state -eq 'success') {
                [pscustomobject]@{ Host = $hostName; Login = $entry.login; Active = [bool]$entry.active }
            }
        }
    }
}

function Get-PhxGhToken {
    # One account's token, for one child process. Throws with the login to run when gh has none.
    param([Parameter(Mandatory)][string]$Account, [string]$HostName = 'github.com')
    $token = & gh auth token --hostname $HostName --user $Account 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $token) { throw "gh has no token for $Account on $HostName - run: gh auth login --hostname $HostName (as $Account)" }
    "$token".Trim()
}
