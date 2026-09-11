## §12's first open question, kept answered.
##
## Distribution-And-Packaging.md §12 opens with:
##
##   "Exact ``REPROBUILD_*``/``*_PREFIX`` wrapper-var list to encode in
##   the packaging layer (derive mechanically from the flake wrapper
##   contract)."
##
## and §5 says why it has to be mechanical rather than transcribed:
##
##   "The authoritative list is derived from the flake's
##   ``packagedRuntimeCompileCheck`` wrapper contract so it stays in
##   sync."
##
## ``runtime_contract.ReprobuildWrapperVariables`` is that list. This
## suite is what makes "stays in sync" true rather than aspirational.
##
## ## Why a test and not a code generator
##
## Generating the list from ``flake.nix`` at build time would couple
## every reprobuild build to parsing Nix, for a list that changes a few
## times a year. A test that reads the same file and compares is the
## same guarantee at a fraction of the cost, and it fails on the commit
## that introduces the drift rather than at the next release.
##
## ## Why this is not paranoia
##
## The failure this prevents is silent and late. A new
## ``--set-default`` in the flake that the packaging layer does not know
## about produces a Nix build that works and a ``.deb`` whose binary
## dies at run time on a missing source prefix — and it dies on the
## USER's machine, because every developer has the variable in their
## dev shell.
##
## ## The PER-BINARY dimension, which this guard did not have
##
## M1's N17. The list above is one list for one product, and the two
## worlds stopped shipping one product: under Nix, ``reproBinaryCache``
## is ``reprobuild.overrideAttrs`` and ``postFixup`` wraps EVERY
## ``$out/bin/*``, so the Nix ``repro-binary-cache`` receives all of
## these variables -- while the deb/rpm/Arch one, correctly per N9,
## receives none. The divergence is deliberate. What was missing is that
## nothing EXPRESSED it: the guard modelled the flake as one list for
## one product and would have stayed green through any change on either
## side of the cache role.
##
## The cases at the end of this suite add that dimension. They assert,
## per role, what the two worlds are expected to do -- the CLI role
## agrees with the flake name-for-name and in order; the cache role
## deliberately disagrees, and the flake side of that disagreement is
## read out of ``flake.nix`` rather than assumed. A cache list that
## stopped being empty, or a flake that stopped wrapping every binary,
## fails here instead of shipping.

import std/[os, strutils, unittest]

import repro_dsl_stdlib/packaging
import ./packaging_test_support

proc flakeWrapperVariables(): seq[string] =
  ## Extract the ``--set-default NAME`` operands from ``flake.nix``'s
  ## ``postFixup`` ``wrapProgram`` loop, in source order.
  let path = repoRootFromTest() & "/flake.nix"
  doAssert fileExists(path), "flake.nix not found at " & path
  for line in readFile(path).splitLines():
    let trimmed = line.strip()
    if not trimmed.startsWith("--set-default "):
      continue
    let rest = trimmed["--set-default ".len .. ^1].strip()
    var name = ""
    for ch in rest:
      if ch == ' ' or ch == '\t': break
      name.add(ch)
    if name.len > 0 and name notin result:
      result.add(name)

suite "packaging: the §5 wrapper-var list tracks flake.nix":

  test "flake.nix still has a recognisable wrapProgram contract":
    # The extractor is a text scan, so its most likely failure is
    # matching nothing after an unrelated reformat — which would make
    # every case below pass vacuously.
    let names = flakeWrapperVariables()
    check names.len >= 15
    check "REPROBUILD_SOURCE_ROOT" in names
    check "CLINGO_PREFIX" in names

  test "the layer's list is exactly the flake's list, in the same order":
    check ReprobuildWrapperVariables.len == flakeWrapperVariables().len
    check @ReprobuildWrapperVariables == flakeWrapperVariables()

  test "the dlopen-by-leaf-name set is the one §5 names":
    # §5: "blake3, xxHash, sqlite, openssl, zstd, clingo — the last two
    # dlopen'd by leaf name". Those last two are the reason the RPATH is
    # mandatory rather than merely tidy, so they are named in the layer
    # rather than left implicit in the closure.
    check @ReprobuildDlopenPackages == @["zstd", "clingo"]

  test "the leaf names are LOADER names, not package names":
    # M0's residual R3. ``RuntimeContract.dlopenLeafNames`` became a
    # CHECKED post-condition -- the closure walk resolves each name by
    # exact file name and fails the build when it cannot -- while the
    # constant feeding it still held §5's package names. A recipe that
    # passed one to the other would have failed the build with "no
    # search path contains it", naming ``zstd``.
    #
    # The case is written as a shape assertion rather than as a literal
    # comparison, because a literal comparison would have passed
    # against the broken value too if someone had pasted it in.
    for targetOs in [toLinux, toDarwin, toWindows]:
      let leaves = reprobuildDlopenLeafNames(targetOs)
      check leaves.len == ReprobuildDlopenPackages.len
      for leaf in leaves:
        # A loader name has an extension; a package name does not.
        check leaf.contains(".")
        # And it is a LEAF: the ``@rpath/`` prefix is part of the
        # Darwin dlopen ARGUMENT, not part of the file's name, and the
        # walk looks for a file.
        check not leaf.contains("/")
      check leaves != @ReprobuildDlopenPackages

  test "the leaf names match the modules that actually dlopen them":
    # The drift guard, and the reason the values are not a guess: the
    # dlopen strings are stated exactly once each, per target, at the
    # call sites. Read them back rather than trusting a transcription.
    #
    # A TEXT scan rather than an import: importing repro_solver and the
    # binary-cache client into the DSL stdlib's test binary would pull
    # two of the heaviest modules in the tree in for two string
    # literals, and importing them into the LAYER (which every recipe
    # compiles) would be worse still.
    let zstdSrc = readFile(repoRootFromTest() &
      "/libs/repro_binary_cache_client/src/repro_binary_cache_client/" &
      "dynlib_names.nim")
    let clingoSrc = readFile(repoRootFromTest() &
      "/libs/repro_solver/src/repro_solver/dynlib_names.nim")
    # Guard against the scan matching nothing after an unrelated edit,
    # which would make every check below pass vacuously.
    check zstdSrc.contains("zstdDynlibName")
    check clingoSrc.contains("clingoDynlibName")

    proc namesAppear(src: string; leaves: seq[string]) =
      for leaf in leaves:
        doAssert src.contains("\"" & leaf & "\"") or
                 src.contains("/" & leaf & "\""),
          "the packaging layer claims reprobuild dlopens '" & leaf &
          "', but no such string literal appears in the module that " &
          "does the dlopen; one of the two has drifted"

    namesAppear(zstdSrc, @[reprobuildDlopenLeafNames(toLinux)[0]])
    namesAppear(zstdSrc, @[reprobuildDlopenLeafNames(toDarwin)[0]])
    namesAppear(zstdSrc, @[reprobuildDlopenLeafNames(toWindows)[0]])
    namesAppear(clingoSrc, @[reprobuildDlopenLeafNames(toLinux)[1]])
    namesAppear(clingoSrc, @[reprobuildDlopenLeafNames(toDarwin)[1]])
    namesAppear(clingoSrc, @[reprobuildDlopenLeafNames(toWindows)[1]])

  test "the list is names only, with no Nix store paths":
    # The VALUES cannot come from the flake: they are /nix/store paths,
    # and a native package's values are paths inside its own install
    # prefix. A store path that leaked into this list would produce a
    # package whose wrapper points at a directory that does not exist on
    # the target machine — and would still work on the build host.
    for name in ReprobuildWrapperVariables:
      check not name.contains("/")
      check not name.contains("nix")
      check name == name.toUpperAscii()

# ---------------------------------------------------------------------------
# The per-binary dimension (M1's N17).
# ---------------------------------------------------------------------------

proc flakeText(): string =
  readFile(repoRootFromTest() & "/flake.nix")

proc flakeWrapsEveryInstalledBinary(): bool =
  ## Whether ``flake.nix``'s ``postFixup`` wraps a GLOB of installed
  ## binaries rather than one named entry point.
  ##
  ## This is the fact that makes the Nix cache server carry the CLI's
  ## variables: ``reproBinaryCache`` overrides only ``pname`` and
  ## ``meta``, so it inherits this loop, and ``repro-binary-cache`` is
  ## one of the ``$out/bin`` entries the loop walks.
  flakeText().contains("for b in \"$out\"/bin/*")

proc flakeCacheIsAnOverrideOfReprobuild(): bool =
  ## Whether the cache package is derived from the CLI package rather
  ## than built separately. If this ever stops being true, the inherited
  ## ``postFixup`` reasoning above stops holding with it.
  flakeText().contains("reproBinaryCache = reprobuild.overrideAttrs")

proc flakeCacheOverridesPostFixup(): bool =
  ## Whether the cache override supplies a ``postFixup`` of its own.
  ##
  ## Scoped to the override's own attribute set: a match anywhere in the
  ## file would be true of the CLI's ``postFixup`` and the question
  ## would answer itself.
  let text = flakeText()
  let start = text.find("reproBinaryCache = reprobuild.overrideAttrs")
  if start < 0: return false
  let stop = text.find("reproBinaryCacheApp", start)
  if stop < 0: return false
  text[start ..< stop].contains("postFixup")

suite "packaging: the drift guard has a PER-BINARY dimension":

  test "the flake wraps every installed binary, from ONE inherited postFixup":
    # The three facts the divergence rests on, read out of the file
    # rather than assumed. Each is separately capable of changing.
    check flakeWrapsEveryInstalledBinary()
    check flakeCacheIsAnOverrideOfReprobuild()
    check not flakeCacheOverridesPostFixup()
    # Non-vacuity: the extractors must be looking at a file that has a
    # postFixup and a wrapProgram in it at all, or all three could pass
    # by matching nothing.
    check flakeText().contains("postFixup")
    check flakeText().contains("wrapProgram")

  test "each ROLE is compared to the flake, and the cache role DISAGREES":
    # The property N17 asked for. Stated per role, so that a change to
    # either role has to come here and say what it means.
    let cli = newReprobuildDistribution("0.1.3", toLinux)
    let cache = newReprobuildCacheDistribution("0.1.3", toLinux)

    # THE CLI ROLE: the flake's list, name for name, in order. This is
    # the property the suite above already held; it is restated here so
    # the two roles can be read side by side.
    var cliNames: seq[string] = @[]
    for (name, _) in reprobuildWrapperValues(cli): cliNames.add(name)
    check cliNames == flakeWrapperVariables()

    # THE CACHE ROLE: empty, DELIBERATELY, against a flake that gives
    # the same binary every one of these variables. The divergence is
    # asserted in both directions -- it is not "the layer happens to
    # give none", it is "the layer gives none where Nix gives all".
    var cacheNames: seq[string] = @[]
    for (name, _) in reprobuildWrapperValues(cache): cacheNames.add(name)
    check cacheNames.len == 0
    check flakeWrapsEveryInstalledBinary()
    check flakeWrapperVariables().len > 0

    # AND THE ESCAPE HATCH IS CLOSED. If the cache role ever becomes
    # non-empty, this case fails rather than silently leaving that list
    # uncompared -- which was N17's (a): both values-side guards call
    # the TOOL proc, so a non-empty cache list would be checked against
    # nothing at all. Whoever makes it non-empty has to decide here
    # whether the flake must gain the same names.
    if cacheNames.len > 0:
      doAssert cacheNames == flakeWrapperVariables(),
        "reprobuildCacheWrapperValues is no longer empty, so the cache " &
        "role now has names that can drift from flake.nix; either make " &
        "the flake wrap that binary with the same list or record here " &
        "why the two worlds may differ for this product"

  test "the role dispatch is what makes the two answers differ":
    # Non-vacuity for the case above: ask the CLI's proc with the
    # CACHE's distribution and the full list comes back, so "empty" is a
    # decision about the ROLE and not a property of the distribution's
    # fields.
    let cache = newReprobuildCacheDistribution("0.1.3", toLinux)
    check reprobuildToolWrapperValues(cache).len ==
      ReprobuildWrapperVariables.len
    check reprobuildCacheWrapperValues(cache).len == 0

  test "the retired variable is gone from BOTH worlds":
    # M1's N16. ``CT_INTERPOSE_SRC`` was set by the flake, pinned by
    # this guard, and shipped as a source tree by every package -- and
    # read by nothing since ``86cb1bf6`` removed it from
    # ``config.nims``. A guard whose whole job is to keep two worlds
    # equal cannot notice that both are equally wrong, which is why this
    # is a separate assertion rather than a consequence of the
    # comparison above.
    check "CT_INTERPOSE_SRC" notin ReprobuildWrapperVariables
    check "CT_INTERPOSE_SRC" notin flakeWrapperVariables()
    # M1's N19 finished the job: the flake no longer SETS it either, in
    # the dev shell, in the lint hook or in the package environment.
    #
    # The assertion is about ASSIGNMENT rather than about the string,
    # deliberately. ``flake.nix`` still NAMES the variable -- in the
    # comment that records why it went -- so ``not
    # flakeText().contains("CT_INTERPOSE_SRC")`` would fail on a correct
    # flake and would have to be "fixed" by deleting the explanation.
    # What must be absent is a setter, in either of the two forms the
    # file uses.
    check not flakeText().contains("export CT_INTERPOSE_SRC=")
    check not flakeText().contains("CT_INTERPOSE_SRC = ")

  test "the list's variables are read by something, and 14 by config.nims":
    # The test N16's evidence should have been. ``config.nims`` is the
    # reader for the ``*_SRC`` family; the rest are read by the engine or
    # are the layer's own. N9's argument said TWO of these are read by
    # ``config.nims``; the number is fourteen, and that matters because
    # "occurs as a string in the binary" -- N9's actual test -- can never
    # be true of a variable ``config.nims`` reads.
    let configNims = readFile(repoRootFromTest() & "/config.nims")
    var readByConfigNims = 0
    for name in ReprobuildWrapperVariables:
      if configNims.contains(name): inc readByConfigNims
    # Asserted as a floor rather than an equality, so adding a variable
    # ``config.nims`` reads does not fail the case while several readers
    # going away at once does.
    check readByConfigNims >= 14
    check readByConfigNims <= ReprobuildWrapperVariables.len
