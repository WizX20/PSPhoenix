# Questions to the user. Every question goes through Read-PhxAnswer, so a test replaces this one
# function and drives a whole conversation with scripted answers.

function Read-PhxAnswer {
    # One answer, trimmed; Enter takes the default (shown in brackets).
    param([Parameter(Mandatory)][string]$Prompt, [string]$Default = '')
    $shown = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
    try { $answer = Read-Host $shown }
    catch [System.Management.Automation.PSInvalidOperationException] {
        throw 'this needs an interactive console - run it in a terminal, not with -NonInteractive'
    }
    $answer = "$answer".Trim()
    if ($answer) { $answer } else { $Default }
}
