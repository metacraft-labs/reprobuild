## DSL-port M9.H acceptance — ``fetch:`` block registry (git-archive
## mode).
##
## Pins the M9.H ``fetch:`` directive contract for the git-clone shape.
## ``gitUrl`` (instead of ``url``) drives the kind discriminant to
## ``dfkGitArchive``; ``gitRevision`` pins the resolved tag / commit;
## the hash setter (``sha256`` or ``blake3``) verifies the resulting
## shallow-clone tarball.
##
## Coverage:
##
##   * Test 1 — git clone: ``gitUrl`` + ``gitRevision`` + ``sha256``.
##     The registry row pins ``kind == dfkGitArchive``, ``url`` holds
##     the git URL, ``gitRevision`` round-trips verbatim,
##     ``extractStrip`` defaults to 1 (matches GitHub archive default),
##     and ``extractedRoot`` stays empty.

import std/[strutils, unittest]

import repro_project_dsl

package gitPkg:
  fetch:
    gitUrl: "https://github.com/bus1/dbus-broker.git"
    gitRevision: "v36"
    sha256: "abc" & repeat("0", 61)

suite "DSL-port M9.H — fetch: block registry (git-archive mode)":

  test "git clone: gitUrl + gitRevision + sha256":
    let spec = registeredFetchSpec("gitPkg")
    # Spec attributed to the package.
    check spec.packageName == "gitPkg"
    # kind discriminant flipped to git-archive when ``gitUrl`` is the
    # source field used (the URL itself lives in spec.url).
    check spec.kind == dfkGitArchive
    check spec.url == "https://github.com/bus1/dbus-broker.git"
    # Revision round-trip verbatim.
    check spec.gitRevision == "v36"
    # sha256 captured at the canonical 64-hex length.
    check spec.hashAlg == dshaSha256
    check spec.hashHex.len == 64
    # extractStrip defaults to 1 when the recipe does not declare it
    # (matches the documented default in DslFetchSpec).
    check spec.extractStrip == 1
    # extractedRoot stays at the empty default.
    check spec.extractedRoot == ""
