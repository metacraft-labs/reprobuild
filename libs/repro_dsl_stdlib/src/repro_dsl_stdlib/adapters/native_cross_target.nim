## Spec-Implementation M3 — native ``CrossTarget`` default adapter.
##
## Per Reprobuild-Standard-Library §"Cross-Cutting Interfaces" /
## §"`CrossTarget`", the native adapter is synthesised at build
## context construction when no ``targetTriple`` variant is in effect.
## It returns the host triple, an empty sysroot, and a degenerate
## ``splice`` where each facet of the ``SplicedPackageSet`` is the
## input list passed in. Non-native targets (M5) replace this with
## sysroot-aware adapters.

import ../interfaces/cross_target
export cross_target

proc detectHostTriple(): string =
  ## Determine the host triple from compile-time constants. Mirrors
  ## Nix's host-triple synthesis: ``<cpu>-<os>-<abi>`` where ``cpu``
  ## comes from ``hostCPU``, ``os`` from ``hostOS``, and ``abi`` is
  ## ``"gnu"`` on Linux, ``""`` elsewhere (the spec's
  ## ``hostTriple`` field has no ABI requirement on macOS/Windows).
  let cpu = hostCPU
  let os = hostOS
  let abi =
    case os
    of "linux": "gnu"
    of "macosx": "darwin"
    of "windows": "msvc"
    else: ""
  if abi.len > 0:
    cpu & "-" & os & "-" & abi
  else:
    cpu & "-" & os

proc detectBinaryFormat(): BinaryFormat =
  case hostOS
  of "macosx": bfMachO
  of "windows": bfPE
  else: bfELF

proc nativeCrossTarget*(): CrossTarget =
  ## The stdlib's default native ``CrossTarget``. Installed into the
  ## active-build-context slot when the ``targetTriple`` variant is
  ## absent or resolves to ``"native"``.
  let triple = detectHostTriple()
  let binFmt = detectBinaryFormat()
  proc nativeTargetTriple(): string = triple
  proc nativeHostPrefix(): string = ""
  proc nativeSplice(buildPkgs, hostPkgs, targetPkgs: seq[string]):
      SplicedPackageSet =
    # Degenerate native splice — every facet passes through unchanged
    # so a recipe written for cross compilation still works on a
    # native build.
    SplicedPackageSet(
      buildPkgs: buildPkgs,
      hostPkgs: hostPkgs,
      targetPkgs: targetPkgs)
  newCrossTarget(
    name = "native",
    triple = triple,
    sysroot = "",
    isNative = true,
    cFlags = @[],
    linkFlags = @[],
    binaryFormat = binFmt,
    pageSize = 4096,
    targetTriple = nativeTargetTriple,
    hostPrefix = nativeHostPrefix,
    splice = nativeSplice)

proc crossTargetFromTriple*(triple: string): CrossTarget =
  ## Build a non-native ``CrossTarget`` whose triple is the value
  ## passed in. The ``targetTriple`` variant's resolved value drives
  ## the input. M3 supplies a stub adapter whose ``hostPrefix`` is the
  ## triple plus a trailing dash (the GNU convention); the proper
  ## per-target sysroot adapters land in M5 alongside the
  ## cross-compilation worked example.
  proc crossTargetTriple(): string = triple
  proc crossHostPrefix(): string =
    if triple.len > 0: triple & "-" else: ""
  proc crossSplice(buildPkgs, hostPkgs, targetPkgs: seq[string]):
      SplicedPackageSet =
    # M3 cross-adapter splice rule: build-host stays as-is; host-host
    # and target-host carry the triple-prefixed names so adapters can
    # tell them apart. The merging logic mirrors Nix's
    # ``pkgsCross.<target>.splicedPackages`` shape, simplified to the
    # name-only representation.
    var hostPrefixed = newSeq[string](hostPkgs.len)
    var targetPrefixed = newSeq[string](targetPkgs.len)
    for i, p in hostPkgs:
      hostPrefixed[i] = p & "-for-" & triple
    for i, p in targetPkgs:
      targetPrefixed[i] = p & "-for-" & triple
    SplicedPackageSet(
      buildPkgs: buildPkgs,
      hostPkgs: hostPrefixed,
      targetPkgs: targetPrefixed)
  newCrossTarget(
    name = "cross-" & triple,
    triple = triple,
    sysroot = "",
    isNative = false,
    cFlags = @["--target=" & triple],
    linkFlags = @["--target=" & triple],
    binaryFormat = bfELF,
    pageSize = 4096,
    targetTriple = crossTargetTriple,
    hostPrefix = crossHostPrefix,
    splice = crossSplice)
