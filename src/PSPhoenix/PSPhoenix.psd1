@{
    RootModule        = 'PSPhoenix.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '1bb730fc-8f34-4dcb-9793-8b8e23d58251'
    Author            = 'WizX20'
    CompanyName       = 'WizX20'
    Copyright         = '(c) 2026 WizX20. Business Source License 1.1.'
    Description       = 'phx - back up what a developer machine would lose in a crash (repository inventory, local-only git work, gitignored local files, Claude Code memory, machine setup) and rebuild a new machine from it.'
    PowerShellVersion = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport = @('phx')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('backup', 'restore', 'git', 'claude-code', 'winget', 'scoop', 'windows', 'cli')
            LicenseUri = 'https://github.com/WizX20/PSPhoenix/blob/main/LICENSE'
            ProjectUri = 'https://github.com/WizX20/PSPhoenix'
            ReleaseNotes = 'https://github.com/WizX20/PSPhoenix/blob/main/CHANGELOG.md'
        }
    }
}
