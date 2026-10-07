# Developer Guide

Contributor reference for PSPhoenix (`phx`). End-user install and usage live in [README.md](README.md); what the tool is meant to become lives in [docs/design.md](docs/design.md).

## Layout

```
src/PSPhoenix/PSPhoenix.psm1        loader, help, the `phx` dispatcher and its completer
src/PSPhoenix/PSPhoenix.psd1        module manifest (ModuleVersion is the release version)
src/PSPhoenix/Private/*.ps1         helpers, one file per concern (paths, config, provider registry, ...)
src/PSPhoenix/Providers/*.ps1       one file per backup unit; each calls Register-PhxProvider at import
tests/PSPhoenix.Tests.ps1           Pester 5+ suite; never touches the real home, registry or Task Scheduler
docs/design.md                      the design and the roadmap - the contract the code builds towards
changelog.d/                        one release-notes fragment per pull request; the release folds them into CHANGELOG.md
scripts/                            lint / test / pack / set-version / cut-changelog / dev-link
bucket/psphoenix.json               Scoop manifest; this repo doubles as the Scoop bucket
.github/workflows/ci.yml            lint + test on pwsh (Windows and Linux), then pack
.github/workflows/release.yml       weekly / manual release: stamp, test, pack, bump bucket, tag, GitHub Release
.gitconfig                          maintainer-only: makes this clone talk to GitHub as WizX20
Taskfile.yml                        `task --list`
```

The loader dot-sources `Private/` and then `Providers/`, each in file-name order. Only `phx` is exported.

## Running from source

```powershell
task link                       # junction src/PSPhoenix into your CurrentUser module path
Import-Module PSPhoenix -Force  # after every edit
task unlink                     # remove the junction
```

Or skip the junction and load by path: `Import-Module ./src/PSPhoenix -Force`.

Requires **PowerShell 7.4+**, git, and [Task](https://taskfile.dev) for the `task` shortcuts (every task is a one-liner you can also run by hand). Unlike PSWorktree and PSVsCommand there is no Windows PowerShell 5.1 support: the scheduled run, parallel clones (`ForEach-Object -Parallel`), `ConvertFrom-Json -AsHashtable` and the crypto lean on PowerShell 7.

## Tests and lint

```powershell
task check                      # lint + test, what CI runs
task lint                       # PSScriptAnalyzer over src/, scripts/, tests/
task test                       # Pester; `task test -- tests/PSPhoenix.Tests.ps1` for one file
task help                       # print `phx --help` (the README quotes it)
```

- Tests need **Pester 5+** (`Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck`) and lint needs **PSScriptAnalyzer** (`Install-Module PSScriptAnalyzer -Scope CurrentUser`). On CI both are installed on the fly when missing.
- **Nothing in the suite may touch the real machine.** Config and state paths derive from `APPDATA`/`LOCALAPPDATA` (Windows) and `XDG_CONFIG_HOME`/`XDG_STATE_HOME` (elsewhere); `Use-TestHome` points them into `$TestDrive`. Providers follow the same rule: a fake home per test, and anything that reaches outside the file system (the registry, Task Scheduler, `winget`, `scoop`, `gh`) goes through a small wrapper function the tests mock.
- **Every provider gets a round-trip test**: back up into one `$TestDrive` home, restore into another, compare. Git-backed tests build throwaway repositories (a bare `origin` plus a clone) the way PSWorktree's suite does.
- `phx` prints through `Write-Host`; tests capture it with `6>&1` (the `Get-PhxOutput { phx ... }` helper). Call `phx` with real switches inside the block — splatting `'-Provider'` as a string would bind it positionally.
- CI runs the suite on Windows and Linux (pwsh). No `\` in a path that reaches git or gets compared: build paths with `Join-Path`, match separators in test regexes with `[\\/]`.
- When `task help` changes, paste it into the README's help block. Two lines differ per machine — keep `config: %APPDATA%\PSPhoenix\config.json` and `module: <module folder>` there.

## Adding a provider

1. Read [docs/design.md → Provider contract](docs/design.md#provider-contract) and the provider's row in the table.
2. Create `src/PSPhoenix/Providers/<Name>.ps1` that calls `Register-PhxProvider` with `Name`, `Description`, `Platforms`, `Cadence`, and the `Backup`, `Restore` and `Status` scriptblocks. Helpers only that provider needs stay in its file, prefixed `<Name>`.
3. Write the round-trip test first.
4. If the provider deviates from the design, change `docs/design.md` in the same PR.

## GitHub account: everything as WizX20

This repo is published from a machine that also has a work GitHub account logged in to `gh`. Rather than `gh auth switch` back and forth, the repo carries a [`.gitconfig`](.gitconfig) that a maintainer includes once per clone:

```powershell
task setup      # = git config --local include.path ../.gitconfig
```

From then on, inside this clone:

- commits are authored as `WizX20 <…>`;
- `git push` / `git fetch` authenticate as WizX20 — the credential helper obtains that account's token from the keyring at call time via `gh auth token --user WizX20` and hands it to `gh auth git-credential` through `GH_TOKEN` (the CLI's helper otherwise only serves the *active* account);
- `git gh <anything>` (or `task gh -- <anything>`) runs the GitHub CLI the same way: `git gh pr create`, `git gh run watch`, …

Nothing is written to disk and the active `gh` account is untouched. Plain `gh` still uses whatever account is active — use `git gh` in this repo. Contributors never need any of this; without the include the file is inert. (PSPhoenix's own `repos` provider records exactly this kind of repo-local setup, so a restore re-applies it.)

## Release process

The same pipeline as PSWorktree. `.github/workflows/release.yml` runs **once a week, Tuesday 06:00 UTC**, and on manual dispatch:

```powershell
task release                    # release now: next patch version (or the manifest's version if never released)
task release VERSION=0.2.0      # release now with an explicit version
```

The `check` job decides on `main`: anything to release (`main` moved past the last `v*` tag), which version (dispatch input, else an unreleased manifest version, else the next patch), validates it, and waits for CI on that exact commit to be green (an API error, or no CI run after five minutes, refuses the release rather than letting it through). The `release` job then checks out that same commit — not whatever `main` is by then — stamps `ModuleVersion` and the changelog (`scripts/set-version.ps1`, `scripts/cut-changelog.ps1 -FallbackFromGit`), lints and tests the stamped module, packs `dist/PSPhoenix-x.y.z.zip`, bumps `bucket/psphoenix.json` (`version`, `url`, `hash`) and commits `chore: release vx.y.z`. Then, in this order: it drafts the GitHub Release with the zip attached, pushes the commit and tag `vx.y.z` atomically to `main`, and publishes the draft. When `main` moved meanwhile the push is refused, the draft is deleted and nothing is published — run it again. When only publishing fails, the next run stops with the command that publishes the draft by hand (`git gh release edit vx.y.z --draft=false`); until then `scoop install` cannot download the zip.

For a minor or major bump, raise `ModuleVersion` in `src/PSPhoenix/PSPhoenix.psd1` in a PR; the next release ships exactly that.

### First release — not done yet

1. Create `WizX20/PSPhoenix` on GitHub (**public**: Scoop downloads release assets anonymously) and push `main`.
2. Create the `PSPHOENIX_RELEASE_TOKEN` secret (below).
3. Add the ruleset (below), then `task release` once CI is green — it ships the manifest's `0.1.0`. Until then `bucket/psphoenix.json` carries a placeholder hash and `scoop install` fails.

### Required secret: `PSPHOENIX_RELEASE_TOKEN`

`main` is protected by a ruleset that only the repository admin may bypass; `GITHUB_TOKEN` cannot bypass rulesets on a user-owned repository, so the release commit is pushed with a maintainer token:

1. GitHub → Settings → Developer settings → Personal access tokens → **Fine-grained tokens** → Generate. Resource owner `WizX20`, repository access: only `PSPhoenix`, permissions: **Contents: Read and write**. Expiry: one year at most.
2. `git gh secret set PSPHOENIX_RELEASE_TOKEN -R WizX20/PSPhoenix` and paste the token.

CI's **release token expiry** job reads the token's real expiry from the API on every PR and push, and in a weekly scheduled run on Mondays: a warning 30 days out, a failure 14 days out, and a failure when the secret is missing. A failed scheduled run emails the maintainer. GitHub disables scheduled workflows after 60 days without repository activity, so in a very quiet stretch the dated `maintenance` issue and GitHub's own expiry mail are the reminders left.

### Branch rules (ruleset `main`)

To set up on GitHub: **Settings → Rules → Rulesets → main**. Pull request required, `squash` the only merge method, required checks `lint + test (pwsh)`, `lint + test (pwsh-linux)`, `pack module zip` and `release token expiry`, deletion and force-push blocked; bypass list: repository admin only.

## Scoop bucket maintenance

- Manifest: `bucket/psphoenix.json`. The release workflow bumps `version`/`url`/`hash`; `checkver: github` + `autoupdate` let `scoop update` find new releases.
- Users subscribe straight from this repo: `scoop bucket add psphoenix https://github.com/WizX20/PSPhoenix`. With three WizX20 tools now, moving the manifests into one `WizX20/scoop-bucket` repo is worth doing (see PSWorktree's DEVGUIDE).
- `psmodule.name: PSPhoenix` junctions `~/scoop/modules/PSPhoenix` to the install dir; `post_install` patches `PSModulePath` in the running process. No `depends: pwsh`: that would install a second PowerShell next to a winget or MSI one.

## Conventions

- **Design first** — `docs/design.md` is the contract; a PR that deviates changes it too.
- **Changelog** — a user-visible change adds a fragment `changelog.d/<branch>.<section>.md` ([format](changelog.d/README.md)); `scripts/cut-changelog.ps1` folds the fragments into `CHANGELOG.md` at release and deletes them. Never edit released sections.
- **Help text** — `Show-PhxHelp` is the contract; the README quotes it. Change both.
- **Commits** — new commits, no amends of published commits, no skipped hooks.
