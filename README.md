<p align="center">
  <a href="https://github.com/WizX20/PSPhoenix">
    <img src="docs/psphoenix-logo.png" alt="PSPhoenix" width="420">
  </a>
</p>

# PSPhoenix

[![CI](https://github.com/WizX20/PSPhoenix/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/WizX20/PSPhoenix/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/WizX20/PSPhoenix?label=release)](https://github.com/WizX20/PSPhoenix/releases/latest)

Your machine dies; your code does not - it lives in remotes. What dies with the machine is everything that never left it. PSPhoenix (`phx`) keeps exactly that, quietly in the background, and rebuilds a new machine from it:

- **Which repositories you had** — every remote, the folder it lived in, and which GitHub account it talks to (a personal and a work account side by side included). Tracked files are not copied: a restore clones them.
- **Local-only git work** — unpushed commits, branches without an upstream, stashes, worktrees.
- **Gitignored files that matter** — local config, secrets (encrypted), IDE user files. Never `bin/`, `obj/`, `node_modules/` or NuGet packages, and never anything big or unknown without asking first.
- **Claude Code** — per-project memory (found again after a restore to another folder), settings, skills, commands, agents and MCP servers. Never its credentials.
- **The machine setup** — winget and Scoop packages, your PowerShell profile and modules, Windows Terminal settings, WSL distros, user environment variables, git and SSH config.

> **Status: 0.x preview - not stable yet.** Released and installable, and backing up for real:
>
> - **Built (M1-M3):** the set-up (`phx init`, `phx roots`, `phx scan`, `phx status`), the background run (`phx run`, `phx schedule`), the repository inventory, gitignored files as `phx review` decides, Claude Code's memory and settings, and secrets age-encrypted.
> - **Not yet:** local-only git work (M4), the machine setup (M5) and `phx restore` (M6). Until M6 a snapshot is readable by hand - JSON, plain files and age files - but `phx` cannot rebuild a machine from it yet.
> - **Until 1.0** the config, the state and the snapshot layout may still change between versions; a change that needs it says so in the [Changelog](CHANGELOG.md).
>
> Commands marked `(Mx)` below arrive with that milestone; the [roadmap](docs/design.md#roadmap) and the [milestones](https://github.com/WizX20/PSPhoenix/milestones) show what comes when.

## License

This project is licensed under the [Business Source License 1.1](LICENSE) (BUSL-1.1). Free for personal, internal, academic, and non-commercial redistribution use; resale or paid commercial distribution is not permitted. Converts to Apache 2.0 on the Change Date (2030-10-01). All copies and forks must retain the [NOTICE](NOTICE) file.

## How it works

- **A wizard first.** `phx init` asks where your repositories live — as many folders as you like (`C:\Repos`, `D:\Work`, ...) — where backups go, how often, and walks you through the gitignored files it found. `phx review` does that walk again whenever new ones turn up: a whole folder or a pattern at a time, and a file nobody decided on is not backed up.
- **Then in the background.** A per-user scheduled task runs every hour (configurable). A run with nothing changed compares a few hundred file timestamps and is done; slow inventories such as `winget export` run once a day.
- **Any folder as the target.** OneDrive, Dropbox, a NAS share or a USB disk: PSPhoenix writes plain files, the sync client moves them. A git repository as target follows later.
- **Secrets only encrypted.** A file with a password or token in it — found by its content, not just its name — goes into the snapshot only [age](https://age-encryption.org)-encrypted, to a key `phx init` makes. Keep the key it shows you; a passphrase-protected copy can sit in the target (`key-<id>.age`), so a restore needs only the passphrase. Nothing to install: PSPhoenix speaks age itself.
- **Readable without PSPhoenix.** JSON, plain files, git bundles and age files — recoverable by hand if need be (`age -d -i key-<id>.age file.age`).
- **Restore onto a new layout.** Repositories are known by their remote, not their path: restore into `D:\src` instead of `C:\Repos` and Claude Code still finds its memory.

The full design, including what is not built yet: [docs/design.md](docs/design.md).

## Requirements

- PowerShell 7.4 or later (Windows first; Linux and macOS follow)
- git; `gh` for repositories behind GitHub accounts

## Install

With [Scoop](https://scoop.sh):

```powershell
scoop bucket add psphoenix https://github.com/WizX20/PSPhoenix
scoop install psphoenix
phx help
```

Scoop puts the module on your `PSModulePath`, so `phx` loads itself the first time you type it — in the session that installed it too. Tab completion of the sub-commands arrives with the module; to have it from the first keystroke of every session, add `Import-Module PSPhoenix` to your `$PROFILE`.

```powershell
scoop update psphoenix          # a new version - releases come out weekly when something changed; 0.x: read the Changelog first
scoop uninstall psphoenix
```

Scoop does not install PowerShell 7.4 for you: a dependency would put a second PowerShell next to the one you have from winget or the MSI.

**Without Scoop:** download `PSPhoenix-<version>.zip` from the [latest release](https://github.com/WizX20/PSPhoenix/releases/latest) and extract it into your module folder — the zip holds a `PSPhoenix` folder (on Linux the folder is `~/.local/share/powershell/Modules`):

```powershell
Unblock-File .\PSPhoenix-<version>.zip
Expand-Archive .\PSPhoenix-<version>.zip -DestinationPath (Join-Path (Split-Path $PROFILE.CurrentUserAllHosts) 'Modules')
```

To update, delete that `PSPhoenix` folder and extract the new zip. **From a checkout** (to work on PSPhoenix itself): `task link` - it builds the engine, which needs the .NET SDK 10 or newer - see [DEVGUIDE.md](DEVGUIDE.md#running-from-source).

## Try it

A first run, start to finish - with a target folder of its own, so you can look at what lands there and throw it away:

```powershell
phx init                 # roots, accounts, a target (try a new folder first), machine, key, interval, schedule;
                         # then the review of the gitignored files it found
phx review               # decide on what is still pending - a folder or a pattern at a time
phx run                  # one backup now
phx status               # what is set up, the last run, and what needs attention
```

Then look in `<target>\<machine>`: one folder per provider, `phoenix.json`, your config, and the passphrase-protected copy of your age key. A second `phx run` with nothing changed writes nothing and says how many files it did not read again.

To undo: `phx schedule off`, then remove the target folder, `%APPDATA%\PSPhoenix` (the config) and `%LOCALAPPDATA%\PSPhoenix` (the state).

## Help: `phx help`

```text
phx - PSPhoenix <version>: back up what your machine would lose in a crash, rebuild a new one from it.

Code in a remote is safe already. phx keeps the rest: which repositories you had (remotes,
GitHub account, identity), local-only git work, gitignored local files, Claude Code memory
and settings, and the machine setup - winget, Scoop, PowerShell, Windows Terminal, WSL and
environment variables.

USAGE:
  phx init                        set up or change: roots, accounts, target, machine, key, interval
  phx status                      what is set up, and what needs attention
  phx scan                        re-discover repositories under the roots
  phx roots add|rm|list [<path>]  the folders that hold your repositories; add: -Depth <n>
  phx run [-Provider <name>]      one backup run now (the scheduled task calls this)
  phx schedule on|off|status      the background task; -Every 30m|1h|1d sets the interval
  phx review                      decide which gitignored files to back up
  phx restore [-From <target>]    rebuild this machine from a snapshot                 (M6)
  phx providers                   what gets backed up on this platform
  phx version                     module version
  phx help | -h | --help          show this help

NOTES:
  - (Mx): not built yet, arrives with that milestone - docs/design.md -> Roadmap.
  - config: %APPDATA%\PSPhoenix\config.json
  - module: <module folder>
  - project: https://github.com/WizX20/PSPhoenix
```

## A word on where backups go

A snapshot holds whatever your Claude Code memory and local config hold — for a work machine that is company information. Pick a target inside the boundary that data belongs to: the company OneDrive, or a repository private to your organisation, not a personal account.

## Contributing

Issues and pull requests are welcome — read [CONTRIBUTING.md](CONTRIBUTING.md) first, and [DEVGUIDE.md](DEVGUIDE.md) for the layout, the tests and the release pipeline.
