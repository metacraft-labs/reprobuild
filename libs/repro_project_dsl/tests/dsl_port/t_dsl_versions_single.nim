## DSL-port M2 acceptance — ``versions:`` declarations.
##
## Pins the contract for M2's v8-style ``versions:`` block. Inside the
## block each ``"<version-string>": <body>`` becomes one
## ``DslVersionInfo`` entry registered against the current package.
##
## Public surface introduced by M2 (see
## ``libs/repro_project_dsl/src/repro_project_dsl/dsl_port_runtime.nim``):
##
##   * ``DslVersionInfo`` — the record shape (version + sourceRevision +
##     sourceChecksum + sourceUrl + sourceRepository + arbitrary
##     ``extras`` table for forward-compat). M2 ships the four named
##     fields the openssl + kernel fixtures use; future milestones can
##     widen ``extras`` without a schema bump.
##   * ``registerVersion*(packageName: string; info: DslVersionInfo)`` —
##     the runtime call the ``versions:`` lowerer emits, one per inner
##     ``"<version-string>":`` block.
##   * ``registeredVersions*(packageName: string): seq[DslVersionInfo]``
##     — the host-side accessor. Returns the per-package list in
##     registration order.
##   * ``resetRegisteredVersions*()`` — clears all version registrations
##     across packages so test fixtures don't leak across cases.
##
## Body grammar inside one version entry:
##
##   ``sourceRevision = "<string>"``  → assigns ``info.sourceRevision``
##   ``sourceChecksum = "<string>"``  → assigns ``info.sourceChecksum``
##   ``sourceUrl = "<string>"``       → assigns ``info.sourceUrl``
##   ``sourceRepository = "<string>"``→ assigns ``info.sourceRepository``
##
## v8 (``project_package_dsl.nim`` lines 304-319) accepts the same four
## assignment keys against a ``ResolvedConfigCell``; M2's surface
## records them as plain ``string`` fields so the package macro can
## reflect them without dragging in the full ConfigContext finalise
## machinery. M3+ widen this to Cell-backed fields when the
## ``configCell`` migration lands.

import std/[unittest]

import repro_project_dsl

# Two versions, four assignments each, mirroring the v8 design memo.
package versionedPkg:
  versions:
    "0.1.0":
      sourceRevision = "refs/tags/v0.1.0"
      sourceChecksum = "sha256-aaaaa"
    "0.2.0":
      sourceRevision = "refs/tags/v0.2.0"
      sourceChecksum = "sha256-bbbbb"

suite "DSL-port M2 — versions: declaration":

  test "two versions registered for versionedPkg":
    let vs = registeredVersions("versionedPkg")
    check vs.len == 2

  test "first version preserves declaration order and metadata":
    let vs = registeredVersions("versionedPkg")
    check vs[0].version == "0.1.0"
    check vs[0].sourceRevision == "refs/tags/v0.1.0"
    check vs[0].sourceChecksum == "sha256-aaaaa"

  test "second version preserves declaration order and metadata":
    let vs = registeredVersions("versionedPkg")
    check vs[1].version == "0.2.0"
    check vs[1].sourceRevision == "refs/tags/v0.2.0"
    check vs[1].sourceChecksum == "sha256-bbbbb"

  test "unregistered package yields the empty seq":
    # M2 contract: querying a package that never declared a ``versions:``
    # block returns the empty seq rather than raising. This makes the
    # accessor safe to call from cross-package code that does not know
    # whether the foreign package opted into the versions surface.
    let unknown = registeredVersions("noSuchPackageEverDeclared")
    check unknown.len == 0
