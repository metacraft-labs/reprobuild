## §1.3 / §6.1: the engine contains NO packaging-specific code.
##
## Distribution-And-Packaging.md §6.1 is unusually direct about it:
##
##   "The engine does not know what a ``.deb`` is, and must not. …
##   an unavailable format is just an unresolvable dependency, surfaced
##   through the normal mechanism. … never as a format-aware switch
##   inside the engine. The default assumption is that the engine needs
##   nothing packaging-specific at all."
##
## and the milestone's status block records it as a user decision:
## "Packaging lives entirely in reprobuild USER SPACE — NO
## packaging-specific code in the engine."
##
## ## Why this is a test and not a review note
##
## "The engine has no packaging code" is true today by construction —
## the packaging layer was written entirely in the stdlib and nothing
## was added to the engine to support it. It stays true only if
## something notices when it stops being true, and the way it would stop
## is not a large refactor: it is one plausible-looking convenience.
## Somebody adds a fast path for ``.deb`` outputs to the cache, or a
## ``--format=msi`` flag, or a mime-type table, each defensible on its
## own, and the property is gone with no single commit that looks like
## it removed it.
##
## The scan below is deliberately over the ENGINE and its CLI surface
## only. It is not a repo-wide ban on the word "deb": the stdlib
## packaging layer is full of them, and that is exactly where they
## belong.
##
## ## What the exclusions are, and why each is not a leak
##
## Two pre-existing kinds of hit are excluded by name rather than by
## loosening the pattern:
##
## * ``.deb``/``dpkg`` inside the APT CATALOG reader
##   (``packages/apt_jammy.nim``, and the engine-side archive readers it
##   relies on). Reading a ``.deb`` to REALISE a provisioned dependency
##   is dependency resolution, not packaging: it is how reprobuild
##   consumes a distro package as an input. §6.1 forbids the engine
##   knowing how to PRODUCE a format, and the two directions do not
##   touch.
## * ``msi`` inside the Windows tool-realise path (``lessmsi``, the
##   ``afInstallerMsi`` archive kind). Same argument in the other
##   ecosystem: extracting an MSI that a catalog entry points at is
##   provisioning.
##
## The exclusions are per-FILE and listed explicitly so that a new file
## in the engine matching the pattern fails the test rather than being
## quietly absorbed.

import std/[algorithm, os, strutils, unittest]

import ./packaging_test_support

const
  EngineRoots = [
    "libs/repro_build_engine/src",
    "libs/repro_cli_support/src",
    "libs/repro_local_store/src",
    "libs/repro_project_dsl/src"
  ]
    ## The engine and the surfaces that lower a recipe into it. The DSL
    ## MACRO layer (``repro_project_dsl``) is included deliberately: §6
    ## says the producer interface is "just a recipe signature", so a
    ## packaging concept appearing in the macro layer would be the same
    ## closed-set failure one level out from the engine, and is the more
    ## likely place for it to appear first.

  ProducingTokens = [
    "dpkg-deb",
    "rpmbuild",
    "makensis",
    "candle.exe",
    "light.exe",
    "appimagetool",
    "pkgbuild",
    "createrepo",
    "DEBIAN/control",
    "ServiceInstall",
    "wixobj"
  ]
    ## Tokens that can only appear in code that PRODUCES a package.
    ##
    ## Chosen over bare format names (``deb``, ``msi``) because those
    ## occur legitimately in the consuming direction, and a test that
    ## banned them would either fail immediately or need such broad
    ## exclusions that it stopped meaning anything. Every token here
    ## names a packaging TOOL invocation or an authoring artifact — a
    ## thing that exists only when you are building a package.

  AllowedFiles: seq[string] = @[]
    ## EMPTY, and that is the assertion. The engine has no legitimate
    ## reason to name a packaging tool. If a future milestone genuinely
    ## needs one (§6.1's "capability discovery" escape hatch), adding an
    ## entry here is a deliberate, reviewable act rather than a silent
    ## drift.

proc scanFiles(root: string): seq[string] =
  for path in walkDirRec(root):
    if path.endsWith(".nim"): result.add(path)

proc normalized(path: string): string =
  path.replace('\\', '/')

suite "packaging: the engine knows nothing about producing packages":

  test "no engine source names a packaging tool or authoring artifact":
    let repoRoot = repoRootFromTest()
    var offenders: seq[string] = @[]
    var scanned = 0
    var scannedBytes = 0
    for root in EngineRoots:
      let full = repoRoot & "/" & root
      doAssert dirExists(full),
        "engine root " & full & " does not exist — the scan would " &
        "pass vacuously. Fix the path rather than the assertion."
      for path in scanFiles(full):
        inc scanned
        let rel = normalized(path)
        var skip = false
        for allowed in AllowedFiles:
          if rel.endsWith(allowed): skip = true
        if skip: continue
        let text = readFile(path)
        scannedBytes += text.len
        for token in ProducingTokens:
          if token in text:
            offenders.add(normalized(path) & ": " & token)
    # A vacuous pass is the failure mode this case is most exposed to:
    # a moved root, a walk that returns nothing, and the assertion holds
    # while checking almost nothing.
    #
    # BYTES, not just file count, is the guard that matters here. These
    # four roots are 48 files and 5.5 MB — ``repro_cli_support.nim``
    # alone is over 60,000 lines — so a file-count floor high enough to
    # be meaningful would be wrong, and one low enough to be right would
    # still pass if the walk returned only the small modules.
    check scanned >= 40
    check scannedBytes > 4_000_000
    if offenders.len > 0:
      offenders.sort()
      echo "engine sources naming a packaging tool:"
      for entry in offenders: echo "  " & entry
    check offenders.len == 0

  test "the whole packaging layer lives under the stdlib":
    # The other half of the same claim: the code that DOES know these
    # tokens exists, and is where §6 says it should be. Without this
    # case the one above would also pass if the packaging layer had
    # simply been deleted.
    let repoRoot = repoRootFromTest()
    let layerRoot = repoRoot & "/libs/repro_dsl_stdlib/src/repro_dsl_stdlib"
    check fileExists(layerRoot & "/packaging.nim")
    check fileExists(layerRoot & "/packaging/types.nim")
    check fileExists(layerRoot & "/packaging/runtime_contract.nim")
    check fileExists(layerRoot & "/packaging/producer.nim")
    check fileExists(layerRoot & "/packaging/producers/deb.nim")
    check fileExists(layerRoot & "/packaging/producers/msi.nim")
    check fileExists(layerRoot & "/packaging/producers/tarball.nim")
    var found = 0
    for token in ProducingTokens:
      for path in scanFiles(layerRoot & "/packaging"):
        if token in readFile(path):
          inc found
          break
    check found >= 4

  test "the packaging tools are declared as reprobuild packages":
    # §6 rule 1. A producer that shelled out to an assumed-present host
    # tool would pass every other case in this file: the engine would
    # still know nothing, and the layer would still be in the stdlib.
    # What would be missing is the package DEFINITION, so that is what
    # this case looks for.
    let pkgRoot = repoRootFromTest() &
      "/libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages"
    for module in ["dpkg_deb.nim", "patchelf.nim", "coreutils_install.nim",
                   "wix3_tools.nim", "rpmbuild.nim", "tar.nim"]:
      let path = pkgRoot & "/" & module
      check fileExists(path)
      # ``package <name>:`` is the declaration that makes a tool
      # resolvable through the ordinary dependency mechanism. A catalog
      # row alone (``VersionedProvisioning``) is not one — that is
      # exactly why ``wix3_tools.nim`` exists next to ``wix3.nim``.
      check readFile(path).contains("package ")
