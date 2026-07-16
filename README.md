# git-stack

A lightweight script for managing **stacked pull requests** on GitHub. Each PR is its own named branch, bases set to the previous branch. GitHub's normal Merge button keeps working — no special landing tool required.

```
main
  │
  ├── feature/part-1   ← base: main
  ├── feature/part-2   ← base: feature/part-1
  └─↦ feature/part-3   ← base: feature/part-2   (you are here)
```

## Install

```bash
curl -sLo ~/.local/bin/git-stack https://raw.githubusercontent.com/fireph/git-stack/main/git-stack
chmod +x ~/.local/bin/git-stack
```

Requires `git` and `gh` (GitHub CLI). Ensure `~/.local/bin` is on your `PATH`.

## Commands

| Command | What it does |
|---|---|
| `git stack list` | Show the stack with PR titles and current-branch arrow |
| `git stack status` | Same as `list` + shows which branches need restacking |
| `git stack rebase [base]` | Rebase the whole stack onto a new base (default `origin/main`) |
| `git stack restack` | Restack the whole stack (after amending any branch) |
| `git stack push [-f]` | Push all branches + update each PR's base on GitHub |
| `git stack annotate [--no-plan]` | Insert/update a stack diagram in each PR's description (+ a collapsible *Full PR Stack Plan* from `plan.md` if present) |

## How it works

**Stack detection** is automatic — no branch naming conventions, no metadata files. The script walks git ancestry (`git merge-base --is-ancestor`) to find branches that chain together relative to the base branch, and bridges amends via the reflog (an amended branch is no longer an ancestor of the branches above it, but its old position still is). Checkout any branch in the stack — even after amending — and it figures out the rest.

**Rebasing** uses `git rebase --onto` under the hood, replaying each branch's full commit range in order so each PR stays on its own branch.

**Restacking** works from any branch in the stack. Each branch owns the full commit range after the historical tip of the branch below it. Using those reflog-backed boundaries, `restack` finds the lowest stale relationship and replays every branch's commits onto its parent's current tip. This handles commits added to or amended on any branch. It only fixes inter-stack relationships — if the whole stack has fallen behind `main`, that's a rebase (run `git stack rebase`), which `git stack status` will tell you.

Before rewriting branches, `restack` and `rebase` refuse to run with uncommitted changes, another Git operation in progress, an ambiguous stack, or a stack branch checked out in another worktree.

This includes amending a commit in the middle of a branch with interactive rebase: although that rewrite changes every descendant commit in the branch, the old branch tip remains in the local reflog and lets `restack` recover the boundary. As with any reflog-based detection, deleting/expiring the relevant reflog entries before restacking can make that rewritten relationship impossible to infer automatically.

**Pushing** force-pushes (`--force-with-lease` by default, `--force` with `-f`) all branches in the stack and sets each PR's base to the previous branch via the GitHub API.

**Annotating** inserts a stack diagram into each PR's description, wrapped in invisible HTML comment markers so it's idempotent — run it as many times as you want, it replaces just the stack block, leaving the rest of your description untouched. Each PR marks itself with `➤`:

```markdown
<!-- git-stack:start -->

**Stack**
├── [#101](https://github.com/owner/repo/pull/101)  `Part 1: database schema`
├─➤ **[#102](https://github.com/owner/repo/pull/102)  `Part 2: API endpoints`**
└── [#103](https://github.com/owner/repo/pull/103)  `Part 3: frontend`

← Prev: [#101](https://github.com/owner/repo/pull/101)&nbsp;&nbsp;&nbsp;&nbsp;·&nbsp;&nbsp;&nbsp;&nbsp;Next: [#103](https://github.com/owner/repo/pull/103) →

---
<!-- git-stack:end -->
```

If a `plan.md` file exists at the repo root (gitignored), `annotate` also appends a collapsible block at the **bottom** of each PR description with its contents, again wrapped in HTML comment markers for idempotent replacement. Pass `--no-plan` to skip it (which also removes any existing block):

```markdown
<!-- git-stack-plan:start -->

<details>
<summary>Full PR Stack Plan</summary>

contents of plan.md

</details>
<!-- git-stack-plan:end -->
```

## Typical workflow

```bash
# Start on main, create the first PR branch
git checkout -b feature/part-1
git commit -m "part 1"
gh pr create --base main --title "Part 1" --body ""

# Stack the second on top
git checkout -b feature/part-2
git commit -m "part 2"
gh pr create --base feature/part-1 --title "Part 2" --body ""

# Stack the third on top
git checkout -b feature/part-3
git commit -m "part 3"
gh pr create --base feature/part-2 --title "Part 3" --body ""

# View the stack
git stack list

# Annotate all PRs with the stack diagram
git stack annotate
```

After adding or amending commits in any PR branch (from any branch in the stack):

```bash
git checkout feature/part-1
git commit --amend --no-edit
git stack restack      # restack everything above the amend (run from any branch)
git stack push         # push everything + update PR bases
git stack annotate     # refresh the stack diagrams
```

Branches may contain any number of commits. Adding a commit works the same way:

```bash
git checkout feature/part-2
git commit -m "follow-up fixes"
git stack restack      # replays part 3 onto part 2's new tip
```

When `main` moves ahead:

```bash
git stack rebase origin/main
git stack push
git stack annotate
```

## Why not Graphite / ghstack / sapling?

| Tool | Trade-off |
|---|---|
| **git-stack** | Single file, no install dependency beyond `git` + `gh`, keeps normal GitHub merge. No server, no auth, no metadata files. |
| **Graphite** | Full-featured (AI reviews, inbox, merge queue) but the CLI requires Graphite's backend server. Closed-source server, open-source client. |
| **ghstack** | Different model — one branch with N commits becomes N `gh/username/N/head` branches. Can't use GitHub's Merge button; requires `ghstack land`. Hard to import existing PRs. |
| **sapling** | Complete SCM replacement, not just a stacking tool. Heavier commitment. |

`git-stack` is for people who want stacked PRs without adopting a new workflow, a new server, or a new VCS. It's ~400 lines of Python and does one thing: keep a stack of branches in sync with each other and with GitHub.

## Limitations

- **No conflict resolution assistance.** If a rebase hits conflicts, git drops you into the normal interactive rebase — resolve them, `git rebase --continue`, then re-run the original command.
- **Linear stacks only.** No support for branching stacks (one PR with multiple children). The detection picks one path through the ancestry chain.
