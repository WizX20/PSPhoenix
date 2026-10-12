# phx schedule (docs/design.md -> Scheduling): the per-user Task Scheduler task \PSPhoenix\Backup
# that runs phx-task.ps1 every interval and at logon. Windows only for now (Linux and macOS: #5).
#
# The Task Scheduler cmdlets sit behind four thin wrappers that speak plain objects - the only
# code here that touches the real Task Scheduler, and what the tests replace. Everything else
# (what the task should be, whether the registered one still matches) is plain PowerShell.

$script:PhxTaskPath = '\PSPhoenix\'
$script:PhxTaskName = 'Backup'

function Test-PhxCanSchedule { [bool]$script:OnWindows }

function Get-PhxStableModulePath {
    # The module folder the task should name: one an update leaves in place. Imported through
    # Scoop's modules folder it already is one (a junction to apps\psphoenix\current); imported
    # from apps\psphoenix\<version>\ itself, a task naming that folder breaks with the first update
    # or `scoop cleanup` - so current, next to it, is named instead.
    param([string]$ModuleBase = (Get-Module PSPhoenix).ModuleBase, [string]$Version = "$(Get-PhxVersion)")
    if ((Split-Path $ModuleBase -Leaf) -eq $Version) {
        $current = Join-Path (Split-Path $ModuleBase -Parent) 'current'
        if ([IO.Directory]::Exists($current)) { return $current }
    }
    $ModuleBase
}

function New-PhxTaskDefinition {
    # What the scheduled task should be, as a plain object: the action - conhost --headless, so no
    # console window flashes up each run - and the triggers and settings of docs/design.md.
    param(
        [Parameter(Mandatory)][TimeSpan]$Interval,
        [string]$ModulePath = (Get-PhxStableModulePath),
        [string]$Pwsh = (Get-Process -Id $PID).Path
    )
    $task = Join-Path $ModulePath 'phx-task.ps1'
    [pscustomobject]@{
        Execute          = 'conhost.exe'
        Arguments        = "--headless `"$Pwsh`" -NoProfile -NonInteractive -File `"$task`""
        Pwsh             = $Pwsh
        Script           = $task
        Interval         = $Interval
        LogonDelay       = [TimeSpan]::FromMinutes(5)
        ExecutionLimit   = [TimeSpan]::FromMinutes(15)
        Priority         = 7
        Description      = 'PSPhoenix: back up what this machine would lose in a crash (phx schedule off removes this task)'
    }
}

function Register-PhxScheduledTask {
    # Registers (or replaces) \PSPhoenix\Backup from a definition. Touches the real Task Scheduler.
    param([Parameter(Mandatory)]$Definition)
    $action = New-ScheduledTaskAction -Execute $Definition.Execute -Argument $Definition.Arguments
    $every = New-ScheduledTaskTrigger -Once -At ([DateTime]::Now.AddMinutes(1)) -RepetitionInterval $Definition.Interval
    $logon = New-ScheduledTaskTrigger -AtLogOn -User ([Environment]::UserDomainName + '\' + [Environment]::UserName)
    $logon.Delay = [System.Xml.XmlConvert]::ToString($Definition.LogonDelay)
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit $Definition.ExecutionLimit `
        -Priority $Definition.Priority -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $principal = New-ScheduledTaskPrincipal -UserId ([Environment]::UserDomainName + '\' + [Environment]::UserName) -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskPath $script:PhxTaskPath -TaskName $script:PhxTaskName -Action $action -Trigger $every, $logon `
        -Settings $settings -Principal $principal -Description $Definition.Description -Force | Out-Null
}

function Unregister-PhxScheduledTask {
    # Removes \PSPhoenix\Backup. Touches the real Task Scheduler.
    Unregister-ScheduledTask -TaskPath $script:PhxTaskPath -TaskName $script:PhxTaskName -Confirm:$false
}

function Get-PhxScheduledTask {
    # \PSPhoenix\Backup as a plain object - { Arguments, Interval, LastRunTime, LastResult,
    # NextRunTime } - or nothing when it is not registered. Reads the real Task Scheduler.
    $task = Get-ScheduledTask -TaskPath $script:PhxTaskPath -TaskName $script:PhxTaskName -ErrorAction SilentlyContinue
    if (-not $task) { return }
    $info = $task | Get-ScheduledTaskInfo
    $repetition = @($task.Triggers | Where-Object { $_.Repetition.Interval })[0].Repetition.Interval
    [pscustomobject]@{
        Arguments   = @($task.Actions)[0].Arguments
        Interval    = if ($repetition) { [System.Xml.XmlConvert]::ToTimeSpan($repetition) }
        LastRunTime = $info.LastRunTime
        LastResult  = $info.LastTaskResult
        NextRunTime = $info.NextRunTime
    }
}

function Get-PhxScheduleProblem {
    # What is wrong with the registered task, as lines, nothing when it is fine: a module or
    # PowerShell it names that is gone, another module than this one, an interval other than the
    # config's.
    param([Parameter(Mandatory)]$Task, [Parameter(Mandatory)][System.Collections.IDictionary]$Config)
    $wanted = New-PhxTaskDefinition -Interval (ConvertTo-PhxTimeSpan "$($Config.interval)")
    if ($Task.Arguments -match '--headless "(?<pwsh>[^"]+)" .* -File "(?<script>[^"]+)"') {
        if (-not [IO.File]::Exists($Matches.pwsh)) { "it starts $($Matches.pwsh), which is gone - phx schedule on" }
        if (-not [IO.File]::Exists($Matches.script)) { "it runs $($Matches.script), which is gone - phx schedule on" }
        elseif (-not [string]::Equals($Matches.script, $wanted.Script, (Get-PhxPathComparison))) { "it runs $($Matches.script), not this PSPhoenix ($($wanted.Script)) - phx schedule on" }
    }
    else { 'its action is not the one phx schedule on sets - phx schedule on' }
    if ($Task.Interval -ne $wanted.Interval) { "it runs every $(Format-PhxSpan $Task.Interval), the config says $($Config.interval) - phx schedule on" }
}

function Format-PhxSpan {
    # A TimeSpan as PSPhoenix writes durations: 30m, 2h, 1d.
    param([TimeSpan]$Span)
    if ($Span.TotalDays -ge 1 -and $Span.TotalDays -eq [Math]::Floor($Span.TotalDays)) { return "$([int]$Span.TotalDays)d" }
    if ($Span.TotalHours -ge 1 -and $Span.TotalHours -eq [Math]::Floor($Span.TotalHours)) { return "$([int]$Span.TotalHours)h" }
    "$([int]$Span.TotalMinutes)m"
}

function Get-PhxScheduleLine {
    # The schedule for phx status: { Text, Warn }.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
    if (-not (Test-PhxCanSchedule)) { return [pscustomobject]@{ Text = "not on $(Get-PhxCurrentPlatform) yet (#5) - run phx run yourself, or from cron or a systemd timer"; Warn = $false } }
    $task = Get-PhxScheduledTask
    if (-not $task) { return [pscustomobject]@{ Text = 'off - nothing backs up in the background: phx schedule on'; Warn = $true } }
    $problems = @(Get-PhxScheduleProblem -Task $task -Config $Config)
    if ($problems) { return [pscustomobject]@{ Text = "on, but $($problems[0])"; Warn = $true } }
    $next = if ($task.NextRunTime) { "next $($task.NextRunTime.ToString('yyyy-MM-dd HH:mm'))" } else { 'no next run planned' }
    [pscustomobject]@{ Text = "on, every $(Format-PhxSpan $task.Interval) and at logon - $next"; Warn = $false }
}

function Enable-PhxSchedule {
    # phx schedule on [-Every <duration>]: (re-)registers the task; -Every first changes the
    # interval in the config.
    param([string]$Every)
    if (-not (Test-PhxCanSchedule)) { throw "phx schedule runs on Windows for now - on $(Get-PhxCurrentPlatform), run phx run from cron or a systemd timer (#5)" }
    if (-not [IO.File]::Exists((Get-PhxConfigPath))) { throw 'not set up yet - run: phx init' }
    $config = Read-PhxConfig
    if ($Every) {
        if (-not (Test-PhxInterval $Every)) { throw "-Every $Every - give 15m to 31d, like 30m, 1h or 1d" }
        $config.interval = $Every
        Save-PhxConfig $config
    }
    $definition = New-PhxTaskDefinition -Interval (ConvertTo-PhxTimeSpan "$($config.interval)")
    Register-PhxScheduledTask -Definition $definition
    Write-Host "scheduled: every $($config.interval) and 5 minutes after logon - task $($script:PhxTaskPath)$($script:PhxTaskName)" -ForegroundColor Green
    Write-Host "  it runs $($definition.Script); phx status shows the last run" -ForegroundColor DarkGray
}

function Disable-PhxSchedule {
    if (-not (Test-PhxCanSchedule)) { throw "phx schedule runs on Windows for now (#5)" }
    if (-not (Get-PhxScheduledTask)) { Write-Host 'not scheduled - nothing to turn off' -ForegroundColor DarkGray; return }
    Unregister-PhxScheduledTask
    Write-Host "turned off: task $($script:PhxTaskPath)$($script:PhxTaskName) removed - phx run still backs up by hand" -ForegroundColor Green
}

function Show-PhxSchedule {
    if (-not (Test-PhxCanSchedule)) { throw "phx schedule runs on Windows for now (#5)" }
    $task = Get-PhxScheduledTask
    if (-not $task) { Write-Host 'not scheduled - phx schedule on' -ForegroundColor Yellow; return }
    $config = Read-PhxConfig
    Write-Host "task      $($script:PhxTaskPath)$($script:PhxTaskName), every $(Format-PhxSpan $task.Interval) and at logon"
    $last = if (-not $task.LastRunTime -or $task.LastRunTime.Year -lt 2000) { 'never yet' }
    elseif ($task.LastResult -eq 0) { "$($task.LastRunTime.ToString('yyyy-MM-dd HH:mm')), fine" }
    else { "$($task.LastRunTime.ToString('yyyy-MM-dd HH:mm')), failed (result $($task.LastResult)) - its log: phx status" }
    Write-Host "last run  $last"
    if ($task.NextRunTime) { Write-Host "next run  $($task.NextRunTime.ToString('yyyy-MM-dd HH:mm'))" }
    foreach ($problem in @(Get-PhxScheduleProblem -Task $task -Config $config)) { Write-Host "warning   $problem" -ForegroundColor Yellow }
}

function Invoke-PhxScheduleCommand {
    # phx schedule on|off|status [-Every <duration>]; -Every alone means on.
    param([string]$Action, [string]$Every)
    if (-not $Action) { $Action = if ($Every) { 'on' } else { 'status' } }
    switch ($Action) {
        'on' { Enable-PhxSchedule -Every $Every }
        'off' { Disable-PhxSchedule }
        'status' { Show-PhxSchedule }
        default { throw "unknown action '$Action' - phx schedule on|off|status [-Every 30m|1h|1d]" }
    }
}
