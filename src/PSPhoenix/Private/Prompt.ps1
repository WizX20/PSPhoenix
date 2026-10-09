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
