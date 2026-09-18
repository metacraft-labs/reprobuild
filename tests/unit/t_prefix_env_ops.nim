## ``REPRO_PREFIX_<PACKAGE>`` — where a realized package LANDED, by name.
##
## PATH answers "which programs can I run". It does not answer "where did
## package X land", and for a package whose payload is data rather than
## programs the second question is the only one with an answer at all.
##
## The motivating consumer is electron-builder, which does not read PATH: its
## NSIS and MSI targets resolve four archives through a cache directory laid
## out as ``<cache>/<name>/<name>-<version>/`` and DOWNLOAD whatever is
## missing. Two of those four packages — an NSIS plugin tree and a
## code-signing bundle — contain no program anywhere, so ``command -v`` cannot
## find them. Before this, the only way to locate such a prefix was to search
## PATH for a file the package was known to contain and then walk up a
## hard-coded number of directories, which encodes the package's internal
## layout at the CALL SITE, where an upstream repackaging breaks it silently.
##
## These cases pin the contract that replaces that: every realized package
## publishes its prefix under a derived variable name, once, and a package
## with nothing realized publishes nothing rather than an empty string that a
## consumer would go on to join a path onto.

import std/[os, tempfiles, unittest]

import repro_cli_support
import repro_provider_runtime/types
import repro_tool_profiles

proc profile(selector, prefix, installMethod: string;
             nixPaths: seq[string] = @[]): PathOnlyToolProfile =
  PathOnlyToolProfile(
    packageSelector: selector,
    selectedStorePath: prefix,
    installMethod: installMethod,
    realizedStorePaths: nixPaths)

proc identityOf(profiles: varargs[PathOnlyToolProfile]):
    PathOnlyBuildIdentity =
  PathOnlyBuildIdentity(projectName: "fixture", profiles: @profiles)

proc valueFor(ops: seq[DevEnvShellOp]; name: string): string =
  for op in ops:
    if op.name == name:
      return op.value
  ""

suite "realized package prefixes reach the activated environment":

  test "the variable name is derived from the package selector":
    # Uppercased, and everything outside [A-Za-z0-9] becomes `_` so that a
    # selector carrying a version or a scope still yields a name both a POSIX
    # shell and cmd.exe accept.
    check prefixEnvVarName("electron-builder-nsis") ==
      "REPRO_PREFIX_ELECTRON_BUILDER_NSIS"
    check prefixEnvVarName("winfsp@2.1.25156") == "REPRO_PREFIX_WINFSP_2_1_25156"
    check prefixEnvVarName("jq") == "REPRO_PREFIX_JQ"

  test "each realized package contributes its prefix once":
    let root = createTempDir("repro-prefix-", "")
    defer:
      try: removeDir(root) except CatchableError: discard
    let nsis = root / "nsis"
    let resources = root / "resources"
    createDir(nsis)
    createDir(resources)
    # Two executables from ONE package is the common case (a toolchain
    # prefix contributes several programs); the package's prefix must appear
    # once, not once per program.
    let ops = prefixEnvOpsForDevelop(identityOf(
      profile("electron-builder-nsis", nsis, "tarball"),
      profile("electron-builder-nsis", nsis, "tarball"),
      profile("electron-builder-nsis-resources", resources, "tarball")))
    check ops.len == 2
    check valueFor(ops, "REPRO_PREFIX_ELECTRON_BUILDER_NSIS") == nsis
    check valueFor(ops, "REPRO_PREFIX_ELECTRON_BUILDER_NSIS_RESOURCES") ==
      resources
    for op in ops:
      check op.kind == deskSetEnv

  test "a package with no realized prefix contributes nothing":
    # An empty value is worse than a missing one: a consumer that joins a
    # path onto it gets a path relative to its own working directory, which
    # exists often enough to be found and is never what was meant. The same
    # applies to a prefix that was recorded but is no longer on disk.
    let root = createTempDir("repro-prefix-", "")
    defer:
      try: removeDir(root) except CatchableError: discard
    let ops = prefixEnvOpsForDevelop(identityOf(
      profile("never-realized", "", "tarball"),
      profile("vanished", root / "not-there", "tarball"),
      profile("", root, "tarball")))
    check ops.len == 0

  test "nix-mode reports the store path the resolver selected":
    let root = createTempDir("repro-prefix-", "")
    defer:
      try: removeDir(root) except CatchableError: discard
    let out0 = root / "out0"
    let out1 = root / "out1"
    createDir(out0)
    createDir(out1)
    # `selectedStorePath` is a tarball-mode concept; under nix the realized
    # outputs are the answer and the first is the one the resolver chose.
    let ops = prefixEnvOpsForDevelop(identityOf(
      profile("ripgrep", "", "nix", @[out0, out1])))
    check ops.len == 1
    check valueFor(ops, "REPRO_PREFIX_RIPGREP") == out0
