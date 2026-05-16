# CodeTracer Subset

This E2E copies a narrow real source slice from `../codetracer` into a temporary
Reprobuild project and builds it through the public `repro build` command with
`--tool-provisioning=path`.

The macOS gate does not invoke `tup`. Homebrew marks `tup` Linux-only and
nixpkgs marks it broken on this host. Instead, the test parses and fingerprints
CodeTracer's committed `src/Tuprules.tup` command semantics for the exact
Tup-equivalent actions:

- `!nim_js` semantics for `src/frontend/tests/ipc_registry_test.nim`
- `!trace_object_file` semantics for the copied
  `test-programs/c_sudoku_solver/main.c`

The copied Nim fixture also uses CodeTracer's committed `nim.cfg` search paths
so that the selected source slice resolves the same checked-in libraries.

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
