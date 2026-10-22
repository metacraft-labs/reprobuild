# repro_workspace_snapshot

The `WorkspaceSnapshotManifest` a remote worker materializes before it runs
anything for a caller, and the verification that binds it to a
`git-tree-sha1` content id (`reprobuild-pm/spec/Distributed-Execution.md`
§"Worker Boundary Vocabulary", Test-Certificates TC-8).

- `manifest` — the manifest type, its canonical encoding and BLAKE3 digest,
  and strict receiver-side validation (paths, modes, sizes, counts).
- `git_tree` — a native git tree-object hash over a directory restricted to
  a tracked path set, so a worker can re-verify a worktree after the goal ran
  without trusting anything the goal wrote outside the tracked paths.
- `materialize` — checks a base commit out of a local repository cache into
  a fresh directory, applies the manifest's deletions and BLAKE3-verified
  modified blobs, and verifies the resulting tree id.

Distributed-Execution M7 introduced the receiver-side half. M1 adds capture
(`captureWorkspaceSnapshot`), `repro develop` siblings, the reusable
worktree pool, and fetching missing base commits from peers.
