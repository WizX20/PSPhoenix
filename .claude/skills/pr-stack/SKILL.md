---
name: pr-stack
description: Build, update and merge a stack of dependent pull requests in this repository (each PR based on the branch of the one below it) - branches in worktrees, review fixes carried up the stack, Windows and Linux test runs, and the bottom-up merge with `task merge-stack`. Use when a feature is split into stacked PRs, when review findings must be fixed across such a stack, or when asked to merge a stack.
---

# Stacked pull requests

A feature that is too big for one review goes in as a **stack**: PR 1 is based on `main`, PR 2 on
PR 1's branch, and so on. Each PR stays small and reviewable; together they land as one squash
commit per PR on `main`.

Repository rules that apply throughout (CLAUDE.md): GitHub through `git gh`, never plain `gh` or
`gh auth switch`; commit or push only when the user asked; never push to `main`.

## Build the stack

1. One worktree per branch, under `.claude/worktrees/` - never switch branches in the main clone:
   ```powershell
   git worktree add .claude/worktrees/feature-a -b feature/a origin/main
   git worktree add .claude/worktrees/feature-b -b feature/b feature/a
   ```
   Every Bash/PowerShell call starts in the session's primary folder: `cd` (or `Set-Location`)
   into the worktree in the same command, every time.
2. Each PR gets its own changelog fragment (`changelog.d/<branch>.<section>.md`) and its own
   design.md and help changes, so it can be reviewed on its own.
3. Open each PR against the branch below it:
   `git gh pr create --base feature/a --head feature/b ...`. Say in the body that it is part of a
   stack and which PR comes before it.

## Change something low in the stack

Fix it on the lowest branch that owns the code, then carry it up - each branch merges the one
below it, in order:

```powershell
Set-Location .claude/worktrees/feature-b; git merge feature/a     # resolve, commit, push
Set-Location .claude/worktrees/feature-c; git merge feature/b     # and so on to the top
```

- Resolve conflicts towards what both sides meant; a conflict in a list (a switch, an
  environment-variable list, a test block) usually needs both sides.
- Run `task check` on every level you touched, and once at the top also `task test:linux`
  (Docker) - CI runs Linux too, and paths, case and `[uri]` behave differently there.
- Check after each push that every branch still contains the one below it:
  `git merge-base --is-ancestor origin/feature/a origin/feature/b`.

## Merge the stack

Only when the user asks. All checks green first (`git gh pr checks <n>`), then:

```powershell
task merge-stack -- 38 39 40 41 42 43 -WhatIf  # the plan first: nothing pushed or merged
task merge-stack -- 38 39 40 41 42 43          # bottom first
```

`scripts/merge-stack.ps1` merges one PR at a time: it waits for the checks, squash-merges through
GitHub's asynchronous merge API (the only one GitHub accepts for a stacked PR), waits for the
retarget of the next PR to `main`, and - when that one is behind or in conflict - merges `main`
into its branch **without changing its tree**. That is safe because after a squash `main` holds
exactly the merged PR's head, which the next branch already contains; the script checks both and
stops otherwise. A merged PR is skipped, so after a stop: fix the cause and run the same command
again.

Why not by hand: `git gh pr merge` refuses a stacked PR ("must be merged using the asynchronous
merge REST API"), `PUT /pulls/<n>/merge` returns 403, a short SHA fails as "head branch was
modified", and GitHub does not always rebase the next PR itself. "Update branch" in the web UI
merges `main` in with a three-way merge, which can bring back lines the stack had removed (seen
with a changelog line that had moved to a fragment).

## Afterwards

- Check `main` equals the top branch: `git diff --stat origin/main origin/<top-branch>` is empty.
- The milestone's issues close through `Closes #n` in the PR bodies; check
  `git gh issue list --milestone "<milestone>" --state all`.
- Remove the worktrees and the local branches:
  `git worktree remove .claude/worktrees/<name>; git branch -D <branch>` (squash-merged branches
  are not "merged" for `git branch -d`).
