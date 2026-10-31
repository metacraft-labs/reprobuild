## M69 → GM4b — end-to-end gate for `repro home apply` resolving a home
## profile's packages to their archive realizations.
##
## A 4-package home.nim is planned, and each reference is resolved — with
## the profile resolver the apply pipeline uses (`resolveProfilePackage`,
## GM4b) — for an x86_64-windows target under the `[tarball]` selection
## policy (the GM4b spelling of the old `--prefer-adapter=builtin`). Every
## resolution MUST select the package's `tarball` realization (each has a
## Windows archive), with nothing falling through to another kind, and the
## version a pin names reaches the selection.
##
## A second pass over the same fixture asserts determinism: the selected
## (version, url, lock identity) triple is identical across calls, which is
## what lets the realizers no-op against an existing prefix.
##
## The actual realize step (hundreds of MB of downloads) is NOT exercised
## here; the realizers are covered by `t_builtin_adapter*.nim` and
## `t_realize_honors_requested_version.nim` against `file://` fixtures.
## No mocks.

import std/[os, sets, unittest]

import repro_home_intent
import repro_home_apply/plan
import repro_home_apply/package_catalog
from repro_test_support import testCaseScratchSlug

let TmpDir = "build/test-tmp/e2e-m69-builtin-catalog" / testCaseScratchSlug()

proc resetTmp() =
  if dirExists(TmpDir):
    removeDir(TmpDir)
  createDir(TmpDir)

proc resolveAllTarball(packageIds: openArray[(string, string)]):
    seq[ProfilePackageResolution] =
  ## Resolve each (packageId, requestedVersion) for x86_64-windows under the
  ## `[tarball]` policy. The target is stated, not the runner's: selection is
  ## a pure function of the definitions and the target.
  let target = realizationTargetFor(pcX86_64, poWindows, mlX86_64_v1)
  for (pkgId, requested) in packageIds:
    result.add resolveProfilePackage(pkgId, target, @[rkTarball],
      requestedVersion = requested)

suite "M69/GM4b e2e: home profile packages resolve to their archives":

  test "4-package home.nim parses and plans correctly":
    resetTmp()
    let profilePath = TmpDir / "home.nim"
    writeFile(profilePath, """import repro/profile

profile "rt":
  activity dev:
    package(cmake)
    package(just)
    package(nim)
    package(ninja)
  hosts:
    "test-host": [dev]
""")
    let parsed = loadProfile(profilePath)
    let plan = buildPlan(parsed, TmpDir, "test-host")
    check plan.packages.len == 4
    var ids: HashSet[string]
    for p in plan.packages:
      ids.incl p.packageId
    check ids == toHashSet(["cmake", "just", "nim", "ninja"])

  test "all 4 packages resolve to their tarball realization":
    let resolutions = resolveAllTarball([
      ("cmake", ""),
      ("just", ""),
      ("nim", ""),
      ("ninja", ""),
    ])
    check resolutions.len == 4
    for r in resolutions:
      checkpoint r.packageId
      check r.selection.kind == rkTarball
      check r.selection.version.len > 0
      check r.selection.tarball.url.len > 0
      check r.selection.tarball.os == "windows"
      check r.selection.tarball.sha256.len == 64
      check r.selection.lockIdentity.len > 0
      check r.selection.tarball.executablePath.len > 0
      # Exactly one policy step, the one that selected.
      check r.selection.trace.len == 1
      check r.selection.trace[0].kind == rkTarball
      check r.selection.trace[0].selected

  test "a version pin reaches the selection":
    let pinned = resolveAllTarball([("just", "1.51.0")])
    check pinned[0].selection.version == "1.51.0"
    let bare = resolveAllTarball([("just", "")])
    check bare[0].selection.version == pinned[0].selection.version

  test "second pass resolves to the same (version, url, lock) triple":
    # Selection is pure — re-resolving a bare reference must produce the
    # identical record, so a realizer cache-hits the prefix the first apply
    # realized.
    let pass1 = resolveAllTarball([("cmake", ""), ("just", ""),
                                   ("nim", ""), ("ninja", "")])
    let pass2 = resolveAllTarball([("cmake", ""), ("just", ""),
                                   ("nim", ""), ("ninja", "")])
    check pass1.len == pass2.len
    for i in 0 ..< pass1.len:
      check pass1[i].selection.version == pass2[i].selection.version
      check pass1[i].selection.tarball.url == pass2[i].selection.tarball.url
      check pass1[i].selection.lockIdentity == pass2[i].selection.lockIdentity
