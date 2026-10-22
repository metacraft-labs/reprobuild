# repro_distributed_worker

The receiving end of a remote goal (Distributed-Execution M7; M2-M4 build on
it). A worker:

- hydrates a content-addressed `GraphCacheDescriptor` and a
  `WorkspaceSnapshotManifest` by BLAKE3 digest (`graph_descriptor`,
  `repro_workspace_snapshot`), and requires the descriptor to be bound to the
  snapshot's `git-tree-sha1`;
- answers a `ReachGoalRequest` (`reach_goal`) only for a node CONTAINED in
  that descriptor, whose argv and input paths derive from it and from the
  verified snapshot — never an argv the caller composed (`derivation`);
- runs the node in a confined execution lease (`lease`, with the Linux
  launcher in `c/repro_lease_linux.c`, a Seatbelt profile on macOS and a Job
  Object on Windows, which confines lifecycle only), with deny-by-default
  egress through supervisor-owned forwarders, the outputs of declared input
  nodes mounted read-only and executable, and the isolation level that ran
  recorded per goal;
- re-verifies the worktree's tree id after the goal and before any
  certificate is signed (`receiver`);
- records every refusal and every lease detection in the goal's execution
  record (in the worker's CAS) and its local detection log, and — in the
  hardened trust profile — also reports them to the evidence sink.

The threat model is `reprobuild-pm/spec/Distributed-Execution-Threat-Model.md`;
the message vocabulary is `reprobuild-pm/spec/Distributed-Execution.md`
§"Worker Boundary Vocabulary".
