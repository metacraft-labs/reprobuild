import std/[os, strutils]

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
  # ``ct_test_unittest_parallel`` is the test-binary protocol support that
  # reprobuild's own ``tools/test-runner`` and parallel-runner tests link.
  "ct_test_interface",
  "ct_test_nim_unittest",
  "ct_test_unittest_parallel",
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
  "repro_diagnostics",
  "repro_cli_support",
  "repro_daemon_core",
  "blake3",
  "xxh3",
  "gxhash",
  "repro_hash",
  "cbor",
  "repro_domain_types",
  "repro_depfile",
  "repro_project_dsl",
  "repro_project_dsl_runtime_dll",
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
  # Action-Cache-Per-Edge-Store AC-2a: shared-memory hot-tier data structures
  # (control region, generation segments, seqlock table, MPSC ring). Pure data
  # structures — no daemon (AC-2b) / engine wiring (AC-2c) yet.
  "repro_shm_index",
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
  # Incremental-Test-Runner M0b-3: the former vendored ``repro_ct_incremental``
  # engine copy was DELETED. The ``repro watch --ct-incremental`` decision seam
  # now flows through the engine-free ``ct_incremental_adapter`` (resolved from
  # CodeTracer's ``src`` above) onto codetracer's canonical engine. No
  # reprobuild-side engine library remains.
]:
  switch("path", "libs" / libName / "src")

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

proc addPackagePath(envName: string; candidates: openArray[string];
                    marker: string; useDevShellFallback = false) =
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
], "bearssl.nim")
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

# SHM-QUEUE-MIGRATE / io-mon LOSSLESS M1: reprobuild's action-cache submission
# ring (libs/repro_shm_index) AND the io-mon sibling's dependency queue BOTH sit
# on nim-shm-queue's Layer-1 MPSC ring; the io-mon sibling ALSO sits on
# nim-shm-gset (``shm_gset/transport``). Because config.nims compiles the io-mon
# SIBLING in-tree (the io-mon block above prefers ``../io-mon`` over $IO_MON_SRC),
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

# SHM-GSET: io-mon's Linux dependency-capture channel is the grow-only
# shared-memory set ``shm_gset`` (nim-shm-gset — Candidate C of the Lossless
# Event Capture campaign; dedup-at-source over file-backed shards). reprobuild
# does not import it directly, but io_mon's fs_snoop.nim / writer.nim do, so the
# io-mon compile that flows in through ``import io_mon`` needs ``shm_gset`` on the
# --path. Resolve it like every other Nim sibling: prefer ``$SHM_GSET_SRC``, then
# the sibling checkout.
addPackagePath("SHM_GSET_SRC", [
  ".." / "nim-shm-gset" / "src",
], "shm_gset.nim", useDevShellFallback = true)

# R2: vm-harness lives in the sibling ``D:/metacraft/vm-harness/`` repo
# (see ReproOS-MVP R0 status). The R2 boot integration test
# (tests/integration/t_r2_iso_boot.nim) imports ``vm_harness`` to drive
# the bootFromMedia/captureSerial/expectLine primitives against the
# Hyper-V Gen-2 UEFI backend. Prefer $VM_HARNESS_SRC, then the
# sibling-repo checkout.
addPackagePath("VM_HARNESS_SRC", [
  ".." / "vm-harness" / "src",
], "vm_harness.nim")

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
