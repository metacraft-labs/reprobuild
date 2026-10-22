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

  The base checkout (`checkoutBaseTree`) writes every file as its **blob
  bytes**, read with `git cat-file --batch`, without any git conversion: no
  `.gitattributes` (`eol`, `filter=` smudge, `ident`,
  `working-tree-encoding`), no `info/attributes` or global attributes file,
  no `core.autocrlf`, and no `refs/replace` substitute
  (`GIT_NO_REPLACE_OBJECTS`). Each blob must hash to the id its tree names,
  and a tree path git would refuse to check out (`..`, a `.git` component in
  any letter case) refuses the whole checkout. That is the one definition of a worktree's content on
  the worker: modified entries are written verbatim, and the tree id
  (`treeIdOf`, `reverifyTree`) hashes the bytes on disk, so a converted
  checkout would hash to another tree and every snapshot of a repository
  with such attributes would be refused. Goals therefore see the
  repository's canonical content, not a developer's smudged working tree.

Distributed-Execution M7 introduced the receiver-side half. M1 adds capture
(`captureWorkspaceSnapshot`), `repro develop` siblings, the reusable
worktree pool, and fetching missing base commits from peers.
