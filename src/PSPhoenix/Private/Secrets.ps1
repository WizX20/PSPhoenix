# What looks like a credential, and how PSPhoenix keeps it out of snapshots, logs and error
# messages (docs/design.md -> Secrets). Recognised by form: known token prefixes, `password=`, and
# credentials inside a URL. #45 extends this to every file a provider stages.

# Tokens by their published prefixes: GitHub (classic and fine-grained), GitLab, Slack, AWS keys.
$script:PhxTokenPattern = '\b(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16})'

function Test-PhxSecretText {
    # True when text holds a secret written out: a token with a known prefix, or `password=`.
    param([AllowEmptyString()][string]$Text)
    $Text -match $script:PhxTokenPattern -or $Text -match '(?i)\bpassw(or)?d\s*='
}

function Test-PhxTokenLike {
    # A user name that is itself a credential: a GitHub, GitLab or Slack token, or a long opaque
    # string such as an Azure DevOps PAT.
    param([string]$Text)
    $Text -match '^(gh[pousr]_|github_pat_|glpat-|xox[abprs]-)' -or ($Text.Length -ge 32 -and $Text -match '^[A-Za-z0-9_-]+$')
}

function Remove-PhxUrlSecret {
    # A remote URL as PSPhoenix may record it: the password of `user:password@` is dropped, and so is
    # a user name that is itself a token. Snapshots and logs never carry a credential.
    param([AllowEmptyString()][string]$Url)
    if ($Url -match '^(?<scheme>[A-Za-z][A-Za-z0-9+.-]*://)(?<user>[^/@:]*)(?::[^/@]*)?@(?<rest>.*)$') {
        $user = if (Test-PhxTokenLike $Matches.user) { '' } else { $Matches.user }
        return $Matches.scheme + $(if ($user) { "$user@" } else { '' }) + $Matches.rest
    }
    $Url
}

function Hide-PhxSecret {
    # Text for a log line or an error message: credentials in any URL inside it masked, and any
    # token with a known prefix.
    param([AllowEmptyString()][string]$Text)
    $Text = [regex]::Replace($Text, $script:PhxTokenPattern, '***')
    $Text = [regex]::Replace($Text, '(?<=://)(?<user>[^/@:\s]*):[^/@\s]*@', { "$($args[0].Groups['user'].Value):***@" })
    [regex]::Replace($Text, '(?<=://)(?<user>[^/@:\s]+)@', { if (Test-PhxTokenLike $args[0].Groups['user'].Value) { '***@' } else { $args[0].Value } })
}

function Get-PhxCredentialSecret {
    # Why a repo-local credential setting must not be recorded, or nothing: a secret in its value,
    # a token as its user name, or credentials in the URL its key is scoped to
    # (credential.https://user:token@host.helper).
    param([Parameter(Mandatory)][string]$Key, [AllowEmptyString()][AllowNull()][string]$Value)
    if ($Key -match '^credential\.(?<url>.+)\.[^.]+$' -and (Remove-PhxUrlSecret $Matches.url) -cne $Matches.url) { return 'carries credentials in its URL' }
    if ($Key -match '\.username$' -and (Test-PhxTokenLike "$Value")) { return 'has a token as its user name' }
    if (Test-PhxSecretText "$Value") { return 'holds a secret' }
}
