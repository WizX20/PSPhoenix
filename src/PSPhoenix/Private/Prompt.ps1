# Questions to the user. Every question goes through Read-PhxAnswer, so a test replaces this one
# function and drives a whole conversation with scripted answers.

function Read-PhxAnswer {
    # One answer, trimmed; Enter takes the default (shown in brackets). The end of input (stdin
    # redirected from a file that ran out) cancels: Read-Host then returns nothing on every call,
    # which would otherwise loop on a question or take every default unasked.
    param([Parameter(Mandatory)][string]$Prompt, [string]$Default = '')
    $shown = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
    try { $answer = Read-Host $shown }
    catch [System.Management.Automation.PSInvalidOperationException] {
        throw 'this needs an interactive console - run it in a terminal, not with -NonInteractive'
    }
    if ($null -eq $answer) { throw [OperationCanceledException]::new('input ended') }
    $answer = $answer.Trim()
    if ($answer) { $answer } else { $Default }
}

function Show-PhxSecretLine {
    # A line that holds a secret - a new age key: straight to the console, past PowerShell's
    # streams, so a transcript (Start-Transcript, or one a group policy turns on) does not record it.
    # Tests replace this one as well.
    param([Parameter(Mandatory)][string]$Text)
    [Console]::Out.WriteLine($Text)
}

function Read-PhxSecretAnswer {
    # A secret answer - a passphrase: not echoed, not trimmed. Tests replace this one too.
    param([Parameter(Mandatory)][string]$Prompt)
    try { $secure = Read-Host $Prompt -AsSecureString }
    catch [System.Management.Automation.PSInvalidOperationException] {
        throw 'this needs an interactive console - run it in a terminal, not with -NonInteractive'
    }
    if ($null -eq $secure) { throw [OperationCanceledException]::new('input ended') }
    [Net.NetworkCredential]::new('', $secure).Password
}
