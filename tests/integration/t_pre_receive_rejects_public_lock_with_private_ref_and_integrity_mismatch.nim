## Unified-Locking-And-Hooks HL-5 (§6 Decision 3 / §8.3) — the SERVER-SIDE
## public-tier lock gate in ``pre-receive``, driven through the REAL bare-repo
## hook.
##
## The pre-receive gateway was certificate-only. HL-5 makes it ADDITIONALLY
## gate the PUBLIC tier — the only tier the server can see, because the
## committed ``repro.lock`` arrives inside the pushed content. This test drives
## the REAL bare-repo ``pre-receive`` hook (``repro gateway pre-receive``) and
## asserts the two checks, both ``--no-verify``-proof:
##
##   (a) A push whose committed ``repro.lock`` references a PRIVATE-ONLY repo
##       (a dep tagged ``visibility = "personal"``) is REJECTED
##       (``lock_references_private_repo``). ``git push --no-verify`` still hits
##       the server gate (client hooks are skipped, but the receiving bare's
##       pre-receive runs regardless) — it cannot bypass it.
##   (b) A push whose committed ``repro.lock`` has a TAMPERED integrity
##       multihash (a valid public dep but a bogus ``git-sha1:`` value that no
##       longer matches the received commit object) is REJECTED
##       (``locked-integrity-mismatch``), again ``--no-verify``-proof.
##
## Baseline: a CLEAN public lock (a single public dep whose integrity is the
## real object id of the pushed commit) is ACCEPTED — so the two rejections are
## caused by the private ref / tamper, not by the gate refusing every lock.
##
## Falsifiability (confirmed in the campaign log): disable the server lock gate
## (make ``gatewayVerifyPublicLock`` always accept) → BOTH bad pushes are
## ACCEPTED and the negative assertions trip.
##
## Hermetic: only local ``git init`` / ``git init --bare`` repos + the REAL
## installed ``pre-receive`` hook; no network. The cert gate is set to ``off``
## so this test exercises the lock gate in isolation (the lock gate runs
## independently of the certificate gate mode).
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
  let res = runCmd(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
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
    upstreamBare: string   ## the REAL upstream (stands in for GitHub)
    gatewayBare: string    ## the daemon-managed gateway bare
    workPath: string       ## the developer's clone
    objFmt: string

proc seedAndWire(gitBin: string): Fixture =
  ## Seed the upstream + a developer clone with an initial commit and wire the
  ## gateway as the clone's PUSH remote (fetch stays on upstream). The gateway's
  ## cert policy is ``off`` — the lock gate runs regardless of it.
  result.scratch = createTempDir("hl5-prerecv-", "")
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
  writeFile(result.workPath / "README.md", "HL-5 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(result.workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(result.workPath) & " commit -m seed")
  discard requireGit(q(gitBin) & " -C " & q(result.workPath) &
    " remote add origin " & q(result.upstreamBare))
  discard requireGit(q(gitBin) & " -C " & q(result.workPath) &
    " push origin main")

  result.objFmt = requireGit(q(gitBin) & " -C " & q(result.workPath) &
    " rev-parse --show-object-format").strip()

  # Wire the gateway: cert gate OFF, but the lock gate still runs.
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
  ## Write ``repro.lock`` in the working tree, commit it, and return the new
  ## HEAD sha (the commit that carries the lock in its tree).
  writeFile(workPath / "repro.lock", lockContent)
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add repro.lock")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " commit -m lock --allow-empty")
  headSha(gitBin, workPath)

proc publicLock(name, path, revision, integrity: string): string =
  ## A minimal v2 committed lock carrying a single PUBLIC dep.
  serializeLockedDependencies(LockedDependencies(
    schema: "reprobuild.solved-graph-lock.v2",
    deps: @[LockedDep(
      name: name, path: path,
      coordinates: Coordinates(kind: ckVcs, url: "", gitRef: "main",
        revision: revision),
      integrity: integrity, visibility: "public")]))

proc lockWithPrivateRef(objFmt, selfRev: string): string =
  ## A public lock that ALSO references a private-only repo (visibility
  ## ``personal``) — the tier-isolation violation the server must reject.
  serializeLockedDependencies(LockedDependencies(
    schema: "reprobuild.solved-graph-lock.v2",
    deps: @[
      LockedDep(name: "self", path: ".",
        coordinates: Coordinates(kind: ckVcs, gitRef: "main",
          revision: selfRev),
        integrity: gitObjectMultihash(objFmt, selfRev),
        visibility: "public"),
      LockedDep(name: "secret-internal", path: "secret-internal",
        coordinates: Coordinates(kind: ckVcs, gitRef: "main",
          revision: selfRev),
        integrity: "", visibility: "personal")]))

proc pushNoVerify(gitBin: string; fx: Fixture):
    tuple[code: int; output: string] =
  ## Push through the gateway with ``--no-verify`` (skips ALL client hooks); the
  ## receiving bare's pre-receive still runs.
  runShell(shellCommand(@[
    gitBin, "-C", fx.workPath, "push", "--no-verify", "origin", "main"],
    @[(name: "REPROBUILD_REPRO", value: fx.reproBin)]))

proc upstreamHas(gitBin, upstreamBare, sha: string): bool =
  let exists = runCmd(q(gitBin) & " -C " & q(upstreamBare) &
    " cat-file -e " & q(sha & "^{commit}"))
  exists.code == 0

suite "HL-5 — pre-receive rejects public lock with private ref + " &
    "integrity mismatch":

  test "t_pre_receive_rejects_public_lock_with_private_ref_and_integrity_mismatch":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = seedAndWire(gitBin)
      defer: removeDir(fx.scratch)

      # ---- baseline: a CLEAN public lock is ACCEPTED --------------------
      # (proves the gate is not simply rejecting every lock; the rejections
      # below are caused by the private ref / tamper.)
      block cleanBaseline:
        # First commit an empty lock placeholder so HEAD advances, then rewrite
        # it with the correct self integrity in a follow-up commit.
        let rev0 = commitLock(gitBin, fx.workPath,
          publicLock("self", ".", "placeholder", ""))
        let goodLock = publicLock("self", ".", rev0,
          gitObjectMultihash(fx.objFmt, rev0))
        let cleanRev = commitLock(gitBin, fx.workPath, goodLock)
        # Fix the integrity to the FINAL commit (the one actually pushed).
        let finalLock = publicLock("self", ".", cleanRev,
          gitObjectMultihash(fx.objFmt, cleanRev))
        let pushedRev = commitLock(gitBin, fx.workPath, finalLock)
        let cleanPush = pushNoVerify(gitBin, fx)
        checkpoint("clean push output: " & cleanPush.output)
        check cleanPush.code == 0
        check upstreamHas(gitBin, fx.upstreamBare, pushedRev)

      # ---- (a) private-only reference in the public lock → REJECTED ------
      block privateRef:
        let rev = headSha(gitBin, fx.workPath)
        let badLock = lockWithPrivateRef(fx.objFmt, rev)
        let badRev = commitLock(gitBin, fx.workPath, badLock)
        let push = pushNoVerify(gitBin, fx)
        checkpoint("(a) private-ref push output: " & push.output)
        # Falsifiable: if the server lock gate were disabled, this push would
        # SUCCEED and the upstream would receive ``badRev``.
        check push.code != 0
        check "lock_references_private_repo" in push.output
        check ("REJECTED" in push.output or "rejected" in push.output)
        check not upstreamHas(gitBin, fx.upstreamBare, badRev)
        # Roll the working branch back to the last accepted commit so the next
        # case starts from an accepted upstream state.
        discard requireGit(q(gitBin) & " -C " & q(fx.workPath) &
          " reset --hard HEAD~1")

      # ---- (b) tampered integrity multihash → REJECTED ------------------
      block integrityTamper:
        let rev = headSha(gitBin, fx.workPath)
        # A public dep at the real revision but with a BOGUS integrity that no
        # longer matches the received commit object.
        let bogus =
          if fx.objFmt == "sha256":
            "git-sha256:" & repeat("0", 64)
          else:
            "git-sha1:" & repeat("0", 40)
        let tamperedLock = publicLock("self", ".", rev, bogus)
        let tamperRev = commitLock(gitBin, fx.workPath, tamperedLock)
        let push = pushNoVerify(gitBin, fx)
        checkpoint("(b) integrity-tamper push output: " & push.output)
        # Falsifiable: with the lock gate disabled this push SUCCEEDS.
        check push.code != 0
        check "locked-integrity-mismatch" in push.output
        check ("REJECTED" in push.output or "rejected" in push.output)
        check not upstreamHas(gitBin, fx.upstreamBare, tamperRev)
