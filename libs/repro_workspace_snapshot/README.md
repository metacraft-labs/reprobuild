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
  modified blobs, and verifies the resulting tree id (M7; used when a worker
  has no worktree pool). Its base checkout writes blob bytes itself
  (`checkoutBaseTree`, below); the pool's base checkout is git's own, made
  canonical (`git --attr-source=<empty tree>`, git >= 2.40; a cache with
  `info/attributes` is refused by the pool). A base commit the cache lacks
  is completed from the snapshot's base pack (`ensureBaseObjects`), and a
  base tree over the checkout bounds is refused before anything is written.
- `capture` (M1) — `captureWorkspaceSnapshot`: the requester's working tree
  and every active `repro develop` sibling as one manifest, each tree id
  computed in a temporary index (the user's `.git/index` is never written),
  the modified and allowed untracked files' bytes handed to a `BlobSink`
  (the requester's snapshot store, `repro_peer_cache/snapshot_blobs`), and
  each repository's unpushed history (objects reachable from the base commit
  and not from a remote-tracking ref) as a bounded BASE PACK.
- `pool` (M1) — the worker's worktree pool: base worktrees per repository
  (completing a missing base commit from the snapshot's base pack and an
  operator-configured remote), each
  goal's worktree a copy-on-write clone of one with the snapshot's delta
  applied, verified against the files on disk; `materializeWorkspaceSnapshot`
  for the primary repository and its siblings.
- `git_process` — how both run git (a built, not inherited, environment).

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

Distributed-Execution M7 introduced the receiver-side half; M1 added capture,
`repro develop` siblings, the reusable worktree pool, base packs and fetching
missing base commits. The worker's receiver (`repro_distributed_worker`)
materializes siblings read-only beside the worktree (`REPRO_DEVELOP_SIBLINGS`)
and issues no certificate while they are present, until M2 binds them into
certification.
