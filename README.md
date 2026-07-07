# git-stack

A lightweight script for managing **stacked pull requests** on GitHub. Each PR is its own named branch, bases set to the previous branch. GitHub's normal Merge button keeps working — no special landing tool required.

```
main
  │
  ├── feature/part-1   ← base: main
  ├── feature/part-2   ← base: feature/part-1
  └─⮞ feature/part-3   ← base: feature/part-2   (you are here)
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
| `git stack restack` | After amending a lower branch, restack everything above it |
| `git stack push [-f]` | Push all branches + update each PR's base on GitHub |
| `git stack annotate` | Insert/update a stack diagram in each PR's description |

## How it works

**Stack detection** is automatic — no branch naming conventions, no metadata files. The script walks git ancestry (`git merge-base --is-ancestor`) to find branches that chain together relative to the base branch. Checkout any branch in the stack and it figures out the rest.

**Rebasing** uses `git rebase --onto` under the hood, then remaps intermediate branches by commit subject so each PR stays on its own commit. After rebasing, intermediate branch pointers are updated to the matching commits in the new history.

**Restacking** finds the old position of your amended branch via the reflog (no SHA lookup needed) and replays everything above it onto the new position.

**Pushing** force-pushes (`--force-with-lease` by default, `--force` with `-f`) all branches in the stack and sets each PR's base to the previous branch via the GitHub API.

**Annotating** inserts a stack diagram into each PR's description, wrapped in invisible HTML comment markers so it's idempotent — run it as many times as you want, it replaces just the stack block, leaving the rest of your description untouched. Each PR marks itself with `⮞`:

```markdown
<!-- git-stack:start -->

**Stack**
├── [#101](https://github.com/owner/repo/pull/101)  `Part 1: database schema`
├─⮞ [#102](https://github.com/owner/repo/pull/102)  `Part 2: API endpoints`
└── [#103](https://github.com/owner/repo/pull/103)  `Part 3: frontend`

---
<!-- git-stack:end -->
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

After amending a lower PR:

```bash
git checkout feature/part-1
git commit --amend --no-edit
git stack restack      # restack part-2 and part-3 on top
git stack push         # push everything + update PR bases
git stack annotate     # refresh the stack diagrams
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

- **One commit per branch.** Each branch should have exactly one commit (its PR). Multi-commit branches work for rebasing but the remap-by-subject logic assumes one commit per PR.
- **No conflict resolution assistance.** If a rebase hits conflicts, git drops you into the normal interactive rebase — resolve them, `git rebase --continue`, then re-run the original command.
- **Linear stacks only.** No support for branching stacks (one PR with multiple children). The detection picks one path through the ancestry chain.
