## The engine-only part of reprobuild's own ``repro.nim``: its imports of the
## engine's libraries and of Nim's standard library, and the constants,
## tables and procedures its ``package reprobuild:`` block uses.
##
## ``repro.nim`` includes this file under ``when reproDslMode != rdmThin:``.
## Every compilation the engine makes of the recipe (interface extraction,
## the provider, in-process evaluation) therefore compiles it exactly as if
## its text stood in ``repro.nim``, at the include, while a program that
## imports ``repro.nim`` with no mode define compiles the DSL's thin mode and
## none of this file, so none of the engine. It is not a module: it is never
## compiled on its own, and its names are ``repro.nim``'s.

import std/[algorithm, os, osproc, sequtils, strutils]
# Ambient-execution hatches. Every call below is bootstrap tier: the recipe has
# to locate a host tool BEFORE any engine-provisioned prefix exists, so a typed
# execution profile is not available to it. Naming the hatch says so at the
# call site instead of leaving it to be inferred — `git grep uncontrolled` is
# the audit surface.
import repro_core/ambient_execution
              # Incremental-Test-Runner M7: getEnv + the `/` path operator
              # for the io-mon / nim-stackable-hooks sibling resolution in the
              # test-fixtures monitor-shim build edge below.
import repro_dsl_stdlib/foreign_env
import repro_dsl_stdlib/packages/sh
import repro_dsl_stdlib/packages/llvm_objcopy
import repro_dsl_stdlib/packages/gcc as gcc_module
import repro_dsl_stdlib/fs as dslfs
import repro_dsl_stdlib/types
              # Windows-Cacheable-Builds-Session-Residuals S1: the four
              # side-by-side Windows monitor artefact names live in one module
              # so the recipe and the regression test spell them once.
import repro_dsl_stdlib/monitor_shim_artifacts
              # M8: the openssl package's own library-channel vocabulary. This
              # recipe offers ONE prefix to it (the MSYS2 install in this
              # repo's Windows dev-deps tree) and takes no part in deciding
              # the linker flags — see the ``registerOpensslPrefixCandidate``
              # call in the ``build:`` block below.
import repro_dsl_stdlib/openssl_layout
import repro_dsl_stdlib/source_only_packages
              # A15: the monitor shim's version script, merged with the
              # `cross_zig` compiler-rt node under a zig target (below).
import repro_dsl_stdlib/adapters/cross_zig
import repro_dsl_stdlib/operations/zig_c
              # A15: the installed prefix (`.#prefix`, below).
import repro_dsl_stdlib/operations/pinned_fetch
import repro_dsl_stdlib/operations/compile
import repro_dsl_stdlib/operations/link
import repro_dsl_stdlib/types/options
import repro_dsl_stdlib/packaging/producers/installed_prefix
from repro_dsl_stdlib/packaging/types import toLinux
from repro_dsl_stdlib/packaging/runtime_contract import
  reprobuildDlopenLeafNames
from repro_dsl_stdlib/packaging/reprobuild_dist import
  reprobuildNimDlopenLeafNames, nimForkGuardScript, NimForkGuardTools,
  PrefixSourcesTools
from repro_tool_profiles import fromSourceRecipeRoot
from repro_project_dsl/install_mirror_resolver import installMirrorSubpathFor

const ReprobuildPrefixDebs = [
  ## The runtime libraries an installed prefix for a triple takes from the
  ## target distribution instead of building them:
  ## `(triple, library directory inside the package, the .deb)`,
  ## each pinned to the `SHA256` of the distribution's `Packages` index.
  ## Debian trixie armhf, `main`, read from
  ## https://deb.debian.org/debian/dists/trixie/main/binary-armhf/Packages.xz
  ## on 2026-11-03. Both need glibc 2.38 at most, the `cross_zig` row's.
  ("armv7-unknown-linux-gnueabihf", "usr/lib/arm-linux-gnueabihf",
    PinnedArchive(name: "libsqlite3-0", kind: pakDeb,
      url: "https://deb.debian.org/debian/pool/main/s/sqlite3/" &
        "libsqlite3-0_3.46.1-7+deb13u2_armhf.deb",
      sha256: "15d6a91264010e8ee439d0b3e95782dd87e31fea71aee379deca53fbb99ea957")),
  ("armv7-unknown-linux-gnueabihf", "usr/lib/arm-linux-gnueabihf",
    PinnedArchive(name: "libzstd1", kind: pakDeb,
      url: "https://deb.debian.org/debian/pool/main/libz/libzstd/" &
        "libzstd1_1.5.7+dfsg-1_armhf.deb",
      sha256: "da5238dd84fc51f782f39d435821bff556409b3dbc82d232e4e81f427fb1ca65")),
]

proc glibcOfZigTarget(zigTarget: string): string =
  ## The glibc version a zig glibc target names (`arm-linux-gnueabihf.2.38`
  ## -> `2.38`), or "" for a target without one.
  let at = zigTarget.find('.')
  if at < 0: "" else: zigTarget[at + 1 .. ^1]

proc sanitizeStaticExec(val: string): string =
  var cleanLines: seq[string] = @[]
  for line in val.splitLines:
    let s = line.strip()
    if s.len > 0 and not s.startsWith("io-mon:"):
      cleanLines.add(s)
  if cleanLines.len > 0: cleanLines[^1] else: ""

# The POSIX arm names NO executable. `staticExec` on POSIX already runs its
# argument through `/bin/sh -c` (`execCmdEx` + `poEvalCommand`), and `printf`
# is a shell builtin, so the whole read happens inside the shell the compiler
# started. The previous spelling wrapped this in a BARE `sh -c '…'`, which
# stopped resolving once a compile action's `PATH` became exactly
# `<nim>/bin:<gcc-wrapper>/bin` — the same defect, and the same fix, as the
# DSL's resource-accessor generator (see
# `repro_project_dsl/compile_time_shell.nim`). Windows keeps its explicit
# shell because there `staticExec` executes the program directly.
when defined(windows):
  const CompileTimeIoMonSrc =
    sanitizeStaticExec(staticExec("cmd /C if defined IO_MON_SRC (echo %IO_MON_SRC%)"))
  const CompileTimeStackableHooksSrc =
    sanitizeStaticExec(staticExec("cmd /C if defined STACKABLE_HOOKS_SRC (echo %STACKABLE_HOOKS_SRC%)"))
  const CompileTimeShmGsetSrc =
    sanitizeStaticExec(staticExec("cmd /C if defined SHM_GSET_SRC (echo %SHM_GSET_SRC%)"))
else:
  const CompileTimeIoMonSrc =
    sanitizeStaticExec(staticExec("printf %s \"${IO_MON_SRC:-}\""))
  const CompileTimeStackableHooksSrc =
    sanitizeStaticExec(staticExec("printf %s \"${STACKABLE_HOOKS_SRC:-}\""))
  const CompileTimeShmGsetSrc =
    sanitizeStaticExec(staticExec("printf %s \"${SHM_GSET_SRC:-}\""))

# Interface extraction compiles this project file without the provider build
# body. Keep the stdlib typed-value surface visible for generated DSL helpers.

# Bootstrap-And-Self-Build B4: Python tests participate in the ``test``
# build graph collection via the ``pythonUnittest`` typed-tool wrapper.
# Each entry in ``pythonTestPaths`` (generated by
# ``scripts/generate_test_edges.nim``) expands to one
# ``pythonUnittest.run(...)`` execute edge that the engine schedules
# alongside the Nim test execute edges. The wrapper records a
# ``PublicCliCall`` against the ``python3`` profile so the engine's
# normal tool-resolution path drives the run.
import repro_dsl_stdlib/packages/python_unittest_runner

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

# Test-Edges-And-Parallel-Runner M1: ``ct_test_nim_unittest`` is the in-tree
# Nim-unittest framework adapter that supplies the
# ``buildNimUnittest.build(...)`` typed-tool used by every entry in
# the generated ``repro_tests.nim``. The module re-exports
# ``repro_project_dsl`` so the import order is fine either way.
# ``config.nims`` adds ``libs/ct_test_nim_unittest/src`` to the Nim path.
import ct_test_nim_unittest
# Test-Binary-Grouping M2: the group plan's pure helpers (group module text,
# module path). The plan itself is stamped into ``repro_tests.nim``.
import ct_test_nim_unittest/grouping

# Spec-Implementation M4: install the in-process ct-test ``TestRunner``
# adapter (from the ``reprobuild-ct-test-runner`` repo) onto
# the active build context so ``repro test`` RUN/LIST/ENUMERATE route
# through the test binary's protocol instead of the stdlib default. The
# engine-coupled ``setTestRunner`` wiring lives in this reprobuild-side
# helper (see ``ct_test_runner_install.nim``); the install call fires from
# inside the ``build:`` block below where a build context is active.
import ct_test_runner_install

# Graph-Owned-Test-Artifacts M3: the test → graph-built-artifact table.
#
# The single place that answers "which graph-built artifacts does this test
# EXECUTE?". The test-execute loop below reads it to put each artifact's path
# on the edge as a typed input and each artifact's action id on the edge as an
# ordering dep; ``scripts/check_test_body_helper_compilation.py`` reads it to
# tell a migrated test apart from one that still compiles its own helper.
#
# ON PATHS, AND WHY THEY ARE SPELLED REPO-RELATIVE HERE.
#
# M3's open question was how a helper's location reaches the test binary
# "without reintroducing host-local assumptions", and this repository has been
# bitten by host paths reaching cache keys more than once. The answer used
# here is the one already established by ``reproBinaryPath`` in
# ``repro_test_support``: NOTHING absolute is written down. The graph names the
# artifact by a repo-relative path, which is what the engine fingerprints; the
# test resolves the same repo-relative path against ``ReprobuildRepoRoot``,
# which is derived from ``currentSourcePath()`` — the checkout that contains
# the test source — rather than from ``$PWD``, ``$HOME`` or an environment
# variable a runner may or may not have set. The absolute path exists only as
# a value inside the running test process; it never enters a fingerprint, an
# action id, or a tracked artifact.
#
# The corollary, and the reason this is a table rather than an env var: an
# artifact a test needs must be DECLARED, so that the edge re-runs when the
# artifact changes. Passing a path through the environment would move the
# dependency out of the graph's sight, which is the failure M3 is closing, not
# a way to close it.
type
  TestGraphArtifact* = object
    path*: string      ## repo-relative output path, as the producing edge declares it
    actionId*: string
      ## the producing edge's action id; EMPTY for a checked-in fixture file,
      ## which no edge produces — its path is still a typed input of the
      ## execute edge, so editing it re-runs the test, and there is nothing to
      ## order before it
  TestGraphArtifacts* = object
    source*: string
    artifacts*: seq[TestGraphArtifact]

const
  ctShimFixtureRoot = "build/test-fixtures/ct-test-unittest-parallel"
  installMirrorFixtureRoot = "build/test-fixtures/install-mirror-runtime"
  preloadHostAllocatorFixtureRoot =
    "build/test-fixtures/preload-host-allocator"

  ctShimProtocolThreeTests = TestGraphArtifact(
    path: ctShimFixtureRoot & "/fixture_protocol_three_tests",
    actionId: "reprobuild.test_fixtures.ct_shim_fixture_protocol_three_tests")
  ctShimProtocolAbortPaths = TestGraphArtifact(
    path: ctShimFixtureRoot & "/fixture_protocol_abort_paths",
    actionId: "reprobuild.test_fixtures.ct_shim_fixture_protocol_abort_paths")
  ctShimM4ParitySuite = TestGraphArtifact(
    path: ctShimFixtureRoot & "/fixture_m4_parity_suite",
    actionId: "reprobuild.test_fixtures.ct_shim_fixture_m4_parity_suite")
  ctShimBaselineStdUnittest = TestGraphArtifact(
    path: ctShimFixtureRoot & "/fixture_baseline_std_unittest",
    actionId: "reprobuild.test_fixtures.ct_shim_fixture_baseline")

  rp3FixtureRecipeRoot* = "tests/fixtures/rp3-bind-deps"
  rp3FixtureProviderRoot* = "build/test-fixtures/rp3-bind-deps"
    ## The RP3 bind-deps fixtures: five checked-in recipes (`dep`, `depv2`,
    ## `consumer-a`, `consumer-b`, `plain`), each compiled to a provider
    ## binary by its own graph edge (declared in the build block), so
    ## `t_rp3_bind_deps_and_sharing` runs providers and never compiles one.
    ## The edge ids are `reprobuild.test_fixtures.rp3_provider_<name>` with
    ## `-` folded to `_`.

  sc7CapstoneFixtureRoot* = "tests/fixtures/sc7-capstone"
    ## The SC-7 capstone's checked-in producer and consumer recipes; see
    ## ``tests/fixtures/sc7-capstone/README.md``.

  testDataFixtureRoot* = "build/test-fixtures"

  cvmTestKeysRoot* = "build/test-fixtures/cvm-test-keys"
  cvmTestKeysActionId* = "reprobuild.test_fixtures.cvm_test_rsa_keys"
  cvmTestKeys* = [
    "build/test-fixtures/cvm-test-keys/snp-marked-ark.key",
    "build/test-fixtures/cvm-test-keys/snp-marked-ask.key",
    "build/test-fixtures/cvm-test-keys/snp-unmarked-ark.key",
    "build/test-fixtures/cvm-test-keys/snp-unmarked-ask.key",
  ]
    ## The RSA-4096 keys of the software-root security-processor test
    ## hierarchies (`tests/integration/cvm_evidence_emulator.nim`,
    ## `snpTestRootKeyPath`), generated from fixed seeds by
    ## `tests/fixtures/cvm-test-keys/gen_cvm_test_keys.nim`. Four key
    ## generations cost about a CPU-minute, which every process of every test
    ## that minted a hierarchy paid at start-up.
  cvmTestKeysConsumers = [
    "tests/integration/t_genuine_tier_policy_refuses_emulated_cvm_evidence.nim",
    "tests/integration/t_cvm_evidence_emulator_all_protocol_paths.nim",
    "tests/integration/t_reproos_uki_through_the_cvm_path.nim",
  ]

  gm4bLikeUsesRoot* = "build/test-fixtures/gm4b-like-uses"
  gm4bLikeUsesActionId* = "reprobuild.test_fixtures.gm4b_like_uses"
  gm4bLikeUsesArtifact* =
    "build/test-fixtures/gm4b-like-uses/out/project-interface.rbsz"
    ## The interface of the recipe `t_e2e_home_profile_resolves_like_uses`
    ## compares a profile with (`tests/fixtures/gm4b/gen_gm4b_like_uses.nim`).
  gm4bCatalogImportsRoot* = "build/test-fixtures/gm4b-catalog-imports"
  gm4bCatalogImportsActionId* =
    "reprobuild.test_fixtures.gm4b_catalog_imports"
  gm4bCatalogImportsOutputs* = [
    "build/test-fixtures/gm4b-catalog-imports/payload/gm4bimported",
    "build/test-fixtures/gm4b-catalog-imports/reprobuild-packages/packages/" &
      "interfaces/gm4bimported/repro.nim",
    "build/test-fixtures/gm4b-catalog-imports/gm4b-contribution-catalog/" &
      "repro.nim",
    "build/test-fixtures/gm4b-catalog-imports/recipe-with-import/" &
      "project-interface.rbsz",
    "build/test-fixtures/gm4b-catalog-imports/recipe-without-import/" &
      "project-interface.rbsz",
  ]
    ## The tree of `t_e2e_home_profile_imports_contribution_catalog`
    ## (`tests/e2e/gm4b/gm4b_catalog_imports_fixture.nim`, whose
    ## `CatalogImportsOutputs` names the same files relative to the root).

  nixPackageFixtureActionId* = "reprobuild.test_fixtures.nix_package"
  nixPackageOutPathFixture* = "build/test-fixtures/nix-package/out-path"
    ## The store path of `nix build <this checkout>#default`, recorded by edge
    ## `nixPackageFixtureActionId` (`scripts/build_nix_package_fixture.sh`,
    ## Linux and macOS, `test-package-fixtures` collection) for the gates that
    ## run the INSTALLED package (`nixPackageGateSources`).
    ##
    ## Each of those gates' cases used to run the `nix build` itself. The
    ## build runs in the nix daemon's builder, outside the case's process
    ## group, and nix serialises concurrent builds of one derivation, so every
    ## case but one waited silently and the runner killed it on its IDLE
    ## TIMEOUT (full-suite runs 33 and 34). The cases now read this file
    ## (`tests/e2e/m83/nix_package_support.nim`, `nixPackageUnderTest`),
    ## check it against their own `nix eval` of the tree's `outPath`, and
    ## build only when it is absent or names a different tree's package.

  nixPackageFixtureArtifact = TestGraphArtifact(
    path: nixPackageOutPathFixture, actionId: nixPackageFixtureActionId)

  nixPackageGateSources* = [
    "tests/e2e/m83/t_e2e_nix_package_compiles_profile.nim",
    "tests/e2e/m83/t_e2e_nix_package_compiles_profile_clean_env.nim",
  ]

  M4ConsolidationVerificationTest* =
    "tests/integration/t_m4_pure_unit_consolidation.nim"
    ## Suite-Modernization M4. The one test whose execute edge takes EVERY
    ## shared pure-unit binary as a typed input; see the loop below.

  PerCaseFixtureGate* =
    "tests/integration/" &
    "t_when_each_case_runs_alone_no_fixture_outlives_its_process.nim"
    ## Runs each subject below the way the suite runner does -- a
    ## `--list-json` probe, then one process per case -- and fails when a
    ## fixture outlives the process that acquired it. Its execute edge takes
    ## every subject's binary as a typed input; see the loop below.

  PerCaseFixtureGateSubjects* = [
    "libs/repro_cas_store/tests/t_cas_ingest_link.nim",
    "libs/repro_cas_store/tests/t_cas_link_mutation_safety.nim",
    "libs/repro_cas_store/tests/t_cas_materialize_link.nim",
    "libs/repro_cas_store/tests/t_cas_store_occupancy_cost.nim",
    "libs/repro_cas_store/tests/t_link_capability_facts.nim",
    "libs/repro_cas_store/tests/t_link_capability_probe.nim",
    "libs/repro_cli_support/tests/t_l5_environment_is_in_the_graph_cache_key.nim",
    "libs/repro_fs_facts/tests/t_fs_facts_conformance.nim",
    "libs/repro_resources/tests/t_l4_service_instance_identity_and_state.nim",
    "libs/repro_resources/tests/t_l5_environment_is_in_the_instance_key.nim",
    "tests/integration/t_auto_runquota_shared_per_user_daemon.nim",
    "tests/integration/t_auto_runquota_uses_private_endpoint_policy.nim",
    "tests/integration/t_runquota_long_temp_rendezvous.nim",
    "tests/integration/t_runquota_auto_spawned_daemon_follows_host_config.nim",
    "tests/integration/t_build_declares_its_pools_to_runquota.nim",
    "tests/integration/t_runquota_daemon_from_another_build_makes_way.nim",
    "tests/integration/t_cloud_adapter_launches_nothing_in_ci.nim",
    "tests/integration/t_inline_launch_refuses_unhostable_monitor_hosting.nim",
    "tests/integration/t_leaked_instance_is_reaped.nim",
    "tests/integration/t_measurement_manifest_cross_check.nim",
    "tests/integration/t_monitor_fault_fails_the_action_not_the_daemon.nim",
    "tests/integration/t_snp_evidence_reaches_the_verdict.nim",
    "tests/integration/t_snp_expectation_reaches_the_manifest.nim",
    "tests/integration/t_tarball_provisioning_cold_store_extractors.nim",
    "tests/integration/t_tdx_expectation_reaches_the_verifier.nim",
    "tests/integration/t_teardown_runs_on_failure_path.nim",
    "tests/integration/t_vcs_lock_failure_preserves_action_and_publication_results.nim",
    "tests/integration/t_verify_e2e_mock.nim",
  ]
    ## The test files that once released their fixtures only in a final
    ## "teardown" CASE, or acquired them at module or suite scope and never
    ## released them, and so leaked them from every per-case process. Kept in
    ## step with the gate's own list by the gate's last case. A subject must
    ## sort BEFORE the gate in `reprobuildTestSpecs`, so that its build edge
    ## has been collected when the gate's execute edge is emitted.

  AgentHarborFixtureFailureGate* =
    "tests/integration/t_agent_harbor_fixture_failure_fails_the_case.nim"
    ## Runs each Agent Harbor gate below the way the suite runner does, with
    ## a failing `cc`, and fails unless the probe acquires nothing and the
    ## failed fixture install is a case's FAIL with a result document. Its
    ## execute edge takes every subject's binary as a typed input, collected
    ## like `PerCaseFixtureGate`'s.

  AgentHarborFixtureFailureGateSubjects* = [
    "tests/e2e/agent-harbor/t_e2e_agent_harbor_change_to_generation_and_remix.nim",
    "tests/e2e/agent-harbor/t_e2e_agent_harbor_combines_and_augments_remixes.nim",
    "tests/e2e/agent-harbor/t_e2e_agent_harbor_modifies_installed_source_package.nim",
    "tests/e2e/agent-harbor/t_e2e_agent_harbor_preview_accept_reject.nim",
  ]
    ## Kept in step with the test's own list by its last case. Every subject
    ## sorts before the test (`tests/e2e/` before `tests/integration/`).

  profileCompileNimSpy = TestGraphArtifact(
    path: "build/test-bin/nim_spy",
    actionId: "reprobuild.test_helpers.nim_spy")
    ## The pass-through `nim` the profile-compile-edge gates put first on
    ## PATH to count compiler spawns (`tests/e2e/m83/nim_spy.nim`). A
    ## compiled program, not a shell script, so the gates run on Windows and
    ## macOS too; every test that imports
    ## `tests/e2e/m83/profile_compile_edge_harness.nim` executes it.

  binaryCacheHelperConsumers = block:
    ## The tests that run the binary-cache server or its client CLI as
    ## helpers (``reprobuild.test_helpers.repro_binary_cache``, ``_m6`` with
    ## TLS, ``repro_binary_cache_client_cli``). Without a row a focused run of
    ## one of them found no helper unless a whole-graph build had made it
    ## earlier (found by the A8 review: two deploy-agent tests needed it
    ## copied by hand).
    const
      Base = TestGraphArtifact(path: "build/test-bin/repro_binary_cache",
        actionId: "reprobuild.test_helpers.repro_binary_cache")
      M6 = TestGraphArtifact(path: "build/test-bin/repro_binary_cache_m6",
        actionId: "reprobuild.test_helpers.repro_binary_cache_m6")
      Cli = TestGraphArtifact(
        path: "build/test-bin/repro_binary_cache_client_cli",
        actionId: "reprobuild.test_helpers.repro_binary_cache_client_cli")
    var rows: seq[TestGraphArtifacts]
    for (source, artifacts) in [
        ("libs/repro_deploy_agent/tests/t_repro_deploy_agent_converges_from_signed_manifest.nim", @[Base]),
        ("libs/repro_deploy_agent/tests/t_repro_https_cache_end_to_end.nim", @[M6]),
        ("libs/repro_profile_compile/tests/t_infra_apply_substitutes_from_cache.nim", @[Base]),
        ("tests/integration/t_tool_prefix_cache_round_trip_post_extract.nim", @[Base]),
        ("libs/repro_binary_cache_server/tests/t_repro_binary_cache_https_publish_authz.nim", @[M6]),
        ("libs/repro_binary_cache_client/tests/t_a2_5_p2_manifest_fetch.nim", @[Base]),
        ("libs/repro_binary_cache_client/tests/t_a2_5_p3_streaming_sink.nim", @[Base]),
        ("libs/repro_binary_cache_client/tests/t_a2_5_p4_engine_dispatch.nim", @[Base]),
        ("libs/repro_binary_cache_client/tests/t_a2_5_p5_closure_walk.nim", @[Base]),
        ("libs/repro_binary_cache_client/tests/t_a2_5_p6_daemon_substitute.nim", @[Base]),
        ("libs/repro_binary_cache_client/tests/t_a2_5_p6_daemon_substitute_ipc.nim", @[Base]),
        ("libs/repro_binary_cache_client/tests/t_a2_5_p7_in_process_substitute.nim", @[Base]),
        ("libs/repro_binary_cache_client/tests/t_a2_5_p8_throughput_bench.nim", @[Base]),
        ("libs/repro_binary_cache_client/tests/t_a3_p2_cli_substitute.nim", @[Base, Cli]),
        ("libs/repro_binary_cache_client/tests/t_a3_p6_closure_walk_r4.nim", @[Base]),
        ("libs/repro_binary_cache_client/tests/t_a4_p2_sentinel_wait.nim", @[Base]),
        ("libs/repro_binary_cache_client/tests/t_cache_connect_is_bounded.nim", @[Base]),
        ("libs/repro_binary_cache_client/tests/t_client_cli_prefix_substitute.nim", @[Base, Cli]),
        ("libs/repro_binary_cache_client/tests/t_portable_memo_cache.nim", @[Base]),
        ("libs/repro_binary_cache_client/tests/t_portable_memo_refuses_timestamp_records.nim", @[Base]),
        ("libs/repro_binary_cache_client/tests/t_r1_client_trust.nim", @[Base]),
        ("libs/repro_binary_cache_client/tests/test_publish_in_process.nim", @[Base]),
        ("libs/repro_cli_support/tests/t_materialized_restore_stages_under_a_private_name.nim", @[Base])]:
      rows.add TestGraphArtifacts(source: source, artifacts: artifacts)
    rows

  shellHookCountingShimConsumers = block:
    ## Every test that opens a case through
    ## `tests/e2e/dev-env/shell_hook_helper.prepareShellHookCase`, which
    ## requires the graph-built counting shim.
    var rows: seq[TestGraphArtifacts]
    for name in ["t_e2e_shell_hook_noop_io_bounded",
                 "t_e2e_shell_hook_noop_latency",
                 "t_e2e_shell_hook_realistic_workload",
                 "t_e2e_shell_hook_cd_activate_deactivate",
                 "t_e2e_shell_hook_nushell_activates"]:
      rows.add TestGraphArtifacts(
        source: "tests/e2e/dev-env/" & name & ".nim",
        artifacts: @[TestGraphArtifact(
          path: "build/test-bin/repro_shell_hook_counting_shim",
          actionId: "reprobuild.test_fixtures.shell_hook_counting_shim")])
    rows

  profileCompileNimSpyConsumers = block:
    var rows: seq[TestGraphArtifacts]
    for name in ["t_e2e_profile_compile_staticread_payload_change",
                 "t_e2e_profile_compile_runtime_read_tracked",
                 "t_e2e_home_export_matches_compiled_intent",
                 "t_e2e_home_export_check_detects_stale_snapshot",
                 "t_e2e_export_describes_other_platform_resources",
                 "t_e2e_export_refuses_compile_time_dependent_intent",
                 "t_e2e_home_set_writes_guarded_config",
                 "t_e2e_data_file_edit_does_not_recompile",
                 "t_e2e_data_file_rollback_restores_rows",
                 "t_e2e_data_file_validation",
                 "t_e2e_home_add_appends_data_row",
                 "t_e2e_home_export_expands_data_files",
                 "t_e2e_nix_reads_data_like_profile",
                 "t_e2e_nix_reads_intent_like_export",
                 "t_e2e_profile_compile_clang_first_run_published",
                 "t_e2e_profile_compile_ignores_ancestor_membership",
                 "t_e2e_profile_resave_without_edit_does_not_recompile",
                 "t_e2e_home_facts_from_isolated_plan",
                 "t_e2e_activity_scoped_resource_follows_host_selection",
                 "t_e2e_profile_compiles_of_one_profile_are_serialised"]:
      rows.add TestGraphArtifacts(source: "tests/e2e/m83/" & name & ".nim",
        artifacts: @[profileCompileNimSpy])
    # ReproOS add-on mode gates (`tests/e2e/addon/`), on the same harness.
    for name in ["t_addon_registry_mode_round_trip",
                 "t_system_profile_host_selection",
                 "t_addon_mode_mismatch_is_refused"]:
      rows.add TestGraphArtifacts(source: "tests/e2e/addon/" & name & ".nim",
        artifacts: @[profileCompileNimSpy])
    # Integration tests on the same harness: `repro system plan|apply` beside
    # `repro infra plan|apply`, and the `--json` documents.
    rows.add TestGraphArtifacts(source: "tests/integration/" &
      "t_system_plan_apply_symmetry_and_universal_json.nim",
      artifacts: @[profileCompileNimSpy])
    # The clang first-run gate's positive control compiles through a "clang"
    # that drops `-fno-temp-file` (`tests/e2e/m83/exec_without_arg.nim`); a
    # compiled program for the reason `nim_spy` is one, so the control runs
    # on macOS as well as Linux.
    rows.add TestGraphArtifacts(
      source: "tests/e2e/m83/" &
        "t_e2e_profile_compile_clang_first_run_published.nim",
      artifacts: @[TestGraphArtifact(path: "build/test-bin/exec_without_arg",
        actionId: "reprobuild.test_helpers.exec_without_arg")])
    rows

  cvmTestKeysRows = block:
    var rows: seq[TestGraphArtifacts]
    for source in cvmTestKeysConsumers:
      var artifacts: seq[TestGraphArtifact]
      for path in cvmTestKeys:
        artifacts.add TestGraphArtifact(path: path,
          actionId: cvmTestKeysActionId)
      rows.add TestGraphArtifacts(source: source, artifacts: artifacts)
    rows

  testFixtureArtifacts*: seq[TestGraphArtifacts] = @[
    # Execute the enrolled production CLI, not a test-only compilation.
    TestGraphArtifacts(
      source: "tests/integration/t_agent_conformance_cli_portability.nim",
      artifacts: @[TestGraphArtifact(
        path: "build/bin/repro-agent-conformance",
        actionId: "reprobuild.apps.repro-agent-conformance")]),
    # The engine runs the per-test producer from beside its own image, so a
    # `repro test` of a package that uses `runPerTest` needs the shipped app.
    TestGraphArtifacts(
      source: "tests/integration/" &
        "test_cs_m14_repro_collects_tests_per_entry.nim",
      artifacts: @[TestGraphArtifact(
        path: "build/bin/repro-tests-fragment",
        actionId: "reprobuild.apps.repro-tests-fragment")]),
    TestGraphArtifacts(
      source: "tests/integration/" &
        "test_cs_m14_shim_answers_tests_entry.nim",
      artifacts: @[TestGraphArtifact(
        path: "build/bin/repro-tests-fragment",
        actionId: "reprobuild.apps.repro-tests-fragment")]),
    # The engine runs the completion edge's producer from beside its own
    # image, so a build of a package with a `cli:` executable needs it.
    TestGraphArtifacts(
      source: "tests/integration/" &
        "test_cs_m14_package_build_generates_completion_files.nim",
      artifacts: @[TestGraphArtifact(
        path: "build/bin/repro-completion-files",
        actionId: "reprobuild.apps.repro-completion-files")]),
    # Same producer: the packages of a `cli:` executable carry its files.
    TestGraphArtifacts(
      source: "tests/integration/" &
        "test_cs_m8d_generated_packages_add_completion.nim",
      artifacts: @[TestGraphArtifact(
        path: "build/bin/repro-completion-files",
        actionId: "reprobuild.apps.repro-completion-files")]),
    TestGraphArtifacts(
      source: "libs/repro_build_engine/tests/t_engine_macos_sip_safe_launch.nim",
      artifacts: @[TestGraphArtifact(
        path: "build/test-fixtures/macos-no-bundle/no_bundle_launch",
        actionId: "reprobuild.test_fixtures.macos_no_bundle_launch")]),
    TestGraphArtifacts(
      source: "tests/integration/t_d1_buildnimunittest_resolves_in_path_mode.nim",
      artifacts: @[
        TestGraphArtifact(path: "build/test-fixtures/runquota/runquotad",
          actionId: "reprobuild.test_fixtures.runquotad")]),
    TestGraphArtifacts(
      source: "tests/integration/t_b0_develop_mode_uses_local_source.nim",
      artifacts: @[
        TestGraphArtifact(path: "build/test-fixtures/runquota/runquotad",
          actionId: "reprobuild.test_fixtures.runquotad")]),
    TestGraphArtifacts(
      source: "tests/integration/t_runner_exclusive_phase_budget.nim",
      artifacts: @[
        TestGraphArtifact(path: "build/bin/repro_test_runner",
          actionId: "reprobuild.test_helpers.repro_test_runner"),
        TestGraphArtifact(path: "build/test-fixtures/exclusive-phase/exclusive_phase_probe",
          actionId: "reprobuild.test_fixtures.exclusive_phase_probe")]),
    # SHARED, and deliberately so. ``fixture_protocol_three_tests`` is one
    # artifact behind two tests (six cases); before M3 each case compiled a
    # private copy into its own scratch directory to avoid relinking a binary
    # a sibling case was executing.
    TestGraphArtifacts(
      source: "libs/ct_test_unittest_parallel/tests/" &
        "t_every_test_binary_speaks_list_json_protocol.nim",
      artifacts: @[ctShimProtocolThreeTests]),
    TestGraphArtifacts(
      source: "libs/ct_test_unittest_parallel/tests/" &
        "t_test_binary_run_one_writes_result_file.nim",
      artifacts: @[ctShimProtocolThreeTests, ctShimProtocolAbortPaths]),
    # SHARED likewise: one parity fixture behind the parity test and the
    # partition-file test.
    TestGraphArtifacts(
      source: "libs/ct_test_unittest_parallel/tests/" &
        "t_ct_test_runner_full_suite_parity.nim",
      artifacts: @[ctShimM4ParitySuite]),
    TestGraphArtifacts(
      source: "libs/ct_test_unittest_parallel/tests/" &
        "t_ct_test_runner_partition_file_mode.nim",
      artifacts: @[ctShimM4ParitySuite]),
    TestGraphArtifacts(
      source: "libs/ct_test_unittest_parallel/tests/" &
        "t_backward_compat_std_unittest_test_runs_unchanged.nim",
      artifacts: @[ctShimBaselineStdUnittest]),
    # THE SHIPPING APP BINARY, not a test-only rebuild of it.
    # ``apps/repro-peer-cache-admin/repro_peer_cache_admin.nim`` is listed in
    # ``apps/entrypoints.txt`` and is already built by the ``apps`` collection
    # (edge ``reprobuild.apps.repro-peer-cache-admin`` →
    # ``build/bin/repro-peer-cache-admin``). Declaring a SECOND edge over the
    # same source, into ``build/test-bin`` with a second nimcache, would be two
    # builds of one source — which is precisely what "built once through the
    # graph" forbids, and would have made M3 violate the property it exists to
    # establish. The test consumes the app edge's output.
    TestGraphArtifacts(
      source: "libs/repro_peer_cache/tests/t_peer_cache_admin_cli_status.nim",
      artifacts: @[TestGraphArtifact(
        path: "build/bin/repro-peer-cache-admin",
        actionId: "reprobuild.apps.repro-peer-cache-admin")]),
    TestGraphArtifacts(
      source: "tests/integration/t_installer_tarball_shared_cache.nim",
      artifacts: @[TestGraphArtifact(
        path: "build/bin/repro-binary-cache",
        actionId: "reprobuild.apps.repro-binary-cache")]),
    TestGraphArtifacts(
      source: "tests/integration/t_rp3_bind_deps_and_sharing.nim",
      artifacts: @[
        TestGraphArtifact(path: rp3FixtureProviderRoot & "/dep",
          actionId: "reprobuild.test_fixtures.rp3_provider_dep"),
        TestGraphArtifact(path: rp3FixtureProviderRoot & "/depv2",
          actionId: "reprobuild.test_fixtures.rp3_provider_depv2"),
        TestGraphArtifact(path: rp3FixtureProviderRoot & "/consumer-a",
          actionId: "reprobuild.test_fixtures.rp3_provider_consumer_a"),
        TestGraphArtifact(path: rp3FixtureProviderRoot & "/consumer-b",
          actionId: "reprobuild.test_fixtures.rp3_provider_consumer_b"),
        TestGraphArtifact(path: rp3FixtureProviderRoot & "/plain",
          actionId: "reprobuild.test_fixtures.rp3_provider_plain")]),
    # CHECKED-IN fixture recipes, not graph-built artifacts: no producing
    # edge, so no action id. The test copies them into its scratch tree; their
    # bytes are fixed so the run-wide action cache serves their recipe
    # compiles (see the note in the test).
    TestGraphArtifacts(
      source: "tests/integration/" &
        "t_sc_capstone_reprobuild_runquota_and_library_edge_both_modes.nim",
      artifacts: @[
        TestGraphArtifact(path: sc7CapstoneFixtureRoot & "/exeprod/repro.nim"),
        TestGraphArtifact(path: sc7CapstoneFixtureRoot & "/libprod/repro.nim"),
        TestGraphArtifact(path: sc7CapstoneFixtureRoot & "/libprod/greeting.h"),
        TestGraphArtifact(path: sc7CapstoneFixtureRoot & "/consumer/repro.nim"),
        TestGraphArtifact(path: sc7CapstoneFixtureRoot & "/consumer/main.c"),
        TestGraphArtifact(
          path: sc7CapstoneFixtureRoot & "/noedge-consumer/repro.nim")]),
    TestGraphArtifacts(
      source: "tools/catalog-harvester/tests/" &
        "test_harvester_app_name_validation.nim",
      artifacts: @[TestGraphArtifact(
        path: "build/test-bin/repro_catalog_harvester",
        actionId: "reprobuild.test_helpers.repro_catalog_harvester")]),
    # The launcher test executes both helpers. Without this row its execute
    # edge fingerprinted neither, so a focused run of the test served a
    # stale `repro_trampoline` built from an older tree.
    TestGraphArtifacts(
      source: "tests/integration/" &
        "t_the_resolving_launcher_execs_the_pinned_image.nim",
      artifacts: @[
        TestGraphArtifact(path: "build/test-bin/repro_trampoline",
          actionId: "reprobuild.test_helpers.repro_trampoline"),
        TestGraphArtifact(path: "build/test-bin/m5_stub_repro_image",
          actionId: "reprobuild.test_helpers.m5_stub_repro_image")]),
    # The tests below executed a graph-built helper with no row here, so a
    # run that had not built the whole `test-helpers` / `test-fixtures`
    # collections first failed on the missing file, and a rebuilt helper did
    # not re-run them.
    TestGraphArtifacts(
      source: "tests/integration/t_repro_test_runner_catalog_selection.nim",
      artifacts: @[TestGraphArtifact(path: "build/bin/repro_test_runner",
        actionId: "reprobuild.test_helpers.repro_test_runner")]),
    TestGraphArtifacts(
      source: "tests/integration/t_local_daemons_control_plane_m2.nim",
      artifacts: @[TestGraphArtifact(path: "build/test-bin/live_endpoint_helper",
        actionId: "reprobuild.test_helpers.live_endpoint_helper")]),
    TestGraphArtifacts(
      source: "tests/integration/t_local_daemons_control_plane_m11.nim",
      artifacts: @[TestGraphArtifact(
        path: "build/test-bin/fake_protocol_daemon_helper",
        actionId: "reprobuild.test_helpers.fake_protocol_daemon_helper")]),
  ] & shellHookCountingShimConsumers & profileCompileNimSpyConsumers & binaryCacheHelperConsumers &
    cvmTestKeysRows & @[
    TestGraphArtifacts(
      source: "tests/e2e/gm4b/t_e2e_home_profile_resolves_like_uses.nim",
      artifacts: @[TestGraphArtifact(path: gm4bLikeUsesArtifact,
        actionId: gm4bLikeUsesActionId)]),
    TestGraphArtifacts(
      source: "tests/e2e/gm4b/" &
        "t_e2e_home_profile_imports_contribution_catalog.nim",
      artifacts: block:
        # Not the payload: it has no extension, so on Windows the row
        # would name `gm4bimported.exe`. The catalog carries its sha256, so
        # a changed payload re-runs the test through the catalog anyway.
        var files: seq[TestGraphArtifact]
        for path in gm4bCatalogImportsOutputs[1 .. ^1]:
          files.add TestGraphArtifact(path: path,
            actionId: gm4bCatalogImportsActionId)
        files)] &
    (when defined(linux) and defined(amd64): @[
    TestGraphArtifacts(
      source: "tests/e2e/hcr-linux-threads/" &
        "t_integration_hcr_linux_stack_mapping_changes_do_not_fault.nim",
      artifacts: @[TestGraphArtifact(
        path: "build/test-fixtures/hcr-linux-stack-access/stack-access",
        actionId: "reprobuild.test_fixtures.hcr_linux_stack_access")])]
    else: @[]) & (when defined(linux): @[
    TestGraphArtifacts(
      source: "tests/integration/" &
        "t_preloaded_monitor_shim_keeps_out_of_the_host_allocator.nim",
      artifacts: @[
        TestGraphArtifact(
          path: preloadHostAllocatorFixtureRoot &
            "/clock-under-allocator-lock",
          actionId: "reprobuild.test_fixtures.clock_under_allocator_lock"),
        TestGraphArtifact(
          path: preloadHostAllocatorFixtureRoot &
            "/liballocating_clock_hook.so",
          actionId: "reprobuild.test_fixtures.allocating_clock_hook")])]
    else: @[]) & (when defined(linux) or defined(macosx): @[
    # Linux and macOS, where the producing edge is declared (there is no Nix
    # package on Windows; both gates skip there).
    TestGraphArtifacts(source: nixPackageGateSources[0],
      artifacts: @[nixPackageFixtureArtifact]),
    TestGraphArtifacts(source: nixPackageGateSources[1],
      artifacts: @[nixPackageFixtureArtifact])]
    else: @[])

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

proc windowsDiyInstallRoot(): string =
  ## The metacraft Windows DIY toolchain root, resolved as the workspace
  ## ``env.ps1``'s ``Get-DefaultInstallRoot`` does: explicit override first,
  ## then ``D:\`` (where the shared binary cache lives), then
  ## ``%LOCALAPPDATA%``. Empty when none of those exist.
  ##
  ## Candidates are VALIDATED rather than taken on faith, because
  ## ``WINDOWS_DIY_INSTALL_ROOT`` means two different things in this tree.
  ## ``windows/bootstrap-toolchain.ps1`` sets it to the TOOLCHAIN install
  ## root -- ``%LOCALAPPDATA%\reprobuild\toolchains``, where
  ## ``ensure-nim.ps1`` and ``ensure-gcc.ps1`` unpack nim and gcc -- while
  ## everything below wants the metacraft-dev-deps root that holds msys2 and
  ## the fixture toolchains. One name, two roots.
  ##
  ## Taking the variable literally therefore broke every probe in the
  ## Windows ``devEnv:`` block the moment ``env.ps1`` had run: swift, gradle,
  ## maven, jdk, zig, go, dotnet, fpc, the WinLibs gcc lib dir and msys2 all
  ## resolved under a directory with none of that layout, so each one
  ## silently contributed nothing while the dev-env reported success. The
  ## marker check below is what turns "wrong root" into "keep looking".
  proc looksLikeDiyRoot(candidate: string): bool =
    if candidate.len == 0 or not dirExists(candidate):
      return false
    # The markers are exactly the fixtures this root is probed FOR, which is
    # also what makes them discriminating: the toolchain install root that
    # bootstrap-toolchain.ps1 points the variable at holds nim, gcc, clingo,
    # gh and git-repo -- so `gcc` and `clingo` would match BOTH roots and
    # settle nothing. None of the entries below appears there.
    # A host need not have provisioned all of them; one is enough.
    for marker in ["msys2", "swift", "gradle", "maven", "jdk", "zig", "go",
                   "dotnet", "fpc"]:
      if dirExists(candidate / marker):
        return true
    false

  var candidates: seq[string] = @[]
  let explicitRoot = getEnv("WINDOWS_DIY_INSTALL_ROOT")
  if explicitRoot.len > 0:
    candidates.add(explicitRoot)
  if dirExists("D:\\"):
    candidates.add("D:/metacraft-dev-deps")
  let localAppData = getEnv("LOCALAPPDATA")
  if localAppData.len > 0:
    candidates.add(localAppData / "metacraft-dev-deps")

  for candidate in candidates:
    if looksLikeDiyRoot(candidate):
      return candidate
  # None carried the layout: fall back to the first candidate that at least
  # exists, preserving the previous behaviour for a host that set the
  # variable deliberately at a root not yet populated.
  for candidate in candidates:
    if dirExists(candidate):
      return candidate
  ""

const
  ## Fixture toolchain pins, moved here verbatim from the metacraft
  ## workspace's ``windows/toolchain-versions.env`` along with the
  ## toolchains themselves. These are NOT "whatever is installed" — each
  ## one is part of a fixture contract:
  ##
  ##   * ``ZigVersion`` is a pre-1.0 pin; bumping it requires re-auditing
  ##     the M44 zig-mode3 / mixed-zig fixtures.
  ##   * ``DotnetSdkVersion`` stays in the 8.0 LTS band so the SDK's own
  ##     shared runtime keeps the same major as the deployed 8.0.3 CoreCLR
  ##     the fixtures target (patch roll-forward is automatic, major is
  ##     not). 8.0 goes EOL 2026-11-10 — once the fixtures no longer have
  ##     to match an 8.0.3 host, move to the 10.0 LTS pin.
  ##   * ``FpcVersion`` bumps require re-validating the ``_lang_survey``
  ##     pascal fixture.
  ##
  ## Discovery must not second-guess them: resolving "the newest directory
  ## under ``<root>/<tool>/``" would pick a 9.0 .NET SDK over the pinned
  ## 8.0 one, and sorts ``3.9.9`` above ``3.9.16``. An unpinned version
  ## present on disk is not the version these fixtures were validated
  ## against, so it reads as "not provisioned".
  JdkVersion = "21.0.5"
  MavenVersion = "3.9.16"
  GradleVersion = "8.10.2"
  SwiftVersion = "5.10.1"
  ZigVersion = "0.13.0"
  GoVersion = "1.23.4"
  DotnetSdkVersion = "8.0.424"
  FpcVersion = "3.2.2"

proc newestDirWith(root, probe: string): string =
  ## Highest-sorting directory under `root` that carries `probe`, mirroring
  ## ``env.ps1``'s ``Get-ChildItem -Directory | Sort-Object -Descending``
  ## walks. Used ONLY for gcc, which — unlike the fixture toolchains above
  ## — carries no version pin: it is provisioned by the framework's
  ## ``ensure-gcc.ps1`` (WinLibs, one version per install), so "whichever
  ## one is there" is the correct answer rather than a pin violation.
  if root.len == 0 or not dirExists(root):
    return ""
  var newest = ""
  for kind, path in walkDir(root):
    if kind notin {pcDir, pcLinkToDir}:
      continue
    if not (fileExists(path / probe) or dirExists(path / probe)):
      continue
    if newest.len == 0 or path > newest:
      newest = path
  newest

proc windowsI686Gcc(): string =
  ## Absolute path to a 32-bit (i686) mingw ``gcc``, or "" when the host has
  ## none. Mirrors the resolution order in ``io-mon/scripts/build_shim.sh``:
  ## the ``IO_MON_I686_GCC`` override first, then a cross-prefixed driver on
  ## PATH, then the MSYS2 ``mingw32`` prefix under the metacraft DIY root.
  ##
  ## Deliberately NOT resolved by putting the i686 bin dir on the ambient
  ## PATH. A bare ``gcc`` there would win over the 64-bit driver for the
  ## 64-bit shim edge too, and that build then dies on a pointer-size assert
  ## rather than on anything naming the cause. The path is handed to the
  ## 32-bit edges explicitly instead (``gccExe`` / ``gccLinkerExe``), and the
  ## bin directory is scoped to those edges' own env.
  ##
  ## ``IO_MON_I686_GCC`` is AUTHORITATIVE when set. A value naming a file
  ## that does not exist reports "no toolchain" — which takes the
  ## degradation path and says out loud what will not be monitored — rather
  ## than falling through to a different compiler than the operator named.
  ## Silently substituting one would reintroduce the failure shape this
  ## whole initiative exists to remove.
  let fromEnv = getEnv("IO_MON_I686_GCC")
  if fromEnv.len > 0:
    return (if fileExists(fromEnv): fromEnv else: "")
  let onPath = uncontrolledFindExe("i686-w64-mingw32-gcc")
  if onPath.len > 0:
    return onPath
  let diyRoot = windowsDiyInstallRoot()
  if diyRoot.len > 0:
    let msys2I686 =
      diyRoot / "msys2" / "msys64" / "mingw32" / "bin" / "gcc.exe"
    if fileExists(msys2I686):
      return msys2I686
  ""

proc missingI686ToolchainNote(): string =
  ## The degradation message, in one place so the ``build:`` block and the
  ## ``devEnv:`` block cannot drift apart. It names the artefacts, what stops
  ## being monitored without them, and the fix — because the failure it
  ## describes produces no error of its own downstream: the injector meets a
  ## 32-bit child, finds no shim, refuses, and the subtree simply goes
  ## unobserved.
  var missing: seq[string] = @[]
  for name in windowsCrossBitnessArtifactNames():
    missing.add(monitorArtifactPath(name))
  "no i686 (32-bit) toolchain found, so " & missing.join(", ") &
    " will NOT be built. 32-bit child processes (scoop PATH shims and " &
    "older toolchain binaries are i386) cannot be injected without them; " &
    "their subtrees run UNMONITORED, which grades as an unknown-scope " &
    "evidence loss and makes the owning action uncacheable. Install one " &
    "with 'pacman -S mingw-w64-i686-gcc', or point IO_MON_I686_GCC at an " &
    "existing i686 gcc.exe."

proc shimLinkEnvironment(): seq[(string, string)] =
  ## The link environment of the Linux preload shim: no rpath of the linker
  ## wrapper's making may reach it. The same rule, for the same reasons, as
  ## ``preload_shim_link_without_rpath`` in
  ## ``scripts/lib/preloaded_shim_loader.sh``, which states them at length:
  ##
  ## * ``NIX_DONT_SET_RPATH=1`` stops the nixpkgs ``ld`` wrapper adding an
  ##   rpath entry for every ``-L`` directory, the C runtime's included.
  ## * every ``NIX_LDFLAGS*`` variable is emptied, because stdenv's setup puts
  ##   ``-rpath $out/lib`` into ``NIX_LDFLAGS``, and in ``nix develop``
  ##   ``$out`` is ``<checkout>/outputs/out``. An action's environment is
  ##   layered over the engine's own, so without this the shim came out with
  ##   a DT_RUNPATH naming that nonexistent build-host directory, and any
  ##   DT_RUNPATH on a preloaded library switches off the host program's
  ##   DT_RPATH for the library's dependencies: a program that finds its C
  ##   runtime through its own DT_RPATH then cannot start under the monitor
  ##   (``libm.so.6: cannot open shared object file``).
  ##
  ## The shim needs nothing ``NIX_LDFLAGS`` carries: its DT_NEEDED is the C
  ## runtime, which the compiler driver finds on its own. Both are
  ## nixpkgs-specific and inert elsewhere; the artifact checks (run_tests.sh
  ## after ``.#test-fixtures``, and
  ## ``tests/integration/t_preloaded_monitor_shim_carries_no_runpath.nim``,
  ## which replays this edge's lowered link) are the guarantee.
  result = @[("NIX_DONT_SET_RPATH", "1"), ("NIX_LDFLAGS", "")]
  # The wrapper also reads the role-salted spellings
  # (``NIX_LDFLAGS_<target>``, ``_FOR_TARGET``, ``_BEFORE``); empty whichever
  # of them the engine's environment carries, so none can be layered in.
  # Sorted, so the action's environment does not depend on `environ` order.
  var salted: seq[string] = @[]
  for key, _ in envPairs():
    if key.startsWith("NIX_LDFLAGS") and key != "NIX_LDFLAGS":
      salted.add(key)
  for key in sorted(salted):
    result.add((key, ""))

proc linuxShimDefines(zigTriple: string): seq[string] =
  ## The Nim defines of the Linux preload shim edge, mirroring io-mon's
  ## ``scripts/build_shim.sh``. ``zigTriple`` is the zig cross target's
  ## triple, or "" for a native build.
  ##
  ## * ``useMalloc``: io-mon refuses to compile the shim library without it
  ##   (the per-thread Nim heaps return a cell through the TLS of a host
  ##   thread that may already have exited).
  ## * ``ioMonGlibcPrivateHeap``: on glibc, the shim's own
  ##   malloc/calloc/realloc/free references are linked (``--wrap``) to a
  ##   private allocator over anonymous ``mmap`` inside io-mon. Without it
  ##   ``useMalloc`` takes them from WHATEVER allocator the host program
  ##   provides, and the shim's hooks run inside that allocator: jemalloc,
  ##   which rustc links statically, calls ``clock_gettime`` from
  ##   ``arena_new`` while it holds ``arenas_lock``, the shim's
  ##   ``clock_gettime`` hook formats its evidence record with a Nim string,
  ##   and the allocation re-enters jemalloc, which waits on its own
  ##   non-recursive lock forever. That is how the release shim built by
  ##   this edge hung every rustc it was preloaded into (rustc 1.94, a first
  ##   ``--print=file-names`` probe, all threads in ``futex_wait``), while
  ##   the Nix package, built by ``build_shim.sh``, did not.
  ##   ``tests/integration/t_preloaded_monitor_shim_keeps_out_of_the_host_allocator.nim``
  ##   runs the shim this edge produces inside a program that reads the clock
  ##   under its allocator lock.
  ##
  ## io-mon passes ``ioMonGlibcPrivateHeap`` when the build host's C runtime
  ## is glibc (``getconf GNU_LIBC_VERSION``). This edge builds for the build
  ## host or for a zig ``*-linux-gnu*`` target, which are glibc on every
  ## platform the repository ships, so the define is withheld only from a
  ## musl target.
  result = @["useMalloc"]
  if "musl" notin zigTriple:
    result.add("ioMonGlibcPrivateHeap")

proc pinnedToolDir(root, tool, version, probe: string): string =
  ## ``<root>/<tool>/<version>`` when it exists and carries `probe`, else
  ## "". Same contract as ``env.ps1``'s ``Test-Path`` guards: a missing or
  ## differently-versioned install reads as "not provisioned" rather than
  ## as a broken path, which is what makes the fixtures SKIP cleanly.
  if root.len == 0:
    return ""
  let dir = root / tool / version
  if fileExists(dir / probe) or dirExists(dir / probe):
    return dir

proc recipeProjectRoot(): string =
  ## The checkout this recipe is evaluated for: the provider's request-supplied
  ## root, or the process directory outside a provider dispatch (the recipe's
  ## own directory in every path that reaches here).
  result = activeProviderProjectRoot()
  if result.len == 0:
    result = getCurrentDir()

proc loadNixFlake(): bool =
  ## ``REPRO_LOAD_NIX_FLAKE`` from the project's ``.env`` (the same file
  ## ``.envrc`` loads with ``dotenv_if_exists``). Absent file or absent key
  ## means the flake is loaded. Only an explicit ``0`` / ``false`` / ``no`` /
  ## ``off`` selects the repro-native environment.
  let root = recipeProjectRoot()
  if not fileExists(root / ".env"):
    return true
  # `readDevEnvFile` records the read as an evaluation input of the dev-env
  # introspection; it exists only in the provider build, which is the only
  # one whose answer matters here.
  let text =
    when defined(reproProviderMode): readDevEnvFile(".env")
    else: readFile(root / ".env")
  for rawLine in text.splitLines():
    var line = rawLine.strip()
    if line.startsWith("export "):
      line = line["export ".len .. ^1].strip()
    let eq = line.find('=')
    if line.startsWith("#") or eq <= 0:
      continue
    if line[0 ..< eq].strip() != "REPRO_LOAD_NIX_FLAKE":
      continue
    let value = line[eq + 1 .. ^1].strip().strip(chars = {'"', '\''})
    return value.toLowerAscii() notin ["0", "false", "no", "off"]
  true
