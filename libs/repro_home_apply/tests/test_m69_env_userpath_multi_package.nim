## M69 — regression: two packages with non-empty bin dirs must own
## DISTINCT sentinel-delimited blocks in `~/.bashrc` (POSIX) and the
## live state must round-trip through the apply / observe / destroy
## drivers without one package clobbering the other.
##
## Pre-fix (single global `repro-home-userpath` sentinel id), every
## `rkEnvUserPath` resource collapsed into the same managed block —
## the last writer won and the loser's contribution was silently
## lost. Post-fix the M69 emitter derives a per-resource block id
## from the resource address (`repro-home-userpath:home.package.<id>.bin`)
## and `realWorldIdentity` encodes both the host rc file AND the
## per-resource block id so destroy / drift-observe can recover the
## right block at rollback time.
##
## Coverage:
##
##   * `planEnvBindings` produces TWO `rkEnvUserPath` resources with
##     DISTINCT addresses AND distinct `pathBlockId`s.
##   * `applyUserPath` against the same shell rc file produces TWO
##     sentinel-delimited blocks, one per resource — neither
##     contribution overlaps the other.
##   * Removing one resource's contribution leaves the other block
##     byte-identical (the gate-4 invariant at the per-resource grain).
##   * `realWorldIdentity` encodes the block id so rollback can
##     recover both the host file and the block id from the recorded
##     identity.

import std/[os, strutils, tempfiles, unittest]

import repro_home_resources
import repro_home_apply/env_binding
import repro_home_apply/realize

proc makeRecord(pkg, exePath: string): RealizedRecord =
  result.packageId = pkg
  result.adapter = akBuiltin
  result.prefixAbsolutePath = exePath.parentDir.parentDir
  result.resolvedExecutablePath = exePath

proc findUserPath(plan: EnvBindingPlan; address: string):
    tuple[found: bool; r: Resource] =
  for r in plan.resources:
    if r.kind == rkEnvUserPath and r.address == address:
      return (true, r)
  (false, Resource(kind: rkEnvUserPath))

suite "M69 env.userPath multi-package regression":

  test "two packages produce two distinct rkEnvUserPath resources":
    let r1 = makeRecord("pkg-alpha", "/tmp/store/alpha/bin/alpha")
    let r2 = makeRecord("pkg-beta", "/tmp/store/beta/bin/beta")
    let plan = planEnvBindings(@[r1, r2])
    let pa = findUserPath(plan, "home.package.pkg-alpha.bin")
    let pb = findUserPath(plan, "home.package.pkg-beta.bin")
    check pa.found
    check pb.found
    check pa.r.address != pb.r.address
    # Per-resource block id derived from the address — the fix.
    when not defined(windows):
      check pa.r.pathBlockId.len > 0
      check pb.r.pathBlockId.len > 0
      check pa.r.pathBlockId != pb.r.pathBlockId
      check pa.r.pathBlockId.contains("pkg-alpha")
      check pb.r.pathBlockId.contains("pkg-beta")

  test "realWorldIdentity encodes the per-resource block id (POSIX)":
    when defined(windows):
      skip()
    else:
      let r1 = makeRecord("pkg-alpha", "/tmp/store/alpha/bin/alpha")
      let plan = planEnvBindings(@[r1])
      let pa = findUserPath(plan, "home.package.pkg-alpha.bin")
      check pa.found
      var rsc = pa.r
      rsc.pathHostFilePath = "/tmp/fake.bashrc"
      let identity = realWorldIdentity(rsc)
      check identity.startsWith("/tmp/fake.bashrc#")
      check identity.endsWith("repro-home-userpath:home.package.pkg-alpha.bin")

  test "applyUserPath: two packages write two independent rc blocks":
    when defined(windows):
      skip()
    else:
      let tempRoot = createTempDir("repro-userpath-multi-", "")
      defer:
        try: removeDir(tempRoot) except OSError: discard
      let rc = tempRoot / "bashrc"
      writeFile(rc, "# pre-existing user content\nexport USER_VAR=42\n")

      # Build M69 resources for two packages.
      let plan = planEnvBindings(@[
        makeRecord("pkg-alpha", "/tmp/store/alpha/bin/alpha"),
        makeRecord("pkg-beta",  "/tmp/store/beta/bin/beta")])
      let alpha = findUserPath(plan, "home.package.pkg-alpha.bin").r
      let beta = findUserPath(plan, "home.package.pkg-beta.bin").r

      # Apply both contributions (the apply pipeline calls this with
      # the desired block id threaded through; we replicate that here
      # so the driver writes TWO sentinel-delimited blocks).
      discard applyUserPath(alpha.pathEntries, priorContribution = @[],
        hostFilePath = rc, blockId = alpha.pathBlockId)
      discard applyUserPath(beta.pathEntries, priorContribution = @[],
        hostFilePath = rc, blockId = beta.pathBlockId)

      let body = readFile(rc)
      # User's pre-existing content survived.
      check body.contains("export USER_VAR=42")
      # Both per-package sentinels are present.
      check body.contains("repro-managed:" & alpha.pathBlockId)
      check body.contains("repro-managed:" & beta.pathBlockId)
      # Both bin dirs are present in the rc file.
      check body.contains("/tmp/store/alpha/bin")
      check body.contains("/tmp/store/beta/bin")
      # Neither block id is the legacy single shared id.
      check alpha.pathBlockId != "repro-home-userpath"
      check beta.pathBlockId != "repro-home-userpath"
      # And the legacy single shared sentinel must NOT appear — the
      # M69 emitter MUST emit per-package ids.
      check (not body.contains("repro-managed:repro-home-userpath\n"))

      # Drop one resource: removing alpha's contribution must leave
      # beta's block byte-identical.
      let bodyBeforeRemove = readFile(rc)
      let openBeta = "# >>> repro-managed:" & beta.pathBlockId
      let closeBeta = "# <<< repro-managed:" & beta.pathBlockId
      let betaOpenBefore = bodyBeforeRemove.find(openBeta)
      let betaCloseBefore = bodyBeforeRemove.find(closeBeta)
      check betaOpenBefore >= 0
      check betaCloseBefore > betaOpenBefore
      let betaSliceBefore = bodyBeforeRemove[
        betaOpenBefore .. (betaCloseBefore + closeBeta.len - 1)]

      removeUserPathContribution(alpha.pathEntries,
        hostFilePath = rc, blockId = alpha.pathBlockId)
      let bodyAfter = readFile(rc)

      # Alpha's block is gone.
      check (not bodyAfter.contains("repro-managed:" & alpha.pathBlockId))
      # Beta's block survives byte-identically.
      let betaOpenAfter = bodyAfter.find(openBeta)
      let betaCloseAfter = bodyAfter.find(closeBeta)
      check betaOpenAfter >= 0
      check betaCloseAfter > betaOpenAfter
      let betaSliceAfter = bodyAfter[
        betaOpenAfter .. (betaCloseAfter + closeBeta.len - 1)]
      check betaSliceBefore == betaSliceAfter
      # User content still survives.
      check bodyAfter.contains("export USER_VAR=42")

  test "observeUserPath returns joined-entries digest in both branches":
    ## Bug-2 regression: when the live block doesn't match what we'd
    ## render NOW (e.g. the desired contribution shrank since the
    ## last apply), `observeUserPath` must still return a digest in
    ## the same space as `applyUserPath`'s recorded `postWriteDigest`
    ## — i.e. `digest(joined-entries)`. Without that, the
    ## drift-vs-safe-update branch of `decideAction` can never see
    ## `recorded.postWriteDigest == observed.digest` even when the
    ## live block is byte-exactly our last write.
    when defined(windows):
      skip()
    else:
      let tempRoot = createTempDir("repro-userpath-digest-", "")
      defer:
        try: removeDir(tempRoot) except OSError: discard
      let rc = tempRoot / "bashrc"
      writeFile(rc, "")

      let blockId = "repro-home-userpath:home.package.pkg-gamma.bin"
      # Apply with TWO entries; capture the recorded post-write
      # payload bytes (joined entries).
      let recordedBytes = applyUserPath(
        @["/opt/gamma/bin", "/opt/gamma/libexec"],
        priorContribution = @[],
        hostFilePath = rc, blockId = blockId)
      var recordedJoined = newString(recordedBytes.len)
      for i, b in recordedBytes: recordedJoined[i] = char(b)
      check recordedJoined == "/opt/gamma/bin:/opt/gamma/libexec"
      let recordedDigest = digestOfBytes(recordedBytes)

      # Observe with a SHRUNK desired (only the first entry). The
      # live block still has both entries — so we're in the
      # unequal-bytes branch. The returned digest MUST equal the
      # joined-entries digest of what's actually in the live block,
      # NOT the desired contribution, AND it must be comparable to
      # `recordedDigest` (same digest space). In the specific case
      # where the live block reflects what we last wrote verbatim
      # (the typical "two-package apply, then drop one to a single-
      # package re-apply" scenario), `observed.digest` MUST equal
      # `recordedDigest` byte-for-byte.
      let obs = observeUserPath(@["/opt/gamma/bin"],
        hostFilePath = rc, blockId = blockId)
      check obs.present
      check obs.digest == recordedDigest
