import std/[os, strutils]

switch("styleCheck", "hint")

# Project-DSL-Composition M6: ``repro.nim`` ``import``s the generated
# ``repro_tests.nim`` (data table of declared test edges) that lives
# alongside it at the repo root. Adding ``.`` to ``--path`` lets
# library-local tests in ``libs/*/tests/`` also import the table for
# the M6 smoke check.
switch("path", ".")

# Test-Edges-And-Parallel-Runner M1: ``repro.nim`` consumes the
# generated ``repro_tests.nim`` whose data entries each become a
# ``buildNimUnittest.build(...)`` call. The build-side typed-tool
# (``ct_test_nim_unittest`` + its ``ct_test_interface`` contract) now
# lives in-tree under ``libs/`` (added via the ``libName`` loop below):
# it depends only on ``repro_project_dsl`` and is the half ``repro.nim``
# imports, so hosting it in-tree removes the reprobuild↔adapter
# dependency cycle that the previous external import closed. Only the
# execution-time ``TestRunner`` adapter (``ct_test_runner_adapter`` — the
# in-process bridge in the ``reprobuild-ct-test-runner`` repo) stays
# external and is resolved from the sibling checkout below.
let ctTestRunnerRoot = block:
  let fromEnv = getEnv("REPRO_CT_TEST_RUNNER_SRC")
  if fromEnv.len > 0:
    fromEnv
  else:
    ".." / "reprobuild-ct-test-runner"
for ctTestLib in [
  "ct_test_runner_adapter",
  # Incremental-Test-Runner M0b-2: the watch-integration incremental-decision
  # seam (``ct_incremental_adapter`` — ``watchTestEdgeDecision`` /
  # ``WatchEdgeDecision``), backed by codetracer's canonical engine. Replaces
  # reprobuild's former vendored ``repro_ct_incremental`` copy.
  "ct_incremental_adapter",
]:
  let candidate = ctTestRunnerRoot / "libs" / ctTestLib / "src"
  if dirExists(candidate):
    switch("path", candidate)

# Incremental-Test-Runner M0b-2: ``ct_incremental_adapter`` imports codetracer's
# CANONICAL incremental engine (``codetracer/src/ct_test/incremental/engine.nim``)
# directly as a workspace SIBLING — the whole point of M0b is that reprobuild
# consumes the canonical engine with NO vendored copy and NO drift. The engine's
# transitive imports stay within codetracer's ``ct_test/incremental`` modules
# plus codetracer-trace-format-nim's seekable CTFS reader; it pulls in NO
# reprobuild, runquota, or io-mon module. This wiring MIRRORS the adapter repo's
# own ``config.nims`` (``wireCodetracerEngine``) and codetracer's
# ``src/ct_test/config.nims`` + ``nim.cfg`` — the only build configuration that
# makes the engine compile: the engine module path, the codetracer-trace-format-nim
# sibling path, the ``results >= 0.5`` pin its seekable reader needs, and the
# zstd dev include for the trace-format-nim CTFS reader's ``#include <zstd.h>``.
# Every path is defended with ``dirExists``/``fileExists`` so a checkout missing
# the codetracer sibling fails LOUDLY at compile time rather than mis-resolving.
proc wireCodetracerEngine() =
  # 1. The canonical engine module directory. Resolved from
  #    ``CODETRACER_CT_TEST_SRC`` (the dev shell / CI sets it) or the sibling
  #    checkout next to this repo for local development.
  let ctTestSrc =
    if getEnv("CODETRACER_CT_TEST_SRC").len > 0:
      getEnv("CODETRACER_CT_TEST_SRC")
    else:
      ".." / "codetracer" / "src" / "ct_test"
  let engineDir = ctTestSrc / "incremental"
  if fileExists(engineDir / "engine.nim"):
    switch("path", engineDir)

  # 2. codetracer-trace-format-nim — the package the engine's seekable
  #    executed-function reader (``ctfs_seekable.nim``) links.
  let traceFormatSrc =
    if getEnv("CODETRACER_TRACE_FORMAT_NIM_SRC").len > 0:
      getEnv("CODETRACER_TRACE_FORMAT_NIM_SRC")
    else:
      ".." / "codetracer-trace-format-nim" / "src"
  if fileExists(traceFormatSrc / "codetracer_ct_print_lib.nim"):
    switch("path", traceFormatSrc)

  # 3. ``results >= 0.5`` pin (env var, then the newest ``results-0.5*`` under
  #    ``~/.nimble/pkgs2``). codetracer-trace-format-nim needs the ``.v`` field
  #    the ``?`` operator expands to; the older vendored ``results`` lacks it.
  block pinResults:
    let envSrc = getEnv("CODETRACER_RESULTS_SRC")
    if envSrc.len > 0 and dirExists(envSrc):
      switch("path", envSrc)
      break pinResults
    let pkgs2 = getHomeDir() / ".nimble" / "pkgs2"
    if dirExists(pkgs2):
      var best = ""
      for kind, p in walkDir(pkgs2):
        if kind == pcDir and p.lastPathPart.startsWith("results-0.5"):
          if p.lastPathPart > best.lastPathPart:
            best = p
      if best.len > 0:
        switch("path", best)

  # 4. zstd dev include for the trace-format-nim CTFS reader's
  #    ``#include <zstd.h>`` — re-surfaced out of the nix cc-wrapper's
  #    ``NIX_CFLAGS_COMPILE`` exactly as codetracer's ``config.nims`` does.
  let nixCflags = getEnv("NIX_CFLAGS_COMPILE")
  if nixCflags.len > 0:
    let toks = nixCflags.splitWhitespace()
    var i = 0
    while i < toks.len:
      if toks[i] == "-isystem" and i + 1 < toks.len:
        let dir = toks[i + 1]
        if "zstd" in dir:
          switch("passC", "-isystem " & dir)
        i += 2
      else:
        i += 1

# NOTE: ``wireCodetracerEngine()`` is CALLED at the very END of this config
# (after the vendored ``results`` ``--path`` below), not here. In NimScript the
# LAST ``--path`` added is searched FIRST, so codetracer's ``results >= 0.5``
# pin (which the canonical engine + codetracer-trace-format-nim require — their
# ``?`` operator expands to the ``.v`` field that version introduced) must be
# added AFTER reprobuild's vendored ``libs/results`` to take precedence for the
# engine modules. The proc is defined here; the call is deferred to the bottom.

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
  "repro_home_generations",
  "repro_home_apply",
  "repro_home_rollback",
  # ReproOS-Generations-And-Foreign-Packages B3: system-scope
  # switch / rollback / list / gc / repair primitives. Lifts the
  # home-profile rollback contract into system scope.
  "repro_system_rollback",
  "repro_home_resources",
  "repro_homebrew_adapter",
  "repro_elevation",
  "repro_infra",
  "repro_interface_artifacts",
  "repro_dev_env_artifacts",
  "repro_dev_env_activation",
  "repro_dev_env_engine",
  "repro_tool_profiles",
  "repro_local_store",
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
  # Incremental-Test-Runner M0b-3: the former vendored ``repro_ct_incremental``
  # engine copy was DELETED. The ``repro watch --ct-incremental`` decision seam
  # now flows through the engine-free ``ct_incremental_adapter`` (resolved from
  # the ``reprobuild-ct-test-runner`` sibling above) onto codetracer's canonical
  # engine. No reprobuild-side engine library remains.
]:
  switch("path", "libs" / libName / "src")

# Incremental-Test-Runner M7: reprobuild's build engine consumes the shared
# ``io-mon`` filesystem-monitoring library instead of its own former
# ``repro_monitor_depfile`` / ``repro_monitor_shim`` / ``repro_monitor_hooks``
# fs-snoop stack (now deleted). io-mon is a byte-identical wire-format + ABI
# relocation of that stack onto ``nim-stackable-hooks``; the depfile API
# (``MonitorDepFile`` / ``readMonitorDepFile`` / ``MonitorRecord`` / the
# ``mr*`` / ``mo*`` / ``mc*`` enums / ``MonitorDepFileReaderError`` / the
# ``fs_snoop`` driver + ``findShimLibrary``) is re-exported under the same
# names from ``import io_mon`` (and the shim/hooks runtime under
# ``io_mon/shim`` / ``io_mon/hooks``), so the consumers swapped their imports
# only — no logic changed. The package's Nim name is ``io_mon`` with srcDir
# ``src``; resolve the sibling checkout by path like every other workspace
# Nim sibling. Prefer ``$IO_MON_SRC``, then the sibling checkout.
let ioMonSrc = block:
  let fromEnv = getEnv("IO_MON_SRC")
  if fromEnv.len > 0:
    fromEnv
  else:
    ".." / "io-mon" / "src"
if fileExists(ioMonSrc / "io_mon.nim"):
  switch("path", ioMonSrc)

proc addPackagePath(envName: string; candidates: openArray[string];
                    marker: string) =
  let envPath = getEnv(envName)
  if envPath.len > 0 and fileExists(envPath / marker):
    switch("path", envPath)
    return
  for candidate in candidates:
    if fileExists(candidate / marker):
      switch("path", candidate)
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

# Incremental-Test-Runner M0b-2: wire codetracer's canonical incremental engine
# LAST, so its ``results >= 0.5`` pin is searched ahead of reprobuild's vendored
# ``libs/results`` (NimScript: the last ``--path`` wins). The engine +
# codetracer-trace-format-nim require the ``.v`` field the newer ``results``
# introduces; the older vendored copy lacks it. Modules that only need the
# vendored ``results`` still resolve it (it is still on the path) — only the
# engine's seekable-reader chain needs the newer one, and it gets it by
# precedence. See ``wireCodetracerEngine`` above.
wireCodetracerEngine()

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

# R2: vm-harness lives in the sibling ``D:/metacraft/vm-harness/`` repo
# (see ReproOS-MVP R0 status). The R2 boot integration test
# (tests/integration/t_r2_iso_boot.nim) imports ``vm_harness`` to drive
# the bootFromMedia/captureSerial/expectLine primitives against the
# Hyper-V Gen-2 UEFI backend. Prefer $VM_HARNESS_SRC, then the
# sibling-repo checkout.
addPackagePath("VM_HARNESS_SRC", [
  ".." / "vm-harness" / "src",
], "vm_harness.nim")

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

let useSystemHashLibs = getEnv("REPROBUILD_USE_SYSTEM_HASH_LIBS").toLowerAscii() in
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
  let vendoredBlake3Inc = thisDir() / "libs" / "blake3" / "src" /
    "blake3" / "vendor"
  let vendoredXxhashInc = thisDir() / "libs" / "xxh3" / "src" /
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
