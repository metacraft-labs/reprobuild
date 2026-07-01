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
## Falsifiability (confirmed in the campaign log): make the server ALSO reject
## based on a planted team-tier condition (e.g. gate on the presence of the
## planted team-backend marker) → the clean push is wrongly REJECTED and (a)/(b)
## trip.
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

      # ---- (b) the server stayed BLIND to the team/personal backends ----
      # The push was accepted based on the PUBLIC lock alone. The planted team
      # backend bare received NOTHING (the server never reads/writes it) and
      # the personal record is untouched — the server made no claim about them.
      check not bareHasAnyBranch(gitBin, fx.teamBackendBare)
      check fileExists(fx.personalRecord)
      check readFile(fx.personalRecord).contains(
        "0000000000000000000000000000000000000000")
