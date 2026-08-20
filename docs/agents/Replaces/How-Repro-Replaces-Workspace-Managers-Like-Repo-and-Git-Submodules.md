# How Repro Replaces Workspace Managers (repo, Git submodules)

> **Status:** Conceptual mapping guide for developers managing multi-repository checkout states.

Reprobuild coordinates VCS repository layouts and checks in tandem with the build graph.

## Conceptual Mapping

Reprobuild replaces multi-repo wrappers (like Google's `repo` tool or Git submodules) with a unified manifest and develop-mode routing to ensure reproducible workspace setups.

| VCS Manager Concept | Reprobuild Equivalent | How Repro Solves It |
|---|---|---|
| **Manifest File** (`default.xml`) | `repro-workspace.toml` | Declares sibling git repositories, clone locations, and track branches. |
| **`repo sync` / submodules** | `repro workspace sync` | Clones and fast-forwards sibling checkouts to match the manifest configuration. |
| **Branch Status** (`repo status`) | `repro workspace status` | Audits uncommitted changes and commit hash alignments across all checkouts. |
| **Workspace Init** | `repro workspace init` | Bootstraps a clean workspace on a new host. |

## Key Commands

- `repro workspace init` — bootstrap a clean multi-project workspace on a new host.
- `repro workspace sync` — clone and fetch all repositories in the manifest.
- `repro workspace status` — audit git status across all sibling repositories.
- `repro workspace migrate` — reconcile each existing checkout's local git
  state (remote names and URLs, detached HEADs) with what the manifest now
  declares. Rarely needed by hand: the managed `post-merge` hook runs the same
  reconciliation, so an ordinary `git pull` is enough. Reach for the command
  when you want to see the plan first (`--dry-run`) or re-read a report that
  scrolled past.

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
