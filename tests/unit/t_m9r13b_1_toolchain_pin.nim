## DSL-port M9.R.13b.1 — Windows interface-extract / provider-compile
## carry the vendored-hash define so xxhash.c / blake3.c land in the
## link.
##
## ## Context
##
## After M9.R.13a collapsed the per-recipe provider compile from hours
## to ~84 s for the wayland from-source smoke, the next gap surfaced
## at the interface-extractor LINK stage:
##
##   undefined reference to `XXH3_64bits'
##   undefined reference to `XXH3_64bits_withSeed'
##   collect2.exe: error: ld returned 1 exit status
##   Error: execution of an external program failed:
##     'gcc.exe  @extract_runner_linkerArgs.txt'
##
## ``libs/xxh3/src/xxh3.nim`` guards the inclusion of the vendored
## ``xxhash.c`` translation unit behind ``when defined(reproVendoredHash)``;
## the reprobuild root ``config.nims`` defines that symbol when
## ``REPROBUILD_USE_SYSTEM_HASH_LIBS`` is unset. The interface-extract
## runner is compiled with ``cwd=workDir`` so it COULD pick up the root
## ``config.nims`` -- but the runner module lives in
## ``%TEMP%\repro-interface-extract\...\extract_runner.nim`` which is
## outside the project tree, so Nim does not include the project's
## ``config.nims`` for the compile. The runner is therefore compiled
## WITHOUT ``-d:reproVendoredHash``; ``xxh3.nim`` skips the
## ``{.compile: xxhash.c.}`` block; ``xxh3/capi.c`` is still compiled
## (it is unconditional) but its references to ``XXH3_64bits`` /
## ``XXH3_64bits_withSeed`` have no implementation translation unit to
## link against, so the final ``gcc`` link fails.
##
## ``externalHashFlags`` was already replaying the ``-I`` include paths
## for blake3 / xxhash from the workDir-relative vendored tree; the fix
## is to also append ``--define:reproVendoredHash`` when both vendored
## sources exist and ``REPROBUILD_USE_SYSTEM_HASH_LIBS`` is unset --
## matching the root ``config.nims`` exactly.
##
## ## What this test pins
##
## 1. The provider-compile command emitted for a Windows-style workDir
##    contains ``--define:reproVendoredHash`` when the vendored sources
##    are present and the system-hash env override is unset. This is
##    the symbol Nim looks for at the ``{.compile: xxhash.c.}`` pragma.
##
## 2. Setting ``REPROBUILD_USE_SYSTEM_HASH_LIBS=1`` suppresses the
##    define (matches ``config.nims``'s behaviour -- a system install
##    provides the symbols via ``-lxxhash`` instead, so the vendored
##    compile pragma must NOT fire to avoid multiple-definition link
##    errors).
##
## 3. The ``-I`` flags for both blake3 and xxhash are still emitted
##    alongside the define -- the runner ``xxh3/capi.c`` includes
##    ``xxhash.h``, so the header is still needed even when the
##    implementation is system-provided.
##
## The arms run on every host because the contract is host-agnostic at
## the workDir level -- the Windows-only branch of ``externalHashFlags``
## is the one being modified, but the test reasons about the
## emitted command via ``providerCompileCommand`` and inspects the
## argv. We compile-gate the arms by ``defined(windows)`` because the
## non-Windows branch in ``externalHashFlags`` goes through homebrew /
## nix prefix discovery that does not run on the CI host.

import std/[os, sequtils, strutils, unittest]

import repro_interface_artifacts

# ---------------------------------------------------------------------------
# Test fixture helpers
# ---------------------------------------------------------------------------

proc reproRoot(): string =
  ## Walk upward from this test file to find the repo root (the one
  ## containing ``references/mold/third-party/xxhash/xxhash.h``). The
  ## test is invoked from various cwds (just / nimble / manual), so the
  ## walk is anchored at ``currentSourcePath`` instead.
  var dir = parentDir(currentSourcePath())
  while dir.len > 0 and dir != parentDir(dir):
    if fileExists(dir / "references" / "mold" / "third-party" / "xxhash" /
        "xxhash.h"):
      return dir
    dir = parentDir(dir)
  raise newException(IOError,
    "could not locate reprobuild root from " & currentSourcePath() &
      " -- expected references/mold/third-party/xxhash/xxhash.h ancestor")

template withSystemHashEnv*(value: string; body: untyped) =
  ## Run ``body`` with ``REPROBUILD_USE_SYSTEM_HASH_LIBS=value`` and
  ## restore the prior env (preserving the unset case via ``delEnv``).
  ## Templated so the body can return any type (or nothing).
  let key = "REPROBUILD_USE_SYSTEM_HASH_LIBS"
  let priorSet = existsEnv(key)
  let priorVal = if priorSet: getEnv(key) else: ""
  if value.len > 0:
    putEnv(key, value)
  else:
    delEnv(key)
  try:
    body
  finally:
    if priorSet:
      putEnv(key, priorVal)
    else:
      delEnv(key)

# ---------------------------------------------------------------------------
# Test suites
# ---------------------------------------------------------------------------

suite "M9.R.13b.1 -- vendored-hash define propagation":
  setup:
    let workDir = reproRoot()
    let modulePath = workDir / "tests" / "unit" /
      "t_m9r13b_1_toolchain_pin.nim"   # any file inside the tree
    let outBin = workDir / "build" / "bin" / "m9r13b1_marker"

  test "Arm 1: vendored sources present + env unset -> define emitted":
    when defined(windows):
      withSystemHashEnv "":
        let cmd = providerCompileCommand(modulePath = modulePath,
          outputBinaryPath = outBin,
          workDir = workDir)
        let hasDefine = cmd.anyIt(it == "--define:reproVendoredHash")
        if not hasDefine:
          checkpoint("command: " & cmd.join(" "))
          checkpoint("providerCompileCommand must propagate " &
            "--define:reproVendoredHash when the vendored xxhash/" &
            "blake3 sources are present and REPROBUILD_USE_SYSTEM_HASH_LIBS " &
            "is unset; otherwise the interface-extract runner skips " &
            "xxh3.nim's {.compile: xxhash.c.} block and the link fails " &
            "on XXH3_64bits.")
        check hasDefine
    else:
      skip()  # non-Windows: branch tested via the system prefix path

  test "Arm 2: REPROBUILD_USE_SYSTEM_HASH_LIBS=1 suppresses define":
    when defined(windows):
      withSystemHashEnv "1":
        let cmd = providerCompileCommand(modulePath = modulePath,
          outputBinaryPath = outBin,
          workDir = workDir)
        let hasDefine = cmd.anyIt(it == "--define:reproVendoredHash")
        if hasDefine:
          checkpoint("command: " & cmd.join(" "))
          checkpoint("REPROBUILD_USE_SYSTEM_HASH_LIBS=1 must suppress " &
            "--define:reproVendoredHash so the vendored {.compile:.} " &
            "pragma does NOT fire alongside a system -lxxhash (which " &
            "would multiply-define the symbols).")
        check not hasDefine
    else:
      skip()

  test "Arm 3: include dirs still emitted alongside define":
    when defined(windows):
      withSystemHashEnv "":
        let cmd = providerCompileCommand(modulePath = modulePath,
          outputBinaryPath = outBin,
          workDir = workDir)
        let blakeI = cmd.anyIt(it.startsWith("--passC:-I") and
          it.contains("blake3" & DirSep & "c"))
        let xxhI = cmd.anyIt(it.startsWith("--passC:-I") and
          it.contains("xxhash"))
        if not blakeI:
          checkpoint("missing blake3 -I; command: " & cmd.join(" "))
        if not xxhI:
          checkpoint("missing xxhash -I; command: " & cmd.join(" "))
        check blakeI
        check xxhI
    else:
      skip()

  test "Arm 4: env values other than 1/true/yes/on do NOT suppress define":
    when defined(windows):
      # config.nims accepts only ["1","true","yes","on"] (lowercased) as
      # the system-hash flip; any other value (including "0", "off",
      # "false", "no") leaves the vendored path active.
      for ambiguous in ["0", "off", "false", "no", "maybe", ""]:
        withSystemHashEnv ambiguous:
          let cmd = providerCompileCommand(modulePath = modulePath,
            outputBinaryPath = outBin,
            workDir = workDir)
          let hasDefine = cmd.anyIt(it == "--define:reproVendoredHash")
          if not hasDefine:
            checkpoint("env=" & ambiguous & " command: " & cmd.join(" "))
          check hasDefine
    else:
      skip()
