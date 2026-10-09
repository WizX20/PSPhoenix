# The GitHub CLI (docs/design.md -> GitHub accounts). Every call goes through Invoke-PhxGh, the one
# seam tests replace - so they need no gh installed and never reach the real one. Tokens are read
# per call and handed to one child process through GH_TOKEN; never written down, never logged,
# never `gh auth switch`.

function Invoke-PhxGh {
    # gh with these arguments; stdout as lines, stderr dropped. $LASTEXITCODE is gh's. Throws
    # CommandNotFoundException when gh is not installed.
    param([Parameter(Mandatory)][string[]]$Arguments)
    & gh @Arguments 2>$null
}

function Get-PhxGhAccount {
    # The accounts gh is logged in with: { Host, Login, Active, Verified }. Verified is false when
    # gh could not reach the host to check the token (offline) - still logged in, the token still
    # there. An account whose token gh found invalid is left out. Nothing when gh is missing or
    # reports nothing usable - callers then treat every account as missing.
    try {
        $json = Invoke-PhxGh -Arguments 'auth', 'status', '--json', 'hosts'
        $status = ($json -join "`n") | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    catch { return }   # gh not installed, or output this version cannot read
    if ($status -isnot [System.Collections.IDictionary] -or $status.hosts -isnot [System.Collections.IDictionary]) { return }
    foreach ($hostName in @($status.hosts.Keys)) {
        foreach ($entry in @($status.hosts[$hostName])) {
            if ($entry.login -and $entry.state -in 'success', 'timeout') {
                [pscustomobject]@{ Host = $hostName; Login = $entry.login; Active = [bool]$entry.active; Verified = $entry.state -eq 'success' }
            }
        }
    }
}

function Get-PhxGhToken {
    # One account's token, for one child process. Throws with the login to run when gh has none.
    param([Parameter(Mandatory)][string]$Account, [string]$HostName = 'github.com')
    $failure = "gh has no token for $Account on $HostName - run: gh auth login --hostname $HostName (as $Account)"
    try { $token = Invoke-PhxGh -Arguments 'auth', 'token', '--hostname', $HostName, '--user', $Account }
    catch [System.Management.Automation.CommandNotFoundException] { throw "gh is not installed - $failure" }
    if ($LASTEXITCODE -ne 0 -or -not $token) { throw $failure }
    "$token".Trim()
}
