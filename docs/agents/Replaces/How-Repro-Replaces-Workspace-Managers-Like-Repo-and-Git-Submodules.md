# How Repro Replaces Workspace Managers (repo, Git submodules)

> **Status:** Conceptual mapping guide for developers managing multi-repository checkout states.

Reprobuild coordinates VCS repository layouts and checks in tandem with the build graph.

## Conceptual Mapping

Reprobuild replaces multi-repo wrappers (like Google's `repo` tool or Git submodules) with a unified manifest and develop-mode routing to ensure reproducible workspace setups.

| VCS Manager Concept | Reprobuild Equivalent | How Repro Solves It |
|---|---|---|
| **Manifest File** (`default.xml`) | `repos/*.toml` fragments (+ `repro-workspace.toml` settings) | Fragments declare sibling git repositories, clone locations, and mainline branches; the settings file holds workspace-wide policy. |
| **`repo sync` / submodules** | `repro workspace sync` | Clones and fast-forwards sibling checkouts to match the manifest configuration. |
| **Branch Status** (`repo status`) | `repro workspace status` | Audits uncommitted changes and commit hash alignments across all checkouts. |
| **Workspace Init** | `repro workspace init` | Bootstraps a clean workspace on a new host. |

## Key Commands

- `repro workspace init` — bootstrap a clean multi-project workspace on a new host.
- `repro workspace sync` — clone and fetch all repositories in the manifest.
- `repro workspace status` — audit git status across all sibling repositories.
- `repro workspace branch-roles` — print the branch every branch role
  (`mainline`, `unstable`, `stable`, ...) resolves to per repo, with the
  fallback chain for a role a repo does not declare. `--unstable` (or
  `--to=<role>`) prints one role; `--json` is the machine form. A read-only
  lookup: use it instead of probing remotes for a branch name.
- `repro sync --to=<role>` / `repro switch --to=<role>` /
  `repro branch <path> --from=<role>` — reconcile with, switch to, or fork
  from the branch a role resolves to in every repo at once, whatever each repo
  calls it (`--unstable` reaches `agents` in a repo that declares it and the
  mainline in one that does not). The shorthands `--mainline`, `--unstable`,
  `--staging`, `--stable`, `--production` and `--lts` mean exactly
  `--to=<role>` (on `branch`, `--from=<role>`). This is what replaces
  `repo forall -c 'git rebase origin/<branch>'`: the branch name is read from
  the manifest per repo, never typed. A declared role whose branch the remote
  lacks is refused (`no_role_ref`) rather than silently redirected.
- `repro workspace migrate` — reconcile each existing checkout's local git
  state (remote names and URLs, detached HEADs) with what the manifest now
  declares. Rarely needed by hand: the managed `post-merge` hook runs the same
  reconciliation, so an ordinary `git pull` is enough. Reach for the command
  when you want to see the plan first (`--dry-run`) or re-read a report that
  scrolled past.

### The workspace branch and repository branches

The default workspace branch is the root repository's `mainline`, declared in
`repro-workspace.toml`. The root can declare that mainline directly in
`[workspace]` or through its `profile` or `default_profile`; with no
declaration there is no default workspace branch. Member repositories keep their own mainlines;
a member's product profile does not determine the workspace branch.

`workspace init` and a fully successful `workspace pull` record this default.
`workspace lock` and pre-push checks prefer a recorded workspace branch, then
the declared default. Status also prefers recorded state, then a live branch
shared by every checkout, then the declared default. Its `--unmerged` query uses
each repository's mainline, while ahead/behind counts use that checkout's
remote-tracking upstream.

### Keeping an existing checkout current

When a manifest changes what a repository is *called* — its primary remote's
name, the URL it points at, or the branch it tracks — the manifest alone cannot
fix the checkouts that already exist on disk. `repro workspace migrate` closes
that gap, and does it under two rules:

- **It never discards work.** A checkout with uncommitted changes, unpushed
  commits, stashed work, or commits held only by a detached HEAD is skipped,
  named, and paired with the command that unblocks it. Its remotes are still
  reconciled — renaming a remote cannot lose a commit — but its HEAD is left
  exactly where you put it.
- **It is idempotent and offline.** A second run is a no-op that prints
  nothing, and no step reaches the network, so it is safe to run from a hook.

Expect it to find nothing in a workspace that has been kept current — that is
the steady state, not evidence the command is unnecessary. Its work falls
almost entirely on checkouts that predate a manifest change: a remote still
named after the hosting organisation, a fork with no `upstream` (nothing
before per-binding URL prefixes could express one), or a HEAD left detached by
an older tool. A workspace created after the change has none of those and will
report "already match the manifest" forever.
