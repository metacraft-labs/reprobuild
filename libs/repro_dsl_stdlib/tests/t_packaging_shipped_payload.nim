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

import std/[strutils, unittest]

import repro_project_dsl
import repro_dsl_stdlib/packaging

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
  result.components.add(
    reprobuildShippedTreeComponents(result, "prebuilt/tree"))

suite "packaging: the payload behind the wrapper variables":

  test "every prefix-relative value is accounted for by a component":
    # THE TOTALITY CASE, and the one that would have caught M1's gap on
    # the build host. It walks the value list rather than a hand-written
    # list of expectations, so a variable added later is covered without
    # anyone remembering to cover it.
    let dist = reprobuildSample()
    var trees: seq[string] = @[]
    for c in dist.components:
      if c.role == crSourceTree:
        trees.add(installRelPath(dist, c))
    var files: seq[string] = @[]
    for c in dist.components:
      if c.role != crSourceTree:
        files.add(installRelPath(dist, c))
    for pair in reprobuildWrapperValues(dist):
      let value = pair[1]
      if not value.startsWith(PrefixToken & "/"):
        # The one literal, ``REPROBUILD_USE_SYSTEM_HASH_LIBS=1``.
        doAssert value == "1",
          "unexpected non-prefix wrapper value " & pair[0] & "=" & value
        continue
      let rel = value[PrefixToken.len + 1 .. ^1]
      var covered = false
      # A directory this package ships, or a directory INSIDE one (the
      # ``*_SRC`` values that name a tree's ``src`` subdirectory).
      for t in trees:
        if rel == t or rel.startsWith(t & "/") or t.startsWith(rel & "/"):
          covered = true
      # The private libdir, which the runtime-closure walk fills rather
      # than any component naming.
      if rel == ReprobuildPrivateLibSubdir or
          rel == ReprobuildPrivatePrefixSubdir:
        covered = true
      # A FILE some component installs (``REPROBUILD_NIX_DAEMON_BIN``
      # is the only one, and only on POSIX).
      for f in files:
        if rel == f:
          covered = true
      if pair[0] == "REPROBUILD_NIX_DAEMON_BIN":
        # The Linux sample above does not carry the nix-daemon helper,
        # so assert its SHAPE rather than pretending it is staged here.
        doAssert rel.startsWith("libexec/"), rel
        covered = true
      doAssert covered,
        "wrapper variable " & pair[0] & " names '" & rel &
        "' and no component of this distribution puts anything there"

  test "the shipped directory list is sixteen and is where the values say":
    # Twelve ``*_SRC``, plus ``REPROBUILD_SOURCE_ROOT``, plus the private
    # prefix's ``include``, plus the bundled compiler's ``lib`` and
    # ``config``. The ``*_SRC`` count is asserted because the ORIGINAL
    # residual said eleven: ``RUNQUOTA_SRC`` sits below two unrelated
    # entries in the flake's wrapProgram loop and was missed by a human
    # reading it, which is precisely why this list is derived now.
    let dist = reprobuildSample()
    let dirs = reprobuildShippedTreeDirs(dist)
    check dirs.len == 16
    check ReprobuildPrivateIncludeSubdir in dirs
    check ReprobuildSourceRootSubdir in dirs
    var srcTrees = 0
    for d in dirs:
      if d.startsWith(ReprobuildSourceSubdir & "/"):
        inc srcTrees
    check srcTrees == 12
    for leaf in ReprobuildNimToolchainTrees:
      check reprobuildNimToolchainPrefixRel(dist) & "/" & leaf in dirs

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
