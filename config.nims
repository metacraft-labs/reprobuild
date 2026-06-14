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
# ``buildNimUnittest.build(...)`` call from the codetracer-side
# ``ct_test_nim_unittest`` adapter. The adapter re-exports
# ``ct_test_interface`` so both module paths land on ``--path``.
let ctTestRoot = block:
  let fromEnv = getEnv("CT_TEST_SRC")
  if fromEnv.len > 0:
    fromEnv
  else:
    ".." / "ct-test"
for ctTestLib in [
  "ct_test_interface",
  "ct_test_nim_unittest",
  "ct_test_unittest_parallel",
  # Spec-Implementation M4: ``ct_test_runner_adapter`` is the
  # ``TestRunner`` cross-cutting-interface adapter that delegates to
  # ``ct-test-runner`` for run/list/enumerate. Reprobuild project files
  # import it after ``ct_test_nim_unittest`` to wire the adapter into
  # the active build context. The previous shim at
  # ``libs/repro_cli_support/src/repro_cli_support.nim`` ~line 1295
  # was retired in M4; the adapter shoulders the execution-time
  # responsibility while the build-time ``buildNimUnittest.build`` call
  # now routes through the normal ``nim`` profile via the typed-tool
  # wrapper machinery.
  "ct_test_runner_adapter",
]:
  let candidate = ctTestRoot / "libs" / ctTestLib / "src"
  if dirExists(candidate):
    switch("path", candidate)

for libName in [
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
  "repro_monitor_depfile",
  "repro_depfile",
  "repro_monitor_shim",
  "repro_monitor_hooks",
  "repro_project_dsl",
  "repro_project_dsl_runtime_dll",
  "repro_dsl_stdlib",
  "repro_home_intent",
  "repro_profile",
  "repro_profile_intent",
  "repro_profile_compile",
  "repro_home_generations",
  "repro_home_apply",
  "repro_home_rollback",
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
  # Spec-Implementation M2a: ``repro_solver`` ships the clingo Nim
  # bindings + the high-level Solver/Solution/Constraint placeholder
  # types. M2b-M2e extend it with the ASP encoder; downstream libs
  # import it via ``import repro_solver`` once the encoder is alive.
  "repro_solver",
]:
  switch("path", "libs" / libName / "src")

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

# The Windows monitor shim's hook chain is implemented on top of
# ``metacraft-labs/nim-stackable-hooks`` (the framework portion that
# the spec at MCR-OS-Interposition.status.org §M0 describes as the
# Nim port of agent-harbor's stackable-hooks Rust library). Prefer
# an explicit STACKABLE_HOOKS_SRC, then the sibling-repo checkout,
# then a vendored copy under libs/repro_monitor_shim/vendor.
addPackagePath("STACKABLE_HOOKS_SRC", [
  ".." / "nim-stackable-hooks" / "src",
  "libs" / "repro_monitor_shim" / "vendor" / "nim-stackable-hooks" / "src",
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

# Windows and the default local build use the vendored blake3 / xxhash sources
# we already ship under references/mold/. `blake3.nim` and `xxh3.nim` compile
# the portable .c implementations directly when `reproVendoredHash` is defined;
# we just need their headers on the include path.
if not useSystemHashLibs:
  let vendoredBlake3Inc = thisDir() / "references" / "mold" / "third-party" /
    "blake3" / "c"
  let vendoredXxhashInc = thisDir() / "references" / "mold" / "third-party" /
    "xxhash"
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
