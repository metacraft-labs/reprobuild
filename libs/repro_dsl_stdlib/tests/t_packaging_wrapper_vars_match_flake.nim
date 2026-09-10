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
