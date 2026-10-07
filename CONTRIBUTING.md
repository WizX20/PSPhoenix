# Contributing

Thanks for taking the time to contribute to PSPhoenix (`phx`).

This document covers how to file issues, propose changes, and get a pull request merged. For running from source, the tests, and the release pipeline, see [DEVGUIDE.md](DEVGUIDE.md); for what the tool is meant to become, [docs/design.md](docs/design.md).

By participating in this project you agree to abide by the [Code of Conduct](CODE_OF_CONDUCT.md).

## Reporting bugs

Open a [GitHub issue](https://github.com/WizX20/PSPhoenix/issues/new/choose) with:

- What you did (the exact `phx` command line, numbered steps)
- What you expected
- What happened — full console output as text
- Your OS, PowerShell version and host, git version, the target type (folder, git) and how you installed `phx`

**Never paste a snapshot, a config with a recipient you care about, or log output without reading it first** — a backup tool handles exactly the files you would not want in a public issue.

## Suggesting features

Open an issue describing the use case before writing code. Anything that changes what gets backed up by default, how secrets are handled, or the snapshot layout needs a short design discussion first — and an update to `docs/design.md` in the PR.

### Issue labels

New issues start as `triage`. After a first look they get a type — `bug`, `enhancement`, `documentation` or `maintenance` — and, once accepted, a status:

- `status/planned` — accepted and on the list; no branch yet
- `status/in-progress` — a branch or PR exists; the PR references the issue (`Fixes #123`) so it closes on merge

An open issue without a status label is an idea, not a commitment. There is no "done" label: merging the PR closes the issue.

## Security issues

Do **not** open a public issue for security-sensitive bugs (anything that could leak a secret into a snapshot, a log or the console). Use GitHub's [private security advisory](https://github.com/WizX20/PSPhoenix/security/advisories/new) on this repo instead.

## Submitting a pull request

1. Fork the repo and create a topic branch off `main`.
2. Make your change. Keep the diff focused — one concern per PR.
3. Run `task check` (PSScriptAnalyzer + Pester). Add or extend a test in `tests/` for behaviour you changed; a new provider comes with a round-trip test.
4. Update [`CHANGELOG.md`](CHANGELOG.md) — add a line under **Unreleased** for any user-visible change. Never edit released sections.
5. Update `Show-PhxHelp` in `src/PSPhoenix/PSPhoenix.psm1` if a command, flag or behaviour changed, and paste the new `task help` output into the README's help block.
6. Update `docs/design.md` if the change deviates from it.
7. Push and open a PR against `main`. Reference any related issue (`Fixes #123`).

CI runs lint + tests on PowerShell 7 on Windows and Linux for every PR — make sure both pass before requesting review.

### Branch naming

- `feature/<short-description>` — new functionality
- `fix/<short-description>` — bug fixes
- `chore/<short-description>` — refactors, build/CI, docs, dependency bumps

### Commit messages

- Imperative subject, ≤72 characters, no trailing period (`Add the winget provider`, not `Added the winget provider.`).
- Optional `feat:` / `fix:` / `chore:` prefix when it adds clarity — match the existing `git log` style.
- Body (when needed): wrap at 72 columns, explain **why** more than what.
- Create new commits — do not amend or force-push published commits.
- Do not skip hooks (`--no-verify`) or signing.

### Code style

- `src/PSPhoenix/PSPhoenix.psm1` holds the loader, the help and the `phx` dispatcher; helpers live in `Private/`, one file per concern; each backup unit is one file in `Providers/`. Only `phx` is exported.
- PowerShell 7.4+. Windows first, but PowerShell 7 on Linux must keep working. Build paths with `Join-Path`; Windows-only tools go behind `$script:OnWindows`.
- External tools (`git`, `gh`, `winget`, `scoop`, `age`, `schtasks`, the registry) are called through small wrapper functions, so tests can mock them and never touch the real machine.
- Console output goes through `Write-Host` with the colour conventions of PSWorktree: green for done, yellow for refused/needs attention, red for errors, dark gray for hints.
- Comments explain *why*, not what; keep them terse.
- 4-space indentation, `PascalCase` Verb-Noun helpers with the `Phx` prefix (`Get-PhxConfigPath`), `$camelCase` locals. `task lint` must stay clean; rule exclusions live in `PSScriptAnalyzerSettings.psd1` with a reason each.

## Releasing

Maintainers only. See [DEVGUIDE.md → Release process](DEVGUIDE.md#release-process).

## Licence

By contributing you agree that your contribution is licensed under the [Business Source License 1.1](LICENSE) (BUSL-1.1), and that the [NOTICE](NOTICE) file is preserved in any redistribution.
