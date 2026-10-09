<p align="center">
  <a href="https://github.com/WizX20">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="docs/wizx20.png">
      <img src="docs/wizx20-transparent.png" alt="WizX20" height="140">
    </picture>
  </a>
</p>

# PSPhoenix

[![CI](https://github.com/WizX20/PSPhoenix/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/WizX20/PSPhoenix/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/WizX20/PSPhoenix?label=release)](https://github.com/WizX20/PSPhoenix/releases/latest)

Your machine dies; your code does not - it lives in remotes. What dies with the machine is everything that never left it. PSPhoenix (`phx`) keeps exactly that, quietly in the background, and rebuilds a new machine from it:

- **Which repositories you had** — every remote, the folder it lived in, and which GitHub account it talks to (a personal and a work account side by side included). Tracked files are not copied: a restore clones them.
- **Local-only git work** — unpushed commits, branches without an upstream, stashes, worktrees.
- **Gitignored files that matter** — local config, secrets (encrypted), IDE user files. Never `bin/`, `obj/`, `node_modules/` or NuGet packages, and never anything big or unknown without asking first.
- **Claude Code** — per-project memory, settings, skills and commands.
- **The machine setup** — winget and Scoop packages, your PowerShell profile and modules, Windows Terminal settings, WSL distros, user environment variables, git and SSH config.

> **Status: early development.** Released and installable, but it does not back anything up yet: this is milestone M0 — the module skeleton, the help, and the [design](docs/design.md). Commands marked `(Mx)` below arrive with that milestone. See the [Changelog](CHANGELOG.md) for updates.

## License

This project is licensed under the [Business Source License 1.1](LICENSE) (BUSL-1.1). Free for personal, internal, academic, and non-commercial redistribution use; resale or paid commercial distribution is not permitted. Converts to Apache 2.0 on the Change Date (2030-10-01). All copies and forks must retain the [NOTICE](NOTICE) file.

## How it works

- **A wizard first.** `phx init` asks where your repositories live — as many folders as you like (`C:\Repos`, `D:\Work`, ...) — where backups go, how often, and walks you through the gitignored files it found.
- **Then in the background.** A per-user scheduled task runs every hour (configurable). A run with nothing changed compares a few hundred file timestamps and is done; slow inventories such as `winget export` run once a day.
- **Any folder as the target.** OneDrive, Dropbox, a NAS share or a USB disk: PSPhoenix writes plain files, the sync client moves them. A git repository as target follows later.
- **Readable without PSPhoenix.** JSON, plain files, git bundles and [age](https://age-encryption.org)-encrypted secrets — recoverable by hand if need be.
- **Restore onto a new layout.** Repositories are known by their remote, not their path: restore into `D:\src` instead of `C:\Repos` and Claude Code still finds its memory.

The full design, including what is not built yet: [docs/design.md](docs/design.md).

## Requirements

- PowerShell 7.4 or later (Windows first; Linux and macOS follow)
- git; `gh` for repositories behind GitHub accounts
- [age](https://age-encryption.org) to back up secrets (`scoop install age` or `winget install FiloSottile.age`)

## Install

With [Scoop](https://scoop.sh):

```powershell
scoop bucket add psphoenix https://github.com/WizX20/PSPhoenix
scoop install psphoenix
phx help
```

Scoop puts the module on your `PSModulePath`, so `phx` loads itself the first time you type it — in the session that installed it too. Tab completion of the sub-commands arrives with the module; to have it from the first keystroke of every session, add `Import-Module PSPhoenix` to your `$PROFILE`.

```powershell
scoop update psphoenix          # a new version - releases come out weekly when something changed
scoop uninstall psphoenix
```

Scoop does not install PowerShell 7.4 for you: a dependency would put a second PowerShell next to the one you have from winget or the MSI.

**Without Scoop:** download `PSPhoenix-<version>.zip` from the [latest release](https://github.com/WizX20/PSPhoenix/releases/latest) and extract it into your module folder — the zip holds a `PSPhoenix` folder (on Linux the folder is `~/.local/share/powershell/Modules`):

```powershell
Unblock-File .\PSPhoenix-<version>.zip
Expand-Archive .\PSPhoenix-<version>.zip -DestinationPath (Join-Path (Split-Path $PROFILE.CurrentUserAllHosts) 'Modules')
```

To update, delete that `PSPhoenix` folder and extract the new zip. **From a checkout** (to work on PSPhoenix itself): `task link`, see [DEVGUIDE.md](DEVGUIDE.md#running-from-source).

## Help: `phx help`

```text
phx - PSPhoenix <version>: back up what your machine would lose in a crash, rebuild a new one from it.

Code in a remote is safe already. phx keeps the rest: which repositories you had (remotes,
GitHub account, identity), local-only git work, gitignored local files, Claude Code memory
and settings, and the machine setup - winget, Scoop, PowerShell, Windows Terminal, WSL and
environment variables.

USAGE:
  phx init                        set up: roots, target, interval, secrets, schedule   (M1)
  phx status                      last run, pending review items, local-only work      (M1)
  phx scan                        re-discover repositories under the roots
  phx roots add|rm|list [<path>]  the folders that hold your repositories; add: -Depth <n>
  phx run [-Provider <name>]      one backup run now (the scheduled task calls this)   (M2)
  phx schedule on|off|status      the background task; -Every <n>h sets the interval   (M2)
  phx review                      decide on new gitignored files                       (M3)
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
