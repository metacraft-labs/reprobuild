## Reprobuild repo project file.
##
## A Mode 1 / Mode 3 hybrid (per
## ``reprobuild-specs/Three-Mode-Convention-System.md``):
##
## * Declares the upstream tool dependencies via ``uses:`` so future
##   consumers can ``uses: "reprobuild"`` and pick up the same toolchain
##   floor that the existing ``flake.nix`` provisions today (nim, gcc,
##   just, libblake3, xxhash, sqlite, plus the two source-only fixed
##   inputs nimcrypto-src and runquota-src).
## * Declares ``library reprobuild`` so consumers can express a
##   workspace dependency on this repo with ``uses: "reprobuild"``. The
##   library is the umbrella view of every ``libs/<name>/src`` tree
##   (see ``config.nims`` for the active path list); there is no single
##   ``src/reprobuild.nim`` umbrella because the repo is a fan-out of
##   independent libs the apps wire together explicitly.
## * Declares the eleven shipping executables one-for-one with
##   ``apps/entrypoints.txt``. The Nim-identifier names are camelCase
##   stand-ins for the hyphenated binary names; ``name: "<bin>"``
##   inside each ``executable`` body pins the on-disk artifact.
## * Wraps the existing ``scripts/build_apps.sh`` byte-for-byte in a
##   single ``build:`` action so today's build behaviour is preserved.
##   This is the option-(A) cut described in the repo packaging memo —
##   coarse-grained, opaque, but immediately consistent with what
##   ``just build`` / ``flake.nix`` already do. Option (B) — one
##   ``nim c`` per entrypoint via the DSL's per-entry ``buildAction``
##   primitive — is deferred to a follow-on milestone.
##
## The ``build:`` action inherits ``BLAKE3_PREFIX`` / ``XXHASH_PREFIX``
## / ``SQLITE_PREFIX`` / ``NIMCRYPTO_SRC`` / ``RUNQUOTA_SRC`` /
## ``REPROBUILD_USE_SYSTEM_HASH_LIBS`` from the calling environment, the
## same way the ``flake.nix`` devShell and the existing ``just build``
## drop-in do. The Nix package definition at
## ``nix/pkgs/by-name/re/reprobuild/package.nix`` sets every one of
## those before invoking ``just build``; an interactive developer gets
## them out of the ``nix develop`` shell.

import repro_project_dsl
import repro_dsl_stdlib/packages/sh

# Bootstrap-And-Self-Build B1: ``nim.c(...)`` typed-tool calls in the
# package-level ``build:`` block below resolve through the ``nim``
# const emitted by the ``package nim:`` DSL block in
# ``repro_dsl_stdlib/packages/nim.nim``. That module is auto-imported
# by the ``package`` macro's ``usesImportCode`` pass because
# ``"nim >=2.2 <3.0"`` appears in our ``uses:`` block (the macro
# imports it ``as nim_module`` so the bare ``nim`` identifier resolves
# to the const value, not to the module — direct ``import
# repro_dsl_stdlib/packages/nim`` would shadow the const with the
# module name and break ``nim.c(...)`` method-call resolution).

# Test-Edges-And-Parallel-Runner M1: ``ct_test_nim_unittest`` is the
# codetracer-side Nim-unittest framework adapter that supplies the
# ``buildNimUnittest.build(...)`` typed-tool used by every entry in
# the generated ``repro_tests.nim``. The module re-exports
# ``repro_project_dsl`` so the import order is fine either way.
# ``config.nims`` adds ``../ct-test/libs/ct_test_nim_unittest/src`` to
# the Nim path.
import ct_test_nim_unittest

# Project-DSL-Composition M6: the generated test-edge table.
# ``repro_tests.nim`` exports ``reprobuildTestSpecs*: seq[TestSpec]``;
# the ``build:`` block below iterates the table and registers one
# ``buildNimUnittest.build(...)`` edge per spec, then aggregates the
# resulting actions into the ``test`` target so ``repro build test``
# schedules every test-binary compilation in one engine pass.
#
# Pre-M6 the generated file was ``repro.tests.nim`` and emitted a
# ``build:`` block included from this file. The package macro's
# ``collectBuildStatements`` did not see through ``include`` nodes,
# so the 450+ edges were silently dropped — ``repro build test``
# reported "no named targets in this project". The data + iteration
# migration shape (Approach A from
# ``reprobuild-specs/Project-DSL-Composition.md``) lifts the
# registration into the caller, so the macro sees the typed-tool
# calls and the edges register correctly. The rename also lets Nim
# import the module by name (Nim does not accept dotted module
# identifiers in ``import`` statements).
import repro_tests

package reprobuild:
  # Declare ``path``-mode tool provisioning so the engine adopts it
  # automatically. Without this, ``repro build`` refuses to run with
  # "typed tool provisioning is required for uses declarations" unless
  # the caller passes ``--tool-provisioning=path`` explicitly. The
  # reprobuild dev shell (``nix develop``) and the Nix package both
  # furnish every tool we need via PATH and via env vars
  # (BLAKE3_PREFIX / XXHASH_PREFIX / SQLITE_PREFIX / NIMCRYPTO_SRC /
  # RUNQUOTA_SRC / SSZ_SERIALIZATION_SRC), so the weak-local PATH mode
  # is the right default for this repo.
  defaultToolProvisioning "path"

  uses:
    # Toolchain floor — mirrors flake.nix's nativeBuildInputs. These
    # are the PATH-resolvable binaries the reprobuild build needs;
    # they're sufficient for the path-mode tool resolver to succeed
    # under ``nix develop``.
    "nim >=2.2 <3.0"
    "gcc >=12"
    "just >=1"
    "sh"

    # Bootstrap-And-Self-Build B0: ``runquotad`` is a runtime
    # dependency (spawned as a subprocess by daemon tests at
    # ``../runquota/build/bin/runquotad``). Declaring it in ``uses:``
    # makes the dependency explicit + lets path-mode resolution find
    # the sibling-built binary when ``../runquota/build/bin`` is on
    # ``$PATH``. The sibling ``runquota`` repo now ships its own
    # ``repro.nim`` so later milestones (B1+) can flip this to
    # ``uses: "runquota"`` and consume runquota's typed
    # ``executable runquotad`` output via cross-project resolution;
    # ``runquotad`` (the bare executable selector) is the path-mode
    # form that works today.
    "runquotad"

    # Note: the system hash libraries (libblake3, xxhash, sqlite3) and
    # the source-only fixed inputs (nimcrypto, runquota,
    # ssz-serialization, ct_test_nim_unittest) are NOT listed here.
    # The path-mode resolver requires every ``uses:`` selector to be
    # findable on ``$PATH`` as an executable file, and these are
    # shared libraries, header bundles, or Nim source trees rather
    # than CLI binaries. They are provisioned by ``flake.nix`` /
    # ``nix/pkgs/by-name/re/reprobuild/package.nix`` via env vars
    # (BLAKE3_PREFIX / XXHASH_PREFIX / SQLITE_PREFIX / NIMCRYPTO_SRC /
    # RUNQUOTA_SRC / SSZ_SERIALIZATION_SRC) and consumed by
    # ``config.nims``. Once the DSL grows a typed "env-provided
    # dependency" concept (a ``provides:`` clause, or a Mode 2 catalog
    # shape for header-only / source-only deps) the list above will
    # grow back to capture them; until then the constraints live in
    # ``flake.nix`` and ``config.nims``.

  # Library declaration — every ``.nim`` file under ``libs/<name>/src``
  # that ``config.nims`` adds to ``--path`` is importable when this
  # package is consumed via ``uses: "reprobuild"``. The umbrella is
  # implicit (no single ``src/reprobuild.nim``); consumers import the
  # individual lib modules they need (``import repro_core``,
  # ``import repro_cli_support``, ...).
  library reprobuild

  # Shipping executables, one entry per non-comment line in
  # apps/entrypoints.txt. Nim identifiers are camelCase; the hyphenated
  # on-disk binary name is restored via ``name: "<bin>"``. The order
  # below matches apps/entrypoints.txt to make drift visually obvious.
  #
  # Bootstrap-And-Self-Build B1: the executable declarations stay as
  # naming/visibility records here; the per-executable ``nim.c(...)``
  # build edges are emitted in the package-level ``build:`` block below
  # (the project DSL's ``parseExecutable`` currently accepts only
  # ``name:`` and ``cli:`` body members — a ``build:`` body inside an
  # executable would be silently ignored, so the edges live one scope
  # out and aggregate into the ``apps`` build graph collection there).
  executable repro:
    discard

  executable reproFsSnoop:
    name: "repro-fs-snoop"

  executable reproHcrLink:
    name: "repro-hcr-link"

  executable reproController:
    name: "repro-controller"

  executable reproWorker:
    name: "repro-worker"

  executable reproDaemon:
    name: "repro-daemon"

  executable reproPeerCacheTier2:
    name: "repro-peer-cache-tier2"

  executable reproPeerCacheAdmin:
    name: "repro-peer-cache-admin"

  executable reproPeerCacheMintCert:
    name: "repro-peer-cache-mint-cert"

  executable reprostored:
    discard

  executable reproProviderHost:
    name: "repro-provider-host"

  executable reproCmakeDyndepFragment:
    name: "repro-cmake-dyndep-fragment"

  executable reproCmakeTrycompileProvider:
    name: "repro-cmake-trycompile-provider"

  executable reproStandardProvider:
    name: "repro-standard-provider"

  # Bootstrap-And-Self-Build B2: test-helper executables.
  #
  # Three helper binaries that more than one test suite reuses. Before
  # B2 these were direct ``nim c`` calls in ``scripts/run_tests.sh``
  # (the ``build_test_helper`` shell function + the
  # ``harness_apply_lock_holder`` block); B2 declares them as typed
  # ``executable`` blocks here and adds per-helper ``nim.c(...)`` edges
  # in the package-level ``build:`` body below. The helpers form their
  # own ``test-helpers`` build graph collection so consumers can
  # ``repro build .#test-helpers`` to materialise the trio in one
  # engine pass (and so test edges can declare typed-input dependencies
  # on them later — B2 spec deliverable note about
  # ``buildNimUnittest``'s ``inputs:`` slot).
  #
  # B5 retires the corresponding ``build_test_helper`` lines from
  # ``scripts/run_tests.sh`` once the in-graph path is the supported
  # one end-to-end.
  executable liveEndpointHelper:
    name: "live_endpoint_helper"

  executable fakeProtocolDaemonHelper:
    name: "fake_protocol_daemon_helper"

  executable harnessApplyLockHolder:
    name: "harness_apply_lock_holder"

  build:
    # Project-DSL-Composition M6: declared typed-output build edges for
    # every ``t_*.nim`` / ``test_*.nim`` file under tests/,
    # libs/*/tests/, and tools/*/tests/. The data table is generated by
    # ``scripts/generate_test_edges.nim`` into ``repro_tests.nim``; this
    # ``for`` loop registers one ``buildNimUnittest.build(...)`` edge
    # per ``TestSpec`` and aggregates the collected actions into the
    # ``test`` target so ``repro build test`` schedules every
    # test-binary compilation in one engine pass.
    #
    # The M5 active-build-context handle is what makes the iteration
    # shape work: each call to ``buildNimUnittest.build(...)`` reads
    # ``currentBuildState()`` to find the active package even though
    # the call now happens inside a runtime ``for`` loop rather than
    # at a literal top-level position in the ``build:`` body.
    #
    # Bootstrap-And-Self-Build B3: each TestSpec now expands into TWO
    # edges (per Package-Model.md §"The test template"):
    #
    #   * A BUILD edge — the compile-only ``buildNimUnittest.build(...)``
    #     call that produces ``build/test-bin/<stem>``. Actions accumulate
    #     into ``reprobuildTestBuildActions`` and collect into a
    #     ``test-builds`` build graph collection so callers that want
    #     compile-only verification (the old ``repro build test``
    #     semantics) can still do ``repro build .#test-builds``.
    #
    #   * An EXECUTE edge — ``edge.testBinary.run(...)`` per Package-
    #     Model.md ~line 994. The binary path flows in as a typed input
    #     so the engine action-cache keys on the binary content. When
    #     the TestSpec's ``requiresReproBinary`` flag is set the engine-
    #     built ``./build/bin/repro`` artifact is declared as an extra
    #     typed input via the ``requiredBinaries`` slot the
    #     ``ct_test_nim_unittest`` adapter exposes — this is the
    #     mechanism that triggers a ``repro`` rebuild before an e2e test
    #     runs, and re-runs the test execute edge when a source under
    #     ``libs/repro_*/`` changes. Execute actions accumulate into
    #     ``reprobuildTestExecuteActions`` and the resulting collection
    #     is registered as ``test``, so ``repro test`` /
    #     ``repro build test`` now materialises the EXECUTE closures
    #     (each execute action transitively depends on its build edge).
    #
    # B5 retires the out-of-band ``ct-test-runner`` walk of
    # ``build/test-bin/`` in favour of these graph-native execute edges
    # entirely; B3 + B4 land both paths in parallel.
    var reprobuildTestBuildActions: seq[BuildActionDef] = @[]
    var reprobuildTestExecuteActions: seq[BuildActionDef] = @[]
    const reproBinaryPath = "build/bin/repro"

    proc reproTestExecuteId(binary: string): string =
      ## Compute the per-test EXECUTE-edge action id from the build
      ## edge's binary path. Uses raw string-slicing instead of
      ## ``os.extractFilename`` because the package macro lifts the
      ## body into a generated proc whose scope does not transparently
      ## see ``std/os``.
      var lastSlash = -1
      for i in 0 ..< binary.len:
        if binary[i] == '/' or binary[i] == '\\':
          lastSlash = i
      let stem =
        if lastSlash >= 0: binary[lastSlash + 1 .. ^1]
        else: binary
      "reprobuild.test_execute." & stem

    for spec in reprobuildTestSpecs:
      let edge = buildNimUnittest.build(
        source = spec.source,
        binary = spec.binary,
        defines = spec.defines)
      reprobuildTestBuildActions.add(edge.action)
      # B3: emit the EXECUTE edge.
      #
      # ``requiredBinaries`` is the typed input slot the
      # ``ct_test_nim_unittest.run`` proc exposes (Bootstrap-And-Self-
      # Build B3 extension): when a TestSpec carries
      # ``requiresReproBinary``, the engine-built
      # ``build/bin/repro`` artifact is recorded as an input on the
      # execute edge. Without the flag the execute edge depends only on
      # its own binary content — keeping the action-cache fingerprint
      # small for the 500+ tests that do NOT spawn the CLI.
      let executeActionId = reproTestExecuteId(spec.binary)
      # ``registerImplicitName = false`` because the BUILD edge
      # already registers the binary basename as the implicit target
      # name for this package; the execute edge would otherwise
      # collide on the same name and the per-package target-export
      # table rejects the duplicate with a ``duplicate implicit target
      # name`` diagnostic at provider time. The explicit ``actionId``
      # is the selector for the execute edge.
      let executeEdge =
        if spec.requiresReproBinary:
          edge.testBinary.run(
            requiredBinaries = [reproBinaryPath],
            actionId = executeActionId,
            registerImplicitName = false)
        else:
          edge.testBinary.run(
            actionId = executeActionId,
            registerImplicitName = false)
      reprobuildTestExecuteActions.add(executeEdge)
    # Spec-Implementation M0: the ``test`` build graph collection
    # (per reprobuild-specs/Build-Graph-Collections.md). ``repro test``
    # and ``repro build test`` both materialize this collection's
    # closure.
    #
    # B3: the collection now holds EXECUTE edges (the build edges are
    # transitive inputs reached automatically by the engine's closure
    # walk). The semantic change is per Bootstrap-And-Self-Build B3
    # outcome and Package-Model.md §"The test template". The compile-
    # only verification (former ``repro build test`` semantics) is
    # available via the ``test-builds`` collection registered below.
    discard collect("test", reprobuildTestExecuteActions)

    # B3: a parallel collection of just the BUILD halves for callers
    # that want compile-only verification of the test corpus without
    # actually executing the tests (e.g. CI byte-equivalence checks,
    # the historical ``repro build test`` behaviour before B3).
    discard collect("test-builds", reprobuildTestBuildActions)

    # Bootstrap-And-Self-Build B1: per-app typed-tool build edges +
    # the ``apps`` build graph collection.
    #
    # One ``nim.c(...)`` edge per non-comment line in
    # ``apps/entrypoints.txt``. The mapping reproduces the per-entry
    # shell loop in ``scripts/build_apps.sh``: each entry's binary
    # basename becomes ``build/bin/<name>`` and the source path is the
    # ``.nim`` file under ``apps/<name>/<source>.nim``. The two
    # provider entries carry ``-d:reproProviderMode`` (the third field
    # in ``apps/entrypoints.txt`` for those rows).
    #
    # Per-app edge actions are accumulated into ``reprobuildAppsActions``
    # and folded into a build graph collection named ``apps`` via the
    # M0 ``collect`` primitive. ``repro build .#apps`` materialises
    # every member in one engine pass. (The fragment form ``.#apps``
    # is required because the CLI's path-vs-name classifier treats
    # bare ``apps`` as the on-disk ``apps/`` directory; the fragment
    # syntax disambiguates per the Named-Targets M3 rules in
    # CLI/build.md §"Target Selection".)
    #
    # The option-(A) ``shell(command = "bash scripts/build_apps.sh", ...)``
    # wrapper below stays in place for one transition milestone (B5
    # retires it). B1 ships both paths in parallel so consumers can
    # cut over incrementally; the per-app edges are the supported path
    # going forward.
    var reprobuildAppsActions: seq[BuildActionDef] = @[]

    reprobuildAppsActions.add(nim.c(
      source = "apps/repro/repro.nim",
      binary = "build/bin/repro",
      actionId = "reprobuild.apps.repro"))

    reprobuildAppsActions.add(nim.c(
      source = "apps/repro-fs-snoop/repro_fs_snoop.nim",
      binary = "build/bin/repro-fs-snoop",
      actionId = "reprobuild.apps.repro-fs-snoop"))

    reprobuildAppsActions.add(nim.c(
      source = "apps/repro-hcr-link/repro_hcr_link.nim",
      binary = "build/bin/repro-hcr-link",
      actionId = "reprobuild.apps.repro-hcr-link"))

    reprobuildAppsActions.add(nim.c(
      source = "apps/repro-controller/repro_controller.nim",
      binary = "build/bin/repro-controller",
      actionId = "reprobuild.apps.repro-controller"))

    reprobuildAppsActions.add(nim.c(
      source = "apps/repro-worker/repro_worker.nim",
      binary = "build/bin/repro-worker",
      actionId = "reprobuild.apps.repro-worker"))

    reprobuildAppsActions.add(nim.c(
      source = "apps/repro-daemon/repro_daemon.nim",
      binary = "build/bin/repro-daemon",
      actionId = "reprobuild.apps.repro-daemon"))

    reprobuildAppsActions.add(nim.c(
      source = "apps/repro-peer-cache-tier2/repro_peer_cache_tier2.nim",
      binary = "build/bin/repro-peer-cache-tier2",
      actionId = "reprobuild.apps.repro-peer-cache-tier2"))

    reprobuildAppsActions.add(nim.c(
      source = "apps/repro-peer-cache-admin/repro_peer_cache_admin.nim",
      binary = "build/bin/repro-peer-cache-admin",
      actionId = "reprobuild.apps.repro-peer-cache-admin"))

    reprobuildAppsActions.add(nim.c(
      source = "apps/repro-peer-cache-mint-cert/repro_peer_cache_mint_cert.nim",
      binary = "build/bin/repro-peer-cache-mint-cert",
      actionId = "reprobuild.apps.repro-peer-cache-mint-cert"))

    reprobuildAppsActions.add(nim.c(
      source = "apps/reprostored/reprostored.nim",
      binary = "build/bin/reprostored",
      actionId = "reprobuild.apps.reprostored"))

    reprobuildAppsActions.add(nim.c(
      source = "apps/repro-provider-host/repro_provider_host.nim",
      binary = "build/bin/repro-provider-host",
      actionId = "reprobuild.apps.repro-provider-host"))

    reprobuildAppsActions.add(nim.c(
      source = "apps/repro-cmake-dyndep-fragment/repro_cmake_dyndep_fragment.nim",
      binary = "build/bin/repro-cmake-dyndep-fragment",
      actionId = "reprobuild.apps.repro-cmake-dyndep-fragment"))

    # Provider-mode entries carry ``-d:reproProviderMode`` per the
    # third field on their ``apps/entrypoints.txt`` line.
    reprobuildAppsActions.add(nim.c(
      source = "apps/repro-cmake-trycompile-provider/repro_cmake_trycompile_provider.nim",
      binary = "build/bin/repro-cmake-trycompile-provider",
      defines = @["reproProviderMode"],
      actionId = "reprobuild.apps.repro-cmake-trycompile-provider"))

    reprobuildAppsActions.add(nim.c(
      source = "apps/repro-standard-provider/repro_standard_provider.nim",
      binary = "build/bin/repro-standard-provider",
      defines = @["reproProviderMode"],
      actionId = "reprobuild.apps.repro-standard-provider"))

    discard collect("apps", reprobuildAppsActions)

    # Bootstrap-And-Self-Build B2: per-helper typed-tool build edges +
    # the ``test-helpers`` build graph collection.
    #
    # One ``nim.c(...)`` edge per helper binary. The source paths
    # mirror the three ``build_test_helper`` (and one inline ``nim c``)
    # invocations in ``scripts/run_tests.sh``:
    #
    #   * ``live_endpoint_helper`` —
    #     ``tests/fixtures/local-daemons-control-plane/live-endpoint-helper/``
    #   * ``fake_protocol_daemon_helper`` —
    #     ``tests/fixtures/local-daemons-control-plane/fake-protocol-daemon-helper/``
    #   * ``harness_apply_lock_holder`` —
    #     ``tests/e2e/home-generations/``
    #
    # The three actions aggregate into a separate ``test-helpers``
    # collection (NOT ``apps`` — apps are shipping binaries; helpers
    # are test scaffolding). ``repro build .#test-helpers`` materialises
    # all three in one engine pass. As with ``apps``, the fragment form
    # is required because the path-vs-name classifier would otherwise
    # try to resolve ``test-helpers`` against the on-disk tree.
    #
    # The corresponding ``build_test_helper`` / inline ``nim c`` lines
    # in ``scripts/run_tests.sh`` stay during the transition; B5
    # retires them once the in-graph path is the supported one.
    var reprobuildTestHelpersActions: seq[BuildActionDef] = @[]

    reprobuildTestHelpersActions.add(nim.c(
      source = "tests/fixtures/local-daemons-control-plane/live-endpoint-helper/live_endpoint_helper.nim",
      binary = "build/test-bin/live_endpoint_helper",
      actionId = "reprobuild.test_helpers.live_endpoint_helper"))

    reprobuildTestHelpersActions.add(nim.c(
      source = "tests/fixtures/local-daemons-control-plane/fake-protocol-daemon-helper/fake_protocol_daemon_helper.nim",
      binary = "build/test-bin/fake_protocol_daemon_helper",
      actionId = "reprobuild.test_helpers.fake_protocol_daemon_helper"))

    reprobuildTestHelpersActions.add(nim.c(
      source = "tests/e2e/home-generations/harness_apply_lock_holder.nim",
      binary = "build/test-bin/harness_apply_lock_holder",
      actionId = "reprobuild.test_helpers.harness_apply_lock_holder"))

    discard collect("test-helpers", reprobuildTestHelpersActions)

    # Option (A) from the repo packaging memo: wrap scripts/build_apps.sh
    # byte-for-byte so the action's behaviour is identical to ``just
    # build`` today. The action declares the union of source roots the
    # script reads (apps/, libs/, config.nims, reprobuild.nimble) as
    # extra inputs.
    #
    # Bootstrap-And-Self-Build B1: the wrapper no longer declares the
    # 14 ``build/bin/<name>`` app binaries as ``extraOutputs`` — the
    # per-app ``nim.c(...)`` edges above own those artifacts now and
    # the engine rejects duplicate owned-effect claims on the same
    # output path. The wrapper retains its monitor-shim and DSL-runtime
    # DLL outputs (which the per-app edges don't produce) so that
    # ``bash scripts/build_apps.sh`` remains a complete drop-in for
    # ``just build`` during the transition. B5 retires the wrapper
    # entirely.
    #
    # Env vars (BLAKE3_PREFIX / XXHASH_PREFIX / SQLITE_PREFIX /
    # NIMCRYPTO_SRC / RUNQUOTA_SRC / REPROBUILD_USE_SYSTEM_HASH_LIBS)
    # are inherited from the caller. Both the flake.nix and the new
    # nixpkgs-format package.nix at nix/pkgs/by-name/re/reprobuild/
    # set them before invoking this script.
    shell(
      command = "bash scripts/build_apps.sh",
      actionId = "reprobuild.build_apps",
      extraInputs = @[
        "apps/entrypoints.txt",
        "apps",
        "libs",
        "config.nims",
        "reprobuild.nimble",
        "scripts/build_apps.sh",
      ])
