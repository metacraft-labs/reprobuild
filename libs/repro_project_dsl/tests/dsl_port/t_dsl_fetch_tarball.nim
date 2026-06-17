## DSL-port M9.H acceptance — ``fetch:`` block registry (tarball mode).
##
## Pins the M9.H ``fetch:`` directive contract for the tarball-source
## shape. The block recognises seven setters; the tarball case exercises
## ``url`` + ``sha256`` (or ``blake3``) + ``extractStrip`` +
## ``extractedRoot``. The git-clone shape is exercised in the sibling
## ``t_dsl_fetch_git.nim``.
##
## Coverage:
##
##   * Test 1 — basic tarball: ``url`` + ``sha256`` + ``extractStrip: 1``.
##     The registry row captures every declared field verbatim and the
##     kind discriminant is ``dfkTarball``. ``hashAlg`` is ``dshaSha256``.
##     ``extractedRoot`` stays at the empty default.
##
##   * Test 2 — blake3 + extractedRoot: ``url`` + ``blake3`` + custom
##     ``extractedRoot`` + ``extractStrip: 0``. The registry row pins
##     ``hashAlg == dshaBlake3``, ``extractStrip == 0``, and
##     ``extractedRoot == "src"``.

import std/[strutils, unittest]

import repro_project_dsl

package fooPkg:
  fetch:
    url: "https://example.com/foo-1.0.tar.gz"
    sha256: "abc" & repeat("0", 61)
    extractStrip: 1

package barPkg:
  fetch:
    url: "https://example.com/bar.tar.xz"
    blake3: "def" & repeat("0", 61)
    extractedRoot: "src"
    extractStrip: 0

suite "DSL-port M9.H — fetch: block registry (tarball mode)":

  test "basic tarball: url + sha256 + extractStrip":
    let spec = registeredFetchSpec("fooPkg")
    # Spec attributed to the package.
    check spec.packageName == "fooPkg"
    # url + kind round-trip.
    check spec.url == "https://example.com/foo-1.0.tar.gz"
    check spec.kind == dfkTarball
    # Hash captured verbatim with the right algorithm.
    check spec.hashAlg == dshaSha256
    check spec.hashHex.len == 64
    check spec.hashHex == "abc" & repeat("0", 61)
    # extractStrip captured at the declared value.
    check spec.extractStrip == 1
    # Undeclared fields stay at the documented defaults.
    check spec.gitRevision == ""
    check spec.extractedRoot == ""

  test "blake3 + extractedRoot + extractStrip: 0":
    let spec = registeredFetchSpec("barPkg")
    check spec.packageName == "barPkg"
    check spec.url == "https://example.com/bar.tar.xz"
    check spec.kind == dfkTarball
    # blake3 precedence — hashAlg is dshaBlake3, hashHex matches the
    # blake3 spelling, sha256 is left unset by the recipe.
    check spec.hashAlg == dshaBlake3
    check spec.hashHex == "def" & repeat("0", 61)
    check spec.hashHex.len == 64
    # extractedRoot captured verbatim.
    check spec.extractedRoot == "src"
    # extractStrip honours a 0 value (different from the unset default
    # of 1).
    check spec.extractStrip == 0
