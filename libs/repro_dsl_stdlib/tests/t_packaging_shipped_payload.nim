## The payload behind the wrapper variables — `crSourceTree`, the
## private prefix, and `build/lib/*`.
##
## M1 packaged a reprobuild whose wrapper set twenty variables, all
## correct, all prefix-relative, none of them a store path — and whose
## payload contained none of what thirteen of them named. `dpkg -L
## reprobuild` had no `share/repro` at all, no `lib/repro/include`, and
## neither of the two shared libraries the flake installs out of
## `build/lib`. An installed package answered `repro --version`, ran its
## daemon, served its cache, and could not build anything, because the
## FIRST edge of every `repro build` is the interface-extraction edge
## that compiles the recipe against exactly those sources.
##
## The defect was not a forgotten component. It was that the value list
## and the payload list were two lists, and nothing checked them against
## each other — the same class of defect `ReprobuildWrapperVariables`
## and its flake drift-guard exist for, one level further down. So the
## fix is a DERIVATION (`reprobuildShippedTreeDirs`) and these cases are
## what keeps the derivation total: every prefix-relative value is a
## directory the package ships, a directory the closure walk fills, or a
## file a component installs. Nothing else is allowed to be true.

import std/[os, strutils, unittest]

import repro_project_dsl
import repro_dsl_stdlib/packaging
import ./packaging_test_support

proc reprobuildSample(targetOs = toLinux): Distribution =
  let sfx = (if targetOs == toWindows: ".exe" else: "")
  result = newReprobuildDistribution("0.1.3", targetOs,
    prefix = (if targetOs == toWindows: "" else: "/usr"))
  result.components = @[
    executableComponent("prebuilt/bin/repro" & sfx),
    component(crHelperExecutable, "prebuilt/bin/repro-standard-provider" & sfx),
    component(crConfigFile, "build/gen/caches.conf",
      installName = "caches.conf", subdir = "repro")
  ]
  result.components.add(runtimeLibraryComponent(
    "prebuilt/lib/librepro_monitor_shim.so"))
  result.components.add(runtimeLibraryComponent(
    "prebuilt/lib/librepro_project_dsl_runtime.so"))
  for alias in ReprobuildLinkerAliasLibraries:
    result.components.add(runtimeLibraryComponent("prebuilt/lib/" & alias))
  result.components.add(component(crHelperExecutable,
    "prebuilt/tree/" & reprobuildNimToolchainPrefixRel(result) & "/bin/nim",
    subdir = ReprobuildNimToolchainSubdir & "/bin"))
  # ``REPROBUILD_NIX_DAEMON_BIN``'s target. The sample used to omit it
  # and the old totality case exempted it by NAME -- which is exactly
  # the shape of hole that made that case unable to fail. The staged
  # guard has no such exemption: a file-valued variable is checked
  # against the staged file list like every other value, so the sample
  # has to carry the file the real recipe carries.
  if targetOs != toWindows:
    result.components.add(component(crHelperScript,
      "prebuilt/bin/reprobuild-nix-daemon"))
  result.components.add(
    reprobuildShippedTreeComponents(result, "prebuilt/tree"))

proc payloadRoot(name: string): string =
  ## A real directory tree on disk, because that is what makes the
  ## totality assertion below mean something: ``stageInstallTree``
  ## ENUMERATES a ``crSourceTree`` component's files from the
  ## filesystem, so the payload side of the comparison is not derived
  ## from the value list the wrapper side comes from.
  result = "build/test-tmp/" & name
  removeDir(result)
  createDir(result)

proc fillPayload(dist: Distribution; root: string;
                 skip: openArray[string] = []) =
  ## Put one file into every directory this distribution's wrapper says
  ## it ships, EXCEPT the ones named in ``skip``. Skipping is how a case
  ## proves the guard can fail.
  for rel in reprobuildShippedTreeDirs(dist):
    if rel in skip: continue
    createDir(root & "/" & rel)
    writeFile(root & "/" & rel & "/payload.nim", "discard" & "\n")

proc stagedRootRelPaths(tree: StagedTree): seq[string] =
  for f in tree.files:
    result.add(f.rootRelPath)

proc wrapperTextOf(dist: Distribution): string =
  posixWrapperText(dist, realFileName(dist, "repro"), "bin")

proc withTreesFrom(dist: var Distribution; root: string;
                   omit = ""): seq[DistComponent] =
  ## Re-point the sample's source-tree components at ``root``, dropping
  ## the one whose install path ends in ``omit``. Returns the full set
  ## for the caller to inspect.
  result = reprobuildShippedTreeComponents(dist, root)
  var kept: seq[DistComponent] = @[]
  for c in dist.components:
    if c.role != crSourceTree: kept.add(c)
  for c in result:
    if omit.len == 0 or not installRelPath(dist, c).endsWith(omit):
      kept.add(c)
  dist.components = kept

suite "packaging: the payload behind the wrapper variables":

  test "the wrapper can be read back, and the reader is not vacuous":
    # THE PRECONDITION FOR EVERY CASE BELOW. M1's docker gate asserted
    # "ALL WRAPPER PATHS EXIST" over a loop whose parser matched ZERO
    # lines, so the interesting property here is not that the parser
    # works -- it is that a parser which stopped working could not
    # quietly report success.
    let dist = reprobuildSample()
    let text = wrapperTextOf(dist)
    let readBack = wrapperExportedValues(dist, text)
    check readBack.len == dist.runtime.envDefaults.len
    check readBack.len > 0
    check readBack == dist.runtime.envDefaults
    # ...and a wrapper whose lines it cannot read RAISES rather than
    # returning the ones it could.
    var truncated = ""
    var dropped = false
    for line in text.splitLines():
      if not dropped and line.startsWith("  REPROBUILD_SOURCE_ROOT="):
        dropped = true
        continue
      truncated.add(line & "\n")
    check dropped
    var raised = false
    try:
      discard wrapperExportedValues(dist, truncated)
    except ValueError as err:
      raised = true
      check err.msg.contains("refusing a check")
    check raised

  test "every prefix-relative value is backed by a STAGED file":
    # THE TOTALITY CASE, rewritten. The version this replaces compared
    # ``reprobuildWrapperValues`` against a component list DERIVED from
    # ``reprobuildWrapperValues``, so the two sides agreed by
    # construction: injecting a twenty-second ``*_SRC`` variable PASSED
    # it, and only a hand-maintained ``dirs.len == 16`` noticed, at 17.
    #
    # Both sides are now independent. The wrapper side is parsed out of
    # the text ``posixWrapperText`` emits; the payload side is
    # ``StagedTree.files``, which staging built by walking the build
    # tree ON DISK. A value with no payload has nothing to match.
    resetBuildActionRegistry()
    let root = payloadRoot("shipped-payload-full")
    var dist = reprobuildSample()
    dist.stagingRoot = "build/test-tmp/shipped-payload-full-stage"
    discard withTreesFrom(dist, root)
    fillPayload(dist, root)
    let tree = stageInstallTree(dist, "deb")
    let gaps = envDefaultPayloadGaps(dist, wrapperTextOf(dist),
      stagedRootRelPaths(tree), rootedAtPrefix = false)
    check gaps.len == 0
    # Non-vacuity: the staged tree really does carry the source trees,
    # and the check really did resolve prefix-relative values.
    check tree.files.len > reprobuildShippedTreeDirs(dist).len
    var prefixRelValues = 0
    var literals: seq[string] = @[]
    for pair in wrapperExportedValues(dist, wrapperTextOf(dist)):
      if pair[1].startsWith(PrefixToken & "/"): inc prefixRelValues
      else: literals.add(pair[0])
    # DERIVED, not counted by hand. The number this used to carry was a
    # literal, and a literal is exactly what went stale when
    # ``CT_INTERPOSE_SRC`` -- a prefix-relative value nothing read --
    # left the list (M1's N16). The property is that EVERY variable but
    # the one documented literal names a path under the prefix, and
    # naming that one exception is what keeps the check from being a
    # tautology over its own source.
    check literals == @["REPROBUILD_USE_SYSTEM_HASH_LIBS"]
    check prefixRelValues == ReprobuildWrapperVariables.len - literals.len
    check prefixRelValues > 15

  test "a wrapper path with no staged tree FAILS the guard":
    # THE PROOF THAT THE CASE ABOVE CAN FAIL, which is the whole reason
    # it was rewritten. One tree is left unstaged and the SAME
    # comparison must name the variable that pointed at it.
    resetBuildActionRegistry()
    let root = payloadRoot("shipped-payload-gap")
    var dist = reprobuildSample()
    dist.stagingRoot = "build/test-tmp/shipped-payload-gap-stage"
    # The post-condition is switched OFF here so the gap can be
    # INSPECTED rather than merely thrown; the case after this one is
    # the one that asserts the build stops.
    dist.runtime.requireEnvDefaultPayload = false
    let orphan = "share/repro/src/io-mon/src"
    check orphan in reprobuildShippedTreeDirs(dist)
    discard withTreesFrom(dist, root, omit = orphan)
    fillPayload(dist, root, skip = [orphan])
    let tree = stageInstallTree(dist, "deb")
    let gaps = envDefaultPayloadGaps(dist, wrapperTextOf(dist),
      stagedRootRelPaths(tree), rootedAtPrefix = false)
    check gaps.len == 1
    check gaps[0].contains("IO_MON_SRC")
    check gaps[0].contains(orphan)

  test "requireEnvDefaultPayload makes that gap a BUILD failure":
    # The same gap through the path a recipe actually takes. The guard
    # is a checked post-condition of staging, in the sense
    # ``dlopenLeafNames`` already was: the build stops, naming the
    # variable, instead of producing a package that installs.
    resetBuildActionRegistry()
    let root = payloadRoot("shipped-payload-refuse")
    var dist = reprobuildSample()
    check dist.runtime.requireEnvDefaultPayload
    dist.stagingRoot = "build/test-tmp/shipped-payload-refuse-stage"
    let orphan = "share/repro/source"
    discard withTreesFrom(dist, root, omit = orphan)
    fillPayload(dist, root, skip = [orphan])
    var raised = false
    try:
      discard stageInstallTree(dist, "deb")
    except ValueError as err:
      raised = true
      check err.msg.contains("REPROBUILD_SOURCE_ROOT")
      check err.msg.contains("nothing in this package installs")
    check raised

  test "the shipped directory list is exactly what the wrapper asks for":
    # REPLACES ``check dirs.len == 16``. A hand-maintained count is the
    # thing that goes stale -- and it was the ONLY part of the old suite
    # that noticed an injected variable, which is an accident rather
    # than a guard. The identity below is derived on both sides and
    # cannot go stale: every prefix-relative value is either one of
    # these directories, inside one, or one of the three shapes that is
    # deliberately not a shipped tree.
    let dist = reprobuildSample()
    let dirs = reprobuildShippedTreeDirs(dist)
    var treeBacked = 0
    var notTrees: seq[string] = @[]
    for pair in wrapperExportedValues(dist, wrapperTextOf(dist)):
      if not pair[1].startsWith(PrefixToken & "/"):
        check pair[1] == "1"
        continue
      let rel = pair[1][PrefixToken.len + 1 .. ^1]
      var inside = false
      for d in dirs:
        if rel == d or rel.startsWith(d & "/") or d.startsWith(rel & "/"):
          inside = true
      if inside: inc treeBacked else: notTrees.add(pair[0])
    # The three shapes that are deliberately NOT source trees, NAMED
    # rather than counted, so a fourth one has to be argued for.
    check notTrees == @["REPROBUILD_RUNTIME_LIBRARY_PATH",
                        "REPROBUILD_NIX_DAEMON_BIN", "REPRO_NIM_COMPILER"]
    # Every remaining directory is either backed by a variable or is one
    # of the bundled compiler's two, which no variable names and which
    # dangle in exactly the way a missing tree does (``nim c`` on a
    # toolchain with no ``lib/`` fails on the first ``import``).
    var literals = 0
    for pair in wrapperExportedValues(dist, wrapperTextOf(dist)):
      if not pair[1].startsWith(PrefixToken & "/"): inc literals
    check treeBacked + notTrees.len + literals ==
      dist.runtime.envDefaults.len
    # THE OTHER DIRECTION, which is what a count was standing in for:
    # no directory is shipped that nothing asks for. Every entry is
    # either named by an exported value or is one of the bundled
    # compiler's two -- which no variable names and which dangle in
    # exactly the way a missing tree does (``nim c`` on a toolchain
    # with no ``lib/`` fails on the first ``import``).
    var nimTrees: seq[string] = @[]
    for leaf in ReprobuildNimToolchainTrees:
      nimTrees.add(reprobuildNimToolchainPrefixRel(dist) & "/" & leaf)
      check nimTrees[^1] in dirs
    var seenDirs: seq[string] = @[]
    for d in dirs:
      check d notin seenDirs
      seenDirs.add(d)
      if d in nimTrees: continue
      var asked = false
      for pair in wrapperExportedValues(dist, wrapperTextOf(dist)):
        if not pair[1].startsWith(PrefixToken & "/"): continue
        let rel = pair[1][PrefixToken.len + 1 .. ^1]
        if rel == d or rel.startsWith(d & "/") or d.startsWith(rel & "/"):
          asked = true
      doAssert asked,
        "the package ships '" & d & "' and no wrapper variable names it"
    check ReprobuildPrivateIncludeSubdir in dirs
    check ReprobuildSourceRootSubdir in dirs

  test "the bundled compiler's PCRE dlopen name is pinned, per target":
    # ``reprobuildNimDlopenLeafNames`` was pinned by NO test. It is the
    # value that closed M1's fifth wall: the vendored Nim binds PCRE
    # with ``{.dynlib: "libpcre.so(.3|.1|)".}`` and resolves it at
    # MODULE-INIT time, so a shipped compiler whose private libdir has
    # no PCRE does not fail on some regex-using compile -- it fails on
    # ``nim --version``, before ``main``, with ``could not load``.
    #
    # A dlopen leaves no DT_NEEDED, so the closure walk cannot discover
    # this: declaring the leaf name IS the fix, and an unpinned value
    # that silently emptied would put the failure back on the target.
    check reprobuildNimDlopenLeafNames(toLinux) == @["libpcre.so.1"]
    check reprobuildNimDlopenLeafNames(toDarwin) == @["libpcre.1.dylib"]
    # WINDOWS IS EMPTY AND THAT IS NOT AN OMISSION. No Windows Nim
    # toolchain is staged yet, and ``dlopenLeafNames`` is a CHECKED
    # post-condition -- naming a ``pcre*.dll`` for a compiler this
    # package does not ship would fail the walk rather than document a
    # gap.
    check reprobuildNimDlopenLeafNames(toWindows).len == 0
    # Loader names, not package names: same shape rule the reprobuild
    # list is held to.
    for targetOs in [toLinux, toDarwin]:
      for leaf in reprobuildNimDlopenLeafNames(targetOs):
        check leaf.contains(".")
        check not leaf.contains("/")
    # SEPARATE from reprobuild's own dlopen list, and the separation is
    # the point rather than tidiness: that list is drift-guarded against
    # the two modules that state reprobuild's dlopen strings, and PCRE
    # is a property of a third-party toolchain this package happens to
    # vendor. A package that stopped bundling the compiler would stop
    # needing it, so the two must move independently -- and appending
    # one to the other must not produce a duplicate.
    for targetOs in [toLinux, toDarwin, toWindows]:
      let own = reprobuildDlopenLeafNames(targetOs)
      let nim = reprobuildNimDlopenLeafNames(targetOs)
      for leaf in nim:
        check leaf notin own
      check (own & nim).len == own.len + nim.len

  test "the pinned PCRE name is one the bundled compiler asks for":
    # THE ANCHOR, when there is a payload to anchor against. The value
    # above is a literal, and a literal is exactly what goes stale, so
    # it is read back out of the staged compiler: Nim's dynlib pattern
    # ``libpcre.so(.3|.1|)`` expands to three candidates and the
    # declared name must be one of them.
    #
    # The payload is gitignored and staged per host, so this case is
    # CONDITIONAL -- and it says which branch it took rather than
    # passing silently, because a case that quietly checks nothing is
    # the defect this whole suite was rewritten over.
    let nimBin = repoRootFromTest() &
      "/tests/fixtures/packaging/reprobuild-dist/prebuilt/tree/" &
      "libexec/reprobuild/nim/bin/nim"
    if not fileExists(nimBin):
      echo "    (no staged Nim toolchain at ", nimBin,
        "; the pattern anchor did not run)"
      check not fileExists(nimBin)
    else:
      let image = readFile(nimBin)
      const Pattern = "libpcre.so(.3|.1|)"
      check image.contains(Pattern)
      var candidates: seq[string] = @[]
      for alt in ".3|.1|".split('|'):
        candidates.add("libpcre.so" & alt)
      check candidates == @["libpcre.so.3", "libpcre.so.1", "libpcre.so"]
      for leaf in reprobuildNimDlopenLeafNames(toLinux):
        doAssert leaf in candidates,
          "the layer declares the bundled compiler dlopens '" & leaf &
          "', but its dynlib pattern expands to " & $candidates
        # ...and the one it names is the SONAME nixpkgs' pcre provides,
        # which is why the second candidate rather than the first is
        # the one that resolves.
        check leaf == "libpcre.so.1"

  test "the bundled compiler is a PATCHED helper, not part of a tree":
    # The distinction is 9 MB of file that either runs on the target or
    # answers ``not found``: the nix-built ``nim`` names a ``/nix/store``
    # ELF interpreter, and only ``crHelperExecutable`` goes through
    # patchelf. A toolchain shipped wholesale as a ``crSourceTree``
    # would install cleanly and be unable to start.
    let dist = reprobuildSample()
    var nimRole = crSourceTree
    var nimPath = ""
    for c in dist.components:
      if defaultInstallName(c) == "nim":
        nimRole = c.role
        nimPath = installRelPath(dist, c)
    check nimRole == crHelperExecutable
    check nimPath == reprobuildNimToolchainPrefixRel(dist) & "/bin/nim"
    # ...and it sits in a ``bin`` directory ON PURPOSE: the compiler
    # derives its own prefix from argv[0] and looks for ``../lib``, so a
    # binary dropped straight into ``libexec/reprobuild`` would go
    # hunting for the package's private libdir instead of a Nim stdlib.
    check nimPath.endsWith("/bin/nim")
    for leaf in ReprobuildNimToolchainTrees:
      check reprobuildNimToolchainPrefixRel(dist) & "/" & leaf ==
        nimPath[0 ..< nimPath.len - "/bin/nim".len] & "/" & leaf

  test "the Nim requirement is vendored and the C one is declared":
    # Opposite treatment, one measured reason: every target
    # distribution packages a C compiler and NEITHER of the two M1's
    # gate uses packages an adequate Nim (trixie and fedora:latest have
    # none at all; bookworm's is 1.6.10). A ``Depends:`` on a package
    # that exists in no archive is not a dependency, it is a package
    # that will not install.
    var dist = reprobuildSample()
    dist.metadata.debDepends = @["gcc", "libc6-dev"]
    for dep in dist.metadata.debDepends:
      check not dep.contains("nim")
    var sawNim = false
    for c in dist.components:
      if c.buildPath.contains("/nim"): sawNim = true
    check sawNim

  test "a source tree's location is the value's, verbatim":
    # ``STACKABLE_HOOKS_SRC`` is the shape that catches a translation
    # bug: its value ends in ``/src``, so the shipped directory is
    # ``nim-stackable-hooks/src`` and NOT its parent. Shipping the
    # parent would leave the variable pointing one level too deep at a
    # directory that exists.
    let dist = reprobuildSample()
    var value = ""
    for pair in reprobuildWrapperValues(dist):
      if pair[0] == "STACKABLE_HOOKS_SRC": value = pair[1]
    check value.endsWith("/nim-stackable-hooks/src")
    var found = ""
    for c in dist.components:
      if c.role == crSourceTree and
          installRelPath(dist, c).endsWith("nim-stackable-hooks/src"):
        found = installRelPath(dist, c)
    check found.len > 0
    check PrefixToken & "/" & found == value

  test "the four library prefixes name a real prefix, not the bare one":
    # The measured failure: pointed at ``/usr`` they resolve to a
    # directory with no ``include/blake3.h`` and no ``lib/libblake3.so``
    # on any stock image, because the closure lives in the PRIVATE
    # libdir under soname-only names. ``externalHashFlags`` accepts a
    # candidate only when BOTH are under it.
    let dist = reprobuildSample()
    for pair in reprobuildWrapperValues(dist):
      if not pair[0].endsWith("_PREFIX"): continue
      check pair[1] == PrefixToken & "/" & ReprobuildPrivatePrefixSubdir
      check pair[1] != PrefixToken
    # ...and the two halves it looks for are both under it.
    check ReprobuildPrivateLibSubdir ==
      ReprobuildPrivatePrefixSubdir & "/lib"
    check ReprobuildPrivateIncludeSubdir ==
      ReprobuildPrivatePrefixSubdir & "/include"

  test "the linker aliases land beside the versioned originals":
    # ``-lblake3`` looks for ``libblake3.so`` and ``libblake3.a`` and
    # nothing else, so a libdir holding only the vendored
    # ``libblake3.so.0`` answers ``ld: cannot find -lblake3``. The alias
    # is an ordinary copy rather than a symlink -- the layer has no
    # symlink role -- and that is safe ONLY because it lands in the same
    # directory as the original, where its ``$ORIGIN`` RPATH resolves
    # against the same closure.
    let dist = reprobuildSample()
    var aliasDirs: seq[string] = @[]
    for c in dist.components:
      if c.role != crRuntimeLibrary: continue
      let rel = installRelPath(dist, c)
      if defaultInstallName(c) in ReprobuildLinkerAliasLibraries:
        aliasDirs.add(rel[0 ..< rel.rfind('/')])
    check aliasDirs.len == ReprobuildLinkerAliasLibraries.len
    for d in aliasDirs:
      check d == ReprobuildPrivateLibSubdir
    # libclingo is deliberately NOT aliased: it is dlopened rather than
    # linked, so no ``-lclingo`` is emitted, and the walk already
    # vendors it under the unversioned name the dlopen uses.
    for alias in ReprobuildLinkerAliasLibraries:
      check not alias.contains("clingo")
    check "libclingo.so" in reprobuildDlopenLeafNames(toLinux)

  test "build/lib's two libraries are components of the CLI package":
    # The first error any ``repro build`` from an installed package
    # produced, before N1's wall: ``cannot find
    # librepro_monitor_shim.so``. The flake installs both out of
    # ``build/lib``; no Distribution had a component for either.
    let dist = reprobuildSample()
    var shipped: seq[string] = @[]
    for c in dist.components:
      if c.role == crRuntimeLibrary:
        shipped.add(defaultInstallName(c))
    check "librepro_monitor_shim.so" in shipped
    check "librepro_project_dsl_runtime.so" in shipped

  test "a source tree is not wrapped, not RPATH-patched and not a seed":
    # ``crSourceTree`` must skip every arm of the §5 contract. A tree
    # that reached ``patchelf`` would fail the build the way
    # ``crHelperScript`` did before it existed (``not an ELF
    # executable``); one that reached the wrapper arm would put a
    # wrapper script where a directory belongs.
    check roleDefaultSubdir(reprobuildSample(), crSourceTree) == ""
    check not escapesPrefix(reprobuildSample(), crSourceTree)
    let dist = reprobuildSample()
    for c in dist.components:
      if c.role != crSourceTree: continue
      # Not an executable, so ``executables()`` never sees it and no
      # service can name it.
      check c notin dist.executables()

  test "the derivation follows a changed value without being edited":
    # THE ANTI-DRIFT PROPERTY, stated as an experiment rather than as a
    # comment: move a variable's value and the component list moves with
    # it. This is the whole reason the list is derived; a hand-written
    # list would pass every case above and still be the thing that broke.
    var dist = reprobuildSample()
    dist.runtime.envDefaults = @[
      ("REPROBUILD_SOURCE_ROOT", PrefixToken & "/share/elsewhere/source")]
    # ``reprobuildShippedTreeDirs`` reads the CANONICAL values rather
    # than the (mutated) distribution, so it is the recipe-visible
    # contract that is pinned here: the canonical list still holds the
    # canonical root.
    check ReprobuildSourceRootSubdir in reprobuildShippedTreeDirs(dist)
    check reprobuildShippedTreeComponents(dist, "prebuilt/tree").len ==
      reprobuildShippedTreeDirs(dist).len
    for c in reprobuildShippedTreeComponents(dist, "prebuilt/tree"):
      check c.buildPath.startsWith("prebuilt/tree/")
      check c.buildPath.endsWith(installRelPath(dist, c))

  test "a source tree that would stage EMPTY is refused, not staged":
    # ``preserveTree`` over a directory that does not exist is SILENT:
    # no entries, no outputs, an empty directory in the tree. The
    # package would then install, its wrapper would name the directory,
    # the directory would be there, and the compile the tree exists to
    # serve would fail on the target with a missing import -- which is
    # exactly the failure this component role was added to close. So
    # forgetting to stage a payload has to be a BUILD error.
    var dist = reprobuildSample()
    dist.components = @[
      executableComponent("prebuilt/bin/repro"),
      sourceTreeComponent("prebuilt/tree/does/not/exist",
        subdir = ReprobuildSourceSubdir, installName = "ghost")]
    dist.services = @[]
    var raised = false
    try:
      discard stageInstallTree(dist, "deb")
    except ValueError as err:
      raised = true
      check err.msg.contains("ghost")
      check err.msg.contains("no files")
    check raised

  test "the distribution still validates with the whole payload attached":
    reprobuildSample().validate()
    # Two components installing to one path is the mistake the derived
    # list could make if a value were duplicated; ``validate`` refuses
    # it by path rather than by role.
    var dup = reprobuildSample()
    dup.components.add(sourceTreeComponent("prebuilt/tree/other",
      subdir = ReprobuildSourceSubdir, installName = "nimcrypto"))
    var raised = false
    try:
      dup.validate()
    except ValueError as err:
      raised = true
      check err.msg.contains("nimcrypto")
    check raised
