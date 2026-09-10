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
    check @ReprobuildDlopenLeafNames == @["zstd", "clingo"]

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
