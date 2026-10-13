# What the scheduled task runs (docs/design.md -> Scheduling): one backup run, headless, at
# below-normal priority, from the module in this folder. Exits 0, or 1 when the run failed - for a
# caller that starts it directly. Under conhost --headless the Task Scheduler only sees conhost's
# own exit code, so phx status and phx schedule status read the result from the state instead.
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = [Diagnostics.ProcessPriorityClass]::BelowNormal }
catch { $null = $_ }   # not allowed here: run at the priority given
Import-Module (Join-Path $PSScriptRoot 'PSPhoenix.psd1') -Force
phx run -ErrorAction Continue
exit $(if ($?) { 0 } else { 1 })
