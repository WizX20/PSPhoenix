<!--
Thanks for the PR! Fill in the sections below — the checklist at the bottom catches the things that bounce most often in review.
-->

## What

<!-- One or two sentences on the change. -->

## Why

<!-- The user-facing problem or use case. Link the issue if there is one: `Fixes #123`. -->

## How it works

<!-- Brief technical note on the approach if non-obvious. Skip for trivial changes. -->

## Testing

<!-- How you verified this. -->

- [ ] `task lint` and `task test` pass locally
- [ ] A new or changed provider has a round-trip test (backup into one fake home, restore into another)
- [ ] No test touches the real machine (home, registry, Task Scheduler, winget/scoop/gh)

## Checklist

- [ ] A changelog fragment in `changelog.d/` (user-visible changes only; see `changelog.d/README.md`) - not an edit to `CHANGELOG.md`.
- [ ] `phx --help` (in `Show-PhxHelp`) updated if a command, flag or behaviour changed — the README quotes it.
- [ ] `docs/design.md` updated if the change deviates from it.
- [ ] No secret, token or private key can end up unencrypted in a snapshot, a log or the console.
- [ ] Commits follow the conventions in [CONTRIBUTING.md](../CONTRIBUTING.md) (imperative subject ≤72 chars, new commits not amends, hooks not skipped).
