import std/[os, strutils]

switch("styleCheck", "hint")

for libName in [
  "repro_core",
  "repro_platform",
  "repro_diagnostics",
  "repro_cli_support",
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
  "repro_dsl_stdlib",
  "repro_interface_artifacts",
  "repro_tool_profiles",
  "repro_local_store",
  "repro_launch_plan",
  "repro_runquota",
  "repro_build_engine",
  "repro_provider_runtime",
  "repro_hcr_linkgraph",
  "repro_hcr_linker",
  "repro_hcr_agent",
  "repro_hcr_test",
]:
  switch("path", "libs" / libName / "src")

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
]:
  switch("path", runquotaRoot / "libs" / libName / "src")

proc firstExistingPrefix(candidates: openArray[string]; header: string;
                         dylibNames: openArray[string]): string =
  for prefix in candidates:
    if prefix.len == 0:
      continue
    if not fileExists(prefix / header):
      continue
    for dylibName in dylibNames:
      if fileExists(prefix / "lib" / dylibName):
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
    if fileExists(prefix / header):
      for dylibName in dylibNames:
        if fileExists(prefix / "lib" / dylibName):
          return prefix
  ""

# Windows: no homebrew/nix prefix is available, so feed the C wrappers the
# vendored blake3 / xxhash sources we already ship under references/mold/.
# `blake3.nim` and `xxh3.nim` compile the vendored portable .c implementations
# directly when defined(windows); we just need their headers on the include
# path.
when defined(windows):
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
    switch("passL", "-L" & xxhashPrefix / "lib")
    switch("passL", "-lxxhash")
