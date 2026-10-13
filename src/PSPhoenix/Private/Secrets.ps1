# What looks like a credential, and how PSPhoenix keeps it out of snapshots, logs and error
# messages (docs/design.md -> Secrets). One detector, the engine's SecretScanner: tokens by their
# published formats, private keys, credentials in URLs and authorization headers, and values under
# password- or secret-like keys. A finding names the kind, line and column - never the value.

function Get-PhxSecretFinding {
    # The secrets in a text, in order: Kind, Line, Column, Key and Description of each.
    param([AllowEmptyString()][string]$Text)
    [PSPhoenix.Engine.SecretScanner]::Scan($Text)
}

function Test-PhxSecretText {
    # True when text holds a secret.
    param([AllowEmptyString()][string]$Text)
    [PSPhoenix.Engine.SecretScanner]::Scan($Text).Count -gt 0
}

function Test-PhxTokenLike {
    # A user name that is itself a credential: a token with a known prefix, or a long opaque string
    # such as an Azure DevOps PAT.
    param([string]$Text)
    [PSPhoenix.Engine.SecretScanner]::IsTokenLike($Text)
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
    # Text for a log line or an error message: every secret in it masked as ***, a password in a URL
    # after its user name (user:***@).
    param([AllowEmptyString()][string]$Text)
    [PSPhoenix.Engine.SecretScanner]::Mask($Text)
}

function Get-PhxCredentialSecret {
    # Why a repo-local credential setting must not be recorded, or nothing: a secret in its value,
    # a token as its user name, or credentials in the URL its key is scoped to
    # (credential.https://user:token@host.helper).
    param([Parameter(Mandatory)][string]$Key, [AllowEmptyString()][AllowNull()][string]$Value)
    if ($Key -match '^credential\.(?<url>.+)\.[^.]+$' -and (Remove-PhxUrlSecret $Matches.url) -cne $Matches.url) { return 'carries credentials in its URL' }
    if ($Key -match '\.username$' -and (Test-PhxTokenLike "$Value")) { return 'has a token as its user name' }
    $finding = @(Get-PhxSecretFinding "$Value")[0]
    if ($finding) { return "holds $($finding.Description)" }
}
