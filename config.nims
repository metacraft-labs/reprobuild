import std/[os, strutils, compilesettings]

# The directory holding THIS file, resolved independently of whatever project
# nim happens to be compiling.
#
# `thisDir()` cannot be used for this and the difference is not academic.
# `repro_profile_compile` compiles a profile that lives outside this repo, and
# it makes this config reachable by STAGING a wrapper `config.nims` next to the
# profile which `include`s this file (see `compile.nim`). Under an `include`,
# `thisDir()` reports the INCLUDER's directory — the profile's — while
# `currentSourcePath()` reports this file. Measured during a real profile
# compile:
#
#   thisDir()           -> C:\rt\cspprobe            (the profile's directory)
#   currentSourcePath() -> ...\reprobuild\src\config.nims
#
# So every relative path below is relative to the PROFILE when a profile is
# being compiled, and to this repo the rest of the time. Anything that must
# denote a location in THIS repository has to be anchored here instead.
let reproRepoRoot = currentSourcePath().parentDir()

switch("styleCheck", "hint")

if defined(windows):
  switch("define", "sslVersion=3-x64")



# M9.R.47.2 — undefine ``nixbuild`` so Nim's ``{.dynlib: <const>.}`` pragma
# does NOT bake an absolute ``/nix/store/<hash>-<pkg>/lib/<lib>.so`` path
# into the binary's ``.rodata`` at compile time.
#
# Background: nixpkgs's Nim ships ``define:nixbuild`` in its ``nim.cfg``
# (line 365 of ``<nim>/nim/config/nim.cfg``).  With ``nixbuild`` active,
# ``stdlib.dynlib.libCandidates`` walks ``NIX_LDFLAGS`` ``-L`` entries +
# ``LD_LIBRARY_PATH`` at COMPILE time and replaces a bare-name candidate
# such as ``libclingo.so`` with its resolved absolute path.  Nim's
# ``cgen.loadDynamicLib`` then emits that absolute path verbatim as a C
# string literal, and ``nimLoadLibrary`` dlopens it at module init.
#
# Once the staged ReproOS rootfs relocates /nix/store -> /repro/store
# (M9.R.46.2), the baked absolute path no longer exists; dlopen fails
# with ENOENT and ``repro hardware probe`` aborts with
# ``could not load: libclingo.so`` (and any other Nim-dynlib library).
# patchelf cannot rewrite ``.rodata``.
#
# Undefining ``nixbuild`` restores Nim's default behaviour:
# ``libCandidates("libclingo.so") -> @["libclingo.so"]`` and the codegen
# emits ``dlopen("libclingo.so", RTLD_NOW)``.  The dynamic loader then
# resolves the soname through DT_RUNPATH (which patchelf rewrites at
# stage time) and ``ld.so.cache`` (M9.R.46.6 forwards its baked path
# via the carve-out symlinks).  See
# ``recipes/reproos-iso/run-evidence/m9r47_phaseA_audit.txt``.
#
# reprobuild does not use the ``nixbuild`` define anywhere else, so the
# undef is a safe one-line guard for every ``nim c`` invocation that
# config.nims governs (i.e. every reprobuild binary built from the repo).
switch("undef", "nixbuild")

# THE ORDER OF ``switch("path", …)`` IN THIS FILE IS THE REVERSE OF THE ORDER
# NIM SEARCHES. ``nimblecmd.addPath`` does ``conf.searchPaths.insert(path, 0)``,
# so every entry is PREPENDED: the LAST ``--path`` added is the FIRST one
# ``rawFindFile`` probes, and the first one added is probed last. A block placed
# at the top of this file therefore ends up at the BACK of the search path,
# where it costs a miss only for the lookups that get all the way down to it.
#
# That is why the RunQuota block is here rather than at the bottom, which is
# where it used to sit. Measured against the cold ``nim c`` of
# ``apps/repro/repro.nim`` at 9a44bf28 (strace -f -e trace=newfstatat, counting
# probes on ``*.nim`` paths): from the bottom of this file its 16 entries
# occupied search indices 0-15 — probed FIRST by every single module lookup —
# and absorbed 19,284 of the 94,968 raw search-path misses (20.3%) while
# resolving 14 modules. Moving the block here moves those entries to the back
# and removes the bulk of that cost with no change to what anything resolves to
# (see the search-order note at the end of this file for how that is checked).
#
# Nothing else about the block changed: these are still RunQuota's libraries,
# resolved from ``$RUNQUOTA_SRC`` or the sibling checkout, and the list still
# mirrors ``runquota``'s own ``libs/`` set.
let runquotaRoot = block:
  let fromEnv = getEnv("RUNQUOTA_SRC")
  if fromEnv.len > 0:
    fromEnv
  else:
    ".." / "runquota"

for libName in [
  "runquota_core",
  "runquota_codec",
  "runquota_protocol",
  "runquota_ipc",
  "runquota_client",
  "runquota_process",
  "runquota_exec",
  "runquota_admission",
  "runquota_host",
  "runquota_host_linux",
  "runquota_host_macos",
  "runquota_host_windows",
  "runquota_persistence",
  "runquota_daemon",
  "runquota_cli_support",
  "runquota_partition",
]:
  switch("path", runquotaRoot / "libs" / libName / "src")

# Project-DSL-Composition M6: ``repro.nim`` ``import``s the generated
# ``repro_tests.nim`` (data table of declared test edges) that lives
# alongside it at the repo root. Adding ``.`` to ``--path`` lets
# library-local tests in ``libs/*/tests/`` also import the table for
# the M6 smoke check.
#
# It is ALSO the repository's package-root anchor, and that second role is
# load-bearing in a way the first is not. The compiler renders the source
# location it plants inside `check` / `require` / `expect` / `assert` — and
# therefore inside every test's `--list-json` `bodyHash` — relative to the
# package root, which `canonicalImportAux` finds from the stdlib directories,
# the `--path:` search roots, or the nearest enclosing `.nimble` file. Every
# reprobuild test is compiled as its own main module, so with none of those
# matching the compiler falls back to `projectPath` (the main module's own
# directory) and each location degrades to a bare basename. Nothing errors
# when that happens: the hashes stay stable and the suite keeps passing while
# two same-named test files in different directories quietly become one.
#
# `reprobuild.nimble` at the repo root supplies the same anchor and either one
# alone is sufficient, so this line may look redundant. It is not: it is the
# anchor that survives the `.nimble` file being moved or renamed. Do not
# delete either without reading `tests/unit/test_package_root_anchor.py`,
# which measures the property both of them exist to hold.
switch("path", ".")

# The same anchor, absolute — and the one that actually holds when the project
# being compiled is NOT in this repo.
#
# `.` above resolves against the project, so during a profile compile it points
# at the profile's own directory and every root-level module in this repository
# silently stops resolving. That is not hypothetical: after
# `repro_core/convention_attribution.nim` gained `import lints/ambient_execution`
# — `lints/` being a root-level directory — `nim c` over this tree kept working
# while every COLD profile compile failed with
# `cannot open file: lints/ambient_execution`, taking `repro infra plan`,
# `repro infra apply` and the deploy agent with it. A warm profile cache hid it,
# so it surfaced as "converged for weeks, then stopped accepting new desired
# state".
#
# Keeping both lines is deliberate. `.` is documented above as the package-root
# anchor with a test measuring the property it holds
# (`tests/unit/test_package_root_anchor.py`), so it is not removed on the
# strength of this; and over-inclusion is safe for the reason
# `repro_profile_compile/sources.nim` documents — extra `--path` entries only
# supply modules that would otherwise not resolve, and cannot hijack one that
# already does.
switch("path", reproRepoRoot)

# Test-Edges-And-Parallel-Runner M1: ``repro.nim`` consumes the
# generated ``repro_tests.nim`` whose data entries each become a
# ``buildNimUnittest.build(...)`` call. The build-side typed-tool
# (``ct_test_nim_unittest`` + its ``ct_test_interface`` contract) now
# lives in-tree under ``libs/`` (added via the ``libName`` loop below):
# it depends only on ``repro_project_dsl`` and is the half ``repro.nim``
# imports, so hosting it in-tree removes the reprobuild↔adapter
# dependency cycle that the previous external import closed. Only the
# execution-time ``TestRunner`` adapter (``ct_test_runner_adapter`` - the
# in-process bridge in the ``reprobuild-ct-test-runner`` repo) stays
# external and is resolved from the sibling checkout below.
let ctTestRunnerRoot = block:
  let fromEnv = getEnv("REPRO_CT_TEST_RUNNER_SRC")
  if fromEnv.len > 0:
    fromEnv
  else:
    ".." / "reprobuild-ct-test-runner"
let ctTestRunnerAdapterSrc = ctTestRunnerRoot / "libs" /
  "ct_test_runner_adapter" / "src"
if dirExists(ctTestRunnerAdapterSrc):
  switch("path", ctTestRunnerAdapterSrc)

# Incremental-Test-Runner: ``ct_incremental_adapter`` is hosted by CodeTracer
# as the std-only process seam for codetracer's canonical incremental engine.
# It reaches the engine by EXECUTING the ``ct`` binary as a subprocess (the
# ``ct test --incremental --watch-decide`` / ``--watch-record`` protocol), NOT
# by compiling the engine in-process.
#
# RESOLUTION ORDER, AND WHY IT IS THIS ORDER:
#
#   1. ``$CODETRACER_SRC`` — a USER override, and only that. Nothing in the
#      flake sets it and nothing in the flake may start setting it: the moment
#      a dev shell, a hook or an installed wrapper seeds it, "unset" stops
#      being a state a developer can be in, and every tier below becomes
#      unreachable.
#   2. ``../codetracer/src`` — the sibling working tree, when it really carries
#      the module. THE LIVE TREE, NOT A COPY OF IT: an edit to the seam in a
#      workspace checkout takes effect on the very next compile, with no shell
#      reload and no input re-materialisation. That is the reason this tier
#      sits above the pin rather than below it.
#   3. ``$CODETRACER_PINNED_SRC`` — the materialised ``codetracer-src`` flake
#      input, seeded by the dev shell, the lint hook, the packaged build and
#      the installed wrappers. Same repository and same file as tier 2, at the
#      pinned revision instead of the working tree. This is what a checkout
#      that is NOT sitting beside CodeTracer compiles, and having it is what
#      stops a directory layout from silently deciding which of two files the
#      build gets.
#   4. the standalone copy shipped in ``reprobuild-ct-test-runner`` — a
#      genuinely different file. Read the note on it below before touching
#      either copy.
#
# The flake exports the pin under its own name for exactly this reason. Naming
# it ``CODETRACER_SRC`` would collapse tiers 1 and 3 into one and make the pin
# beat the sibling everywhere it is set, which is every environment the flake
# builds.
let ctIncrementalSrc = block:
  var found = ""
  for candidate in [getEnv("CODETRACER_SRC"),
                    ".." / "codetracer" / "src",
                    getEnv("CODETRACER_PINNED_SRC")]:
    if candidate.len > 0 and
        fileExists(candidate / "ct_incremental_adapter.nim"):
      found = candidate
      break
  found
if ctIncrementalSrc.len > 0:
  switch("path", ctIncrementalSrc)
else:
  # Last resort: the standalone copy that ships in the pinned
  # ``reprobuild-ct-test-runner`` source input, for a build that has neither an
  # override, nor a sibling, nor the CodeTracer pin.
  #
  # THIS USED TO BE WHAT THE NIX PACKAGE BUILD COMPILED, AND IT NO LONGER IS.
  # The ``reprobuild`` derivation now seeds ``CODETRACER_PINNED_SRC``, so the
  # packaged build takes tier 3 — the canonical file — like every other build
  # in the flake. What is left down here is the case where even the pin is
  # absent: a checkout compiled outside the flake entirely, with only
  # ``REPRO_CT_TEST_RUNNER_SRC`` or a ``../reprobuild-ct-test-runner`` sibling
  # to go on. THAT MAY WELL BE NOBODY, and if it is, this copy is dead weight
  # and should be deleted rather than kept warm by a comment — but establishing
  # that is a separate change from the one that stopped the layout deciding.
  #
  # The two files are SEMANTICALLY EQUIVALENT, NOT IDENTICAL. They differ in
  # import order, doc comments and statement layout, and they live in separate
  # repositories with separate histories, so nothing mechanically holds them
  # together. A byte-compare would fail today on formatting alone, and a gate
  # that goes red for formatting is a gate that gets switched off; it also could
  # not run where the drift actually bites.
  #
  # So the invariant is a human one, stated here rather than pretended away:
  # CODETRACER OWNS THE SEAM, AND A BEHAVIOUR CHANGE TO IT MUST LAND IN BOTH
  # COPIES, with the ``reprobuild-ct-test-runner`` pin bumped, before anything
  # compiling this copy sees it. The Nim compiler still checks the half that
  # can be checked — a copy that loses an exported symbol fails this compile —
  # but it cannot tell you that the two disagree about what a symbol DOES.
  #
  # Pointing the package build at CodeTracer was previously rejected on a cost
  # that was never measured: "several gigabytes", from the observation that
  # overriding a source input to a local path copies the whole working tree
  # into the store. THAT FIGURE IS ABOUT THE OVERRIDE, NOT ABOUT THE PIN, and
  # the two are two orders of magnitude apart. Measured at the current pin:
  # the pinned ``codetracer-src`` input is 25 MB on disk / 47 MiB of store
  # closure, with no dependencies. The multi-gigabyte number is real but
  # belongs to the auto-override — a store copy of a working ``../codetracer``,
  # measured at 6.1 GiB — which only a workspace shell realises, and which such
  # a shell has already realised for ``ctTestTools`` regardless. Tens of
  # megabytes is what tier 3 costs the packaged build, and it buys the
  # canonical file.
  let ctIncrementalFallbackSrc = ctTestRunnerRoot / "libs" /
    "ct_incremental_adapter" / "src"
  if dirExists(ctIncrementalFallbackSrc):
    switch("path", ctIncrementalFallbackSrc)

# The ``TestRunner`` cross-cutting contract lives in the standalone
# ``reprobuild-test-adapters`` package (Nim package ``repro_test_adapters``)
# so out-of-tree adapter libraries and the reprobuild engine share the types
# without a dependency cycle through the engine. Resolve it from
# ``REPRO_TEST_ADAPTERS_SRC`` (seeded by the flake input in the sandboxed
# package build) or a sibling checkout for local dev shells.
let reproTestAdaptersSrc = block:
  let fromEnv = getEnv("REPRO_TEST_ADAPTERS_SRC")
  if fromEnv.len > 0:
    fromEnv
  else:
    ".." / "reprobuild-test-adapters" / "src"
if dirExists(reproTestAdaptersSrc):
  switch("path", reproTestAdaptersSrc)

for libName in [
  # Build-side test typed-tool, moved in-tree (see the ctTestRoot note
  # above): ``ct_test_interface`` is the leaf contract, ``ct_test_nim_unittest``
  # the ``buildNimUnittest`` typed-tool that ``repro.nim`` imports, and
  # ``ct_test_unittest_parallel`` is the test-binary protocol support the
  # shim's own tests and the fixture modules they compile at run time link.
  # Ordinary test sources speak the same protocol through ``std/unittest``,
  # which the codetracer-nim fork carries it in, and do not need this path.
  "ct_test_interface",
  "ct_test_nim_unittest",
  "ct_test_unittest_parallel",
  # ``ct_test_surface``: the reader for CodeTracer's PUBLISHED ``ct test``
  # catalog/provider surface (``ct-test test discover``). It is deliberately
  # not part of the three above: those are how a test BINARY speaks the
  # protocol, while this is how this repository asks the canonical CodeTracer
  # driver what cases the source tree contains. Only tests import it.
  "ct_test_surface",
  # RunQuota-Observation-Store M19: the ``HistoryReporter`` write path.
  # It is NOT part of the three above and must not be: those are linked
  # into test binaries and into ``repro.nim``'s DSL, while this one
  # links the RunQuota client. Only ``tools/test-runner`` imports it.
  "ct_test_history",
  # RunQuota-Observation-Store M20: the SECOND write path into the same
  # generic table, and the query that reads both runners' rows.
  #
  # ``repro_generic_test_recorder`` is deliberately not a mode of
  # ``ct_test_history``: that library declares ``ext_codetracer_test``
  # unconditionally and takes a ``CodetracerTestFacts``, so reusing it
  # would have made the second runner declare a framework it is not. Only
  # ``tools/tap-test-runner`` imports it.
  #
  # ``repro_test_stats`` is likewise NOT hosted inside
  # ``ct_test_history``: putting the framework-neutral query inside
  # CodeTracer's reporter would make every other runner's statistics
  # reachable only by linking CodeTracer's write path — the capture OS-8
  # forbids, by the back door. ``tools/test-runner`` and
  # ``tools/tap-test-runner`` both read through it.
  "repro_generic_test_recorder",
  "repro_test_stats",
  "repro_core",
  "repro_platform",
  # ``repro_diagnostics`` and ``repro_project_dsl_runtime_dll`` are NOT in this
  # list, and the omission is deliberate rather than an oversight — see the note
  # below the loop.
  "repro_cli_support",
  "repro_daemon_core",
  "blake3",
  "xxh3",
  "gxhash",
  "repro_hash",
  # Expected launch measurements and the measurement-manifest schema.
  # Shared by the image build that emits the document and the verifier
  # that consumes it, so it belongs to neither.
  "repro_attest",
  # The daemon over that library: the HTTP surface an attested instance
  # answers a challenge on, its bounds, and the service unit it renders
  # for itself. Kept apart from ``repro_attest`` because it reaches for
  # ``std/net`` and the library above it must stay usable by a verifier
  # that listens on nothing.
  "repro_attest_agent",
  # The other consumer of ``repro_attest``, and deliberately not built on
  # the one above it: the agent sits inside every attested trusted
  # computing base, and a verifier linked into it would be the code that
  # decides whether to trust, shipped inside the thing being trusted.
  "repro_attest_verify",
  "cbor",
  "repro_domain_types",
  "repro_depfile",
  "repro_project_dsl",
  "repro_dsl_stdlib",
  "repro_home_intent",
  "repro_system_apply",
  "repro_profile",
  "repro_profile_intent",
  "repro_profile_compile",
  # Windows-Runner-Binary-Cache-Deploy M5: the signed desired-state
  # manifest pull agent (reprobuild-native analog of mcl-deploy-agent).
  "repro_deploy_agent",
  "repro_home_generations",
  "repro_home_apply",
  "repro_home_rollback",
  # ReproOS-Generations-And-Foreign-Packages B3: system-scope
  # switch / rollback / list / gc / repair primitives. Lifts the
  # home-profile rollback contract into system scope.
  "repro_system_rollback",
  "repro_home_resources",
  # Composable-Resource-Types slice 2: the generic external-provider
  # resource lane (ResourceInstance + provider registry + reconciler).
  "repro_resources",
  "repro_homebrew_adapter",
  "repro_elevation",
  "repro_infra",
  "repro_interface_artifacts",
  "repro_dev_env_artifacts",
  "repro_dev_env_activation",
  "repro_dev_env_engine",
  "repro_tool_profiles",
  # Platform-And-Filesystem-Facts F1/F2: the declared OS and filesystem
  # fact tables (value + citation + observability marker each) and the
  # path -> table-row lookup. Deliberately listed BEFORE the store: the
  # store is a consumer, the facts library depends on nothing in this
  # repository, and it must stay importable without dragging the store
  # (or repro_platform's MSVC dev-env process launcher) in behind it.
  "repro_fs_facts",
  "repro_local_store",
  # M9.R.77.2 — R11 Layer-1 CAS-store facade over ``repro_local_store``
  # (spec: Store-And-Installation-Layout.md §R11 Two-Layer Split).
  # Downstream code that needs only content-addressed put / get /
  # verify / path / gc imports ``repro_cas_store`` so it does not gain
  # access to the Layer-2 prefix / receipt / root / recovery surface.
  "repro_cas_store",
  "repro_store_daemon",
  "repro_launch_plan",
  "repro_runquota",
  "repro_build_engine",
  "repro_provider_runtime",
  "repro_hcr_linkgraph",
  "repro_hcr_linker",
  "repro_hcr_agent",
  "repro_hcr_test",
  "repro_cmake_trycompile",
  "repro_standard_provider_protocol",
  "repro_standard_provider",
  "repro_workspace_vcs",
  "repro_test_support",
  "repro_workspace_manifests",
  "repro_peer_cache",
  # ReproOS-Generations-And-Foreign-Packages A2: binary-cache server
  # library + apps/repro-binary-cache HTTP daemon. Layer-3 substitute
  # plane per Binary-Caches.md; see THREE-LAYER-TAXONOMY.md.
  "repro_binary_cache_server",
  # ReproOS-Generations-And-Foreign-Packages A2.5: binary-cache
  # substitution client + cache-entry-key derivation. The M9.L.4
  # from-source publish action shells out to the client CLI using a
  # hex key derived via ``cache_key.deriveCacheEntryKeyHex``.
  "repro_binary_cache_client",
  # Spec-Implementation M2a: ``repro_solver`` ships the clingo Nim
  # bindings + the high-level Solver/Solution/Constraint placeholder
  # types. M2b-M2e extend it with the ASP encoder; downstream libs
  # import it via ``import repro_solver`` once the encoder is alive.
  "repro_solver",
  # Workspace-Manifest-Optional MO-1: the committed solved-graph lock
  # writer/reader (``SolvedGraphLock`` round-trip + the solution<->lock
  # conversions). ``repro_cli_support`` imports it via ``import
  # repro_lock`` for ``repro lock refresh/validate`` and the build-path
  # lock consumption. Separate from the manifest-repo SHA lock
  # (``repro_workspace_manifests/lock_writer.nim``).
  "repro_lock",
  # Named-Lock-Files NLF-M7: declared lock-file NAMES, their doc comments,
  # the designation stack and precedence chain, the `--lock <name>=<path>`
  # binding, and §4.1/§4.6 propagation down the closure. A `std`-only LEAF:
  # the project DSL's macros, the stdlib build context, the CLI and the
  # lock-generation path all depend on it, and a leaf is the only shape all
  # four can take. Deliberately holds no lock IDENTITY type — §6.2 forbids
  # the name from entering a key, and keeping the name library and the
  # identity library disjoint is how that is made structural.
  "repro_lock_files",
  # Named-Lock-Files NLF-M5: lock GENERATION as build-graph edges —
  # metadata-fetch edges upstream, the solve as a rule-generator edge
  # downstream, the lock as its rule-set artifact. A leaf ABOVE both the
  # engine and the solver: the engine must not import the solver (clingo
  # dynlib at module-init, see ``repro_lock/identity.nim``) and the solver
  # must not import the engine, so the path that needs both lives here.
  "repro_lock_gen",
  # Workspace-Manifest-Optional MO-8: self-describing, algorithm-tagged
  # content digests (``<alg>:<digest>`` multihash) + the BLAKE3 own-file
  # NAR-style tree hash. ``repro_lock`` (the committed-lock integrity) and
  # ``repro_cli_support`` (refresh/validate integrity computation) import it
  # via ``import repro_multihash``.
  "repro_multihash",
  # Workspace-Manifest-Optional MO-3: the abstract Lock/Manifest store
  # interface (``LockStore``) + its portable backends (committed-file,
  # git-notes, separate-branch, external-CLI). ``repro_cli_support``
  # imports it via ``import repro_lock_store`` and defines the
  # git-checkout backend (``GitCheckoutLockStore``) on top of the
  # existing byte-identical publish/read procs.
  "repro_lock_store",
  # M5 SELF-HOST: the pin-resolution leaf. Turns a project's committed
  # `reprobuild` LockedDep into the store prefix holding that version's
  # image. Depends on `repro_lock` and the store's PURE naming/hash pair
  # (`repro_local_store/prefix_paths` + `.../realization_hash`) and on
  # nothing else — that is what lets the resolving launcher link it without
  # opening SQLite. `repro_cli_support` imports it for `repro self`, and
  # `apps/repro-trampoline` is the launcher.
  "repro_selfhost",
  # Incremental-Test-Runner M0b-3: the former vendored ``repro_ct_incremental``
  # engine copy was DELETED. The ``repro watch --ct-incremental`` decision seam
  # now flows through the engine-free ``ct_incremental_adapter`` (resolved from
  # CodeTracer's ``src`` above) onto codetracer's canonical engine. No
  # reprobuild-side engine library remains.
]:
  switch("path", "libs" / libName / "src")

# TWO LIBRARIES IN ``libs/libraries.txt`` ARE ABSENT FROM THE LOOP ABOVE:
# ``repro_diagnostics`` and ``repro_project_dsl_runtime_dll``. A ``--path`` is
# not free — every entry is probed, and missed, by every module lookup that is
# ordered after it — and these two supply modules that nothing imports by name.
#
# The evidence, re-taken at 9a44bf28 by reading every ``import`` / ``export`` /
# ``include`` / ``from`` line in all 4,837 ``.nim`` and ``.nims`` files in this
# repository and under every directory this file puts on ``--path``:
#
#   * ``repro_diagnostics`` appears in NO import statement anywhere. Its only
#     occurrences outside its own directory are this file, ``libs/libraries.txt``,
#     its own README, and ``scripts/validate-interface-codec-back-compat.ps1``
#     — which builds its OWN ``--path`` list and passes
#     ``libs\repro_diagnostics\src`` on the command line, so it does not depend
#     on this entry either (command-line ``--path`` is processed after the
#     configuration and therefore lands in front of everything below).
#   * ``repro_project_dsl_runtime_dll`` is named only as a FILE PATH — by
#     ``scripts/build_apps.sh``, ``repro.nim``'s graph edge and the suite
#     inventory — never as a module. Its own two modules import each other as
#     SIBLINGS (``repro_project_dsl_runtime_dll.nim`` imports
#     ``repro_project_dsl_runtime_entry``, which sits next to it), and
#     ``findModule`` probes the importing module's own directory before it
#     consults the search path at all, so neither needs this entry.
#
# Both are still built and still linted: ``scripts/check_nim_sources.sh`` runs
# ``nim check libs/<lib>/src/<lib>.nim`` for every row of ``libs/libraries.txt``,
# and each compiles as its own main module, where the same sibling rule applies.
# Checked by running it rather than by reading it — with this file as it now
# stands, ``nim check --define:reproProviderMode libs/<lib>/src/<lib>.nim`` is
# rc 0 for BOTH libraries. That run has to be done by hand today, because the
# script is ``set -euo pipefail`` and aborts at row 5
# (``repro_cli_support``, whose ``import runquota_daemon/host_config`` does not
# resolve against either RunQuota source this host offers), so it never reaches
# row 14.
#
# This was the whole of the "drop the entries that resolve nothing" lever once
# it was re-measured. 34 of the 126 search-path entries resolve nothing for a
# cold ``nim c`` of ``apps/repro/repro.nim`` (counted from the trace as entries
# with zero resolving probes; the figure is attribution-sensitive because
# ``$lib`` and ``$lib/pure`` nest), which is the figure that makes the
# lever look large — but this file is read by EVERY compilation in the
# repository, and all but these two are needed by some other entrypoint, test or
# library. An entry is droppable only if it resolves nothing for ALL of them.
#
# If you add an ``import repro_diagnostics`` or an
# ``import repro_project_dsl_runtime_dll``, put the name back in the list above;
# the failure is a plain ``cannot open file``.

# Incremental-Test-Runner M7: reprobuild's build engine consumes the shared
# ``io-mon`` filesystem-monitoring library instead of its own former
# ``repro_monitor_depfile`` / ``repro_monitor_shim`` / ``repro_monitor_hooks``
# io-monitor stack (now deleted). io-mon is a byte-identical wire-format + ABI
# relocation of that stack onto ``nim-stackable-hooks``; the depfile API
# (``MonitorDepFile`` / ``readMonitorDepFile`` / ``MonitorRecord`` / the
# ``mr*`` / ``mo*`` / ``mc*`` enums / ``MonitorDepFileReaderError`` / the
# monitor driver + ``findShimLibrary``) is re-exported under the same
# names from ``import io_mon`` (and the shim/hooks runtime under
# ``io_mon/shim`` / ``io_mon/hooks``), so the consumers swapped their imports
# only — no logic changed. The package's Nim name is ``io_mon`` with srcDir
# ``src``; resolve the sibling checkout by path like every other workspace
# Nim sibling. Prefer ``$IO_MON_SRC``, then the sibling checkout.
let ioMonSrc = block:
  let fromEnv = getEnv("IO_MON_SRC")
  if fromEnv.len > 0 and fileExists(fromEnv / "io_mon.nim"):
    fromEnv
  elif fromEnv.len > 0 and fileExists(fromEnv / "src" / "io_mon.nim"):
    fromEnv / "src"
  else:
    ".." / "io-mon" / "src"
if fileExists(ioMonSrc / "io_mon.nim"):
  switch("path", ioMonSrc)

proc nixDevShellSourcePath(envName, marker: string): string =
  when defined(windows):
    ""
  else:
    if not fileExists("flake.nix"):
      return ""
    let systemResult =
      gorgeEx("nix eval --raw --impure --expr 'builtins.currentSystem' 2>/dev/null")
    if systemResult.exitCode != 0:
      return ""
    let system = systemResult.output.strip()
    if system.len == 0:
      return ""
    let valueResult = gorgeEx(
      "nix eval --raw '.#devShells." & system & ".default." & envName &
      "' 2>/dev/null")
    if valueResult.exitCode != 0:
      return ""
    let candidate = valueResult.output.strip()
    if candidate.len > 0 and fileExists(candidate / marker):
      return candidate
    ""

proc reportUnresolvedPackagePath(envName: string;
                                 candidates: openArray[string];
                                 marker: string; envPath: string;
                                 useDevShellFallback, optional: bool) =
  ## Say, HERE, that a package got no ``--path``.
  ##
  ## Staying silent is not free. The ``--path`` is simply not added and the
  ## first symptom is ``Error: cannot open file: <some/module>`` tens of
  ## modules later, in a message that names neither this file, nor the
  ## environment variable that would have fixed it, nor the development
  ## shell that sets it. A reader of that message concludes the dependency
  ## is missing from the workspace, and the conclusion is wrong often
  ## enough to have cost real time. Name the package, the variable, every
  ## directory tried, the marker file wanted, and the remedy.
  ##
  ## WHY THIS WARNS AND DOES NOT STOP, which is not the obvious choice and
  ## was not the first one. A configuration file cannot know whether an
  ## unresolved package is needed by the particular compilation about to
  ## happen — Nim's ``--path`` is lazy, and a path nothing imports costs
  ## nothing. The first version of this proc ended in ``quit(1)``, and it
  ## broke a real and very common path: the engine's project-interface
  ## extraction runs ``nim c`` against a STORE COPY of this repository
  ## where none of the vendored ``libs/`` trees are present, supplies its
  ## own ``--path`` flags instead, and compiles perfectly well with a
  ## dozen packages unresolved here. Refusing there turned a working build
  ## into a failure. So: say it, name everything, and let the compilation
  ## proceed to fail on its own terms if the package really was wanted.
  ## The value being delivered is that the operator sees this message
  ## ABOVE the ``cannot open file`` one, not that the build stops.
  var report = "\n" & (if optional: "note" else: "warning") &
    ": config.nims added no --path for " & envName & "\n" &
    "  wanted a directory containing: " & marker & "\n" &
    "  $" & envName & ": " &
    (if envPath.len == 0: "unset"
     elif dirExists(envPath): "set to " & envPath & ", which has no " & marker
     else: "set to " & envPath & ", which does not exist") & "\n"
  if candidates.len == 0:
    report.add "  candidate directories: none are declared for this package\n"
  else:
    for candidate in candidates:
      report.add "  candidate directory: " & candidate & " -- " &
        (if dirExists(candidate): "exists, but has no " & marker
         else: "does not exist") & "\n"
  if useDevShellFallback:
    report.add "  development-shell fallback: consulted, no match\n"
  report.add "  fix: build from inside the development shell " &
    "(`direnv exec . <command>`, or `nix develop`), which exports " &
    envName & "; or set " & envName &
    " to a directory containing " & marker & "\n"
  report.add "  the build CONTINUES without it: this file cannot tell " &
    "whether the compilation about to run needs the package, and at least " &
    "one that does not (the engine's interface extraction) compiles " &
    "fine with it absent. If it IS needed, the next error will be " &
    "`cannot open file` -- and this message is the answer to it.\n"
  if optional:
    report.add "  this package is declared optional, so its absence is " &
      "expected in checkouts that do not carry the sibling\n"
  echo report

proc addPackagePath(envName: string; candidates: openArray[string];
                    marker: string; useDevShellFallback = false;
                    optional = false) =
  ## ``optional = true`` says a checkout is EXPECTED to be able to lack this
  ## package, so its report reads as a note rather than a warning. It is for
  ## packages whose absence the tree already tolerates -- today only
  ## ``VM_HARNESS_SRC``, which ``config.nims`` itself guards with
  ## ``vmHarnessAvailable`` further down, and which no Nix execution surface
  ## exports. The distinction is about how surprising the absence is, not
  ## about whether the build proceeds: see ``reportUnresolvedPackagePath``
  ## for why nothing here refuses.
  let envPath = getEnv(envName)
  if envPath.len > 0 and fileExists(envPath / marker):
    switch("path", envPath)
    return
  for candidate in candidates:
    if fileExists(candidate / marker):
      switch("path", candidate)
      return
  if useDevShellFallback:
    let flakePath = nixDevShellSourcePath(envName, marker)
    if flakePath.len > 0:
      switch("path", flakePath)
      return
  reportUnresolvedPackagePath(envName, candidates, marker, envPath,
                              useDevShellFallback, optional)

# M2 dev-env artifacts use status-im/nim-ssz-serialization for their canonical
# payload. Prefer explicit checkouts, then workspace siblings, then local
# vendored copies if present.
addPackagePath("FASTSTREAMS_SRC", [
  "libs" / "nim-faststreams" / "src",
  ".." / "codetracer" / "libs" / "nim-faststreams",
  ".." / "nim-faststreams",
], "faststreams" / "inputs.nim")
addPackagePath("NIM_STEW_SRC", [
  "libs" / "nim-stew" / "src",
  ".." / "codetracer" / "libs" / "nim-stew",
  ".." / "nim-stew",
], "stew" / "objects.nim")
addPackagePath("NIM_SERIALIZATION_SRC", [
  "libs" / "nim-serialization" / "src",
  ".." / "codetracer" / "libs" / "nim-serialization",
  ".." / "nim-serialization",
], "serialization" / "case_objects.nim")
addPackagePath("NIM_JSON_SERIALIZATION_SRC", [
  "libs" / "nim-json-serialization" / "src",
  ".." / "codetracer" / "libs" / "nim-json-serialization",
  ".." / "nim-json-serialization",
], "json_serialization.nim")
addPackagePath("NIM_TOML_SERIALIZATION_SRC", [
  "libs" / "nim-toml-serialization" / "src",
  ".." / "codetracer" / "libs" / "nim-toml-serialization",
  ".." / "nim-toml-serialization",
], "toml_serialization.nim")
addPackagePath("SSZ_SERIALIZATION_SRC", [
  "libs" / "nim-ssz-serialization" / "src",
  ".." / "nim-ssz-serialization",
], "ssz_serialization.nim")
addPackagePath("NIMCRYPTO_SRC", [
  # Vendored source-only slice (cheatfate/nimcrypto @ 423ea4f / v0.7.3).
  # Listed first so reprobuild is self-contained: the recipe-compile no
  # longer depends on a consumer's sibling `nimcrypto` checkout. The
  # package entry module is `nimcrypto.nim` at the repo root with
  # submodules under `nimcrypto/`, so the dir itself is the --path root.
  # Marker is `nimcrypto/hash.nim`.
  "libs" / "nimcrypto",
  ".." / "codetracer" / "libs" / "nimcrypto",
  ".." / "nimcrypto",
], "nimcrypto" / "hash.nim")
# Peer-Cache-BearSSL M0: status-im/nim-bearssl. The package's entry module
# is `bearssl.nim` at the repo root with submodules under `bearssl/`, so the
# repo root itself is the path we want on --path. Marker is `bearssl.nim`.
addPackagePath("BEARSSL_SRC", [
  ".." / "nim-bearssl",
  "libs" / "nim-bearssl",
], "bearssl.nim", useDevShellFallback = true)
addPackagePath("RESULTS_SRC", [
  "libs" / "results" / "src",
], "results.nim")
addPackagePath("STINT_SRC", [
  "libs" / "stint" / "src",
], "stint.nim")

# The monitor shim's hook chain is implemented on top of
# ``metacraft-labs/nim-stackable-hooks`` (the framework portion that
# the spec at MCR-OS-Interposition.status.org §M0 describes as the
# Nim port of agent-harbor's stackable-hooks Rust library). Since
# Incremental-Test-Runner M7, the shim itself lives in the ``io-mon``
# sibling (``io_mon/shim`` + ``io_mon/hooks``), but reprobuild's monitor
# TESTS still compile io-mon's hooks runtime, which imports ``stackable_hooks``
# — so the framework path is still resolved here. Prefer an explicit
# STACKABLE_HOOKS_SRC, then the sibling-repo checkout.
addPackagePath("STACKABLE_HOOKS_SRC", [
  ".." / "nim-stackable-hooks" / "src",
], "stackable_hooks.nim")

# SHM-QUEUE-MIGRATE / io-mon LOSSLESS M1: the io-mon sibling's dependency
# capture sits on nim-shm-gset (``shm_gset/transport``) and still pulls
# nim-shm-queue's Layer-1 MPSC ring through its own tree. Reprobuild's action
# cache used to sit on that ring too; it now sits on the same grow-only set
# (``libs/repro_local_store/src/repro_local_store/action_index.nim``), for a
# different purpose and under a different key discipline. Because config.nims
# compiles whichever io-mon the block above selected — $IO_MON_SRC when it is set (the usual case
# in CI and the sandboxed package build, where the flake exports it), and the
# ``../io-mon`` sibling only as the fallback when it is not —
# these shm packages MUST resolve to their co-developed siblings too — otherwise
# a newer io-mon is compiled against an older $SHM_QUEUE_SRC pin or a
# missing nim-shm-gset, which is exactly the version skew that breaks the build.
# These libraries retain their own sibling-first policy, then the env pin
# ($SHM_QUEUE_SRC / $SHM_GSET_SRC), then the devshell fallback.
proc addSiblingFirstPackagePath(sibling, envName, marker: string) =
  if fileExists(sibling / marker):
    switch("path", sibling)
    return
  addPackagePath(envName, [], marker, useDevShellFallback = true)

addSiblingFirstPackagePath(".." / "nim-shm-queue" / "src", "SHM_QUEUE_SRC",
  "shm_queue.nim")
addSiblingFirstPackagePath(".." / "nim-shm-gset" / "src", "SHM_GSET_SRC",
  "shm_gset.nim")

# SHM-GSET: TWO independent users of one data structure, and the distinction is
# easy to lose. io-mon's Linux dependency-capture channel is the grow-only
# shared-memory set ``shm_gset`` (nim-shm-gset — Candidate C of the Lossless
# Event Capture campaign; dedup-at-source over file-backed shards), reaching
# reprobuild only through ``import io_mon``. Reprobuild ALSO imports the same
# library directly, for its action-cache Tier-2 index — the same structure
# keyed on fingerprints rather than on observed paths
# (Action-Cache-Per-Edge-Store.md §6.1).
#
# ``addSiblingFirstPackagePath`` above is the ONE registration, and there used
# to be a second one here that pinned ``$SHM_GSET_SRC`` unconditionally. Nim
# searches ``--path`` entries most-recently-added first, so that second
# registration silently DEFEATED the sibling-first policy the first one
# states: a checkout with a live ``../nim-shm-gset`` still compiled against the
# devshell's pinned store copy, and an edit to the sibling had no effect on
# anything until the pin moved. That was invisible while reprobuild only
# reached the library transitively through io-mon; it is not invisible now that
# the action cache imports it directly. The sibling-first helper already falls
# back to ``$SHM_GSET_SRC`` and then to the devshell when no sibling checkout
# exists, so removing the duplicate loses no resolution and restores the
# policy.

# R2: vm-harness lives in the sibling ``D:/metacraft/vm-harness/`` repo
# (see ReproOS-MVP R0 status). The R2 boot integration test
# (tests/integration/t_r2_iso_boot.nim) imports ``vm_harness`` to drive
# the bootFromMedia/captureSerial/expectLine primitives against the
# Hyper-V Gen-2 UEFI backend. Prefer $VM_HARNESS_SRC, then the
# sibling-repo checkout.
addPackagePath("VM_HARNESS_SRC", [
  ".." / "vm-harness" / "src",
], "vm_harness.nim", optional = true)

# Define ``vmHarnessAvailable`` only when the optional vm-harness sibling is
# actually present. The R2/R9 boot integration tests guard their
# ``import vm_harness`` on this symbol so they skip-compile when the sibling is
# absent, instead of hard-failing the whole test-build. A missing optional
# sibling must skip, not be fatal (Workspace-alignment RA-23;
# Interactive-UX-And-Progress.md Principle 2).
block:
  let vmhEnv = getEnv("VM_HARNESS_SRC")
  if (vmhEnv.len > 0 and fileExists(vmhEnv / "vm_harness.nim")) or
     fileExists(".." / "vm-harness" / "src" / "vm_harness.nim"):
    switch("define", "vmHarnessAvailable")

# Lib subdirectories to probe under a system prefix. The order matters:
# `lib` covers the default + Debian-multiarch case (Debian/Ubuntu install
# headers under `/usr/include/` but the dylib at `/usr/lib/x86_64-linux-gnu/`);
# `lib64` covers Fedora / openSUSE / RHEL (64-bit lib path); the multiarch
# triples cover Debian/Ubuntu when the prefix is `/usr` or `/usr/local`.
# Without this expansion, `BLAKE3_PREFIX=/usr` on Fedora misses
# `/usr/lib64/libblake3.so` and the build silently falls back to the
# vendored sources (when the system-libs path is intended).
const LibSubdirs = [
  "lib",
  "lib64",
  "lib/x86_64-linux-gnu",
  "lib/aarch64-linux-gnu",
]

proc firstExistingPrefixLibDir(prefix: string;
                               dylibNames: openArray[string]): string =
  ## Return the absolute libdir under `prefix` that holds one of
  ## `dylibNames`, or "" if none match. Probes `prefix/lib`,
  ## `prefix/lib64`, and the two common Debian-multiarch triples.
  for libSub in LibSubdirs:
    let candidate = prefix / libSub
    for dylibName in dylibNames:
      if fileExists(candidate / dylibName):
        return candidate
  ""

proc firstExistingPrefix(candidates: openArray[string]; header: string;
                         dylibNames: openArray[string]): string =
  for prefix in candidates:
    if prefix.len == 0:
      continue
    if not fileExists(prefix / header):
      continue
    if firstExistingPrefixLibDir(prefix, dylibNames).len > 0:
      return prefix
  ""

proc nixPrefix(namePattern, header: string; dylibNames: openArray[string]): string =
  let cmd = "find /nix/store -maxdepth 1 -type d -name '" & namePattern &
    "' 2>/dev/null | sort"
  let result = gorgeEx(cmd)
  if result.exitCode != 0:
    return ""
  for line in result.output.splitLines:
    let prefix = line.strip()
    if prefix.len == 0:
      continue
    if fileExists(prefix / header) and
       firstExistingPrefixLibDir(prefix, dylibNames).len > 0:
      return prefix
  ""

proc firstExistingLibDir(candidates: openArray[string];
                         dylibNames: openArray[string]): string =
  for candidate in candidates:
    let path = candidate.strip()
    if path.len == 0:
      continue
    # Probe the candidate directly (it may already be a libdir like
    # `/usr/lib64` from the sqlite candidate list) and then walk the
    # standard lib subdirectories so a candidate like `/usr` resolves
    # whether the host is `/usr/lib`, `/usr/lib64`, or a Debian-multiarch
    # triple.
    for dylibName in dylibNames:
      if fileExists(path / dylibName):
        return path
    let resolved = firstExistingPrefixLibDir(path, dylibNames)
    if resolved.len > 0:
      return resolved
  ""

proc nixLibDir(namePattern: string; dylibNames: openArray[string]): string =
  let cmd = "find /nix/store -maxdepth 1 -type d -name '" & namePattern &
    "' 2>/dev/null | sort"
  let result = gorgeEx(cmd)
  if result.exitCode != 0:
    return ""
  for line in result.output.splitLines:
    let prefix = line.strip()
    if prefix.len == 0:
      continue
    let libDir = firstExistingLibDir([prefix], dylibNames)
    if libDir.len > 0:
      return libDir
  ""

let useSystemHashLibs =
  not defined(reproVendoredHash) and
  getEnv("REPROBUILD_USE_SYSTEM_HASH_LIBS").toLowerAscii() in
    ["1", "true", "yes", "on"]

if not useSystemHashLibs:
  switch("define", "reproVendoredHash")

# The default local build uses the tracked vendored blake3 / xxhash sources.
# `blake3.nim` and `xxh3.nim` compile the portable
# .c implementations directly when `reproVendoredHash` is defined; system-hash
# mode, including on Windows, leaves that define unset and relies on the
# configured system prefixes instead.
if not useSystemHashLibs:
  switch("passC", "-DREPRO_VENDORED_HASH")
  # `reproRepoRoot`, not `thisDir()`: these name vendored C headers inside THIS
  # repository, and under a profile compile `thisDir()` is the profile's
  # directory (see the note at the top). The `fileExists` guards below meant the
  # miss was silent — the `-I` flags were simply not added, and the failure
  # surfaced later as a C compile error about a missing `blake3.h`.
  let vendoredBlake3Inc = reproRepoRoot / "libs" / "blake3" / "src" /
    "blake3" / "vendor"
  let vendoredXxhashInc = reproRepoRoot / "libs" / "xxh3" / "src" /
    "xxh3" / "vendor"
  if fileExists(vendoredBlake3Inc / "blake3.h"):
    switch("passC", "-I" & vendoredBlake3Inc)
  if fileExists(vendoredXxhashInc / "xxhash.h"):
    switch("passC", "-I" & vendoredXxhashInc)
else:
  let blake3Prefix = block:
    let direct = firstExistingPrefix(
      [getEnv("BLAKE3_PREFIX"), "/opt/homebrew/opt/blake3", "/usr/local/opt/blake3"],
      "include/blake3.h",
      ["libblake3.dylib", "libblake3.so", "libblake3.a"])
    if direct.len > 0: direct
    else: nixPrefix("*-libblake3-*", "include/blake3.h",
                    ["libblake3.dylib", "libblake3.so", "libblake3.a"])

  if blake3Prefix.len > 0:
    switch("passC", "-I" & blake3Prefix / "include")
    # Resolve the actual libdir (lib / lib64 / multiarch) so the `-L`
    # flag points at the directory that holds the resolved dylib.
    let blake3LibDir = firstExistingPrefixLibDir(blake3Prefix,
      ["libblake3.dylib", "libblake3.so", "libblake3.a"])
    if blake3LibDir.len > 0:
      switch("passL", "-L" & blake3LibDir)
    else:
      switch("passL", "-L" & blake3Prefix / "lib")
    switch("passL", "-lblake3")

  let xxhashPrefix = block:
    let direct = firstExistingPrefix(
      [getEnv("XXHASH_PREFIX"), "/opt/homebrew/opt/xxhash", "/usr/local/opt/xxhash"],
      "include/xxhash.h",
      ["libxxhash.dylib", "libxxhash.so", "libxxhash.a"])
    if direct.len > 0: direct
    else: nixPrefix("*-xxHash-*", "include/xxhash.h",
                    ["libxxhash.dylib", "libxxhash.so", "libxxhash.a"])

  if xxhashPrefix.len > 0:
    switch("passC", "-I" & xxhashPrefix / "include")
    let xxhashLibDir = firstExistingPrefixLibDir(xxhashPrefix,
      ["libxxhash.dylib", "libxxhash.so", "libxxhash.a"])
    if xxhashLibDir.len > 0:
      switch("passL", "-L" & xxhashLibDir)
    else:
      switch("passL", "-L" & xxhashPrefix / "lib")
    switch("passL", "-lxxhash")

when not defined(windows) and not defined(macosx):
  let sqliteLibDir = block:
    let direct = firstExistingLibDir(
      [
        getEnv("SQLITE_LIBDIR"),
        getEnv("SQLITE_PREFIX"),
        "/usr",
        "/usr/local",
        "/usr/lib",
        "/usr/lib64",
        "/usr/lib/x86_64-linux-gnu",
      ],
      ["libsqlite3.so", "libsqlite3.a"])
    if direct.len > 0:
      direct
    else:
      nixLibDir("*-sqlite-*", ["libsqlite3.so", "libsqlite3.a"])

  if sqliteLibDir.len > 0:
    switch("passL", "-L" & sqliteLibDir)
    switch("passL", "-Wl,-rpath," & sqliteLibDir)

# OpenSSL link search path for `-d:ssl` edges (POSIX).
#
# The build graph's `-d:ssl` handling appends `-lssl -lcrypto` on every
# platform, but only emits the matching `-L` on Windows
# (`repro_dsl_stdlib/.../openssl_layout.windowsOpensslLinkSearchDir` returns ""
# on non-Windows). macOS/Linux were expected to inherit the search path from
# the dev-shell's ambient `NIX_LDFLAGS` (`pkgs.openssl` in flake.nix buildInputs).
# But the reprobuild ENGINE composes each build action's environment
# deliberately and does NOT carry ambient `NIX_LDFLAGS`, so a graph-built
# `-d:ssl` binary (e.g. `reprobuild.apps.repro`, `apps/repro/repro.nim` compiled
# with `defines=@[..., "ssl"]`) linked `clang ... -lssl -lcrypto` with no `-L`
# and failed the darwin release leg with `ld: library 'ssl' not found`.
#
# Supply the `-L` here the same way blake3/xxhash/sqlite do above: this
# config.nims `passL` reaches the engine's link edge (the failing link already
# carried the blake3/xxhash `-L` flags from those blocks, proving the channel).
# We add only the search path — the graph still owns `-lssl -lcrypto` per edge —
# so this is a no-op for non-ssl edges. Windows keeps its own graph-level path.
when not defined(windows):
  let opensslLibDir = block:
    let direct = firstExistingLibDir(
      [
        getEnv("OPENSSL_LIBDIR"),
        getEnv("OPENSSL_PREFIX"),
        "/opt/homebrew/opt/openssl@3",
        "/opt/homebrew/opt/openssl",
        "/usr/local/opt/openssl@3",
        "/usr/local/opt/openssl",
      ],
      ["libssl.dylib", "libssl.3.dylib", "libssl.so", "libssl.so.3"])
    if direct.len > 0:
      direct
    else:
      nixLibDir("*-openssl-*",
        ["libssl.dylib", "libssl.3.dylib", "libssl.so", "libssl.so.3"])

  if opensslLibDir.len > 0:
    switch("passL", "-L" & opensslLibDir)
    switch("passL", "-Wl,-rpath," & opensslLibDir)

# macOS: reserve Mach-O header room so the release packaging step can rewrite
# install names and add an LC_RPATH (@loader_path/../lib) with install_name_tool
# without failing "larger updated load commands do not fit (... use
# -headerpad_max_install_names)". build_apps.sh reserves this for the engine it
# links directly; the graph-built `.#release` app binaries are linked by the
# engine and need the same reservation to be relocatable into a portable
# tarball. No-op off macOS and harmless for non-packaged builds.
when defined(macosx):
  switch("passL", "-Wl,-headerpad_max_install_names")

# ---------------------------------------------------------------------------
# THE STANDARD LIBRARY IS SEARCHED FIRST. This block must stay LAST in the
# file: it reorders what everything above it added, and an entry added after it
# would jump back in front.
#
# The problem it fixes. Nim's installed ``nim.cfg`` puts ``$lib/pure``,
# ``$lib/core``, … on the search path before this file is read, and
# ``nimblecmd.addPath`` PREPENDS, so every ``--path`` above lands in FRONT of
# the standard library. Measured on the cold ``nim c`` of
# ``apps/repro/repro.nim`` at 9a44bf28, ``$lib/pure`` sat at search index 111 of
# 128 and ``$lib`` at 125: an ``import std/os`` walked past 111 project
# directories, missing every one of them, before it could hit. The stdlib is
# also the most-imported group in the tree, so it pays that walk the most times.
#
# The fix, in configuration only. ``--excludePath`` removes an entry from
# ``conf.searchPaths`` (``compiler/commands.nim``, ``keepItIf(it != path)``);
# re-adding it immediately afterwards puts it back at the front. Walking the
# stdlib entries BACKWARDS and doing that to each one moves the whole block
# ahead of every project path while preserving its internal order exactly.
# Nothing is duplicated: each path is removed before it is re-added.
#
# WHY THIS CANNOT CHANGE WHAT AN IMPORT RESOLVES TO. Reordering a search path is
# only safe if no module name is reachable from two entries. Checked at
# 9a44bf28 against the real filesystem, over every ``import`` / ``export`` /
# ``include`` / ``from`` spec in all 4,837 ``.nim`` files in this repository and
# under every directory on the path, probing both the ``std/x`` and the bare
# ``x`` spelling: exactly 10 specs are reachable from more than one entry, and
# all 10 are ``results`` and ``stew/*``, where this repository's vendored
# ``libs/results/src`` and ``libs/nim-stew/src`` shadow the two copies the Nim
# fork ships in ``$nim/dist``. ZERO specs are ambiguous between the standard
# library and anything else, so the block below moves the one group that can be
# moved without deciding anything.
#
# That is also why the loop is keyed on ``querySetting(libPath)`` and NOT on
# "everything under the Nim installation": ``$nim/dist/nim-stew`` and
# ``$nim/dist/nim-results`` are exactly the 10 ambiguous entries, and hoisting
# them would silently swap the vendored copies for the fork's.
#
# Re-derive the ambiguity set before extending this block — the safety property
# is a fact about the current tree, not an invariant anything enforces.
#
# ONE EXPECTED, ONE-TIME ARTIFACT-HASH CHANGE, AND IT IS NOT FROM THE REORDER.
# Adding ``std/compilesettings`` to the import at the top of this file registers
# that module in the compiler's module graph EARLIER than the program itself
# would (it is already in the program's 831-module closure either way, so
# nothing is added to the binary). That shifts the module id of the three
# modules that happened to sit after it — ``wrappers/openssl``, ``pure/net``,
# ``pure/asyncnet`` — by one slot, which renumbers the generated ``Dl_<n>_``
# dynlib function-pointer identifiers in their C. Measured at 9a44bf28 by
# compiling this file's PREVIOUS contents plus only the import line: 3 of the
# 563 generated ``.c`` files differ from the old build and NONE differs from the
# new one, so the path reordering and the two dropped entries contribute exactly
# zero codegen change. The build is otherwise deterministic — two cold builds of
# the unmodified file produced byte-identical binaries.
#
# How far the hash change reaches, measured rather than argued. Four cold LINK
# builds at 9a44bf28 (old twice, new, and old-plus-only-the-import):
#
#   * old #1 == old #2, byte for byte, from two different nimcaches — so the
#     comparison below means something;
#   * old-plus-only-the-import == new, byte for byte. The reordering and the
#     two dropped entries change not one byte of the executable;
#   * old vs new differ in 359,041 bytes, and EVERY ONE of them is in
#     ``.symtab`` or ``.strtab``. ``.text``, ``.rodata``, ``.data``,
#     ``.data.rel.ro`` and the relocations are identical, both binaries are the
#     same size, the 53 ``Dl_<n>_`` symbols sit at identical addresses, and
#     ``objcopy --strip-all`` of the two produces the SAME file.
#
# So the loaded program is bit-identical; what rotates is the name of a symbol
# in the debug table.
block stdlibFirst:
  let libRoot = querySetting(SingleValueSetting.libPath)
  if libRoot.len > 0:
    var stdlibEntries: seq[string] = @[]
    for entry in querySettingSeq(MultipleValueSetting.searchPaths):
      if (entry == libRoot or entry.startsWith(libRoot & "/") or
          entry.startsWith(libRoot & $DirSep)) and entry notin stdlibEntries:
        stdlibEntries.add entry
    # ``searchPaths`` is in probe order and each re-add prepends, so walking it
    # backwards lands the block in front with its relative order unchanged.
    #
    # ``$lib`` itself is a special case, and the honest description of what
    # happens to it is not "deduped". ``nim.cfg`` does not install it at all —
    # its 14 ``path=`` lines are all ``$lib/<subdir>`` — the COMPILER adds the
    # bare ``$lib``, and it does so more than once and partly AFTER this file
    # has been evaluated. Measured at 9a44bf28 with ``nim dump``: before this
    # block the path holds 128 entries with three copies of ``$lib``; after it,
    # 125 entries with TWO. The ``notin`` plus ``excludePath`` collapse the two
    # copies that exist at config time into the one hoisted to the front; the
    # third is appended later and cannot be reached from here. So one duplicate
    # remains, at the very back, where it costs one extra probe only for a
    # lookup that misses everything. Do not read this loop as a deduplicator.
    for i in countdown(stdlibEntries.high, 0):
      switch("excludePath", stdlibEntries[i])
      switch("path", stdlibEntries[i])

## Worktree-local nimcache: every Nim compile inside this checkout keeps its
## intermediate files (its nimcache) INSIDE this checkout.
##
## WHY.  Nim's default nimcache is `$XDG_CACHE_HOME/nim/<project>_d` (`_r` for
## -d:release; `%USERPROFILE%\nimcache\<project>_d` on Windows).  It is keyed by
## the project NAME only, and the generated file names inside it do not depend
## on the checkout path either.  So two worktrees or clones of this repository
## that build the same project at the same time write, compile and link each
## other's intermediate files.  Measured on 2026-09-26 in a sibling repository:
## ten concurrent builds of two worktrees that differed in a few places gave
## four correct binaries, two that exited 0 with the OTHER worktree's code
## linked in (one of them a mix of both), two compile failures on
## half-rewritten generated C and two link failures.
##
## WHAT.  `<checkout>/.nimcache/<directory of the main module, relative to the
## checkout>/<module name><suffix>`, where the suffix is Nim's own: `_check`
## for `nim check`, `_r` for -d:release or -d:danger, `_d` otherwise.  The
## directory is part of the key, so same-named modules in different directories
## no longer share a cache either.  Only the intermediates move; build outputs
## stay where they were.  An explicit `--nimcache:` on the command line still
## wins, because Nim applies the command line again after the config files.
## `nim js` and project-less invocations are left alone.
##
## HOW IT IS PICKED UP.  Nim runs the `config.nims` of every PARENT directory of
## the compiled module, outermost first, then the one in the module's own
## directory.  So this file applies to every compile under this checkout,
## `just`, the test graph, CI and a bare `nim c` alike, whatever the working directory.
## `--skipParentCfg` switches it off for modules below the checkout root, so a
## recipe that passes that flag must name its own checkout-local `--nimcache:`.
## The app build (`scripts/build_apps.sh`) and the test graph name their own
## `--nimcache:` under `build/`, which still wins; the one script that passes
## `--skipParentCfg` (`scripts/check_toolchain_dlopen.sh`) does too.
## `tests/unit/t_nimcache_is_worktree_local.nim` checks the layout, and fails if the
## config is bypassed; its `--skipParentCfg` negative control proves the probe
## can see a shared cache at all.
##
## WINDOWS.  Nim turns the `/` below into `\` on a Windows host.  The layout adds
## `\.nimcache\<module dir>\<module>_d\` in front of Nim's own object file names,
## so keep the checkout root short (about 80 characters) to stay inside MAX_PATH.
block worktreeLocalNimcache:
  var project = projectName()
  if project.len > 4 and project[^4 .. ^1] == ".nim":
    project = project[0 ..< ^4]
  # No project (`nim dump` with no file): nothing to place.  The JS backend
  # has its own convention (a cache next to its output).  `nim e` never
  # generates C, so it never creates the directory.
  if project.len == 0 or getCommand() == "js":
    break worktreeLocalNimcache

  # Plain "/" joins, NOT std/os `/`: NimScript's `/` follows the TARGET OS,
  # so a `--os:windows` cross-compile on a POSIX host would get backslashes.
  let root = thisDir()
  let projDir = projectDir()
  var rel = ""
  if projDir.len >= root.len and projDir[0 ..< root.len] == root:
    rel = projDir[root.len .. ^1]
  else:
    # Cannot happen for a project Nim found this file for (this file is read
    # because it sits in a parent of the project directory).  Stay inside
    # the checkout and stay unique anyway.
    rel = "_outside/"
    for c in projDir:
      rel.add(if c in {'/', '\\', ':'}: '_' else: c)
  while rel.len > 0 and rel[0] in {'/', '\\'}:
    rel = rel[1 .. ^1]

  let suffix =
    if getCommand() == "check": "_check"
    elif defined(release) or defined(danger): "_r"
    else: "_d"
  var cacheDir = root & "/.nimcache"
  if rel.len > 0:
    cacheDir.add("/" & rel)
  switch("nimcache", cacheDir & "/" & project & suffix)
