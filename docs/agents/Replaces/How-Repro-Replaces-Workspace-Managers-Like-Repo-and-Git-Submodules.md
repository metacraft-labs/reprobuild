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
