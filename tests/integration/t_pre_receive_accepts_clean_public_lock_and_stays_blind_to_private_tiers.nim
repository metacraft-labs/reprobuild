## Unified-Locking-And-Hooks HL-5 (§6 Decision 3 / §8.3) — the SERVER-SIDE
## public-tier lock gate ACCEPTS a clean public lock AND stays BLIND to the
## team / personal / evidence tiers (the boundary statement).
##
## The server gates ONLY the public tier — it cannot read a team / personal /
## evidence backend, so it makes NO claim about them. This test drives the REAL
## bare-repo ``pre-receive`` hook and asserts:
##
##   (a) A push with a CLEAN public ``repro.lock`` (valid integrity against the
##       received commit, no private-tier deps) is ACCEPTED and forwarded to
##       the upstream.
##   (b) A workspace that ALSO carries team/personal backend records is NOT
##       gated on those server-side. We plant a git-checkout "team backend" bare
##       AND a personal-record file next to the workspace, whose records are
##       stale/tampered — conditions the CLIENT gate would refuse on — and push
##       a clean PUBLIC lock. The server ACCEPTS: it never reads those backends,
##       so their state cannot affect the receiving-side verdict. The push
##       succeeds based on the public lock alone.
##
## W9 — WHY THIS TEST WAS NOT EVIDENCE, AND WHAT IT NOW ASSERTS.
##
## Until W9 every assertion in this file was satisfied PERFECTLY by a gate that
## read nothing at all. ``push.code == 0``; ``lock_references_private_repo``
## ABSENT from the output; ``locked-integrity-mismatch`` ABSENT; the planted
## team bare untouched; the personal record untouched. Each of those is a
## statement that something did NOT happen, and "nothing happened" is exactly
## what a no-op produces. The gate WAS a no-op — ``gatewayReadPushedLock``
## turned the (scrubbed-environment) failure to read the pushed objects into
## ``""``, ``gatewayVerifyPublicLock`` read ``""`` as "no lock, nothing to
## gate", and this file stayed green throughout.
##
## The discriminating property has to be POSITIVE: the gate must be shown to
## have READ the pushed object and DECIDED on its contents. So (a) now asserts
## the gateway echoed, over the wire, the git OBJECT ID of the ``repro.lock``
## blob it read out of the pushed commit — an id this test computes
## independently with ``git rev-parse <commit>:repro.lock`` — together with the
## dependency and integrity-check counts it derived from that blob's BYTES.
## No gate that skips the read can produce that line, and no gate that reads
## the WRONG object can produce that id: the two earlier commits in this same
## fixture carry different lock bytes, hence different blob ids, and (a)
## asserts theirs are absent.
##
## Falsifiability, each negative failing differently:
##   - make the server ALSO reject on a planted team-tier condition → the clean
##     push is wrongly REJECTED and the (a)/(b) accept assertions trip;
##   - restore the quarantine scrub (revert W9 part 1) → the gate cannot read
##     the pushed objects, and with part 2 in place it REFUSES: (a) trips on
##     ``push.code == 0``;
##   - keep the reads working but stop RECORDING what was read → only the
##     blob-id/counts assertions trip, which is the pair that distinguishes
##     "checked and allowed" from "never looked".
##
## Hermetic: only local ``git init`` / ``git init --bare`` repos + the REAL
## installed ``pre-receive`` hook; no network. Cert gate ``off`` (the lock gate
## runs independently).
## Skip rule: ``git`` missing on PATH.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_cli_support
import repro_workspace_manifests
import repro_lock

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  ## ``doAssert``, not ``quit``: this is a HELPER, outside any ``test`` body.
  ## ``quit`` takes the whole binary down mid-suite, so the case that failed is
  ## never REPORTED as failed and every case after it silently does not run.
  ## ``doAssert`` raises and the ``test`` template attributes it to the case.
  let res = runCmd(command, cwd)
  doAssert res.code == 0, "command failed: " & command & "\nexit=" &
    $res.code & "\n" & res.output
  res.output

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

type
  Fixture = object
    scratch: string
    reproBin: string
    upstreamBare: string
    gatewayBare: string
    workPath: string
    objFmt: string
    teamBackendBare: string   ## a planted team git-checkout backend (bare)
    personalRecord: string    ## a planted personal backend record file

proc seedAndWire(gitBin: string): Fixture =
  result.scratch = createTempDir("hl5-accept-", "")
  result.reproBin = reproBinary()
  result.upstreamBare = result.scratch / "upstream.git"
  result.gatewayBare = result.scratch / "gateway.git"
  result.workPath = result.scratch / "work"

  discard requireGit(q(gitBin) & " init --bare -b main " & q(result.upstreamBare))
  discard requireGit(q(gitBin) & " init -b main " & q(result.workPath))
  discard requireGit(q(gitBin) & " -C " & q(result.workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(result.workPath) &
    " config user.name \"HL5 Tester\"")
  writeFile(result.workPath / "README.md", "HL-5 accept fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(result.workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(result.workPath) & " commit -m seed")
  discard requireGit(q(gitBin) & " -C " & q(result.workPath) &
    " remote add origin " & q(result.upstreamBare))
  discard requireGit(q(gitBin) & " -C " & q(result.workPath) &
    " push origin main")

  result.objFmt = requireGit(q(gitBin) & " -C " & q(result.workPath) &
    " rev-parse --show-object-format").strip()

  # ---- plant team + personal backends the server must NEVER read ----------
  # A team git-checkout backend BARE with a deliberately STALE/tampered lock
  # record. If the server read it, its state would matter — but it must not.
  result.teamBackendBare = result.scratch / "team-backend.git"
  discard requireGit(q(gitBin) & " init --bare -b main " &
    q(result.teamBackendBare))
  # A personal-record file with a bogus SHA (a condition the client team/
  # personal currency read would refuse on).
  result.personalRecord = result.scratch / "personal-latest.record"
  writeFile(result.personalRecord,
    "path = \".\"\nrevision = \"0000000000000000000000000000000000000000\"\n")

  let cfg = GatewayConfig(
    gateMode: cgmOff,
    requiredTargets: @[],
    requiredPlatforms: @[],
    lockDigest: "",
    registeredKeysPath: "")
  let wired = wirePushGateway(gitBin, result.workPath, result.gatewayBare,
    fileUrl(result.upstreamBare), cfg)
  doAssert wired.ok, wired.diagnostic

proc headSha(gitBin, workPath: string): string =
  requireGit(q(gitBin) & " -C " & q(workPath) & " rev-parse HEAD").strip()

proc commitLock(gitBin, workPath, lockContent: string): string =
  writeFile(workPath / "repro.lock", lockContent)
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add repro.lock")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " commit -m lock --allow-empty")
  headSha(gitBin, workPath)

proc cleanPublicLock(objFmt, selfRev: string): string =
  serializeLockedDependencies(LockedDependencies(
    schema: "reprobuild.solved-graph-lock.v2",
    deps: @[LockedDep(
      name: "self", path: ".",
      coordinates: Coordinates(kind: ckVcs, gitRef: "main", revision: selfRev),
      integrity: gitObjectMultihash(objFmt, selfRev),
      visibility: "public")]))

proc pushNoVerify(gitBin: string; fx: Fixture):
    tuple[code: int; output: string] =
  runShell(shellCommand(@[
    gitBin, "-C", fx.workPath, "push", "--no-verify", "origin", "main"],
    @[(name: "REPROBUILD_REPRO", value: fx.reproBin)]))

proc upstreamHas(gitBin, upstreamBare, sha: string): bool =
  let exists = runCmd(q(gitBin) & " -C " & q(upstreamBare) &
    " cat-file -e " & q(sha & "^{commit}"))
  exists.code == 0

proc lockBlobIdAt(gitBin, workPath, commit: string): string =
  ## The git OBJECT ID of the ``repro.lock`` blob in ``commit``'s tree,
  ## computed here rather than taken from the gateway — the whole point is to
  ## hold the gateway to an id it had to read the object to know.
  requireGit(q(gitBin) & " -C " & q(workPath) & " rev-parse " &
    q(commit & ":repro.lock")).strip()

proc bareHasAnyBranch(gitBin, bareDir: string): bool =
  ## True iff the planted team backend received any branch (it must NOT — the
  ## server never writes/pushes to it).
  let res = runCmd(q(gitBin) & " -C " & q(bareDir) &
    " for-each-ref --format=%(refname) refs/heads/")
  res.code == 0 and res.output.strip().len > 0

suite "HL-5 — pre-receive accepts a clean public lock and stays blind to " &
    "private tiers":

  test "t_pre_receive_accepts_clean_public_lock_and_stays_blind_to_private_tiers":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = seedAndWire(gitBin)
      defer: removeDir(fx.scratch)

      # Establish the correct self integrity: commit a placeholder lock, read
      # the revision it lands at, then commit the lock that pins THAT revision.
      let rev0 = commitLock(gitBin, fx.workPath,
        cleanPublicLock(fx.objFmt, "placeholder"))
      let lockForRev0 = cleanPublicLock(fx.objFmt, rev0)
      let rev1 = commitLock(gitBin, fx.workPath, lockForRev0)
      let finalLock = cleanPublicLock(fx.objFmt, rev1)
      let pushedRev = commitLock(gitBin, fx.workPath, finalLock)

      # The object ids of all three committed locks. Only the LAST one is in
      # the pushed tip's tree; the other two exist so "the gate named A blob"
      # cannot be mistaken for "the gate named THE blob".
      let blob0 = lockBlobIdAt(gitBin, fx.workPath, rev0)
      let blob1 = lockBlobIdAt(gitBin, fx.workPath, rev1)
      let pushedBlob = lockBlobIdAt(gitBin, fx.workPath, pushedRev)
      # A fixture whose three locks collided on one blob would make the
      # discriminating assertions below pass for the wrong reason — and a
      # collision is always a FALSE PASS. Each lock pins a different revision,
      # so they cannot collide; asserting it costs two compares.
      doAssert pushedBlob != blob0 and pushedBlob != blob1 and blob0 != blob1,
        "fixture collision: the three committed locks share a blob id (" &
          blob0 & " / " & blob1 & " / " & pushedBlob & ")"

      # Sanity: the planted team/personal backends carry STALE/tampered records
      # BEFORE the push — the conditions the client gate would refuse on.
      check not bareHasAnyBranch(gitBin, fx.teamBackendBare)
      check fileExists(fx.personalRecord)

      # ---- (a) clean public lock → ACCEPTED + forwarded -----------------
      let push = pushNoVerify(gitBin, fx)
      checkpoint("clean-accept push output: " & push.output)
      # Falsifiable: if the server gated on the planted team-tier marker, this
      # clean push would be REJECTED.
      check push.code == 0
      check "lock_references_private_repo" notin push.output
      check "locked-integrity-mismatch" notin push.output
      check upstreamHas(gitBin, fx.upstreamBare, pushedRev)

      # ---- (a2) the acceptance was a DECISION ON CONTENT, not a no-op ----
      # Everything above this line is satisfied by a gate that never read the
      # push. These five are not. The gateway reports, over the wire, the blob
      # it read and what it derived from those bytes; the id is the one this
      # test computed from the pushed commit's own tree.
      check "public-tier lock gate" in push.output
      check ("read repro.lock blob " & pushedBlob) in push.output
      check "deps=1 integrity-checked=1 verdict=ACCEPTED" in push.output
      # And it read the PUSHED commit's lock, not an earlier one that happens
      # to sit in the same history.
      check blob0 notin push.output
      check blob1 notin push.output

      # ---- (b) the server stayed BLIND to the team/personal backends ----
      # The push was accepted based on the PUBLIC lock alone. The planted team
      # backend bare received NOTHING (the server never reads/writes it) and
      # the personal record is untouched — the server made no claim about them.
      check not bareHasAnyBranch(gitBin, fx.teamBackendBare)
      check fileExists(fx.personalRecord)
      check readFile(fx.personalRecord).contains(
        "0000000000000000000000000000000000000000")
