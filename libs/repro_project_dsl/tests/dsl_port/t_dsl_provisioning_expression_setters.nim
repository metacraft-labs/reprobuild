## Provisioning setters must take an EXPRESSION, not only a string literal.
##
## These setters route through `stringLiteral()`, whose non-literal branch is
##
##     else: result = node.repr
##
## — the SOURCE TEXT of the node. The value is then re-serialised into the
## generated source with `escForCode`, so `url: TarballUrl` emits
## `url: "TarballUrl"`: the identifier's spelling, not the const's value.
##
## That is a worse failure than the one the `service` setters had. A dropped
## setter at least leaves the field at its ground state, where a downstream
## emptiness check can catch it. This one produces a plausible non-empty string
## that is silently wrong, and `sha256`/`url` are exactly the fields where a
## silently wrong value is most expensive: a checksum that cannot match and a
## URL that cannot resolve, reported far from the declaration that caused it.
##
## Written to FAIL first. It records the corruption before the fix.

import std/[unittest]

import repro_project_dsl
import repro_dsl_stdlib/types

# The reusable vocabulary this is meant to enable — a URL built once from
# named parts rather than pasted at every declaration.
const CondaBase = "https://conda.anaconda.org/conda-forge"

func condaUrl(pkg, ver, build, platform: string): string =
  CondaBase & "/" & platform & "/" & pkg & "-" & ver & "-" & build & ".conda"

const PinnedSha = "a55d01d300000000000000000000000000000000000000000000000000000000"

# The prefix-layout vocabulary the runtime-library work wants: name the layout
# once, derive the directory, rather than repeating `Library/bin` per recipe.
type PrefixLayout = enum
  plUnix   ## bin/, lib/       — nixpkgs, most tarballs
  plConda  ## Library/bin/     — conda-forge win-64

func binDir(layout: PrefixLayout): string =
  case layout
  of plUnix: "bin"
  of plConda: "Library/bin"

package provExprPkg:
  provisioning:
    tarball(
      url = condaUrl("clingo", "5.7.1", "py312h0d7def4_0", "win-64"),
      sha256 = PinnedSha,
      executablePath = binDir(plConda) & "/clingo.exe",
      archiveType = "conda")

suite "provisioning setters accept expressions, not only literals":
  let packages = registeredPackages()
  var pkg: PackageDef
  for p in packages:
    if p.packageName == "provExprPkg":
      pkg = p
      break

  test "the package reached the registry with one tarball entry":
    check pkg.packageName == "provExprPkg"
    check pkg.tarballProvisioning.len == 1

  test "a func call in url: is evaluated, not spelled":
    # Before the fix this is the literal text `condaUrl("clingo", "5.7.1", ...)`.
    check pkg.tarballProvisioning[0].url ==
      "https://conda.anaconda.org/conda-forge/win-64/clingo-5.7.1-py312h0d7def4_0.conda"

  test "a const in sha256: is evaluated, not spelled":
    # Before the fix this is the literal text `PinnedSha` — a 9-character
    # string sitting in a field that must hold 64 hex characters.
    check pkg.tarballProvisioning[0].sha256 == PinnedSha

  test "a compound expression in executablePath: is evaluated, not spelled":
    check pkg.tarballProvisioning[0].executablePath == "Library/bin/clingo.exe"

  test "literals alongside expressions are unaffected":
    check pkg.tarballProvisioning[0].archiveType == "conda"
