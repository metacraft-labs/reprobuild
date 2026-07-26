# CodeTracer Subset

This E2E copies a narrow real source slice from `../codetracer` into a temporary
Reprobuild project and builds it through the public `repro build` command with
`--tool-provisioning=path`.

The macOS gate does not invoke `tup`. Homebrew marks `tup` Linux-only and
nixpkgs marks it broken on this host. Instead, the test parses and fingerprints
the command-semantics fixture pinned from CodeTracer commit
`04d6aff3d012b3e768dbebba186c950637e0c2b3`. This is the reviewed `dev`-branch
contract also selected by Reprobuild's `.github/sibling-repos`; using a
Reprobuild-owned fixture keeps the oracle independent of an adjacent
CodeTracer checkout's branch or uncommitted state. The fixture covers the exact
Tup-equivalent actions:

- `!nim_js` semantics for `src/frontend/tests/ipc_registry_test.nim`
- `!trace_object_file` semantics for the copied
  `test-programs/c_sudoku_solver/main.c`

The extracted fixture retains CodeTracer's `AGPL-3.0-or-later` license and
records its exact public source URL in the file header.

The test pins each complete command/output fingerprint, asserts
`-d:nimOldCaseObjects` explicitly, and proves that removing that compiler
semantic input deterministically changes the `!nim_js` fingerprint. When the
real sibling's Git lineage contains the pinned CodeTracer commit, the test also
requires its live `src/Tuprules.tup` fingerprints to match the fixture. This
keeps command drift visible on CI's contracted `codetracer=dev` checkout
without letting an unrelated local branch silently redefine the oracle.

The source slice itself is still copied from the real sibling CodeTracer
checkout. Its Nim fixture uses CodeTracer's committed `nim.cfg` search paths so
that the selected source slice resolves the same checked-in libraries.

The generated-header C compile is a separate Reprobuild dependency-behavior
check. It intentionally adds `-include build/generated/ct_config.h`, so it is
not treated as the Tup-rule oracle.

Run it with:

```bash
just e2e_codetracer_build_subset_without_tup
just e2e_reprobuild_mvp_acceptance
```

The acceptance target runs this selected subset together with the selected
Nix-backed development-environment slice, shared RunQuota coordination, and the
core MVP benchmark gate. It is a macOS MVP slice gate, not a full CodeTracer
repository build replacement.
