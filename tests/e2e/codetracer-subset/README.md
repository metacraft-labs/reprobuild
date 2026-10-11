# CodeTracer Subset

This E2E copies a narrow real source slice from `../codetracer` into a temporary
Reprobuild project and builds it through the public `repro build` command with
`--tool-provisioning=path`.

The macOS gate does not invoke `tup`. Homebrew marks `tup` Linux-only and
nixpkgs marks it broken on this host. Instead, the test parses and fingerprints
the command-semantics fixture pinned from CodeTracer commit
`847c4630edfdd861306da7e35556f074caa18471`. This is the reviewed `dev`-branch
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

The in-place project-file tests use exact `repro.nim` and `config.nims`
payloads pinned from reviewed CodeTracer `dev` commit
`847c4630edfdd861306da7e35556f074caa18471`. The files retain CodeTracer's
`AGPL-3.0-or-later` license in explicit SPDX/provenance headers. Every byte
after those headers is identical to the corresponding public source:

- `https://github.com/metacraft-labs/codetracer/blob/847c4630edfdd861306da7e35556f074caa18471/repro.nim`
- `https://github.com/metacraft-labs/codetracer/blob/847c4630edfdd861306da7e35556f074caa18471/config.nims`

`847c4630` is not an arbitrary newer commit. It is the revision this
repository's `flake.lock` pins for its `codetracer-src` input, so the vendored
project contract, the Tup command-semantics extract and the flake-pinned
CodeTracer source all name one reviewed commit instead of three. The previous
pins (`632fdceed` for the project contract, `04d6aff3` for the Tup extract)
were correctly reported as drift once the sibling moved past them: CodeTracer
changed `repro.nim` (dropping `--hotCodeReloading` from the JavaScript bundles,
adding the build-graph gate edges and the development-environment
activation), `config.nims` (sibling-then-override search-path order) and the
`NIM_REPO_PATH_FLAGS` feeding `!nim_js` (the runquota library paths). The
remedy is to refresh the fixtures, not to relax the comparison.

The `847c4630` refresh followed the next `codetracer-src` pin. CodeTracer's
`repro.nim` gained the `isonim-tui` sibling dependency, `config.nims` gained a
worktree-local nimcache, and
`!nim_js` gained a per-rule `--nimcache:/tmp/ct-nim-cache/%B_nim_js` with the
output exclusion `| $(NIM_SIDE_OUTPUTS_IGNORE)`. The Tup-semantics test now
reads an output section as tup does (outputs before `|`, `^regex` exclusions
after it) and substitutes `%B`, the input's base name.

The real sibling still supplies every source file copied and built by the
tests. Using Reprobuild-owned graph/config fixtures keeps an unrelated local
CodeTracer branch or uncommitted edit from redefining the oracle. When the
sibling's Git lineage contains the pinned contract, the test also requires its
live files to match; GitHub Actions is fail-closed for depth-one clones. A
CodeTracer project/config change therefore requires an explicit fixture review
instead of silently changing the accepted graph. The test pins both payload
SHA-256 digests, so fixture drift also fails when a local CodeTracer checkout
is on an unrelated lineage. Refreshes must copy both payloads from that
explicitly reviewed full commit, retain the headers, and update the commit
constant, payload digests, and fixture names together. The fixtures are
committed rather than fetched at test time so shallow and offline builds
exercise the same graph.

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
