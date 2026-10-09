# Pester 5+ suite for the PSPhoenix module. Nothing here may touch the real machine: config and
# state paths are redirected into $TestDrive through the environment variables they derive from,
# and later providers get the same treatment (a fake home per test, never ~/.claude, the registry
# or Task Scheduler). `phx` prints through Write-Host, so output is captured with 6>&1. CI runs
# the suite on Windows and Linux (pwsh), so paths are built with Join-Path and matched with [\\/].

BeforeAll {
    $script:ModulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src/PSPhoenix/PSPhoenix.psd1'
    Import-Module $script:ModulePath -Force

    function script:Get-PhxOutput {
        # Runs the block (a real `phx ...` call line, switches included) and returns everything
        # it printed as one string.
        param([scriptblock]$Call)
        (& $Call 6>&1 | Out-String)
    }

    function script:Use-TestHome {
        # Points every directory PSPhoenix derives its paths from at a fresh folder under
        # $TestDrive. Returns that folder.
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $root | Out-Null
        $env:APPDATA = Join-Path $root 'Roaming'
        $env:LOCALAPPDATA = Join-Path $root 'Local'
        $env:XDG_CONFIG_HOME = Join-Path $root 'config'
        $env:XDG_STATE_HOME = Join-Path $root 'state'
        # No OneDrive either: phx init would offer the real one.
        $env:OneDriveCommercial = $env:OneDriveConsumer = $env:OneDrive = $null
        $root
    }

    function script:New-TestRepository {
        # A throwaway repository with one commit and the given remotes, in order. Returns its path.
        param([Parameter(Mandatory)][string]$Path, [string[]]$Remote = @())
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
        git -c init.defaultBranch=main init -q $Path
        git -C $Path -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m init
        foreach ($entry in $Remote) {
            $name, $url = $entry -split '=', 2
            git -C $Path remote add $name $url
        }
        $Path
    }

    $script:SavedEnv = @{}
    foreach ($name in 'APPDATA', 'LOCALAPPDATA', 'XDG_CONFIG_HOME', 'XDG_STATE_HOME', 'OneDriveCommercial', 'OneDriveConsumer', 'OneDrive',
        'GH_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM', 'GIT_CONFIG_COUNT', 'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0') {
        $script:SavedEnv[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    # git without the developer's global and system config: a global commit.gpgsign, hooksPath or
    # credential helper must neither change what the tests see nor reach real keys or accounts.
    $script:EmptyGitConfig = Join-Path $TestDrive 'gitconfig-empty'
    New-Item -ItemType File -Path $script:EmptyGitConfig -Force | Out-Null
    $env:GIT_CONFIG_GLOBAL = $script:EmptyGitConfig
    $env:GIT_CONFIG_NOSYSTEM = '1'
    # No developer token in the tests, and no test reaches the real gh - Invoke-PhxGh is the one way
    # to it. Get-PhxGhAccount swallows errors, so a leak is also recorded: the last test of this
    # file fails on it.
    $env:GH_TOKEN = $env:GH_ENTERPRISE_TOKEN = $null
    $script:GhLeaks = [Collections.Generic.List[string]]::new()
    Mock Invoke-PhxGh -ModuleName PSPhoenix {
        $script:GhLeaks.Add("gh $($Arguments -join ' ')")
        throw 'a test reached gh - mock Get-PhxGhAccount or Get-PhxGhToken'
    }
    # From here on no test derives anything from the real home - not even a path printed in the
    # help. A test that needs a folder of its own calls Use-TestHome again for its path. (Pester
    # has no root-level BeforeEach.)
    Use-TestHome | Out-Null
}

AfterAll {
    foreach ($name in $script:SavedEnv.Keys) {
        [Environment]::SetEnvironmentVariable($name, $script:SavedEnv[$name])
    }
}

Describe 'module surface' {
    It 'exports exactly one command: phx' {
        $m = Get-Module PSPhoenix
        $m.ExportedFunctions.Keys | Should -Be @('phx')
        $m.ExportedAliases.Count | Should -Be 0
    }

    It 'prints help for no arguments, --help, -h, help and /?' {
        Get-PhxOutput { phx } | Should -Match 'USAGE:'
        Get-PhxOutput { phx --help } | Should -Match 'USAGE:'
        Get-PhxOutput { phx -h } | Should -Match 'USAGE:'
        Get-PhxOutput { phx help } | Should -Match 'USAGE:'
        Get-PhxOutput { phx /? } | Should -Match 'USAGE:'
    }

    It 'help documents every command and flag' {
        $help = Get-PhxOutput { phx --help }
        foreach ($text in 'phx init', 'phx status', 'phx scan', 'phx roots', 'phx run', '-Provider', 'phx schedule',
            '-Every', 'phx review', 'phx restore', '-From', 'phx providers', 'phx version', 'docs/design.md') {
            $help | Should -Match ([regex]::Escape($text))
        }
    }

    It 'help is quoted word for word in the README' {
        # The README quotes `phx help` (task help). Three lines differ per machine or release and
        # are placeholders there: the version, the config path and the module folder.
        $readme = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'README.md') -Raw
        $quoted = [regex]::Match($readme, '(?s)## Help: `phx help`\s*```text\r?\n(.*?)\r?\n```').Groups[1].Value
        $quoted | Should -Not -BeNullOrEmpty
        $normalise = {
            param([string]$Text)
            @($Text.TrimEnd() -split '\r?\n' | ForEach-Object {
                    $_.TrimEnd() -replace '^(phx - PSPhoenix )[^:]+:', '$1<version>:' `
                        -replace '^(  - config: ).*', '$1<config>' `
                        -replace '^(  - module: ).*', '$1<module>'
                }) -join "`n"
        }
        (& $normalise (Get-PhxOutput { phx help })) | Should -Be (& $normalise $quoted)
    }

    It 'help shows the config path' {
        Use-TestHome | Out-Null
        $expected = InModuleScope PSPhoenix { Get-PhxConfigPath }
        Get-PhxOutput { phx help } | Should -Match ([regex]::Escape($expected))
    }

    It 'tab-completes the sub-commands' {
        $c = [System.Management.Automation.CommandCompletion]::CompleteInput('phx re', 6, $null)
        $c.CompletionMatches.CompletionText | Should -Contain 'review'
        $c.CompletionMatches.CompletionText | Should -Contain 'restore'
        $c.CompletionMatches.CompletionText | Should -Not -Contain 'run'
    }

    It 'prints the module version' {
        $version = (Get-Module PSPhoenix).Version.ToString()
        Get-PhxOutput { phx version } | Should -Match ([regex]::Escape("PSPhoenix $version"))
    }

    It 'fails a command that is not built yet, naming its milestone' {
        { phx schedule -ErrorAction Stop } | Should -Throw '*not built yet*M2*'
        { phx restore -ErrorAction Stop } | Should -Throw '*not built yet*M6*'
        phx run -ErrorAction SilentlyContinue
        $? | Should -BeFalse
    }

    It 'every planned command appears in the help with its milestone' {
        $help = Get-PhxOutput { phx --help }
        $planned = InModuleScope PSPhoenix { $script:PhxPlanned }
        foreach ($name in $planned.Keys) {
            $help | Should -Match ("phx $name\b.*\($($planned[$name])\)")
        }
    }

    It 'fails an unknown command' {
        { phx frobnicate -ErrorAction Stop } | Should -Throw "*unknown command 'frobnicate'*"
        phx frobnicate -ErrorAction SilentlyContinue
        $? | Should -BeFalse
    }

    It 'exits with 1 from pwsh -Command on an unknown command, as a scheduled task would see it' {
        Use-TestHome | Out-Null
        $pwsh = (Get-Process -Id $PID).Path
        & $pwsh -NoProfile -NonInteractive -Command "Import-Module '$script:ModulePath'; phx frobnicate" 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 1
        & $pwsh -NoProfile -NonInteractive -Command "Import-Module '$script:ModulePath'; phx version" 6>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
    }

    It 'keeps -P and -E as short forms of -Provider and -Every' {
        $bound = InModuleScope PSPhoenix {
            $cmd = Get-Command phx
            @{ P = $cmd.ResolveParameter('P').Name; E = $cmd.ResolveParameter('E').Name }
        }
        $bound.P | Should -Be 'Provider'
        $bound.E | Should -Be 'Every'
    }
}

Describe 'paths' {
    It 'keeps config and state apart, both under the redirected home' {
        $root = Use-TestHome
        $paths = InModuleScope PSPhoenix { @{ Config = Get-PhxConfigDir; State = Get-PhxStateDir } }
        $paths.Config | Should -Not -Be $paths.State
        $paths.Config.StartsWith($root) | Should -BeTrue
        $paths.State.StartsWith($root) | Should -BeTrue
    }

    It 'uses the platform convention' {
        $root = Use-TestHome
        $paths = InModuleScope PSPhoenix { @{ Config = Get-PhxConfigDir; State = Get-PhxStateDir; OnWindows = $script:OnWindows } }
        if ($paths.OnWindows) {
            $paths.Config | Should -Be (Join-Path $root 'Roaming/PSPhoenix')
            $paths.State | Should -Be (Join-Path $root 'Local/PSPhoenix')
        }
        else {
            $paths.Config | Should -Be (Join-Path $root 'config/psphoenix')
            $paths.State | Should -Be (Join-Path $root 'state/psphoenix')
        }
    }

    It 'falls back to the known folders when APPDATA and LOCALAPPDATA are not set' -Skip:(-not $IsWindows) {
        # Only computes the paths; nothing is read or written there.
        Use-TestHome | Out-Null
        $env:APPDATA = $null
        $env:LOCALAPPDATA = $null
        $paths = InModuleScope PSPhoenix { @{ Config = Get-PhxConfigDir; State = Get-PhxStateDir } }
        $paths.Config | Should -Be (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'PSPhoenix')
        $paths.State | Should -Be (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PSPhoenix')
    }

    It 'uses the XDG defaults under HOME when the variables are unset or relative' -Skip:$IsWindows {
        # Only computes the paths; nothing is read or written there.
        Use-TestHome | Out-Null
        $env:XDG_CONFIG_HOME = $null
        $env:XDG_STATE_HOME = 'relative/state'
        $paths = InModuleScope PSPhoenix { @{ Config = Get-PhxConfigDir; State = Get-PhxStateDir } }
        $paths.Config | Should -Be (Join-Path $HOME '.config/psphoenix')
        $paths.State | Should -Be (Join-Path $HOME '.local/state/psphoenix')
    }
}

Describe 'config' {
    It 'returns the defaults when there is no config yet' {
        Use-TestHome | Out-Null
        $config = InModuleScope PSPhoenix { Read-PhxConfig }
        $config.version | Should -Be 1
        $config.interval | Should -Be '1h'
        @($config.roots).Count | Should -Be 0
        $config.files.maxKB | Should -Be 1024
    }

    It 'round-trips through Save-PhxConfig' {
        Use-TestHome | Out-Null
        # A full path on this platform: C:\Repos is not one on Linux, and a root must be.
        $root = Join-Path $TestDrive 'Repos'
        $config = InModuleScope PSPhoenix -Parameters @{ Root = $root } {
            param($Root)
            $c = Read-PhxConfig
            $c.roots = @(@{ path = $Root; depth = 3 })
            $c.accounts['github.com/WizX20'] = 'WizX20'
            Save-PhxConfig $c
            Read-PhxConfig
        }
        $config.roots[0].path | Should -Be $root
        $config.roots[0].depth | Should -Be 3
        $config.accounts['github.com/WizX20'] | Should -Be 'WizX20'
        $dir = Split-Path (InModuleScope PSPhoenix { Get-PhxConfigPath })
        @(Get-ChildItem -LiteralPath $dir -Force).Name | Should -Be @('config.json')
    }

    It 'overwrites an existing config' {
        Use-TestHome | Out-Null
        $config = InModuleScope PSPhoenix {
            $c = Read-PhxConfig
            Save-PhxConfig $c
            $c.interval = '2h'
            Save-PhxConfig $c
            Read-PhxConfig
        }
        $config.interval | Should -Be '2h'
    }

    It 'refuses a config written by a newer PSPhoenix' {
        Use-TestHome | Out-Null
        InModuleScope PSPhoenix {
            $path = Get-PhxConfigPath
            New-Item -ItemType Directory -Force -Path (Split-Path $path -Parent) | Out-Null
            Set-Content -LiteralPath $path -Value '{ "version": 99 }'
            { Read-PhxConfig } | Should -Throw '*version 99*'
        }
    }

    It 'refuses a config that is <Case>, naming the file' -ForEach @(
        @{ Case = 'empty'; Json = ''; Message = '*is empty*' }
        @{ Case = 'whitespace only'; Json = "  `n "; Message = '*is empty*' }
        @{ Case = 'not JSON'; Json = '{ "version": 1,'; Message = '*is not valid JSON*' }
        @{ Case = 'an array'; Json = '[1, 2]'; Message = '*is not a JSON object*' }
        @{ Case = 'null'; Json = 'null'; Message = '*is not a JSON object*' }
        @{ Case = 'without a version'; Json = '{}'; Message = "*no whole-number 'version'*" }
        @{ Case = 'versioned with a string'; Json = '{ "version": "1" }'; Message = "*no whole-number 'version'*" }
        @{ Case = 'version 0'; Json = '{ "version": 0 }'; Message = '*version 0*' }
        @{ Case = 'newer, spelled Version'; Json = '{ "Version": 99 }'; Message = '*version 99*' }
        @{ Case = 'ambiguous in case'; Json = '{ "version": 1, "interval": "1h", "Interval": "2h" }'; Message = "*duplicate key 'Interval'*" }
    ) {
        Use-TestHome | Out-Null
        InModuleScope PSPhoenix -Parameters @{ Json = $Json; Message = $Message } {
            param($Json, $Message)
            $path = Get-PhxConfigPath
            [IO.Directory]::CreateDirectory((Split-Path $path)) | Out-Null
            [IO.File]::WriteAllText($path, $Json)
            { Read-PhxConfig } | Should -Throw $Message
            { Read-PhxConfig } | Should -Throw "*$path*"
        }
    }

    It 'reads keys in any case, like the defaults' {
        Use-TestHome | Out-Null
        $config = InModuleScope PSPhoenix {
            Save-PhxConfig (New-PhxDefaultConfig)
            Read-PhxConfig
        }
        $config.Files.MaxKB | Should -Be 1024
        $config['INTERVAL'] | Should -Be '1h'
    }

    It 'fills in what an older or hand-written config leaves out' {
        Use-TestHome | Out-Null
        $config = InModuleScope PSPhoenix {
            $path = Get-PhxConfigPath
            [IO.Directory]::CreateDirectory((Split-Path $path)) | Out-Null
            [IO.File]::WriteAllText($path, '{ "Version": 1, "Files": { "MaxKB": 5 }, "providers": { "winget": { "enabled": false } } }')
            Read-PhxConfig
        }
        $config.files.maxKB | Should -Be 5
        $config.files.Contains('repos') | Should -BeTrue
        $config.interval | Should -Be '1h'
        $config.providers.winget.enabled | Should -BeFalse
        # The defaults' spelling and order survive: a save writes 'version', never 'Version'.
        @($config.Keys) | Should -Be @('version', 'roots', 'target', 'machine', 'interval', 'providers', 'accounts', 'secrets', 'files')
    }

    It 'gives a hand-written root without a depth the default, and drops an empty entry' {
        Use-TestHome | Out-Null
        $root = (Join-Path $TestDrive 'hand-written') -replace '\\', '/'
        $roots = InModuleScope PSPhoenix -Parameters @{ Root = $root } {
            param($Root)
            $path = Get-PhxConfigPath
            [IO.Directory]::CreateDirectory((Split-Path $path)) | Out-Null
            [IO.File]::WriteAllText($path, (@{ version = 1; roots = @($null, @{ path = $Root }) } | ConvertTo-Json -Depth 5))
            , @((Read-PhxConfig).roots)
        }
        $roots | Should -HaveCount 1
        $roots[0].depth | Should -Be 3
    }

    It 'refuses a hand-written root <Case>' -ForEach @(
        @{ Case = 'with depth 0'; Root = @{ path = 'FULL'; depth = 0 }; Message = '*has depth 0 - a whole number from 1 to 10*' }
        @{ Case = 'with a relative path'; Root = @{ path = 'Repos'; depth = 3 }; Message = '*root Repos is not a full path*' }
        @{ Case = 'without a path'; Root = @{ depth = 3 }; Message = '*every root needs a path*' }
    ) {
        Use-TestHome | Out-Null
        if ($Root.path -eq 'FULL') { $Root.path = Join-Path $TestDrive 'full' }
        InModuleScope PSPhoenix -Parameters @{ Root = $Root } {
            param($Root)
            $path = Get-PhxConfigPath
            [IO.Directory]::CreateDirectory((Split-Path $path)) | Out-Null
            [IO.File]::WriteAllText($path, (@{ version = 1; roots = @($Root) } | ConvertTo-Json -Depth 5))
        }
        { InModuleScope PSPhoenix { Read-PhxConfig } } | Should -Throw $Message
    }
}

Describe 'roots' {
    BeforeEach {
        $testHome = Use-TestHome
        $repos = Join-Path $testHome 'Repos'
        New-Item -ItemType Directory -Path (Join-Path $repos 'App') -Force | Out-Null
    }

    It 'adds a root as a full path with the default depth, and lists it' {
        Get-PhxOutput { phx roots add $repos } | Should -Match 'added root'
        $roots = @(InModuleScope PSPhoenix { Get-PhxRoot })
        $roots.Count | Should -Be 1
        $roots[0].path | Should -Be $repos
        $roots[0].depth | Should -Be 3
        Get-PhxOutput { phx roots list } | Should -Match ([regex]::Escape($repos) + '\s+depth 3')
        Get-PhxOutput { phx roots } | Should -Match 'depth 3'
    }

    It 'changes the depth of an existing root with -Depth' {
        phx roots add $repos 6>$null
        Get-PhxOutput { phx roots add $repos -Depth 6 } | Should -Match 'now has depth 6'
        $roots = @(InModuleScope PSPhoenix { Get-PhxRoot })
        $roots.Count | Should -Be 1
        $roots[0].depth | Should -Be 6
    }

    It "stops a caller's script on a failure when the caller asks for Stop" {
        # A script's $ErrorActionPreference = 'Stop' must reach phx's own errors.
        $pwsh = (Get-Process -Id $PID).Path
        $script = "`$ErrorActionPreference = 'Stop'; Import-Module '$script:ModulePath'; try { phx roots add '$(Join-Path $testHome 'nope')' 6>`$null; 'carried on' } catch { 'stopped' }"
        & $pwsh -NoProfile -NonInteractive -Command $script | Should -Be 'stopped'
    }

    It 'stores -Depth' {
        phx roots add $repos -Depth 5 6>$null
        @(InModuleScope PSPhoenix { Get-PhxRoot })[0].depth | Should -Be 5
    }

    It 'refuses a depth outside 1-10' {
        { phx roots add $repos -Depth 11 6>$null } | Should -Throw '*Depth*'
        { phx roots add $repos -Depth 0 6>$null } | Should -Throw '*Depth*'
    }

    It 'stores a relative path with a trailing separator as a clean full path' {
        Push-Location $testHome
        try { phx roots add ('Repos' + [IO.Path]::DirectorySeparatorChar) 6>$null }
        finally { Pop-Location }
        @(InModuleScope PSPhoenix { Get-PhxRoot })[0].path | Should -Be $repos
    }

    It 'refuses <Case>' -ForEach @(
        @{ Case = 'the same root twice'; Second = { $repos }; Message = '*is a root already*' }
        @{ Case = 'a root inside a root'; Second = { Join-Path $repos 'App' }; Message = '*lies inside the root*' }
        @{ Case = 'a root around a root'; Second = { $testHome }; Message = '*contains the root*' }
        @{ Case = 'a folder that does not exist'; Second = { Join-Path $testHome 'nope' }; Message = '*no such folder*' }
    ) {
        if ($Case -ne 'a folder that does not exist') { phx roots add $repos 6>$null }
        $path = & $Second
        { phx roots add $path -ErrorAction Stop 6>$null } | Should -Throw $Message
    }

    It 'treats the same path in another case as the same root on Windows' -Skip:(-not $IsWindows) {
        phx roots add $repos 6>$null
        { phx roots add $repos.ToUpperInvariant() -ErrorAction Stop 6>$null } | Should -Throw '*is a root already*'
    }

    It 'stores a path typed in another case as the folder spells it, on Windows' -Skip:(-not $IsWindows) {
        phx roots add $repos.ToLowerInvariant() 6>$null
        @(InModuleScope PSPhoenix { Get-PhxRoot })[0].path | Should -BeExactly $repos
    }

    It 'does not take a sibling with a longer name for a root inside it' {
        $sibling = "$repos" + '2'
        New-Item -ItemType Directory -Path $sibling | Out-Null
        phx roots add $repos 6>$null
        phx roots add $sibling 6>$null
        @(InModuleScope PSPhoenix { Get-PhxRoot }).Count | Should -Be 2
    }

    It 'removes a root, also one whose folder is gone' {
        phx roots add $repos 6>$null
        Remove-Item -LiteralPath $repos -Recurse -Force
        Get-PhxOutput { phx roots list } | Should -Match 'folder not found'
        Get-PhxOutput { phx roots rm $repos } | Should -Match 'removed root'
        @(InModuleScope PSPhoenix { Get-PhxRoot }).Count | Should -Be 0
    }

    It 'accepts remove for rm' {
        phx roots add $repos 6>$null
        phx roots remove $repos 6>$null
        @(InModuleScope PSPhoenix { Get-PhxRoot }).Count | Should -Be 0
    }

    It 'says how to start when there are no roots' {
        Get-PhxOutput { phx roots list } | Should -Match 'no roots yet.*phx roots add'
    }

    It 'fails <Case> as an error of phx' -ForEach @(
        @{ Case = 'removing a path that is not a root'; Arguments = { 'roots', 'rm', $repos }; Message = '*is not a root*' }
        @{ Case = 'add without a path'; Arguments = { 'roots', 'add' }; Message = '*usage: phx roots add*' }
        @{ Case = 'rm without a path'; Arguments = { 'roots', 'rm' }; Message = '*usage: phx roots rm*' }
        @{ Case = 'an unknown action'; Arguments = { 'roots', 'frob' }; Message = "*unknown action 'frob'*" }
    ) {
        # Positional values only, so splatting binds them as phx <command> <arg> <arg2>.
        $arguments = @(& $Arguments)
        phx @arguments -ErrorAction SilentlyContinue -ErrorVariable failure 6>$null
        $? | Should -BeFalse
        # -ErrorVariable also collects the throw that phx caught; the record callers see is phx's own.
        $record = $failure | Where-Object FullyQualifiedErrorId -Like 'PhxCommandFailed*' | Select-Object -First 1
        $record | Should -Not -BeNullOrEmpty
        $record.Exception.Message | Should -BeLike $Message
        # Shown as "phx: <message>", not as an exception from inside a helper.
        $record.InvocationInfo.MyCommand.Name | Should -Be 'phx'
    }

    It 'expands ~ and keeps a drive or file-system root whole' {
        InModuleScope PSPhoenix {
            ConvertTo-PhxFullPath '~' | Should -Be ($HOME.TrimEnd('\', '/'))
            ConvertTo-PhxFullPath '~/src' | Should -Be (Join-Path $HOME 'src')
            $driveRoot = [IO.Path]::GetPathRoot($TestDrive)
            ConvertTo-PhxFullPath $driveRoot | Should -Be $driveRoot
        }
    }
}

Describe 'repository identity' {
    It 'reads <Url> as <Identity>' -ForEach @(
        @{ Url = 'https://github.com/WizX20/PSPhoenix.git'; Identity = 'github.com/WizX20/PSPhoenix' }
        @{ Url = 'https://github.com/WizX20/PSPhoenix'; Identity = 'github.com/WizX20/PSPhoenix' }
        @{ Url = 'https://someone@GitHub.com/WizX20/PSPhoenix/'; Identity = 'github.com/WizX20/PSPhoenix' }
        @{ Url = 'git@github.com:WizX20/PSPhoenix.git'; Identity = 'github.com/WizX20/PSPhoenix' }
        @{ Url = 'ssh://git@github.com/WizX20/PSPhoenix.git'; Identity = 'github.com/WizX20/PSPhoenix' }
        @{ Url = 'ssh://git@github.com:22/WizX20/PSPhoenix.git'; Identity = 'github.com/WizX20/PSPhoenix' }
        @{ Url = 'git://github.com/WizX20/PSPhoenix.git'; Identity = 'github.com/WizX20/PSPhoenix' }
        @{ Url = 'https://gitlab.example.com/group/sub/name.git'; Identity = 'gitlab.example.com/group/sub/name' }
        @{ Url = 'https://dev.azure.com/org/My%20Project/_git/repo'; Identity = 'dev.azure.com/org/My Project/repo' }
        @{ Url = 'https://org@dev.azure.com/org/proj/_git/repo'; Identity = 'dev.azure.com/org/proj/repo' }
        @{ Url = 'git@ssh.dev.azure.com:v3/org/proj/repo'; Identity = 'dev.azure.com/org/proj/repo' }
        @{ Url = 'https://org.visualstudio.com/DefaultCollection/proj/_git/repo'; Identity = 'dev.azure.com/org/proj/repo' }
        @{ Url = 'https://org.visualstudio.com/proj/_git/repo'; Identity = 'dev.azure.com/org/proj/repo' }
        @{ Url = 'C:\git\origin.git'; Identity = 'file/C/git/origin' }
        @{ Url = 'file:///C:/git/origin.git'; Identity = 'file/C/git/origin' }
        @{ Url = '\\nas\git\origin.git'; Identity = 'file/nas/git/origin' }
        @{ Url = '/srv/git/origin.git'; Identity = 'file/srv/git/origin' }
    ) {
        InModuleScope PSPhoenix -Parameters @{ Url = $Url } { param($Url) ConvertTo-PhxRepoIdentity -Url $Url } | Should -BeExactly $Identity
    }

    It 'removes credentials from <Url>' -ForEach @(
        @{ Url = 'https://user:secret@github.com/o/r.git'; Clean = 'https://user@github.com/o/r.git' }
        @{ Url = 'https://ghp_abcdefghijklmnopqrstuvwxyz0123456789@github.com/o/r.git'; Clean = 'https://github.com/o/r.git' }
        @{ Url = 'https://org@dev.azure.com/org/p/_git/r'; Clean = 'https://org@dev.azure.com/org/p/_git/r' }
        @{ Url = 'ssh://git@github.com/o/r.git'; Clean = 'ssh://git@github.com/o/r.git' }
        @{ Url = 'git@github.com:o/r.git'; Clean = 'git@github.com:o/r.git' }
    ) {
        InModuleScope PSPhoenix -Parameters @{ Url = $Url } { param($Url) Remove-PhxUrlSecret $Url } | Should -BeExactly $Clean
    }

    It 'masks credentials in text such as a git error' {
        InModuleScope PSPhoenix {
            Hide-PhxSecret 'git clone https://user:secret@github.com/o/r.git failed' | Should -Be 'git clone https://user:***@github.com/o/r.git failed'
            Hide-PhxSecret 'remote https://ghp_abcdefghijklmnopqrstuvwxyz0123456789@github.com/o/r' | Should -Be 'remote https://***@github.com/o/r'
            Hide-PhxSecret 'https://org@dev.azure.com/org' | Should -Be 'https://org@dev.azure.com/org'
            # A token on its own, by its prefix (built here, so no token-like text is committed).
            Hide-PhxSecret "gh said $('glpat-' + 'x' * 20) is wrong" | Should -Be 'gh said *** is wrong'
            $failure = { Invoke-PhxGit -Repository $TestDrive -Arguments 'ls-remote', 'https://user:secret@invalid.invalid/x.git' } | Should -Throw -PassThru
            $failure.Exception.Message | Should -Not -Match 'secret'
        }
    }

    It 'tells a link from a folder - a cloud placeholder has no link target' {
        $real = Join-Path $TestDrive 'real-folder'
        $link = Join-Path $TestDrive 'link-folder'
        New-Item -ItemType Directory -Path $real | Out-Null
        New-Item -ItemType ($IsWindows ? 'Junction' : 'SymbolicLink') -Path $link -Target $real | Out-Null
        try {
            InModuleScope PSPhoenix -Parameters @{ Real = $real; Link = $link } {
                param($Real, $Link)
                Test-PhxLinkFolder $Link | Should -BeTrue
                Test-PhxLinkFolder $Real | Should -BeFalse
            }
        }
        finally { (Get-Item -LiteralPath $link -Force).Delete() }
    }

    It 'resolves a relative local remote against the repository' {
        $base = Join-Path $TestDrive 'a/b'
        $identity = InModuleScope PSPhoenix -Parameters @{ Base = $base } { param($Base) ConvertTo-PhxRepoIdentity -Url '../origin.git' -BasePath $Base }
        $identity | Should -BeLike 'file/*/a/origin'
    }
}

Describe 'scan' {
    BeforeEach {
        $testHome = Use-TestHome
        $repos = Join-Path $testHome 'Repos'
        New-Item -ItemType Directory -Path $repos | Out-Null

        function Get-TestScan {
            # Scans and returns the records; the summary goes to $script:ScanOutput.
            $script:ScanOutput = InModuleScope PSPhoenix { Invoke-PhxScan -PassThru } 6>&1
            @($script:ScanOutput | Where-Object { $_ -is [System.Collections.IDictionary] })
        }
    }

    It "finds repositories down to the root's depth, and no deeper" {
        New-TestRepository (Join-Path $repos 'One') -Remote 'origin=https://github.com/o/one.git' | Out-Null
        New-TestRepository (Join-Path $repos 'org/Two') -Remote 'origin=https://github.com/o/two.git' | Out-Null
        New-TestRepository (Join-Path $repos 'a/b/Three') -Remote 'origin=https://github.com/o/three.git' | Out-Null
        New-TestRepository (Join-Path $repos 'a/b/c/Four') -Remote 'origin=https://github.com/o/four.git' | Out-Null
        phx roots add $repos 6>$null
        $records = @(Get-TestScan)
        @($records.identity | Sort-Object) | Should -Be @('github.com/o/one', 'github.com/o/three', 'github.com/o/two')
        ($records | Where-Object identity -EQ 'github.com/o/two').path | Should -Be 'org/Two'
    }

    It 'does not enter a repository: one nested inside it is not found' {
        New-TestRepository (Join-Path $repos 'Outer') -Remote 'origin=https://github.com/o/outer.git' | Out-Null
        New-TestRepository (Join-Path $repos 'Outer/vendor/Inner') -Remote 'origin=https://github.com/o/inner.git' | Out-Null
        phx roots add $repos 6>$null
        @((Get-TestScan).identity) | Should -Be @('github.com/o/outer')
    }

    It 'records a linked worktree on its main repository, not as a repository of its own' {
        $main = New-TestRepository (Join-Path $repos 'Main') -Remote 'origin=https://github.com/o/main.git'
        $worktree = Join-Path $repos 'Main-feature'
        git -C $main worktree add -q $worktree -b feature 2>$null
        # A repository inside the worktree folder: found only if the .git file were not respected.
        New-TestRepository (Join-Path $worktree 'nested') -Remote 'origin=https://github.com/o/nested.git' | Out-Null
        phx roots add $repos 6>$null
        $records = @(Get-TestScan)
        @($records.identity) | Should -Be @('github.com/o/main')
        @($records[0].worktrees).Count | Should -Be 1
        $records[0].worktrees[0].path | Should -Be 'Main-feature'
        $records[0].worktrees[0].branch | Should -Be 'feature'
    }

    It 'skips a submodule and build-output folders' {
        $submodule = Join-Path $repos 'Sub'
        New-Item -ItemType Directory -Path $submodule -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $submodule '.git') -Value 'gitdir: ../App/.git/modules/Sub'
        New-TestRepository (Join-Path $submodule 'nested') -Remote 'origin=https://github.com/o/nested.git' | Out-Null
        New-TestRepository (Join-Path $repos 'web/node_modules/pkg') -Remote 'origin=https://github.com/o/pkg.git' | Out-Null
        New-TestRepository (Join-Path $repos 'Real') -Remote 'origin=https://github.com/o/real.git' | Out-Null
        phx roots add $repos 6>$null
        @((Get-TestScan).identity) | Should -Be @('github.com/o/real')
    }

    It 'does not follow a junction or symbolic link' {
        New-TestRepository (Join-Path $repos 'Real') -Remote 'origin=https://github.com/o/real.git' | Out-Null
        $elsewhere = New-TestRepository (Join-Path $testHome 'Elsewhere') -Remote 'origin=https://github.com/o/elsewhere.git'
        $link = Join-Path $repos 'Link'
        New-Item -ItemType ($IsWindows ? 'Junction' : 'SymbolicLink') -Path $link -Target $elsewhere | Out-Null
        try {
            phx roots add $repos 6>$null
            @((Get-TestScan).identity) | Should -Be @('github.com/o/real')
        }
        finally { (Get-Item -LiteralPath $link -Force).Delete() }
    }

    It 'gives a repository without remotes a local identity, and a local-path remote a file one' {
        New-TestRepository (Join-Path $repos 'Lonely') | Out-Null
        $bare = Join-Path $testHome 'origin.git'
        git init -q --bare $bare
        New-TestRepository (Join-Path $repos 'FromDisk') -Remote "origin=$bare" | Out-Null
        phx roots add $repos 6>$null
        $records = @(Get-TestScan)
        ($records | Where-Object path -EQ 'Lonely').identity | Should -Be 'local/Lonely'
        ($records | Where-Object path -EQ 'FromDisk').identity | Should -BeLike 'file/*/origin'
        $script:ScanOutput -join "`n" | Should -Match '2 repositories, 1 without a remote'
    }

    It 'takes origin, else the first remote' {
        New-TestRepository (Join-Path $repos 'Fork') -Remote 'upstream=https://github.com/up/x.git', 'origin=https://github.com/me/x.git' | Out-Null
        New-TestRepository (Join-Path $repos 'Mirror') -Remote 'upstream=https://github.com/up/y.git', 'backup=https://example.com/b/y.git' | Out-Null
        phx roots add $repos 6>$null
        $records = @(Get-TestScan)
        ($records | Where-Object path -EQ 'Fork').identity | Should -Be 'github.com/me/x'
        ($records | Where-Object path -EQ 'Mirror').identity | Should -Be 'github.com/up/y'
        @(($records | Where-Object path -EQ 'Fork').remotes.Keys) | Should -Be @('upstream', 'origin')
    }

    It 'treats a root that is itself a repository as one repository' {
        $single = New-TestRepository (Join-Path $repos 'Single') -Remote 'origin=https://github.com/o/single.git'
        phx roots add $single 6>$null
        $records = @(Get-TestScan)
        @($records.identity) | Should -Be @('github.com/o/single')
        $records[0].path | Should -Be '.'
    }

    It 'saves the scan and says what is new and what is gone' {
        $one = New-TestRepository (Join-Path $repos 'One') -Remote 'origin=https://github.com/o/one.git'
        New-TestRepository (Join-Path $repos 'Two') -Remote 'origin=https://github.com/o/two.git' | Out-Null
        phx roots add $repos 6>$null
        Get-PhxOutput { phx roots list } | Should -Match 'not scanned yet'
        Get-TestScan | Out-Null
        Test-Path -LiteralPath (Join-Path (InModuleScope PSPhoenix { Get-PhxStateDir }) 'repos.json') | Should -BeTrue
        Get-PhxOutput { phx roots list } | Should -Match '2 repositories'

        Remove-Item -LiteralPath $one -Recurse -Force
        New-TestRepository (Join-Path $repos 'Three') -Remote 'origin=https://github.com/o/three.git' | Out-Null
        $output = Get-PhxOutput { phx scan }
        $output | Should -Match 'new:\s+github.com/o/three'
        $output | Should -Match 'gone:\s+github.com/o/one'
    }

    It 'points out the same remote cloned twice' {
        New-TestRepository (Join-Path $repos 'A') -Remote 'origin=https://github.com/o/same.git' | Out-Null
        New-TestRepository (Join-Path $repos 'B') -Remote 'origin=https://github.com/o/same.git' | Out-Null
        phx roots add $repos 6>$null
        Get-PhxOutput { phx scan } | Should -Match 'github.com/o/same is cloned 2 times'
    }

    It 'keeps the repositories of a root whose folder is gone, marked offline' {
        # An unplugged drive must not make a backup forget what lives on it.
        New-TestRepository (Join-Path $repos 'Away') -Remote 'origin=https://github.com/o/away.git' | Out-Null
        phx roots add $repos 6>$null
        Get-TestScan | Out-Null
        Remove-Item -LiteralPath $repos -Recurse -Force
        $records = @(Get-TestScan)
        $script:ScanOutput -join "`n" | Should -Match 'folder not found - kept 1 repositories from the last scan, marked offline'
        $script:ScanOutput -join "`n" | Should -Match '1 repositories, 1 offline'
        $records[0].identity | Should -Be 'github.com/o/away'
        $records[0].offline | Should -BeTrue
        $script:ScanOutput -join "`n" | Should -Not -Match 'gone:'
    }

    It 'keeps the repositories of a root that turned up empty, marked offline' {
        # Linux keeps an unmounted drive's mount point: an empty folder, not a missing one.
        $away = New-TestRepository (Join-Path $repos 'Away') -Remote 'origin=https://github.com/o/away.git'
        phx roots add $repos 6>$null
        Get-TestScan | Out-Null
        Remove-Item -LiteralPath $away -Recurse -Force
        $records = @(Get-TestScan)
        $script:ScanOutput -join "`n" | Should -Match 'no repositories where the last scan found 1 - kept them, marked offline'
        $records[0].offline | Should -BeTrue
        # Gone for good: removing and adding the root again forgets them. Removing a root trims the
        # last scan without pretending it was a new one.
        $scannedAt = (InModuleScope PSPhoenix { Read-PhxRepoCache }).scannedAt
        phx roots rm $repos 6>$null
        $cache = InModuleScope PSPhoenix { Read-PhxRepoCache }
        @($cache.repositories | Where-Object { $_ }) | Should -HaveCount 0
        $cache.scannedAt | Should -Be $scannedAt
        phx roots add $repos 6>$null
        @(Get-TestScan) | Should -HaveCount 0
    }

    It 'treats owners that differ only in case as the same, as GitHub does' {
        New-TestRepository (Join-Path $repos 'A') -Remote 'origin=https://github.com/WizX20/same.git' | Out-Null
        New-TestRepository (Join-Path $repos 'B') -Remote 'origin=https://github.com/wizx20/same.git' | Out-Null
        phx roots add $repos 6>$null
        InModuleScope PSPhoenix { $c = Read-PhxConfig; $c.accounts['github.com/WizX20'] = 'WizX20'; Save-PhxConfig $c }
        Get-PhxOutput { phx scan } | Should -Match '(?i)github.com/wizx20/same is cloned 2 times'
        $accounts = InModuleScope PSPhoenix {
            $config = Read-PhxConfig
            (Read-PhxRepoCache).repositories | ForEach-Object { Get-PhxRepoAccount -Record $_ -Accounts $config.accounts }
        }
        @($accounts) | Should -Be @('WizX20', 'WizX20')
    }

    It 'reads the branches of a repository on the reftable backend' {
        $remote = Join-Path $testHome 'remote.git'
        git -c init.defaultBranch=main init -q --bare $remote
        $seed = New-TestRepository (Join-Path $testHome 'seed')
        git -C $seed push -q $remote main 2>$null
        git clone -q --ref-format=reftable $remote (Join-Path $repos 'Table') 2>$null
        if ($LASTEXITCODE) { Set-ItResult -Skipped -Because 'this git cannot create a reftable repository (git 2.45+)'; return }
        phx roots add $repos 6>$null
        $record = @(Get-TestScan)[0]
        $record.branch | Should -Be 'main'
        $record.defaultBranch | Should -Be 'main'
    }

    It "keeps a repository's last record when git cannot read it, and says so" {
        $broken = New-TestRepository (Join-Path $repos 'Broken') -Remote 'origin=https://github.com/o/broken.git'
        New-TestRepository (Join-Path $repos 'Fine') -Remote 'origin=https://github.com/o/fine.git' | Out-Null
        phx roots add $repos 6>$null
        Get-TestScan | Out-Null
        Add-Content -LiteralPath (Join-Path $broken '.git/config') -Value '[this is not valid'
        $records = @(Get-TestScan)
        $script:ScanOutput -join "`n" | Should -Match 'skipped .*Broken: git config .* failed.* - kept what the last scan recorded'
        @($records.identity | Sort-Object) | Should -Be @('github.com/o/broken', 'github.com/o/fine')
    }

    It 'does not record a repository git cannot read and never could, and scans the rest' {
        $broken = New-TestRepository (Join-Path $repos 'Broken') -Remote 'origin=https://github.com/o/broken.git'
        New-TestRepository (Join-Path $repos 'Fine') -Remote 'origin=https://github.com/o/fine.git' | Out-Null
        Add-Content -LiteralPath (Join-Path $broken '.git/config') -Value '[this is not valid'
        phx roots add $repos 6>$null
        $records = @(Get-TestScan)
        $script:ScanOutput -join "`n" | Should -Match 'skipped .*Broken: .* - not recorded'
        @($records.identity) | Should -Be @('github.com/o/fine')
    }

    It 'ignores a remote without a URL instead of failing the scan' {
        $odd = New-TestRepository (Join-Path $repos 'Odd')
        git -C $odd config remote.pushonly.pushurl 'https://github.com/o/odd.git'
        New-TestRepository (Join-Path $repos 'Fine') -Remote 'origin=https://github.com/o/fine.git' | Out-Null
        phx roots add $repos 6>$null
        $records = @(Get-TestScan)
        ($records | Where-Object path -EQ 'Odd').identity | Should -Be 'local/Odd'
        @($records).Count | Should -Be 2
    }

    It 'records a remote URL without the credentials in it, and says so' {
        $token = 'ghp_' + ('a1' * 18)
        New-TestRepository (Join-Path $repos 'Tok') -Remote "origin=https://x-access-token:$token@github.com/o/tok.git" | Out-Null
        New-TestRepository (Join-Path $repos 'AsUser') -Remote "origin=https://$token@github.com/o/asuser.git" | Out-Null
        phx roots add $repos 6>$null
        $records = @(Get-TestScan)
        @(($records | Where-Object path -EQ 'Tok').remotes.origin.urls) | Should -Be @('https://x-access-token@github.com/o/tok.git')
        @(($records | Where-Object path -EQ 'AsUser').remotes.origin.urls) | Should -Be @('https://github.com/o/asuser.git')
        $script:ScanOutput -join "`n" | Should -Match 'carries credentials in its URL - recorded without them'
        Get-Content -LiteralPath (Join-Path (InModuleScope PSPhoenix { Get-PhxStateDir }) 'repos.json') -Raw | Should -Not -Match $token
        ($script:ScanOutput -join "`n") | Should -Not -Match $token
    }

    It 'shows a root added after the last scan as not scanned' {
        New-TestRepository (Join-Path $repos 'One') -Remote 'origin=https://github.com/o/one.git' | Out-Null
        $later = Join-Path $testHome 'Later'
        New-Item -ItemType Directory -Path $later | Out-Null
        phx roots add $repos 6>$null
        Get-TestScan | Out-Null
        phx roots add $later 6>$null
        $output = Get-PhxOutput { phx roots list }
        $output | Should -Match ([regex]::Escape($repos) + '\s+depth 3\s+1 repositories')
        $output | Should -Match ([regex]::Escape($later) + '\s+depth 3\s+not scanned yet')
    }

    It 'keeps non-ASCII paths and URLs intact' {
        $e = [char]0x00E9   # spelled as a char code to keep this file ASCII
        New-TestRepository (Join-Path $repos "Caf$e") -Remote "origin=https://example.com/o/caf$e.git" | Out-Null
        phx roots add $repos 6>$null
        $records = @(Get-TestScan)
        $records[0].identity | Should -BeExactly "example.com/o/caf$e"
        $records[0].path | Should -BeExactly "Caf$e"
    }

    It "reports git's own message when git fails" {
        InModuleScope PSPhoenix -Parameters @{ Folder = $repos } {
            param($Folder)
            { Invoke-PhxGit -Repository $Folder -Arguments 'rev-parse', 'HEAD' } | Should -Throw '*git rev-parse HEAD failed in*not a git repository*'
            Invoke-PhxGit -Repository $Folder -Arguments 'rev-parse', 'HEAD' -AllowFailure | Should -BeNullOrEmpty
        }
    }

    It 'refuses to scan without roots' {
        { phx scan -ErrorAction Stop 6>$null } | Should -Throw '*no roots yet*'
    }

    It 'ignores an unreadable cache and rebuilds it' {
        New-TestRepository (Join-Path $repos 'One') -Remote 'origin=https://github.com/o/one.git' | Out-Null
        phx roots add $repos 6>$null
        $cache = Join-Path (InModuleScope PSPhoenix { Get-PhxStateDir }) 'repos.json'
        New-Item -ItemType Directory -Force -Path (Split-Path $cache) | Out-Null
        Set-Content -LiteralPath $cache -Value '{ not json'
        Get-PhxOutput { phx roots list } | Should -Match 'not scanned yet'
        Get-PhxOutput { phx scan } | Should -Match 'ignoring .*repos.json'
        Get-PhxOutput { phx roots list } | Should -Match '1 repositories'
    }
}

Describe 'repos provider' {
    BeforeAll {
        function script:New-TestRemote {
            # A bare repository with a commit on main and one on each -Branch. Returns its path.
            param([Parameter(Mandatory)][string]$Path, [string[]]$Branch = @())
            git -c init.defaultBranch=main init -q --bare $Path
            $seed = Join-Path $TestDrive ('seed-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            git -c init.defaultBranch=main init -q $seed
            git -C $seed -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m init
            git -C $seed push -q $Path main 2>$null
            foreach ($name in $Branch) {
                git -C $seed switch -q -c $name
                git -C $seed -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m $name
                git -C $seed push -q $Path $name 2>$null
            }
            $Path
        }

        function script:Invoke-ReposBackup {
            InModuleScope PSPhoenix -Parameters @{ Staging = $args[0] } {
                param($Staging)
                Backup-PhxRepos -Context (New-PhxContext -Provider repos -Staging $Staging)
            } 6>&1 | Out-String
        }

        function script:Invoke-ReposRestore {
            # The restore's output as one string. When it fails, the output travels in the error
            # message - the per-repository warnings say why.
            param([string]$Staging, [hashtable]$RootMap = @{}, [string[]]$Select = @(), [switch]$DryRun)
            $lines = [Collections.Generic.List[string]]::new()
            try {
                InModuleScope PSPhoenix -Parameters @{ Staging = $Staging; RootMap = $RootMap; Select = $Select; DryRun = [bool]$DryRun } {
                    param($Staging, $RootMap, $Select, $DryRun)
                    Restore-PhxRepos -Context (New-PhxContext -Provider repos -Staging $Staging -RootMap $RootMap -Select $Select -DryRun:$DryRun)
                } 6>&1 | ForEach-Object { $lines.Add("$_") }
            }
            catch { throw "$($_.Exception.Message)`n$($lines -join "`n")" }
            $lines -join "`n"
        }

        function script:Read-TestInventory {
            param([string]$Staging)
            (Get-Content -LiteralPath (Join-Path $Staging 'repos.json') -Raw | ConvertFrom-Json -AsHashtable).repositories
        }

        $remotes = Join-Path $TestDrive 'remotes'
        $script:RemoteOne = New-TestRemote (Join-Path $remotes 'one.git') -Branch 'feature'
        $script:RemoteUp = New-TestRemote (Join-Path $remotes 'one-upstream.git')
        $script:Helper = '!f() { t=$(gh auth token --user WizX20) || return 1; GH_TOKEN=$t gh auth git-credential "$@"; }; f'
    }

    BeforeEach {
        # Machine A: a clone on a feature branch with a second remote, a push URL and the
        # repo-local identity of a WizX20-style .gitconfig include; and a repository without remotes.
        $machineA = Use-TestHome
        $reposA = Join-Path $machineA 'Repos'
        $one = Join-Path $reposA 'One'
        git clone -q $script:RemoteOne $one 2>$null
        git -C $one switch -q feature 2>$null
        git -C $one remote add upstream $script:RemoteUp
        git -C $one remote set-url --push origin 'https://example.invalid/push/one.git'
        git -C $one config user.name 'Test Person'
        git -C $one config user.email 'person@example.invalid'
        git -C $one config include.path '../.gitconfig'
        git -C $one config core.sshCommand 'ssh -i ~/.ssh/id_test'
        git -C $one config --add credential.https://github.com.helper ''
        git -C $one config --add credential.https://github.com.helper $script:Helper
        New-TestRepository (Join-Path $reposA 'Scratch') | Out-Null
        phx roots add $reposA 6>$null
        phx scan 6>$null
        $snapshot = Join-Path $machineA 'snapshot/repos'
        New-Item -ItemType Directory -Force -Path $snapshot | Out-Null
        # A local remote never needs a token; a call would mean a token went somewhere it should not.
        Mock Get-PhxGhToken { throw 'no token expected' } -ModuleName PSPhoenix
        # Restore asks gh which hosts it is logged in to: nowhere, unless a test says otherwise.
        Mock Get-PhxGhAccount -ModuleName PSPhoenix { }
    }

    It 'records remotes, branches, identity settings and the account' {
        Invoke-ReposBackup $snapshot | Should -Match '2 repositories recorded'
        $inventory = @(Read-TestInventory $snapshot)
        $repo = $inventory | Where-Object path -EQ 'One'
        $repo.identity | Should -BeLike 'file/*/remotes/one'
        $repo.branch | Should -Be 'feature'
        $repo.defaultBranch | Should -Be 'main'
        $repo.primaryRemote | Should -Be 'origin'
        @($repo.remotes.Keys) | Should -Be @('origin', 'upstream')
        @($repo.remotes.origin.pushUrls) | Should -Be @('https://example.invalid/push/one.git')
        @($repo.remotes.origin.urls) | Should -Be @($script:RemoteOne)
        $repo.account | Should -Be 'WizX20'
        $repo.accountSource | Should -Be 'credential helper'
        $helper = @($repo.settings | Where-Object key -EQ 'credential.https://github.com.helper' | ForEach-Object value)
        $helper | Should -Be @('', $script:Helper)
        ($repo.settings | Where-Object key -EQ 'core.sshcommand').value | Should -Be 'ssh -i ~/.ssh/id_test'
        ($inventory | Where-Object path -EQ 'Scratch').identity | Should -Be 'local/Scratch'
    }

    It 'restores into another root: clone, remotes, settings and branch' {
        Invoke-ReposBackup $snapshot | Out-Null
        $machineB = Use-TestHome
        $reposB = Join-Path $machineB 'Repos'
        $output = Invoke-ReposRestore $snapshot -RootMap @{ $reposA = $reposB }
        $output | Should -Match '1 cloned, 0 already in place, 1 skipped, 0 failed'
        $output | Should -Match 'local/Scratch: no remote to clone from'
        $restored = Join-Path $reposB 'One'
        git -C $restored branch --show-current | Should -Be 'feature'
        git -C $restored remote get-url origin | Should -Be $script:RemoteOne
        git -C $restored remote get-url --push origin | Should -Be 'https://example.invalid/push/one.git'
        git -C $restored remote get-url upstream | Should -Be $script:RemoteUp
        git -C $restored config --local user.email | Should -Be 'person@example.invalid'
        git -C $restored config --local include.path | Should -Be '../.gitconfig'
        @(git -C $restored config --local --get-all credential.https://github.com.helper) | Should -Be @('', $script:Helper)
        Should -Invoke Get-PhxGhToken -ModuleName PSPhoenix -Times 0
    }

    It 'restores every recorded setting as it was' {
        git -C $one config user.signingkey 'ssh-ed25519 AAAAtest signing@example.invalid'
        git -C $one config gpg.format ssh
        git -C $one config tag.gpgsign true
        git -C $one config includeIf.gitdir:~/work/.path '~/work.gitconfig'
        Invoke-ReposBackup $snapshot | Out-Null
        $reposB = Join-Path (Use-TestHome) 'Repos'
        Invoke-ReposRestore $snapshot -RootMap @{ $reposA = $reposB } | Out-Null
        # Everything PSPhoenix records - identity settings, every URL - per key, in order.
        $pattern = InModuleScope PSPhoenix { $script:PhxRepoSettingPattern }
        $recorded = {
            param($Path)
            @(git -C $Path config --local --list) | Where-Object {
                $key = ($_ -split '=', 2)[0]
                $key -match $pattern -or $key -match '^remote\.[^.]+\.(url|pushurl)$'
            } | Sort-Object -Stable { ($_ -split '=', 2)[0] }
        }
        $expected = @(& $recorded $one)
        $expected.Count | Should -BeGreaterThan 10
        @(& $recorded (Join-Path $reposB 'One')) | Should -Be $expected
    }

    It 'leaves the checked-out branch of a repository in place alone' {
        Invoke-ReposBackup $snapshot | Out-Null
        git -C $one switch -q main
        Invoke-ReposRestore $snapshot | Should -Match '0 cloned, 2 already in place'
        git -C $one branch --show-current | Should -Be 'main'
    }

    It 'records linked worktrees inside and outside the root, detached ones too, and only lists them on restore' {
        git -C $one worktree add -q -b wt-branch (Join-Path $reposA 'One-wt') 2>$null
        $outside = Join-Path $machineA 'elsewhere/wt'
        git -C $one worktree add -q --detach $outside 2>$null
        phx scan 6>$null
        Invoke-ReposBackup $snapshot | Should -Match '2 repositories recorded'
        $worktrees = @((Read-TestInventory $snapshot | Where-Object path -EQ 'One').worktrees)
        $worktrees | Should -HaveCount 2
        ($worktrees | Where-Object path -EQ 'One-wt').branch | Should -Be 'wt-branch'
        $detached = $worktrees | Where-Object path -NE 'One-wt'
        $detached.path | Should -Be ([IO.Path]::GetFullPath($outside))
        $detached.branch | Should -BeNullOrEmpty
        $output = Invoke-ReposRestore $snapshot -RootMap @{ $reposA = (Join-Path (Use-TestHome) 'Repos') }
        $output | Should -Match 'worktree One-wt \(wt-branch\) is not recreated'
        $output | Should -Match ('worktree ' + [regex]::Escape([IO.Path]::GetFullPath($outside)) + ' \(detached\) is not recreated')
    }

    It 'changes nothing on a second restore' {
        Invoke-ReposBackup $snapshot | Out-Null
        $reposB = Join-Path (Use-TestHome) 'Repos'
        Invoke-ReposRestore $snapshot -RootMap @{ $reposA = $reposB } | Out-Null
        $before = git -C (Join-Path $reposB 'One') config --local --list
        Invoke-ReposRestore $snapshot -RootMap @{ $reposA = $reposB } | Should -Match '0 cloned, 1 already in place, 1 skipped, 0 failed'
        git -C (Join-Path $reposB 'One') config --local --list | Should -Be $before
    }

    It "re-applies the recorded settings to a repository that is already there" {
        Invoke-ReposBackup $snapshot | Out-Null
        git -C $one config user.email 'someone-else@example.invalid'
        git -C $one remote remove upstream
        Invoke-ReposRestore $snapshot | Should -Match '0 cloned, 2 already in place, 0 skipped, 0 failed'
        git -C $one config --local user.email | Should -Be 'person@example.invalid'
        git -C $one remote get-url upstream | Should -Be $script:RemoteUp
    }

    It "gives a clone from <HostName> <Account>'s token in <Variable>, and puts the old value back" -ForEach @(
        @{ Account = 'WorkAccount'; HostName = 'github.com'; Variable = 'GH_TOKEN'; Other = 'GH_ENTERPRISE_TOKEN' }
        @{ Account = 'EnterpriseUser'; HostName = 'ghe.example.com'; Variable = 'GH_ENTERPRISE_TOKEN'; Other = 'GH_TOKEN' }
        # GitHub Enterprise Cloud with data residency: gh reads GH_TOKEN there, as for github.com.
        @{ Account = 'CloudUser'; HostName = 'acme.ghe.com'; Variable = 'GH_TOKEN'; Other = 'GH_ENTERPRISE_TOKEN' }
    ) {
        # Both variables set here: what the case before this one left must not decide the outcome.
        [Environment]::SetEnvironmentVariable($Other, $null)
        [Environment]::SetEnvironmentVariable($Variable, 'was-set-before')
        try {
            $seen = InModuleScope PSPhoenix -Parameters @{ Account = $Account; HostName = $HostName; Variable = $Variable; Other = $Other; Target = (Join-Path $TestDrive "clone-$Variable/tok") } {
                param($Account, $HostName, $Variable, $Other, $Target)
                $script:TestSeen = $null
                $script:TestVariables = $Variable, $Other
                Mock Get-PhxGhToken { "token-for-$Account" }
                # What git would get: its arguments and the environment of that moment.
                Mock Invoke-PhxGit {
                    $script:TestSeen = @{
                        Arguments = $Arguments
                        Token     = [Environment]::GetEnvironmentVariable($script:TestVariables[0])
                        Other     = [Environment]::GetEnvironmentVariable($script:TestVariables[1])
                    }
                }
                Invoke-PhxClone -Url "https://$HostName/o/tok.git" -Target $Target -RemoteName origin -Account $Account -TokenHosts 'github.com', 'ghe.example.com', 'acme.ghe.com'
                Should -Invoke Get-PhxGhToken -Times 1 -Exactly
                $script:TestSeen
            }
            [Environment]::GetEnvironmentVariable($Variable) | Should -Be 'was-set-before'
        }
        finally { [Environment]::SetEnvironmentVariable($Variable, $null) }
        $seen.Token | Should -Be "token-for-$Account"
        $seen.Other | Should -BeNullOrEmpty
        $arguments = $seen.Arguments -join ' '
        $arguments | Should -BeLike '-c credential.helper= -c credential.helper=!gh auth git-credential clone --quiet --origin origin -- https://*/o/tok.git *'
    }

    It 'gives the clone the recorded SSH command and credential settings, before the fetch' {
        $arguments = InModuleScope PSPhoenix -Parameters @{ Target = (Join-Path $TestDrive 'clone-ssh/x') } {
            param($Target)
            $script:TestArguments = $null
            Mock Invoke-PhxGit { $script:TestArguments = $Arguments }
            $settings = @(
                @{ key = 'user.email'; value = 'me@example.invalid' }
                @{ key = 'core.sshcommand'; value = 'ssh -i ~/.ssh/id_work' }
                @{ key = 'credential.https://dev.azure.com.usehttppath'; value = $null }
            )
            Invoke-PhxClone -Url 'git@github.com:o/r.git' -Target $Target -RemoteName origin -Settings $settings
            $script:TestArguments
        }
        $arguments -join ' ' | Should -BeLike 'clone --quiet --origin origin --config core.sshcommand=ssh -i ~/.ssh/id_work --config credential.https://dev.azure.com.usehttppath=true -- git@github.com:o/r.git *'
    }

    It 'asks no token for a host gh is not logged in to, nor for a repository without an account' {
        $calls = InModuleScope PSPhoenix -Parameters @{ Target = (Join-Path $TestDrive 'clone-plain/x') } {
            param($Target)
            $script:TestCalls = [Collections.Generic.List[string]]::new()
            Mock Get-PhxGhToken { 'unexpected' }
            Mock Invoke-PhxGit { $script:TestCalls.Add($Arguments -join ' ') }
            Invoke-PhxClone -Url 'https://dev.azure.com/org/proj/_git/ado' -Target $Target -RemoteName origin -Account 'Someone' -TokenHosts 'github.com'
            Invoke-PhxClone -Url 'https://github.com/o/r.git' -Target $Target -RemoteName origin -TokenHosts 'github.com'
            Should -Invoke Get-PhxGhToken -Times 0
            $script:TestCalls
        }
        $calls | Should -HaveCount 2
        $calls | ForEach-Object { $_ | Should -Not -Match 'credential.helper' }
    }

    It 'restores with the account the inventory names, and the hosts gh is logged in to' {
        New-TestRepository (Join-Path $reposA 'Tok') -Remote 'origin=https://github.com/o/tok.git' | Out-Null
        InModuleScope PSPhoenix { $c = Read-PhxConfig; $c.accounts['github.com/o'] = 'WorkAccount'; Save-PhxConfig $c }
        phx scan 6>$null
        Invoke-ReposBackup $snapshot | Out-Null
        Mock Get-PhxGhAccount -ModuleName PSPhoenix { [pscustomobject]@{ Host = 'ghe.example.com'; Login = 'EnterpriseUser'; Active = $true } }
        $script:CloneCall = $null
        Mock Invoke-PhxClone -ModuleName PSPhoenix {
            $script:CloneCall = @{ Url = $Url; Account = $Account; TokenHosts = $TokenHosts; RemoteName = $RemoteName }
            git clone -q $script:RemoteOne $Target 2>$null
        }
        $reposB = Join-Path (Use-TestHome) 'Repos'
        Invoke-ReposRestore $snapshot -RootMap @{ $reposA = $reposB } -Select 'github.com/o/tok' | Should -Match 'cloning github.com/o/tok .* as WorkAccount'
        $script:CloneCall.Url | Should -Be 'https://github.com/o/tok.git'
        $script:CloneCall.Account | Should -Be 'WorkAccount'
        $script:CloneCall.RemoteName | Should -Be 'origin'
        @($script:CloneCall.TokenHosts) | Should -Be @('github.com', 'ghe.example.com')
    }

    It 'restores a lone empty value, a value-less key, a value with a newline and every URL' {
        git -C $one config --unset-all credential.https://github.com.helper
        git -C $one config --add credential.https://github.com.helper ''
        Add-Content -LiteralPath (Join-Path $one '.git/config') -Value "[commit]`n`tgpgsign"
        git -C $one config user.name "Two`nLines"
        git -C $one config --add remote.origin.url 'https://example.invalid/mirror/one.git'
        Invoke-ReposBackup $snapshot | Out-Null
        $repo = Read-TestInventory $snapshot | Where-Object path -EQ 'One'
        ($repo.settings | Where-Object key -EQ 'commit.gpgsign').value | Should -BeNullOrEmpty
        ($repo.settings | Where-Object key -EQ 'user.name').value | Should -Be "Two`nLines"
        $reposB = Join-Path (Use-TestHome) 'Repos'
        Invoke-ReposRestore $snapshot -RootMap @{ $reposA = $reposB } | Out-Null
        $restored = Join-Path $reposB 'One'
        @(git -C $restored config --local --get-all credential.https://github.com.helper) | Should -Be @('')
        git -C $restored config --local --type=bool commit.gpgsign | Should -Be 'true'
        (git -C $restored config --local user.name) -join "`n" | Should -Be "Two`nLines"
        @(git -C $restored config --local --get-all remote.origin.url) | Should -Be @($script:RemoteOne, 'https://example.invalid/mirror/one.git')
        # And a second restore finds nothing to change.
        $before = git -C $restored config --local --list
        Invoke-ReposRestore $snapshot -RootMap @{ $reposA = $reposB } | Out-Null
        git -C $restored config --local --list | Should -Be $before
    }

    It 'finds a remote-less repository below the first level in place' {
        New-TestRepository (Join-Path $reposA 'org/Scratch2') | Out-Null
        phx scan 6>$null
        Invoke-ReposBackup $snapshot | Out-Null
        Invoke-ReposRestore $snapshot -Select 'local/org/Scratch2' | Should -Match '0 cloned, 1 already in place, 0 skipped'
    }

    It 'restores a root that is itself a repository' {
        $single = Join-Path $machineA 'Single'
        git clone -q $script:RemoteOne $single 2>$null
        phx roots add $single 6>$null
        phx scan 6>$null
        Invoke-ReposBackup $snapshot | Out-Null
        $newSingle = Join-Path (Use-TestHome) 'Single'
        Invoke-ReposRestore $snapshot -RootMap @{ $single = $newSingle } -Select ((Read-TestInventory $snapshot | Where-Object path -EQ '.').identity) | Out-Null
        Test-Path -LiteralPath (Join-Path $newSingle '.git') | Should -BeTrue
    }

    It 'skips a root that is not a path on this machine unless it is mapped' {
        $foreign = if ($IsWindows) { '/home/someone/src' } else { 'C:\Repos' }
        $inventory = @{ format = 1; repositories = @(@{ identity = 'github.com/o/x'; root = $foreign; path = 'x'; remotes = @{ origin = @{ urls = @('https://github.com/o/x.git'); pushUrls = @() } }; primaryRemote = 'origin'; settings = @() }) }
        Set-Content -LiteralPath (Join-Path $snapshot 'repos.json') -Value ($inventory | ConvertTo-Json -Depth 10)
        Invoke-ReposRestore $snapshot | Should -Match "github.com/o/x: its root .* is not a path on this machine - map it"
    }

    It 'refuses a tampered inventory: <Case>' -ForEach @(
        @{ Case = 'a setting PSPhoenix does not record'; Tamper = { param($r) $r.settings += @{ key = 'core.hooksPath'; value = 'C:/evil' } }; InPlace = $false; Message = '*core.hooksPath is not a setting PSPhoenix records*' }
        @{ Case = 'a path out of the root'; Tamper = { param($r) $r.path = '../../escaped' }; InPlace = $false; Message = '*leads out of the root*' }
        @{ Case = 'a full path'; Tamper = { param($r) $r.path = (Join-Path $TestDrive 'full-path') }; InPlace = $false; Message = '*is not relative to its root*' }
        @{ Case = 'a URL that reads as an option'; Tamper = { param($r) $r.remotes.upstream.urls = @('--upload-pack=touch pwned') }; InPlace = $true; Message = "*has a URL starting with '-'*" }
    ) {
        Invoke-ReposBackup $snapshot | Out-Null
        $file = Join-Path $snapshot 'repos.json'
        $document = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable
        & $Tamper ($document.repositories | Where-Object identity -NotLike 'local/*')
        Set-Content -LiteralPath $file -Value ($document | ConvertTo-Json -Depth 10)
        $reposB = if ($InPlace) { $reposA } else { Join-Path (Use-TestHome) 'Repos' }
        { Invoke-ReposRestore $snapshot -RootMap @{ $reposA = $reposB } } | Should -Throw $Message
        if (-not $InPlace) {
            git -C (Join-Path $reposB 'One') config --local core.hooksPath 2>$null | Should -BeNullOrEmpty
            Test-Path -LiteralPath ([IO.Path]::GetFullPath((Join-Path $reposB '../../escaped'))) | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $TestDrive 'full-path') | Should -BeFalse
        }
        @(git -C $one remote get-url --all upstream) | Should -Be @($script:RemoteUp)
    }

    It 'records from the last scan what this run cannot read: an offline root, an unreadable repository' {
        $broken = New-TestRepository (Join-Path $reposA 'Broken') -Remote 'origin=https://github.com/o/broken.git'
        phx scan 6>$null
        Add-Content -LiteralPath (Join-Path $broken '.git/config') -Value '[not valid'
        Invoke-ReposBackup $snapshot | Should -Match 'could not read .*Broken.* - recorded from the last scan'
        (Read-TestInventory $snapshot | Where-Object path -EQ 'Broken').fromScan | Should -Be 'unreadable'

        $offlineRoot = Join-Path $machineA 'Usb'
        $awayRepo = New-TestRepository (Join-Path $offlineRoot 'Away') -Remote 'origin=https://github.com/o/away.git'
        git -C $awayRepo config user.email 'away@example.invalid'
        git -C $awayRepo remote set-url --push origin 'https://github.com/o/away-push.git'
        phx roots add $offlineRoot 6>$null
        phx scan 6>$null
        Remove-Item -LiteralPath $offlineRoot -Recurse -Force
        phx scan 6>$null
        Invoke-ReposBackup $snapshot | Should -Match 'offline - recorded from the last scan'
        $away = Read-TestInventory $snapshot | Where-Object identity -EQ 'github.com/o/away'
        $away.fromScan | Should -Be 'offline'
        # In full, as the scan saw it: a snapshot written while the drive is out loses nothing.
        @($away.remotes.origin.urls) | Should -Be @('https://github.com/o/away.git')
        @($away.remotes.origin.pushUrls) | Should -Be @('https://github.com/o/away-push.git')
        $away.branch | Should -Be 'main'
        ($away.settings | Where-Object key -EQ 'user.email').value | Should -Be 'away@example.invalid'
    }

    It 'scans a configured root the last scan did not cover before it backs up' {
        $later = Join-Path $machineA 'Later'
        New-TestRepository (Join-Path $later 'New') -Remote 'origin=https://github.com/o/new.git' | Out-Null
        phx roots add $later 6>$null
        Invoke-ReposBackup $snapshot | Should -Match ('not scanned yet: ' + [regex]::Escape($later) + ' - scanning the roots first')
        @(Read-TestInventory $snapshot).identity | Should -Contain 'github.com/o/new'
    }

    It 'scans only in memory on a -DryRun backup without a scan' {
        $cachePath = InModuleScope PSPhoenix { Get-PhxRepoCachePath }
        Remove-Item -LiteralPath $cachePath
        InModuleScope PSPhoenix -Parameters @{ Staging = $snapshot } {
            param($Staging)
            Backup-PhxRepos -Context (New-PhxContext -Provider repos -Staging $Staging -DryRun)
        } 6>&1 | Out-String | Should -Match 'would record 2 repositories'
        Test-Path -LiteralPath $cachePath | Should -BeFalse
    }

    It 'warns about a file a repository includes from outside its work tree' {
        $external = Join-Path $machineA 'work.gitconfig'
        Set-Content -LiteralPath $external -Value "[user]`n`temail = work@example.invalid"
        git -C $one config --add include.path ($external -replace '\\', '/')
        phx scan 6>$null
        $record = InModuleScope PSPhoenix { (Read-PhxRepoCache).repositories } | Where-Object path -EQ 'One'
        @($record.externalIncludes) | Should -Be @([IO.Path]::GetFullPath($external))
        Invoke-ReposBackup $snapshot | Should -Match ('One: includes ' + [regex]::Escape([IO.Path]::GetFullPath($external)) + ' from outside the repository')
    }

    It 'keeps the credentials of a remote in place that the snapshot records without them' {
        git -C $one remote set-url upstream 'https://x-access-token:tok-123@example.invalid/up.git'
        Invoke-ReposBackup $snapshot | Out-Null
        @((Read-TestInventory $snapshot | Where-Object path -EQ 'One').remotes.upstream.urls) | Should -Be @('https://x-access-token@example.invalid/up.git')
        Invoke-ReposRestore $snapshot | Should -Match '0 cloned, 2 already in place'
        git -C $one remote get-url upstream | Should -Be 'https://x-access-token:tok-123@example.invalid/up.git'
    }

    It 'records only the repositories under the configured roots' {
        phx roots rm $reposA 6>$null
        $other = Join-Path $machineA 'Other'
        New-TestRepository (Join-Path $other 'Elsewhere') -Remote 'origin=https://github.com/o/elsewhere.git' | Out-Null
        phx roots add $other 6>$null
        # The cache still holds reposA's repositories, which no longer count; Other it has not seen.
        Invoke-ReposBackup $snapshot | Should -Match '1 repositories recorded'
        @(Read-TestInventory $snapshot).identity | Should -Be @('github.com/o/elsewhere')
    }

    It 'reads <Helper> as the account <Account>' -ForEach @(
        @{ Helper = '!gh auth token --user WizX20'; Account = 'WizX20' }
        @{ Helper = '!gh auth token -u WizX20'; Account = 'WizX20' }
        @{ Helper = '!gh auth token --user=WizX20'; Account = 'WizX20' }
        @{ Helper = '!f() { t=$(gh auth token --user "Work-Acct") || return 1; }; f'; Account = 'Work-Acct' }
        @{ Helper = 'manager'; Account = $null }
        @{ Helper = '!"C:/Program Files/GitHub CLI/gh.exe" auth token --user WizX20'; Account = 'WizX20' }
        @{ Helper = '!f() { my-tool --user alice; }; f'; Account = $null }
    ) {
        InModuleScope PSPhoenix -Parameters @{ Helper = $Helper } {
            param($Helper)
            Get-PhxCredentialAccount @(@{ key = 'credential.helper'; value = $Helper })
        } | Should -Be $Account
    }

    It 'does not record a credential setting that <Case>' -ForEach @(
        # Token-like values are built at run time: nothing token-like is committed.
        @{ Case = 'writes out a password'; Key = 'credential.https://example.invalid.helper'; Value = '!f() { echo password=hunter2; }; f'; Secret = 'hunter2'; Reason = 'holds a secret' }
        @{ Case = 'holds a GitLab token'; Key = 'credential.https://gitlab.example.invalid.helper'; Value = "!f() { echo username=x; echo secret=$('glpat-' + 'q' * 20); }; f"; Secret = 'glpat-qqqq'; Reason = 'holds a secret' }
        @{ Case = 'has an Azure DevOps PAT as user name'; Key = 'credential.https://dev.azure.com.username'; Value = ('p' * 52); Secret = ('p' * 52); Reason = 'has a token as its user name' }
        @{ Case = 'is scoped to a URL with a token in it'; Key = "credential.https://x:$('glpat-' + 'r' * 20)@gitlab.example.invalid.helper"; Value = 'store'; Secret = 'glpat-rrrr'; Reason = 'carries credentials in its URL' }
    ) {
        git -C $one config --add $Key $Value
        phx scan 6>$null
        $output = Invoke-ReposBackup $snapshot
        $output | Should -Match ([regex]::Escape($Reason) + ' - not recorded')
        $output | Should -Not -Match ([regex]::Escape($Secret))
        Get-Content -LiteralPath (Join-Path $snapshot 'repos.json') -Raw | Should -Not -Match ([regex]::Escape($Secret))
        Get-Content -LiteralPath (InModuleScope PSPhoenix { Get-PhxRepoCachePath }) -Raw | Should -Not -Match ([regex]::Escape($Secret))
    }

    It 'leaves a path alone that holds <Case>' -ForEach @(
        @{ Case = 'another repository'; Make = { param($Path) New-TestRepository $Path -Remote 'origin=https://github.com/x/other.git' | Out-Null }; Message = 'holds github.com/x/other' }
        @{ Case = 'other files'; Make = { param($Path) New-Item -ItemType Directory -Force -Path $Path | Out-Null; Set-Content (Join-Path $Path 'notes.txt') 'x' }; Message = 'exists and is not a repository' }
    ) {
        Invoke-ReposBackup $snapshot | Out-Null
        $reposB = Join-Path (Use-TestHome) 'Repos'
        & $Make (Join-Path $reposB 'One')
        Invoke-ReposRestore $snapshot -RootMap @{ $reposA = $reposB } | Should -Match $Message
    }

    It 'restores only the selected repositories, and nothing with -DryRun' {
        Invoke-ReposBackup $snapshot | Out-Null
        $reposB = Join-Path (Use-TestHome) 'Repos'
        $identity = (Read-TestInventory $snapshot | Where-Object path -EQ 'One').identity
        Invoke-ReposRestore $snapshot -RootMap @{ $reposA = $reposB } -Select $identity -DryRun | Should -Match "would clone .* -> $([regex]::Escape((Join-Path $reposB 'One')))"
        Test-Path -LiteralPath $reposB | Should -BeFalse
        Invoke-ReposRestore $snapshot -RootMap @{ $reposA = $reposB } -Select 'local/Scratch' | Should -Match '0 cloned, 0 already in place, 1 skipped, 0 failed'
    }

    It 'says when the recorded branch is not on the remote' {
        git -C $one switch -q -c only-here 2>$null
        Invoke-ReposBackup $snapshot | Out-Null
        $reposB = Join-Path (Use-TestHome) 'Repos'
        Invoke-ReposRestore $snapshot -RootMap @{ $reposA = $reposB } | Should -Match 'branch only-here is not on origin'
        git -C (Join-Path $reposB 'One') branch --show-current | Should -Be 'main'
    }

    It "takes the account from an included .gitconfig, without copying the included settings" {
        # The WizX20 set-up: the helper lives in a .gitconfig tracked in the repository and pulled
        # in by include.path; the clone brings that file back, so only include.path is re-applied.
        $inc = New-TestRepository (Join-Path $reposA 'Included') -Remote 'origin=https://github.com/o/inc.git'
        Set-Content -LiteralPath (Join-Path $inc '.gitconfig') -Value @(
            '[user]', '    name = Included Person',
            '[credential "https://github.com"]', '    helper =', "    helper = `"$($script:Helper)`"")
        git -C $inc config include.path '../.gitconfig'
        phx scan 6>$null
        Invoke-ReposBackup $snapshot | Out-Null
        $repo = Read-TestInventory $snapshot | Where-Object path -EQ 'Included'
        $repo.account | Should -Be 'WizX20'
        $repo.accountSource | Should -Be 'credential helper'
        @($repo.settings.key) | Should -Be @('include.path')
        (InModuleScope PSPhoenix { Read-PhxRepoCache }).repositories | Where-Object path -EQ 'Included' | ForEach-Object helperAccount | Should -Be 'WizX20'
    }

    It 'keeps going when one repository cannot be cloned, and fails at the end' {
        New-TestRepository (Join-Path $reposA 'Locked') -Remote 'origin=https://github.com/o/locked.git' | Out-Null
        InModuleScope PSPhoenix { $c = Read-PhxConfig; $c.accounts['github.com/o'] = 'Missing'; Save-PhxConfig $c }
        phx scan 6>$null
        Invoke-ReposBackup $snapshot | Out-Null
        Mock Get-PhxGhToken { throw 'gh has no token for Missing on github.com - run: gh auth login' } -ModuleName PSPhoenix
        $env:GH_TOKEN = 'left-alone'
        try {
            $reposB = Join-Path (Use-TestHome) 'Repos'
            { Invoke-ReposRestore $snapshot -RootMap @{ $reposA = $reposB } -ErrorAction Stop } | Should -Throw '*1 repositories could not be restored*'
            $env:GH_TOKEN | Should -Be 'left-alone'
        }
        finally { $env:GH_TOKEN = $null }
        Test-Path -LiteralPath (Join-Path $reposB 'One/.git') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $reposB 'Locked') | Should -BeFalse
    }

    It 'flags LFS and submodules' {
        Set-Content -LiteralPath (Join-Path $one '.gitattributes') -Value '*.psd filter=lfs diff=lfs merge=lfs -text'
        Set-Content -LiteralPath (Join-Path $one '.gitmodules') -Value '[submodule "lib"]'
        Invoke-ReposBackup $snapshot | Out-Null
        $repo = Read-TestInventory $snapshot | Where-Object path -EQ 'One'
        $repo.lfs | Should -BeTrue
        $repo.submodules | Should -BeTrue
        (Read-TestInventory $snapshot | Where-Object path -EQ 'Scratch').lfs | Should -BeFalse
    }

    It 'writes nothing on a -DryRun backup' {
        InModuleScope PSPhoenix -Parameters @{ Staging = $snapshot } {
            param($Staging)
            Backup-PhxRepos -Context (New-PhxContext -Provider repos -Staging $Staging -DryRun)
        } 6>&1 | Out-String | Should -Match 'would record 2 repositories'
        Test-Path -LiteralPath (Join-Path $snapshot 'repos.json') | Should -BeFalse
    }

    It 'does not record a repository gone since the last scan' {
        Remove-Item -LiteralPath (Join-Path $reposA 'Scratch') -Recurse -Force
        Invoke-ReposBackup $snapshot | Should -Match 'gone since the last scan'
        @(Read-TestInventory $snapshot).Count | Should -Be 1
    }

    It 'scans first when there is no scan yet' {
        Remove-Item -LiteralPath (Join-Path (InModuleScope PSPhoenix { Get-PhxStateDir }) 'repos.json')
        Invoke-ReposBackup $snapshot | Should -Match 'no scan yet - scanning'
        @(Read-TestInventory $snapshot).Count | Should -Be 2
    }

    It 'refuses an inventory from a newer PSPhoenix' {
        New-Item -ItemType Directory -Force -Path $snapshot | Out-Null
        Set-Content -LiteralPath (Join-Path $snapshot 'repos.json') -Value '{ "format": 99, "repositories": [] }'
        { Invoke-ReposRestore $snapshot } | Should -Throw '*newer PSPhoenix*'
    }

    It 'is a registered provider with status lines per account' {
        # One (a local file/ remote) needs no account; the GitHub ones do.
        New-TestRepository (Join-Path $reposA 'Mine') -Remote 'origin=https://github.com/WizX20/mine.git' | Out-Null
        New-TestRepository (Join-Path $reposA 'Work') -Remote 'origin=https://github.com/summitnl/work.git' | Out-Null
        InModuleScope PSPhoenix { $c = Read-PhxConfig; $c.accounts['github.com/WizX20'] = 'WizX20'; Save-PhxConfig $c }
        phx scan 6>$null
        Get-PhxOutput { phx providers } | Should -Match 'repos\s+Repositories'
        $lines = @(InModuleScope PSPhoenix { & (Get-PhxProvider 'repos').Status (New-PhxContext -Provider repos -Staging $TestDrive) })
        $lines[0] | Should -Be '4 repositories, 1 without a remote'
        $lines | Should -Contain '  WizX20: 1'
        $lines | Should -Contain '  (host default): 1'
    }
}

Describe 'init' {
    BeforeAll {
        function script:Set-TestAnswer {
            # The answers the next phx init gets, in order; '' is Enter (the default).
            foreach ($answer in $args) { $script:Answers.Enqueue([string]$answer) }
        }
        function script:Read-TestConfig { Get-Content -LiteralPath (InModuleScope PSPhoenix { Get-PhxConfigPath }) -Raw }
    }

    BeforeEach {
        $testHome = Use-TestHome
        $script:InitWork = Join-Path $testHome 'Work'
        $script:InitOther = Join-Path $testHome 'Other'
        New-TestRepository (Join-Path $script:InitWork 'Personal') -Remote 'origin=https://github.com/WizX20/personal.git' | Out-Null
        $helped = New-TestRepository (Join-Path $script:InitWork 'Helped') -Remote 'origin=https://github.com/WizX20/helped.git'
        git -C $helped config --add credential.https://github.com.helper ''
        git -C $helped config --add credential.https://github.com.helper '!f() { gh auth token --user WizX20; }; f'
        New-TestRepository (Join-Path $script:InitWork 'Company') -Remote 'origin=https://github.com/summitnl/app.git' | Out-Null
        New-TestRepository (Join-Path $script:InitOther 'Lab') -Remote 'origin=https://dev.azure.com/org/proj/_git/lab' | Out-Null
        $script:InitEmpty = Join-Path $testHome 'NoRepos'
        New-Item -ItemType Directory -Path $script:InitEmpty | Out-Null
        $script:InitOneDrive = Join-Path $testHome 'OneDrive - Company'
        New-Item -ItemType Directory -Path $script:InitOneDrive | Out-Null
        $env:OneDriveCommercial = $script:InitOneDrive

        $script:Answers = [Collections.Generic.Queue[string]]::new()
        $script:Prompts = [Collections.Generic.List[string]]::new()
        Mock Read-PhxAnswer -ModuleName PSPhoenix {
            $script:Prompts.Add($Prompt)
            $next = $script:Answers.Dequeue()
            if ($next) { $next } else { $Default }
        }
        Mock Get-PhxRootCandidate -ModuleName PSPhoenix { $script:InitWork; $script:InitOther; $script:InitEmpty; (Join-Path $script:InitEmpty 'Missing') }
        Mock Get-PhxGhAccount -ModuleName PSPhoenix {
            [pscustomobject]@{ Host = 'github.com'; Login = 'wpaap'; Active = $true }
            [pscustomobject]@{ Host = 'github.com'; Login = 'WizX20'; Active = $false }
        }
    }

    It 'sets up roots, accounts, target, machine and interval from the defaults and a few answers' {
        # roots, WizX20 account, summitnl account, target, create it?, machine, interval (bad, good), save?
        Set-TestAnswer '' '' '' '' '' '' 'soon' '2h' ''
        $output = Get-PhxOutput { phx init }
        $script:Answers.Count | Should -Be 0
        $config = InModuleScope PSPhoenix { Read-PhxConfig }
        @($config.roots.path) | Should -Be @($script:InitWork, $script:InitOther)
        @($config.roots.depth) | Should -Be @(3, 3)
        $config.accounts['github.com/WizX20'] | Should -Be 'WizX20'      # from its credential helper
        $config.accounts['github.com/summitnl'] | Should -Be 'wpaap'    # the active account
        $config.accounts.Contains('dev.azure.com/org') | Should -BeFalse # not a gh host
        $config.target.type | Should -Be 'folder'
        $config.target.path | Should -Be (Join-Path $script:InitOneDrive 'PSPhoenix')
        Test-Path -LiteralPath $config.target.path | Should -BeTrue
        $config.interval | Should -Be '2h'
        $config.machine.name | Should -Be ([Environment]::MachineName)
        [guid]::Parse($config.machine.id) | Should -Not -BeNullOrEmpty
        $output | Should -Match ('machine\s+' + [regex]::Escape([Environment]::MachineName) + '\s+snapshot in')
        $output | Should -Match '1\. .*Work\s+3 repositories'
        $output | Should -Not -Match 'NoRepos'
        $output | Should -Match 'like 30m, 1h or 1d'
        $output | Should -Not -Match 'company storage'
        $output | Should -Match 'saved .*next: phx status'
        $script:Prompts[-1] | Should -BeExactly "Save to $(InModuleScope PSPhoenix { Get-PhxConfigPath })? (Y/n)"
        # The scan of the chosen roots is saved with the config.
        $cache = InModuleScope PSPhoenix { Read-PhxRepoCache }
        @($cache.roots.path) | Should -Be @($script:InitWork, $script:InitOther)
        @($cache.repositories).Count | Should -Be 4
    }

    It 'changes nothing when run again with Enter all the way' {
        Set-TestAnswer '' '' '' '' '' '' '' ''
        phx init 6>$null
        $before = Read-TestConfig
        # roots, two accounts, target (exists now), machine, interval, save?
        Set-TestAnswer '' '' '' '' '' '' ''
        Get-PhxOutput { phx init } | Should -Match '\(current\)'
        $script:Answers.Count | Should -Be 0
        Read-TestConfig | Should -Be $before
    }

    It 'stops without saving on q at the <Question> question' -ForEach @(
        @{ Question = 'roots'; At = 0 }
        @{ Question = 'first account'; At = 1 }
        @{ Question = 'second account'; At = 2 }
        @{ Question = 'target'; At = 3 }
        @{ Question = 'create-the-target'; At = 4 }
        @{ Question = 'machine'; At = 5 }
        @{ Question = 'interval'; At = 6 }
        @{ Question = 'save'; At = 7 }
    ) {
        $answers = @(@('') * $At) + 'q'
        Set-TestAnswer @answers
        Get-PhxOutput { phx init } | Should -Match 'stopped - nothing saved'
        $? | Should -BeTrue
        $script:Prompts | Should -HaveCount ($At + 1)
        Test-Path -LiteralPath (InModuleScope PSPhoenix { Get-PhxConfigPath }) | Should -BeFalse
        Test-Path -LiteralPath (InModuleScope PSPhoenix { Get-PhxRepoCachePath }) | Should -BeFalse
    }

    It 'leaves the last scan alone when stopped after scanning other roots' {
        Set-TestAnswer '' '' '' '' '' '' '' ''
        phx init 6>$null
        $cachePath = InModuleScope PSPhoenix { Get-PhxRepoCachePath }
        $before = Get-Content -LiteralPath $cachePath -Raw
        # Other holds only an Azure DevOps repository: no account questions, so q answers the target.
        Set-TestAnswer $script:InitOther 'q'
        Get-PhxOutput { phx init } | Should -Match 'Other\s+1 repositories'
        Get-Content -LiteralPath $cachePath -Raw | Should -Be $before
    }

    It 'saves nothing when the last answer is no' {
        Set-TestAnswer '' '' '' '' '' '' '' 'n'
        Get-PhxOutput { phx init } | Should -Match 'not confirmed - nothing saved'
        Test-Path -LiteralPath (InModuleScope PSPhoenix { Get-PhxConfigPath }) | Should -BeFalse
    }

    It 'asks again for roots it cannot use, and takes a typed path' {
        $nope = Join-Path $testHome 'nope'
        Set-TestAnswer '7' $nope '1,1' $script:InitOther '' '' '' '' ''
        $output = Get-PhxOutput { phx init }
        $output | Should -Match 'there is no number 7 in the list'
        $output | Should -Match ([regex]::Escape("no such folder: $nope"))
        $output | Should -Match 'is a root already'
        @((InModuleScope PSPhoenix { Read-PhxConfig }).roots.path) | Should -Be @($script:InitOther)
    }

    It 'asks again for an account gh does not have, and stores its exact spelling' {
        # WizX20's owner first (two repositories): a login gh lacks, then Enter; summitnl: typed in lower case.
        Set-TestAnswer '1' 'nobody' '' 'wizx20' '' '' '' '' ''
        Get-PhxOutput { phx init } | Should -Match 'one of: wpaap, WizX20'
        $script:Answers.Count | Should -Be 0
        (InModuleScope PSPhoenix { Read-PhxConfig }).accounts['github.com/summitnl'] | Should -BeExactly 'WizX20'
    }

    It 'keeps an account that is set when gh is not logged in with it' {
        Set-TestAnswer '' '' '' '' '' '' '' ''
        phx init 6>$null
        $before = Read-TestConfig
        # gh now knows only WizX20: summitnl's wpaap stays the default, and Enter keeps it.
        Mock Get-PhxGhAccount -ModuleName PSPhoenix { [pscustomobject]@{ Host = 'github.com'; Login = 'WizX20'; Active = $true } }
        # roots, summitnl account (asked: its account is not logged in), target, machine, interval, save?
        Set-TestAnswer '' '' '' '' '' ''
        Get-PhxOutput { phx init } | Should -Match 'github.com/summitnl uses wpaap, but gh is not logged in as wpaap'
        $script:Answers.Count | Should -Be 0
        Read-TestConfig | Should -Be $before
    }

    It 'skips the accounts when gh is not logged in' {
        Mock Get-PhxGhAccount -ModuleName PSPhoenix { }
        Set-TestAnswer '' '' '' '' '' ''
        Get-PhxOutput { phx init } | Should -Match 'gh is not logged in'
        (InModuleScope PSPhoenix { Read-PhxConfig }).accounts.Count | Should -Be 0
    }

    It 'asks again for a target number that is not in the list' {
        # roots, two accounts, target (5, a number too big for an int, Enter), create it?, machine, interval, save?
        Set-TestAnswer '' '' '' '5' '99999999999' '' '' '' '' ''
        $output = Get-PhxOutput { phx init }
        $output | Should -Match 'there is no number 5 in the list'
        $output | Should -Match 'there is no number 99999999999 in the list'
        $script:Answers.Count | Should -Be 0
        (InModuleScope PSPhoenix { Read-PhxConfig }).target.path | Should -Be (Join-Path $script:InitOneDrive 'PSPhoenix')
    }

    It 'takes an interval from 15m to 31d' {
        # roots, two accounts, target, create it?, machine, interval (three refused), save?
        Set-TestAnswer '' '' '' '' '' '' '14m' '99999999999m' '32d' '31d' ''
        $output = Get-PhxOutput { phx init }
        [regex]::Matches($output, 'from 15m to 31d').Count | Should -Be 3
        (InModuleScope PSPhoenix { Read-PhxConfig }).interval | Should -Be '31d'
        InModuleScope PSPhoenix {
            foreach ($good in '15m', '1h', '1d', '44640m', '744h') { Test-PhxInterval $good | Should -BeTrue -Because $good }
            foreach ($bad in '', '14m', '0h', '1w', '32d', '1.5h', '99999999999m', ' 1h') { Test-PhxInterval $bad | Should -BeFalse -Because $bad }
        }
    }

    It 'asks again for a machine name that is no folder name, and stores the typed one' {
        # roots, two accounts, target, create it?, machine (bad, good), interval, save?
        Set-TestAnswer '' '' '' '' '' 'my laptop' 'Laptop-2026' '' ''
        Get-PhxOutput { phx init } | Should -Match 'letters, digits, dot, dash and underscore, please'
        $script:Answers.Count | Should -Be 0
        (InModuleScope PSPhoenix { Read-PhxConfig }).machine.name | Should -Be 'Laptop-2026'
    }

    It 'does not take the folder of another installation of this machine' {
        # A reinstalled machine with the same name: its old snapshot is what a restore needs.
        $other = Join-Path (Join-Path $script:InitOneDrive 'PSPhoenix') 'Box'
        New-Item -ItemType Directory -Force -Path $other | Out-Null
        Set-Content -LiteralPath (Join-Path $other 'phoenix.json') -Value '{ "format": 1, "machine": { "name": "Box", "id": "11111111-1111-1111-1111-111111111111" }, "updatedAt": "2026-10-01T08:00:00Z" }'
        # roots, two accounts, target, machine (taken, then the suggested free one), interval, save?
        Set-TestAnswer '' '' '' '' 'Box' '' '' ''
        $output = Get-PhxOutput { phx init }
        $output | Should -Match 'Box holds the snapshot of another installation'
        $script:Answers.Count | Should -Be 0
        (InModuleScope PSPhoenix { Read-PhxConfig }).machine.name | Should -Be 'Box-2'
    }

    It 'takes a typed target folder, and says where company data belongs' {
        $usb = Join-Path $testHome 'USB'
        New-Item -ItemType Directory -Path $usb | Out-Null
        Set-TestAnswer '' '' '' $usb '' '' ''
        Get-PhxOutput { phx init } | Should -Match 'company storage'
        (InModuleScope PSPhoenix { Read-PhxConfig }).target.path | Should -Be $usb
    }
}

Describe 'status' {
    BeforeEach {
        $testHome = Use-TestHome
        $repos = Join-Path $testHome 'Repos'
        New-TestRepository (Join-Path $repos 'Mine') -Remote 'origin=https://github.com/WizX20/mine.git' | Out-Null
        New-TestRepository (Join-Path $repos 'Work') -Remote 'origin=https://github.com/summitnl/work.git' | Out-Null
        New-TestRepository (Join-Path $repos 'Scratch') | Out-Null
        $target = Join-Path $testHome 'Target'
        New-Item -ItemType Directory -Path $target | Out-Null
        Mock Get-PhxGhAccount -ModuleName PSPhoenix {
            [pscustomobject]@{ Host = 'github.com'; Login = 'wpaap'; Active = $true }
            [pscustomobject]@{ Host = 'github.com'; Login = 'WizX20'; Active = $false }
        }

        function Set-TestConfig {
            param([string]$WorkAccount = 'wpaap', [string]$TargetPath = $target)
            InModuleScope PSPhoenix -Parameters @{ Root = $repos; Target = $TargetPath; Work = $WorkAccount } {
                param($Root, $Target, $Work)
                $c = Read-PhxConfig
                $c.roots = @([ordered]@{ path = $Root; depth = 3 })
                $c.target = [ordered]@{ type = 'folder'; path = $Target }
                $c.accounts['github.com/WizX20'] = 'WizX20'
                $c.accounts['github.com/summitnl'] = $Work
                Save-PhxConfig $c
            }
        }
    }

    It 'says when nothing is set up yet' {
        Get-PhxOutput { phx status } | Should -Match 'not set up yet - run: phx init'
    }

    It 'stops with an error of phx on a config it cannot read' {
        $configPath = InModuleScope PSPhoenix { Get-PhxConfigPath }
        New-Item -ItemType Directory -Force -Path (Split-Path $configPath -Parent) | Out-Null
        Set-Content -LiteralPath $configPath -Value '{ not json'
        phx status -ErrorAction SilentlyContinue -ErrorVariable failure 6>$null
        $? | Should -BeFalse
        $record = $failure | Where-Object FullyQualifiedErrorId -Like 'PhxCommandFailed*' | Select-Object -First 1
        $record.Exception.Message | Should -BeLike '*not valid JSON*'
    }

    It 'shows the set-up, and finds nothing that needs attention' {
        Set-TestConfig
        phx scan 6>$null
        $output = Get-PhxOutput { phx status }
        $output | Should -Match ('target\s+' + [regex]::Escape($target))
        $output | Should -Match ('root\s+' + [regex]::Escape($repos) + '\s+depth 3\s+3 repositories')
        $output | Should -Match 'scan\s+just now'
        $output | Should -Match 'repos\s+3 repositories, 1 without a remote'
        $output | Should -Match 'WizX20: 1'
        $output | Should -Match 'account\s+wpaap on github.com \(1 repositories\) - logged in to gh'
        $output | Should -Match 'last run\s+arrives with M2'
        $output | Should -Match 'nothing needs attention'
    }

    It 'needs no gh account for a repository cloned over SSH' {
        git -C (Join-Path $repos 'Work') remote set-url origin 'git@github.com:summitnl/work.git'
        Set-TestConfig -WorkAccount 'Ghost'
        phx scan 6>$null
        $output = Get-PhxOutput { phx status }
        $output | Should -Not -Match 'Ghost on github.com'
        $output | Should -Match 'nothing needs attention'
    }

    It 'says when gh could not check an account, without counting it as a problem' {
        Set-TestConfig
        phx scan 6>$null
        Mock Get-PhxGhAccount -ModuleName PSPhoenix {
            [pscustomobject]@{ Host = 'github.com'; Login = 'wpaap'; Active = $true; Verified = $false }
            [pscustomobject]@{ Host = 'github.com'; Login = 'WizX20'; Active = $false; Verified = $true }
        }
        $output = Get-PhxOutput { phx status }
        $output | Should -Match 'wpaap on github.com \(1 repositories\) - logged in to gh, not checked'
        $output | Should -Match 'nothing needs attention'
    }

    It 'warns about an account gh is not logged in with' {
        Set-TestConfig -WorkAccount 'Ghost'
        phx scan 6>$null
        $output = Get-PhxOutput { phx status }
        $output | Should -Match 'Ghost on github.com \(1 repositories\) - not logged in to gh: gh auth login --hostname github.com'
        $output | Should -Match '1 thing\(s\) need attention'
    }

    It 'warns about a missing target, a missing root folder and a missing scan' {
        Set-TestConfig -TargetPath (Join-Path $testHome 'Unplugged')
        Remove-Item -LiteralPath $repos -Recurse -Force
        $output = Get-PhxOutput { phx status }
        $output | Should -Match 'Unplugged - folder not found'
        $output | Should -Match 'depth 3\s+folder not found'
        $output | Should -Match 'not scanned yet - phx scan'
        $output | Should -Match '3 thing\(s\) need attention'
    }

    It "keeps going when a provider's status fails" {
        Set-TestConfig
        InModuleScope PSPhoenix {
            $script:SavedProviders = [ordered]@{}
            foreach ($key in $script:PhxProviders.Keys) { $script:SavedProviders[$key] = $script:PhxProviders[$key] }
            Register-PhxProvider @{ Name = 'broken'; Description = 'b'; Backup = {}; Restore = {}; Status = { throw 'boom' } }
        }
        try { Get-PhxOutput { phx status } | Should -Match 'broken\s+status failed: boom' }
        finally { InModuleScope PSPhoenix { $script:PhxProviders = $script:SavedProviders } }
    }

    It 'says how long ago, in words' {
        InModuleScope PSPhoenix {
            Format-PhxAge ([DateTime]::UtcNow) | Should -Be 'just now'
            Format-PhxAge ([DateTime]::UtcNow.AddSeconds(-90)) | Should -Be '1 minute ago'
            Format-PhxAge ([DateTime]::UtcNow.AddMinutes(-30)) | Should -Be '30 minutes ago'
            Format-PhxAge ([DateTime]::UtcNow.AddMinutes(-61)) | Should -Be '1 hour ago'
            Format-PhxAge ([DateTime]::UtcNow.AddHours(-5)) | Should -Be '5 hours ago'
            Format-PhxAge ([DateTime]::UtcNow.AddDays(-3)) | Should -Be '3 days ago'
        }
    }

    It 'names the snapshot folder, and warns when another installation wrote it' {
        Set-TestConfig
        phx scan 6>$null
        InModuleScope PSPhoenix { $c = Read-PhxConfig; $c.machine = [ordered]@{ name = 'Box'; id = 'mine' }; Save-PhxConfig $c }
        Get-PhxOutput { phx status } | Should -Match ('machine\s+Box\s+snapshot in ' + [regex]::Escape((Join-Path $target 'Box')))
        New-Item -ItemType Directory -Path (Join-Path $target 'Box') | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'Box/phoenix.json') -Value '{ "format": 1, "machine": { "id": "theirs" } }'
        $output = Get-PhxOutput { phx status }
        $output | Should -Match 'holds the snapshot of another installation'
        $output | Should -Match '1 thing\(s\) need attention'
    }

    It 'warns about a target it cannot write to' {
        Set-TestConfig
        phx scan 6>$null
        Mock Test-PhxWritableFolder -ModuleName PSPhoenix { $false }
        $output = Get-PhxOutput { phx status }
        $output | Should -Match 'cannot write there'
        $output | Should -Match '1 thing\(s\) need attention'
    }

    It 'probes a folder for writing without leaving anything behind' {
        $folder = Join-Path $testHome 'Probe'
        New-Item -ItemType Directory -Path $folder | Out-Null
        InModuleScope PSPhoenix -Parameters @{ Folder = $folder } {
            param($Folder)
            Test-PhxWritableFolder $Folder | Should -BeTrue
            Test-PhxWritableFolder (Join-Path $Folder 'Missing') | Should -BeFalse
        }
        @(Get-ChildItem -LiteralPath $folder -Force).Count | Should -Be 0
    }

    It 'counts only the configured roots, and says which one the last scan did not cover' {
        # Scanned: Repos and Extra. Then Extra is removed and New added - neither scanned that way.
        $extra = Join-Path $testHome 'Extra'
        New-TestRepository (Join-Path $extra 'Gone') -Remote 'origin=https://github.com/summitnl/gone.git' | Out-Null
        $new = Join-Path $testHome 'New'
        New-Item -ItemType Directory -Path $new | Out-Null
        Set-TestConfig
        phx roots add $extra 6>$null
        phx scan 6>$null
        phx roots rm $extra 6>$null
        phx roots add $new 6>$null
        $output = Get-PhxOutput { phx status }
        $output | Should -Match ([regex]::Escape($new) + '\s+depth 3\s+not scanned')
        $output | Should -Match '1 root\(s\) not scanned yet - phx scan'
        $output | Should -Match 'repos\s+3 repositories, 1 without a remote'
        $output | Should -Match 'account\s+wpaap on github.com \(1 repositories\)'
        $output | Should -Not -Match ([regex]::Escape($extra))
    }

    It 'warns about a scan time it cannot read, and says once that it ignores a broken cache' {
        Set-TestConfig
        phx scan 6>$null
        $cachePath = InModuleScope PSPhoenix { Get-PhxRepoCachePath }
        $cache = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json -AsHashtable
        $cache.scannedAt = 'some day'
        Set-Content -LiteralPath $cachePath -Value ($cache | ConvertTo-Json -Depth 10)
        Get-PhxOutput { phx status } | Should -Match 'scan\s+time unknown - phx scan refreshes it'

        Set-Content -LiteralPath $cachePath -Value 'not json'
        $output = Get-PhxOutput { phx status }
        [regex]::Matches($output, 'ignoring ').Count | Should -Be 1
        $output | Should -Match 'not scanned yet - phx scan'
    }
}

Describe 'init without a console' {
    BeforeEach {
        Use-TestHome | Out-Null
        Mock Get-PhxRootCandidate -ModuleName PSPhoenix { }
        Mock Get-PhxGhAccount -ModuleName PSPhoenix { }
    }

    It 'stops at the end of input instead of asking again or taking every default' {
        # Read-Host gives nothing at all once redirected input has run out.
        Mock Read-Host -ModuleName PSPhoenix { }
        Get-PhxOutput { phx init } | Should -Match 'input ended - nothing saved'
        Should -Invoke Read-Host -ModuleName PSPhoenix -Times 1 -Exactly
        Test-Path -LiteralPath (InModuleScope PSPhoenix { Get-PhxConfigPath }) | Should -BeFalse
    }

}

Describe 'snapshot' {
    BeforeEach {
        $testHome = Use-TestHome
        $script:Target = Join-Path $testHome 'Target'
        function Set-TestMachine {
            # A config whose target is $script:Target, as machine $Name with id $Id.
            param([string]$Name, [string]$Id)
            InModuleScope PSPhoenix -Parameters @{ Target = $script:Target; Name = $Name; Id = $Id } {
                param($Target, $Name, $Id)
                $c = Read-PhxConfig
                $c.target = [ordered]@{ type = 'folder'; path = $Target }
                $c.machine = [ordered]@{ name = $Name; id = $Id }
                Save-PhxConfig $c
            }
        }
        function Set-TestStaged {
            # The staged files of a provider: relative path -> content; an empty value removes it.
            param([string]$Provider, [hashtable]$Files)
            $staging = InModuleScope PSPhoenix -Parameters @{ Provider = $Provider } { param($Provider) Get-PhxStagingPath $Provider }
            foreach ($relative in $Files.Keys) {
                $path = Join-Path $staging $relative
                if ($Files[$relative]) {
                    New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
                    [IO.File]::WriteAllText($path, $Files[$relative])
                }
                elseif (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
            }
        }
        function Invoke-TestPublish {
            param([string[]]$Provider)
            InModuleScope PSPhoenix -Parameters @{ Provider = $Provider } { param($Provider) Publish-PhxSnapshot -Config (Read-PhxConfig) -Provider $Provider }
        }
    }

    It 'publishes each provider into its own folder, with phoenix.json and the config' {
        Set-TestMachine 'Box' 'id-1'
        Set-TestStaged repos @{ 'repos.json' = '{ "format": 1 }' }
        Set-TestStaged wip @{ 'github.com/o/r.bundle' = 'bundle' }
        $results = Invoke-TestPublish repos, wip
        $results['repos'].Written | Should -Be 1
        $snapshot = Join-Path $script:Target 'Box'
        Get-Content -LiteralPath (Join-Path $snapshot 'repos/repos.json') -Raw | Should -Be '{ "format": 1 }'
        Test-Path -LiteralPath (Join-Path $snapshot 'wip/github.com/o/r.bundle') | Should -BeTrue
        $info = Get-Content -LiteralPath (Join-Path $snapshot 'phoenix.json') -Raw | ConvertFrom-Json -AsHashtable
        $info.format | Should -Be 1
        $info.machine.name | Should -Be 'Box'
        $info.machine.id | Should -Be 'id-1'
        @($info.providers.Keys) | Should -Be @('repos', 'wip')
        $info.providers.repos.files | Should -Be 1
        (Get-Content -LiteralPath (Join-Path $snapshot 'config.json') -Raw | ConvertFrom-Json -AsHashtable).machine.name | Should -Be 'Box'
    }

    It 'writes nothing when nothing changed' {
        Set-TestMachine 'Box' 'id-1'
        Set-TestStaged repos @{ 'repos.json' = 'one'; 'sub/extra.txt' = 'two' }
        Invoke-TestPublish repos | Out-Null
        $snapshot = Join-Path $script:Target 'Box'
        $before = @(Get-ChildItem -LiteralPath $snapshot -Recurse -File | ForEach-Object { "$($_.FullName)|$($_.LastWriteTimeUtc.Ticks)" })
        Start-Sleep -Milliseconds 50
        $results = Invoke-TestPublish repos
        $results['repos'].Written | Should -Be 0
        $results['repos'].Unchanged | Should -Be 2
        @(Get-ChildItem -LiteralPath $snapshot -Recurse -File | ForEach-Object { "$($_.FullName)|$($_.LastWriteTimeUtc.Ticks)" }) | Should -Be $before
    }

    It 'writes a changed file, removes one no longer staged, and the folders left empty' {
        Set-TestMachine 'Box' 'id-1'
        Set-TestStaged repos @{ 'repos.json' = 'one'; 'deep/er/old.txt' = 'old' }
        Invoke-TestPublish repos | Out-Null
        Set-TestStaged repos @{ 'repos.json' = 'changed'; 'deep/er/old.txt' = '' }
        # A temporary file a crashed run left behind goes too.
        $stale = Join-Path $script:Target 'Box/repos/.repos.json.dead.tmp'
        Set-Content -LiteralPath $stale -Value 'half'
        $result = (Invoke-TestPublish repos)['repos']
        $result.Written | Should -Be 1
        $result.Removed | Should -Be 2
        Get-Content -LiteralPath (Join-Path $script:Target 'Box/repos/repos.json') -Raw | Should -Be 'changed'
        Test-Path -LiteralPath (Join-Path $script:Target 'Box/repos/deep') | Should -BeFalse
        Test-Path -LiteralPath $stale | Should -BeFalse
        $info = Get-Content -LiteralPath (Join-Path $script:Target 'Box/phoenix.json') -Raw | ConvertFrom-Json -AsHashtable
        $info.providers.repos.files | Should -Be 1
    }

    It 'keeps two machines side by side in one target' {
        Set-TestMachine 'Desk' 'id-desk'
        Set-TestStaged repos @{ 'repos.json' = 'desk' }
        Invoke-TestPublish repos | Out-Null
        Use-TestHome | Out-Null
        Set-TestMachine 'Laptop' 'id-laptop'
        Set-TestStaged repos @{ 'repos.json' = 'laptop' }
        Invoke-TestPublish repos | Out-Null
        Get-Content -LiteralPath (Join-Path $script:Target 'Desk/repos/repos.json') -Raw | Should -Be 'desk'
        Get-Content -LiteralPath (Join-Path $script:Target 'Laptop/repos/repos.json') -Raw | Should -Be 'laptop'
    }

    It 'refuses the folder of another installation, and one of a newer PSPhoenix' {
        Set-TestMachine 'Box' 'id-old'
        Set-TestStaged repos @{ 'repos.json' = 'the old one' }
        Invoke-TestPublish repos | Out-Null
        # Reinstalled under the same name: a new installation, a new id.
        Use-TestHome | Out-Null
        Set-TestMachine 'Box' 'id-new'
        Set-TestStaged repos @{ 'repos.json' = 'empty new machine' }
        { Invoke-TestPublish repos } | Should -Throw '*holds the snapshot of another installation*'
        Get-Content -LiteralPath (Join-Path $script:Target 'Box/repos/repos.json') -Raw | Should -Be 'the old one'

        Set-TestMachine 'Next' 'id-new'
        New-Item -ItemType Directory -Path (Join-Path $script:Target 'Next') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Target 'Next/phoenix.json') -Value '{ "format": 99 }'
        { Invoke-TestPublish repos } | Should -Throw '*written by a newer PSPhoenix*'
    }

    It 'needs a machine id' {
        Set-TestMachine 'Box' ''
        { Invoke-TestPublish repos } | Should -Throw '*no id yet - run phx init*'
    }

    It 'accepts only folder-safe machine names' {
        InModuleScope PSPhoenix {
            foreach ($good in 'Box', 'WOUTER-LT', 'box.home', 'a_b') { Test-PhxMachineName $good | Should -BeTrue -Because $good }
            foreach ($bad in '', 'my laptop', '../x', 'a/b', 'trailing.', '-x', ('x' * 64)) { Test-PhxMachineName $bad | Should -BeFalse -Because $bad }
        }
    }
}

Describe 'prompts' {
    It 'reads an answer with its default, and refuses a console without input' {
        InModuleScope PSPhoenix {
            Mock Read-Host { '  typed  ' }
            Read-PhxAnswer -Prompt 'Q' -Default 'd' | Should -Be 'typed'
            Mock Read-Host { '' }
            Read-PhxAnswer -Prompt 'Q' -Default 'd' | Should -Be 'd'
            Mock Read-Host { }
            { Read-PhxAnswer -Prompt 'Q' -Default 'd' } | Should -Throw -ExceptionType ([OperationCanceledException])
            Mock Read-Host { throw [System.Management.Automation.PSInvalidOperationException]::new('NonInteractive mode') }
            { Read-PhxAnswer -Prompt 'Q' } | Should -Throw '*interactive console*'
        }
    }
}

Describe 'gh wrappers' {
    It 'lists the logged-in accounts from gh auth status --json' {
        InModuleScope PSPhoenix {
            Mock Invoke-PhxGh { '{"hosts":{"github.com":[{"state":"success","active":true,"host":"github.com","login":"wpaap"},{"state":"success","active":false,"host":"github.com","login":"WizX20"},{"state":"error","active":false,"host":"github.com","login":"Broken"}]}}' }
            $accounts = @(Get-PhxGhAccount)
            $accounts.Login | Should -Be @('wpaap', 'WizX20')
            ($accounts | Where-Object Login -EQ 'wpaap').Active | Should -BeTrue
        }
    }

    It 'keeps an account gh could not check while offline, as not verified' {
        InModuleScope PSPhoenix {
            Mock Invoke-PhxGh { '{"hosts":{"github.com":[{"state":"timeout","active":true,"host":"github.com","login":"wpaap"}]}}' }
            $account = @(Get-PhxGhAccount)
            $account.Login | Should -Be 'wpaap'
            $account.Verified | Should -BeFalse
        }
    }

    It 'lists nothing when gh says nothing usable' {
        InModuleScope PSPhoenix {
            Mock Invoke-PhxGh { 'not json' }
            @(Get-PhxGhAccount).Count | Should -Be 0
        }
    }

    It "gets one account's token, or says which login to run" {
        InModuleScope PSPhoenix {
            Mock Invoke-PhxGh { $global:LASTEXITCODE = 0; 'secret-token' } -ParameterFilter { $Arguments -contains 'WizX20' }
            Get-PhxGhToken -Account WizX20 | Should -Be 'secret-token'
            Mock Invoke-PhxGh { $global:LASTEXITCODE = 1 } -ParameterFilter { $Arguments -contains 'Nobody' }
            { Get-PhxGhToken -Account Nobody } | Should -Throw '*no token for Nobody*gh auth login*'
        }
    }

    It 'copes with gh not being installed' {
        InModuleScope PSPhoenix {
            Mock Invoke-PhxGh { throw [System.Management.Automation.CommandNotFoundException]::new('gh') }
            @(Get-PhxGhAccount).Count | Should -Be 0
            { Get-PhxGhToken -Account WizX20 } | Should -Throw '*gh is not installed*'
        }
    }
}

Describe 'atomic writes' {
    It 'replaces an existing file and leaves no temporary file behind' {
        $root = Use-TestHome
        $path = Join-Path $root 'a [b] c/file.json'
        InModuleScope PSPhoenix -Parameters @{ Path = $path } {
            param($Path)
            Write-PhxTextFile -Path $Path -Value 'one'
            Write-PhxTextFile -Path $Path -Value 'two'
        }
        Get-Content -LiteralPath $path -Raw | Should -Be 'two'
        @(Get-ChildItem -LiteralPath (Split-Path $path) -Force).Name | Should -Be @('file.json')
    }

    It 'never lets a reader find the file missing while it is replaced' {
        # Move-Item -Force deletes the target before moving: a reader polling in between saw no
        # file in about one check of seven. A rename over the target leaves no such moment.
        $root = Use-TestHome
        $path = Join-Path $root 'config.json'
        $stop = Join-Path $root 'stop'
        InModuleScope PSPhoenix -Parameters @{ Path = $path } { param($Path) Write-PhxTextFile -Path $Path -Value '0' }
        $reader = Start-ThreadJob -ScriptBlock {
            $misses = 0
            while (-not [IO.File]::Exists($using:stop)) { if (-not [IO.File]::Exists($using:path)) { $misses++ } }
            $misses
        }
        try {
            InModuleScope PSPhoenix -Parameters @{ Path = $path } {
                param($Path)
                foreach ($i in 1..300) { Write-PhxTextFile -Path $Path -Value "$i" }
            }
        }
        finally { [IO.File]::WriteAllText($stop, '') }
        $misses = $reader | Wait-Job | Receive-Job
        Remove-Job $reader
        $misses | Should -Be 0
    }
}

Describe 'provider registry' {
    BeforeEach {
        InModuleScope PSPhoenix { $script:SavedProviders = $script:PhxProviders; $script:PhxProviders = [ordered]@{} }
    }
    AfterEach {
        InModuleScope PSPhoenix { $script:PhxProviders = $script:SavedProviders }
    }

    It 'registers a complete provider and defaults it to every platform' {
        InModuleScope PSPhoenix {
            Register-PhxProvider @{ Name = 'demo'; Description = 'demo'; Backup = {}; Restore = {}; Status = {} }
            (Get-PhxProvider 'demo').Platforms | Should -Be @('Windows', 'Linux', 'macOS')
            @(Get-PhxProvider).Name | Should -Contain 'demo'
        }
    }

    It 'rejects a provider without <Missing>' -ForEach @(
        @{ Missing = 'Name' }, @{ Missing = 'Backup' }, @{ Missing = 'Restore' }, @{ Missing = 'Status' }, @{ Missing = 'Description' }
    ) {
        InModuleScope PSPhoenix -Parameters @{ Missing = $Missing } {
            param($Missing)
            $p = @{ Name = 'demo'; Description = 'demo'; Backup = {}; Restore = {}; Status = {} }
            $p.Remove($Missing)
            { Register-PhxProvider $p } | Should -Throw "*missing '$Missing'*"
        }
    }

    It 'rejects a non-scriptblock action, an unknown platform and a duplicate name' {
        InModuleScope PSPhoenix {
            { Register-PhxProvider @{ Name = 'a'; Description = 'a'; Backup = 'nope'; Restore = {}; Status = {} } } |
                Should -Throw '*must be a scriptblock*'
            { Register-PhxProvider @{ Name = 'b'; Description = 'b'; Backup = {}; Restore = {}; Status = {}; Platforms = @('Amiga') } } |
                Should -Throw '*unknown platform*'
            Register-PhxProvider @{ Name = 'c'; Description = 'c'; Backup = {}; Restore = {}; Status = {} }
            { Register-PhxProvider @{ Name = 'c'; Description = 'c'; Backup = {}; Restore = {}; Status = {} } } |
                Should -Throw '*registered twice*'
        }
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'an unknown key (a typo of Platforms)'; Extra = @{ Platform = @('Windows') }; Message = '*unknown key(s) Platform*' }
        @{ Case = 'a name with a path in it'; Extra = @{ Name = '../evil' }; Message = '*lowercase letters*' }
        @{ Case = 'a blank name'; Extra = @{ Name = ' ' }; Message = '*lowercase letters*' }
        @{ Case = 'an upper-case name'; Extra = @{ Name = 'Winget' }; Message = '*lowercase letters*' }
        @{ Case = 'an empty Platforms'; Extra = @{ Platforms = @() }; Message = '*Platforms is empty*' }
        @{ Case = 'a Cadence that is not a duration'; Extra = @{ Cadence = 'banana' }; Message = "*Cadence 'banana'*" }
        @{ Case = 'a zero Cadence'; Extra = @{ Cadence = '0h' }; Message = "*Cadence '0h'*" }
    ) {
        InModuleScope PSPhoenix -Parameters @{ Extra = $Extra; Message = $Message } {
            param($Extra, $Message)
            $p = @{ Name = 'demo'; Description = 'demo'; Backup = {}; Restore = {}; Status = {} }
            foreach ($key in $Extra.Keys) { $p[$key] = $Extra[$key] }
            { Register-PhxProvider $p } | Should -Throw $Message
        }
    }

    It 'accepts a cadence in minutes, hours or days' {
        InModuleScope PSPhoenix {
            foreach ($cadence in '30m', '1h', '7d') {
                Register-PhxProvider @{ Name = "p$cadence"; Description = 'd'; Backup = {}; Restore = {}; Status = {}; Cadence = $cadence }
            }
            (Get-PhxProvider 'p7d').Cadence | Should -Be '7d'
        }
    }

    It 'lists only the providers for the current platform' {
        InModuleScope PSPhoenix {
            $here = Get-PhxCurrentPlatform
            $elsewhere = @('Windows', 'Linux', 'macOS') | Where-Object { $_ -ne $here } | Select-Object -First 1
            Register-PhxProvider @{ Name = 'here'; Description = 'h'; Backup = {}; Restore = {}; Status = {}; Platforms = @($here) }
            Register-PhxProvider @{ Name = 'away'; Description = 'a'; Backup = {}; Restore = {}; Status = {}; Platforms = @($elsewhere) }
            @(Get-PhxProvider).Name | Should -Be @('here')
            (Get-PhxProvider 'away').Name | Should -Be 'away'
        }
    }

    It 'phx providers says so when nothing is registered' {
        Get-PhxOutput { phx providers } | Should -Match 'no providers registered yet'
    }
}

Describe 'test hygiene' {
    # Last in the file on purpose: it reads what every test before it left behind.
    It 'never reached the real gh' {
        $script:GhLeaks.Count | Should -Be 0 -Because "these calls went to gh: $($script:GhLeaks -join '; ')"
    }
}
