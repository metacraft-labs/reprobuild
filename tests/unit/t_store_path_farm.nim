## Short PATH entries for realized store prefixes.
##
## A dev environment that provisions thirty-five packages contributes
## thirty-five PATH entries of the form
## ``<store>/prefixes/<package>/<32 hex>/bin`` — about 105 characters each.
## cmd.exe truncates the environment block it hands a child at 8191
## characters, cutting from the END of PATH and saying nothing, so on a host
## whose own PATH is already several kilobytes those entries are what pushes
## the total over and every cmd.exe-mediated launcher then fails to find
## tools that are demonstrably there.
##
## ``shortenStoreBinDir`` routes each realization through a directory
## junction onto its PREFIX ROOT, so the whole tree stays intact behind a
## short name: clang still finds its resource headers relative to its own
## executable, because relative to the link they are in the same place.
##
## What is asserted here is the part that must not go wrong quietly:
##
##   * the shortened entry is genuinely shorter, and the contents of the
##     prefix are reachable through it;
##   * a flat prefix — an upstream that ships one executable at the root,
##     which is also the LONGEST entry shape — is shortened too;
##   * the slot is stable, so two activations of the same prefix produce the
##     same PATH;
##   * a path outside the store is returned untouched;
##   * the whole thing is a no-op off Windows, where there is no 8191-byte
##     environment block to stay under.

import std/[os, strutils, tempfiles, unittest]

import repro_tool_profiles

proc makePrefix(storeRoot, package, version: string;
                relativeBin: string): string =
  ## Build ``<storeRoot>/prefixes/<package>/<version>/<relativeBin>`` with one
  ## file in it, and return the directory a PATH entry would name.
  let prefixRoot = storeRoot / "prefixes" / package / version
  let binDir = if relativeBin.len > 0: prefixRoot / relativeBin else: prefixRoot
  createDir(binDir)
  writeFile(binDir / "marker.txt", package)
  # A sibling of the bin directory, to prove the junction exposes the whole
  # prefix rather than the one directory PATH happens to name.
  createDir(prefixRoot / "lib")
  writeFile(prefixRoot / "lib" / "resource.txt", "resource-" & package)
  binDir

suite "store path farm":
  test "a realized bin directory is shortened and stays reachable":
    let storeRoot = createTempDir("repro-farm-", "")
    defer:
      try: removeDir(storeRoot) except CatchableError: discard
    let binDir = makePrefix(storeRoot, "node",
      "edaca9bd58ec8e92-5dac743b32498b41", "bin")

    let shortened = shortenStoreBinDir(binDir, storeRoot)
    when defined(windows):
      check shortened.len < binDir.len
      check shortened != binDir
      check readFile(shortened / "marker.txt") == "node"
      # The sibling directory is the point: a merged bin directory would not
      # have it, and every toolchain that resolves resources relative to its
      # own executable would break on one.
      check readFile(shortened / ".." / "lib" / "resource.txt") ==
        "resource-node"
    else:
      check shortened == binDir

  test "a flat prefix with no bin subdirectory is shortened too":
    # cargo-nextest, just, python3 and a dozen others ship one executable at
    # the prefix root. Those entries end at the 33-character version-hash
    # segment, which makes them the LONGEST of the set — an implementation
    # that only handled `<prefix>/bin` would leave most of the length alone.
    let storeRoot = createTempDir("repro-farm-flat-", "")
    defer:
      try: removeDir(storeRoot) except CatchableError: discard
    let binDir = makePrefix(storeRoot, "cargo-nextest",
      "f9144814dc3d348f-ba5127fa797e695d", "")

    let shortened = shortenStoreBinDir(binDir, storeRoot)
    when defined(windows):
      check shortened.len < binDir.len
      check readFile(shortened / "marker.txt") == "cargo-nextest"
    else:
      check shortened == binDir

  test "the slot is stable across calls":
    # Two activations of the same prefix must produce the same PATH, or an
    # activated environment cannot be compared against itself.
    let storeRoot = createTempDir("repro-farm-stable-", "")
    defer:
      try: removeDir(storeRoot) except CatchableError: discard
    let binDir = makePrefix(storeRoot, "jq",
      "8c9f8c9f8c9f8c9f-1d1d1d1d1d1d1d1d", "bin")
    check shortenStoreBinDir(binDir, storeRoot) ==
      shortenStoreBinDir(binDir, storeRoot)

  test "a path outside the store is returned untouched":
    let storeRoot = createTempDir("repro-farm-outside-", "")
    defer:
      try: removeDir(storeRoot) except CatchableError: discard
    let elsewhere = createTempDir("repro-farm-elsewhere-", "")
    defer:
      try: removeDir(elsewhere) except CatchableError: discard
    check shortenStoreBinDir(elsewhere, storeRoot) == elsewhere
    # Nor is the store root itself, or anything shallower than a realization,
    # something to link: there is no prefix there to stand behind the name.
    check shortenStoreBinDir(storeRoot / "prefixes", storeRoot) ==
      storeRoot / "prefixes"
    check shortenStoreBinDir("", storeRoot) == ""
