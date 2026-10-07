# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

**PSPhoenix** — a PowerShell 7.4+ module (`src/PSPhoenix/`) exporting one command, `phx`: it backs up what a developer machine would lose in a crash — the repository inventory (remotes, GitHub account, repo-local identity), local-only git work, selected gitignored files, Claude Code memory and settings, and the machine setup (winget, Scoop, PowerShell, Windows Terminal, WSL, environment) — and rebuilds a new machine from it. Tracked files are never copied: a restore clones them.

The design and roadmap are in [docs/design.md](docs/design.md) — read it before building anything; it is the contract. Layout, tests and the release pipeline: [DEVGUIDE.md](DEVGUIDE.md). Conventions: [CONTRIBUTING.md](CONTRIBUTING.md).

## GitHub account — always WizX20

This repo is published under the **WizX20** account from a machine whose active `gh` account is a work account. Never run `gh auth switch`. Inside this clone:

- `git push` / `git fetch` already authenticate as WizX20 through the included [`.gitconfig`](.gitconfig) (`task setup` once per clone — check with `git config user.name`, it must print `WizX20`).
- Use **`git gh …`** (or `task gh -- …`) instead of `gh …` for PRs, releases, workflow runs, API calls. Plain `gh` acts as the wrong account.
- Commits must be authored as `WizX20 <nerdsonwaves@outlook.com>`; if `git config user.email` shows anything else, run `task setup` before committing.

## Commands

```powershell
task check        # lint + test — run before every push
task test         # Pester (needs Pester 5+); `task test -- tests/PSPhoenix.Tests.ps1`
task lint         # PSScriptAnalyzer; exclusions + reasons in PSScriptAnalyzerSettings.psd1
task help         # `phx --help` from the working copy — README quotes it, keep both in sync
task link         # dev junction into the CurrentUser module path; `task unlink` undoes
task pack         # dist/PSPhoenix-<version>.zip + sha256
task release [VERSION=x.y.z] # dispatch the Release workflow; it also runs weekly and auto-bumps the patch
```

## Rules

- **Never touch the real machine from a test.** No real `~/.claude`, `$PROFILE`, registry, Task Scheduler, `winget`/`scoop`/`gh` calls: redirect paths into `$TestDrive` (`Use-TestHome`) and mock the thin wrapper functions around external tools. The same goes for trying things out by hand: use a throwaway config dir.
- **Behaviour changes need a Pester test; every provider needs a round-trip test** (backup into one fake home, restore into another, compare). Private helpers are reachable via `InModuleScope PSPhoenix`. Call `phx` with real switches inside `Get-PhxOutput { phx run -Provider repos }`.
- **PowerShell 7.4+**, Windows first, Linux pwsh must keep working (CI runs both): `Join-Path` for paths, `[\\/]` in test regexes, Windows-only tools behind `$script:OnWindows`.
- **Providers**: one file per provider in `src/PSPhoenix/Providers/`, registering through `Register-PhxProvider`. A provider writes only inside its staging folder during backup; every `Restore` is idempotent.
- **Secrets**: only ever written encrypted (age, to the recipient in the config). Never DPAPI, never a token or private key in a snapshot, a log or test output.
- **Design is the contract**: a change that deviates from `docs/design.md` updates it in the same PR.
- **Changelog**: a user-visible change adds a fragment `changelog.d/<branch>.<section>.md` (see `changelog.d/README.md`) - never edit `CHANGELOG.md` in a PR; the release folds the fragments in. Do not touch released sections.
- **Versions**: patch bumps are automatic. For a minor/major, raise `ModuleVersion` in `src/PSPhoenix/PSPhoenix.psd1` in the PR.
- **Help is the contract**: change `Show-PhxHelp` and paste `task help` into the README block.
- **Commits**: imperative subject ≤72 chars, new commits (no amend), no `--no-verify`. Branches `feature/…`, `fix/…`, `chore/…` off `main`.
- **Do not commit or push without asking**; never push to `main` directly — open a PR.
