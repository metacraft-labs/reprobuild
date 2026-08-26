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
## W5 adds a THIRD refusal to the same gate, in a case of its own below:
##
##   (c) A committed ``repro.lock`` that parses PERFECTLY but records a
##       checkout path no consumer may be handed (``./.``, ``../..``) is
##       REJECTED, and distinguishably so — the gate says the lock "is not
##       usable", not that it "does not parse". That branch is the ``except``
##       arm of ``gatewayVerifyPublicLock``'s ``parseWorkspaceLockedDeps``
##       call, which W5 taught to tell a truncated lock apart from a
##       well-formed hostile one, and which until now was verified by reading
##       the code and by nothing else.
##
##       (c) calls ``gatewayVerifyPublicLock`` DIRECTLY rather than pushing
##       through the hook, and the reason is recorded in full on the case:
##       (a) and (b) DO NOT CURRENTLY PASS, on Windows or on Linux, and on
##       Windows they fail identically in a pristine ``d0c6ad8f`` worktree, so
##       it is nothing W5 did. The hooks run — ``post-receive`` forwards — but the
##       lock gate accepts, so the HL-5 gate is presently a no-op through the
##       hook. That is a pre-existing defect reported alongside W5 and not
##       fixed by it; a new case in (a)/(b)'s shape would simply have been a
##       third red case for a reason unrelated to what it asserts. (c) keeps
##       the real bare repo, the real pushed commit and the real lock bytes,
##       and gives up only the claim that the hook reaches the proc.
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
  ## `doAssert`, not `quit`: this is a HELPER, outside any `test` body. `quit`
  ## takes the whole binary down mid-suite, so the case that failed is never
  ## REPORTED as failed and every case after it silently does not run —
  ## indistinguishable, in a log, from a suite that is shorter than it looks.
  ## `doAssert` raises, and the `test` template's own `except Exception`
  ## attributes it to the case it happened in, from any call depth.
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

  test "t_pre_receive_rejects_a_pushed_lock_whose_checkout_path_is_unusable":
    ## W5 — the gate's THIRD refusal, and the one route into it that had never
    ## been executed by anything.
    ##
    ## ``gatewayVerifyPublicLock`` reads the pushed ``repro.lock`` through
    ## ``parseWorkspaceLockedDeps``, which since W5 raises
    ## ``LockedCheckoutPathError`` for a checkout path that resolves to the
    ## workspace root or to an ancestor of it. The ``except CatchableError``
    ## around that call is OLDER than W5 — it was written for a TRUNCATED lock,
    ## whose right answer is also "refuse" — and W5's change to it is one
    ## ternary that makes the diagnostic say WHICH of the two happened. A
    ## swallow site is exactly the shape that reads correct and behaves
    ## otherwise, and this one was signed off on a code read while
    ## ``populateLockedDeps`` and ``repro lock validate`` were both checked
    ## behaviourally. This case closes that gap.
    ##
    ## Why the gateway earns a case rather than resting on the reader's. Every
    ## other W5 case protects the machine that already HOLDS the bad lock. This
    ## is the last point at which such a lock is still one author's problem:
    ## past it the document is every future cloner's, and what it does to them
    ## is a ``repro develop --all --reset`` that deletes their workspace root
    ## and reports success.
    ##
    ## WHY THIS CASE CALLS THE GATE DIRECTLY instead of pushing through the
    ## real ``pre-receive`` hook the way the case above does. Because the case
    ## above does not currently work, and neither would this one. Measured:
    ##
    ##   * Windows, working tree: (a) private-ref push SUCCEEDS (exit 0), the
    ##     upstream receives the bad commit, the gateway prints nothing.
    ##   * Windows, a pristine ``d0c6ad8f`` worktree: byte-for-byte the same
    ##     assertions fail the same way, so it is nothing W5 did.
    ##   * Linux (WSL, same tree): identical. So it is not platform-specific
    ##     either — an earlier draft of this comment said "Windows" and was
    ##     wrong; the Linux run is what caught it.
    ##
    ## The gate is not being SKIPPED, which is the part worth recording. The
    ## ``post-receive`` hook fires and forwards the commit to the upstream, so
    ## the managed hooks do run and ``pre-receive`` did return 0 — the gate was
    ## ASKED and answered "accept". ``gatewayReadPushedLock`` turns every git
    ## error into ``""`` and ``gatewayVerifyPublicLock`` reads ``""`` as
    ## "no public lock in this push — nothing to gate", so whatever stops the
    ## pre-receive child from reading ``<commit>:repro.lock`` out of the
    ## receiving bare (receive-pack quarantines the incoming objects until the
    ## refs are updated, which is the obvious suspect and is NOT confirmed
    ## here), the gate fails OPEN rather than loudly. That is a pre-existing
    ## product defect of its own size — the whole HL-5 public-tier lock gate is
    ## a no-op through the hook — and it is reported alongside W5, not fixed by
    ## it. Writing the new case in the hook's shape would have added a third
    ## case that is red for a reason that has nothing to do with what it
    ## asserts.
    ##
    ## Calling ``gatewayVerifyPublicLock`` directly costs the hook plumbing and
    ## keeps everything the case is actually about: real git objects in a real
    ## bare repo, the real committed lock bytes read out of a real pushed
    ## commit, the real ref-update record the hook parses from its stdin, and
    ## the real verdict. What it does not prove is that the hook reaches this
    ## proc with objects it can read — and on today's evidence nothing proves
    ## that, which is the finding rather than this case's omission.
    ##
    ## Falsifiability, and each negative fails differently. Make
    ## ``parseWorkspaceLockedDeps`` accept these paths (or route this call site
    ## around the boundary) and ``accepted`` stays true and the verdict
    ## assertions trip. Collapse the ternary back to one wording and only the
    ## "does not parse" assertion trips — that is the assertion pinning W5's
    ## half of this branch rather than the pre-existing half.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("hl5-lockpath-", "")
      defer: removeDir(scratch)
      let bare = scratch / "gateway.git"
      let workPath = scratch / "work"
      discard requireGit(q(gitBin) & " init --bare -b main " & q(bare))
      discard requireGit(q(gitBin) & " init -b main " & q(workPath))
      discard requireGit(q(gitBin) & " -C " & q(workPath) &
        " config user.email tester@example.invalid")
      discard requireGit(q(gitBin) & " -C " & q(workPath) &
        " config user.name \"HL5 Tester\"")
      writeFile(workPath / "README.md", "HL-5 lock-path fixture\n")
      discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
      discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m seed")
      let objFmt = requireGit(q(gitBin) & " -C " & q(workPath) &
        " rev-parse --show-object-format").strip()

      var revsSeen: seq[string] = @[]
      proc verdictFor(lockContent: string): GatewayVerifyResult =
        ## Commit `lockContent`, land the commit in the bare the gate reads
        ## from, and ask the gate the question the hook would have asked —
        ## same proc, same argument shape, same objects.
        ##
        ## The distinctness `doAssert` is not decoration. Every verdict below
        ## is attributed to the commit this returns, so two commits landing on
        ## one sha would silently ask about the WRONG lock and report a PASS
        ## for it. Chained parents make a collision impossible here; asserting
        ## it costs one compare and removes the need for the reader to work
        ## that out. `doAssert`, not `check`: this is a helper outside the
        ## `test` body, where `unittest.fail` degrades to `setProgramResult 1`
        ## and the case still prints `[OK]`.
        let rev = commitLock(gitBin, workPath, lockContent)
        doAssert rev notin revsSeen,
          "fixture collision: commit sha " & rev & " reused"
        revsSeen.add(rev)
        discard requireGit(q(gitBin) & " -C " & q(workPath) &
          " push --quiet " & q(bare) & " +HEAD:refs/heads/main")
        gatewayVerifyPublicLock(gitBin, bare, @[GatewayRefUpdate(
          oldSha: "0000000000000000000000000000000000000000",
          newSha: rev, refName: "refs/heads/main")])

      # The baseline first: a lock identical in every field except the checkout
      # path is ACCEPTED. Without it, a gate that refused everything handed to
      # it would satisfy every refusal below.
      let seedRev = headSha(gitBin, workPath)
      let cleanVerdict = verdictFor(
        publicLock("self", ".", seedRev, gitObjectMultihash(objFmt, seedRev)))
      checkpoint("(c) clean verdict: accepted=" & $cleanVerdict.accepted &
        " diagnostic=" & cleanVerdict.diagnostic)
      check cleanVerdict.accepted
      check cleanVerdict.diagnostic.len == 0

      # One spelling of each shape the lock boundary knows about: a path that
      # collapses to the workspace ROOT, and one that collapses to an ANCESTOR
      # of it. Both parse perfectly; neither is a lock any cloner may act on.
      for badPath in ["./.", "../.."]:
        let rev = headSha(gitBin, workPath)
        let verdict = verdictFor(
          publicLock("self", badPath, rev, gitObjectMultihash(objFmt, rev)))
        checkpoint("(c) path='" & badPath & "' verdict: accepted=" &
          $verdict.accepted & " diagnostic=" & verdict.diagnostic)

        check not verdict.accepted
        # The ref, so a multi-branch push says which branch; the offending
        # VALUE, so an operator holding a many-dep lock knows which line to
        # look at; and the remedy, which for a machine-written document is the
        # command that rewrites it.
        check "refs/heads/main" in verdict.diagnostic
        check badPath in verdict.diagnostic
        check "repro lock refresh" in verdict.diagnostic
        # And W5's half of the branch: this lock PARSED. Saying it "does not
        # parse" would send the author looking for a truncated file.
        check "is not usable" in verdict.diagnostic
        check "does not parse" notin verdict.diagnostic

      # The constraint, asserted last: the gate did not learn to refuse
      # everything on the way. An ordinary lock still passes afterwards.
      let afterRev = headSha(gitBin, workPath)
      let afterVerdict = verdictFor(
        publicLock("self", ".", afterRev, gitObjectMultihash(objFmt, afterRev)))
      checkpoint("(c) post-refusal verdict: accepted=" &
        $afterVerdict.accepted & " diagnostic=" & afterVerdict.diagnostic)
      check afterVerdict.accepted
      check afterVerdict.diagnostic.len == 0
