## Spec-Implementation M5 — cross-compilation ``Toolchain`` + ``CrossTarget``
## adapter for the ``aarch64-linux-gnu`` triple.
##
## Per Reprobuild-Standard-Library §"Worked Example: Cross-Compilation"
## and Configurable-System §"Worked Example: Cross-Compilation", a
## cross-toolchain adapter package supplies both a populated
## ``Toolchain`` (cross gcc / clang binary + sysroot-aware flags) AND a
## populated ``CrossTarget`` (triple + sysroot + binary format) that
## the active build context wires when the ``targetTriple`` variant
## resolves to ``aarch64-linux-gnu``. The two interfaces are
## independent slots on ``PackageBuildState`` but the cross-toolchain
## adapter populates them together so a recipe that consults
## ``currentBuildContext().toolchain.compile(...)`` and
## ``currentBuildContext().crossTarget.triple`` sees a consistent pair.
##
## ## Cross-compiler discovery
##
## The adapter probes the host for an ``aarch64-{linux,unknown-linux}-gnu-gcc``
## binary in three places, in order:
##   1. The ``REPRO_AARCH64_GCC`` environment variable.
##   2. ``aarch64-linux-gnu-gcc`` / ``aarch64-unknown-linux-gnu-gcc`` on
##      ``$PATH`` (the standard names for Debian-packaged and
##      nixpkgs ``pkgsCross.aarch64-multiplatform.buildPackages.gcc``
##      installs respectively).
##   3. A bare ``aarch64-linux-gnu-gcc`` fallback so the adapter still
##      produces a sensible argv when the engine resolves the binary
##      through a provisioning mechanism the static probe can't see.
##
## When the probe finds nothing the adapter still returns a populated
## ``Toolchain`` whose ``cCompilerPath`` is the bare fallback string;
## the engine reports a clear ``aarch64-linux-gnu-gcc: command not
## found`` at action-execution time. This matches the spec's
## ``"falls back gracefully on platforms without the cross toolchain"``
## contract — the adapter never silently swallows the unavailability.

import std/[os, strutils, tables]

import ../interfaces/cross_target
import ../interfaces/toolchain
export cross_target
export toolchain

const
  CrossAarch64Triple* = "aarch64-linux-gnu"
    ## The canonical triple this adapter answers to. Matches the value
    ## a user supplies via ``--variant targetTriple=aarch64-linux-gnu``
    ## or ``targetTriple.override("aarch64-linux-gnu")``.

  CrossAarch64BinaryName* = "aarch64-linux-gnu-gcc"
    ## Canonical binary name on Debian-packaged cross toolchains.

  CrossAarch64NixBinaryName* = "aarch64-unknown-linux-gnu-gcc"
    ## Canonical binary name on nixpkgs
    ## ``pkgsCross.aarch64-multiplatform.buildPackages.gcc`` installs.

  CrossAarch64EnvVar* = "REPRO_AARCH64_GCC"
    ## Environment variable an operator can set to explicitly point
    ## the adapter at a cross-gcc binary the static probe wouldn't
    ## otherwise find. Test fixtures use this for hermetic / reviewer-
    ## reproducible cross-builds.

proc findOnPath(binary: string): string =
  ## Walk ``$PATH`` looking for ``binary``. Returns the absolute path on
  ## hit, ``""`` on miss. We avoid ``findExe`` from ``std/os`` to keep
  ## the probe identical across platforms — the wrapper-script handling
  ## in ``findExe`` would otherwise return an executable that points at
  ## the host toolchain.
  let pathEnv = getEnv("PATH")
  if pathEnv.len == 0:
    return ""
  for entry in pathEnv.split(PathSep):
    if entry.len == 0:
      continue
    let candidate = entry / binary
    if fileExists(candidate):
      return candidate
  ""

proc resolveCrossAarch64Compiler*(): string =
  ## Return the cross-gcc binary path the adapter should hand to the
  ## engine. Probe order: ``REPRO_AARCH64_GCC`` env var → standard
  ## ``aarch64-linux-gnu-gcc`` on ``$PATH`` → nixpkgs
  ## ``aarch64-unknown-linux-gnu-gcc`` on ``$PATH`` → bare fallback.
  let envOverride = getEnv(CrossAarch64EnvVar)
  if envOverride.len > 0:
    return envOverride
  let onPath = findOnPath(CrossAarch64BinaryName)
  if onPath.len > 0:
    return onPath
  let nixOnPath = findOnPath(CrossAarch64NixBinaryName)
  if nixOnPath.len > 0:
    return nixOnPath
  CrossAarch64BinaryName

proc crossAarch64Compile(source: string; output: string;
                         flags: seq[string]): BuildAction =
  ## ``aarch64-linux-gnu-gcc -c <source> -o <output> <flags>``. The
  ## ``--target=`` flag is implicit in the cross-gcc binary name; we
  ## still emit it under ``cFlags`` so toolchains that share a host
  ## binary (clang with ``--target=``) work without an extra wrapper.
  let cc = resolveCrossAarch64Compiler()
  var argv = @[cc, "-c", source, "-o", output]
  for f in flags:
    argv.add(f)
  BuildAction(
    actionId: "cross-aarch64-compile:" & source,
    argv: argv,
    inputs: @[source],
    outputs: @[output],
    env: initTable[string, string]())

proc crossAarch64Link(objects: seq[string]; output: string;
                      flags: seq[string]): BuildAction =
  let cc = resolveCrossAarch64Compiler()
  var argv = @[cc]
  for o in objects:
    argv.add(o)
  argv.add("-o")
  argv.add(output)
  for f in flags:
    argv.add(f)
  BuildAction(
    actionId: "cross-aarch64-link:" & output,
    argv: argv,
    inputs: objects,
    outputs: @[output],
    env: initTable[string, string]())

proc crossAarch64ArchiveExecutable(binary: string;
                                   archive: string): BuildAction =
  BuildAction(
    actionId: "cross-aarch64-archive:" & archive,
    argv: @["cp", binary, archive],
    inputs: @[binary],
    outputs: @[archive],
    env: initTable[string, string]())

proc crossAarch64LinuxGnuToolchain*(): Toolchain =
  ## Build a populated ``Toolchain`` whose ``compile`` / ``link``
  ## actions invoke the cross-aarch64 gcc. Selected by the active
  ## build context's ``resolveToolchain`` when the ``targetTriple``
  ## variant resolves to ``aarch64-linux-gnu``.
  let cc = resolveCrossAarch64Compiler()
  newToolchain(
    name = "cross-aarch64-linux-gnu-toolchain",
    cCompilerPath = cc,
    cxxCompilerPath = cc.replace("-gcc", "-g++"),
    linkerPath = cc,
    defaultFlags = ToolchainFlags(
      pic: false,
      debug3: false,
      optimization: "O2",
      languageStandard: "c11"),
    compile = crossAarch64Compile,
    link = crossAarch64Link,
    archiveExecutable = crossAarch64ArchiveExecutable)

proc crossAarch64LinuxGnuTarget*(): CrossTarget =
  ## Build a populated ``CrossTarget`` for the ``aarch64-linux-gnu``
  ## triple. Selected by the active build context's
  ## ``resolveCrossTarget`` when the ``targetTriple`` variant resolves
  ## to the matching triple.
  proc tripleAccess(): string = CrossAarch64Triple
  proc hostPrefixAccess(): string = CrossAarch64Triple & "-"
  proc spliceAccess(buildPkgs, hostPkgs, targetPkgs: seq[string]):
      SplicedPackageSet =
    var hostPrefixed = newSeq[string](hostPkgs.len)
    var targetPrefixed = newSeq[string](targetPkgs.len)
    for i, p in hostPkgs:
      hostPrefixed[i] = p & "-for-" & CrossAarch64Triple
    for i, p in targetPkgs:
      targetPrefixed[i] = p & "-for-" & CrossAarch64Triple
    SplicedPackageSet(
      buildPkgs: buildPkgs,
      hostPkgs: hostPrefixed,
      targetPkgs: targetPrefixed)
  newCrossTarget(
    name = "cross-aarch64-linux-gnu",
    triple = CrossAarch64Triple,
    sysroot = "",
    isNative = false,
    cFlags = @[],
    linkFlags = @[],
    binaryFormat = bfELF,
    pageSize = 4096,
    targetTriple = tripleAccess,
    hostPrefix = hostPrefixAccess,
    splice = spliceAccess)

proc isCrossAarch64Triple*(triple: string): bool =
  ## Predicate the active-context resolver consults when picking
  ## between the generic ``crossTargetFromTriple`` stub and this
  ## adapter. Accepts the canonical ``aarch64-linux-gnu`` triple AND
  ## the nixpkgs-flavoured ``aarch64-unknown-linux-gnu`` synonym since
  ## both name the same target ABI.
  triple == CrossAarch64Triple or
    triple == "aarch64-unknown-linux-gnu"
