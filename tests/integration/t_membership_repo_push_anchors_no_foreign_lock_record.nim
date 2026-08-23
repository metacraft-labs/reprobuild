## A membership-repo push must not anchor its lock at another repo's commit.
##
## The incident
## ------------
## Pushing the workspace/manifest repo — the checkout carrying ``projects/``
## and ``repos/``, which no project declares as one of its repos — was refused:
##
##   lock-failure — immutable lock record already exists at
##   '.repro/manifests/locks/codetracer/codetracer/514b40f3….toml' with
##   different repository coordinates (changed paths: infra, nixos-modules,
##   metacraft-specs, …30 repos); keep the existing record and create a lock
##   anchored by the commit that changed
##
## A membership push supplies neither a trigger NAME (it is not a declared
## repo) nor a trigger PATH, so ``pickTriggerRepo`` fell through to its
## fallback (3) — "the repo whose ``name`` equals the project name" — and filed
## the workspace's state under the PRIMARY repo's name at the PRIMARY repo's
## commit. Two things follow, and the second is what wedges a workspace:
##
##   * the record is a false claim: it says "at <primary>@<sha> the workspace
##     looked like this", about a commit that never saw this state; and
##   * the key is derived from a commit the push does not move. Published lock
##     records are immutable and publication is additions-only, so once one
##     membership push has burned that coordinate, EVERY later membership push
##     recomputes the same key, finds the siblings have moved, and refuses.
##     Nothing can advance it until the primary repo's HEAD happens to move.
##     ``repro workspace lock`` refuses identically, so there is no way out
##     from either the hook or the verb.
##
## What the specs say the anchor is
## --------------------------------
## Workspace-Manifests.md §"``locks/<project>/<repo>/<sha>.toml`` — Workspace
## Lock": the record "is written under the directory of the repo whose commit
## TRIGGERED it"; §"Declared repos with no on-disk checkout": "A lock record is
## keyed by the trigger repo's commit". Unified-Locking-And-Hooks.md §6
## Decision 1, consequence 2 is the one that settles the membership case:
##
##   "The partition is anchored only at a trigger that belongs to it. …
##    Filing the team partition under a public or personal trigger both puts
##    the record where nobody looks and drops a team SHA into a directory named
##    for a repo of another tier. When the trigger is outside the partition,
##    the manifest gets no trigger-keyed document for that operation."
##
## The membership repo is the extreme of "outside the partition": no project
## declares it, so it has no manifest ``name`` and there is no ``<repo>``
## component to encode (§"Path components are encoded names, not joined paths"
## — the component is a declared repo's *name*). Workspace-And-Develop-Mode.md
## §"Gate scope when the pushed repo is the membership repo" states the same
## premise for the gate's scope: it "is not a project repo". So a membership
## push writes no trigger-keyed record — and, above all, does not borrow
## somebody else's.
##
## What is asserted, and why none of it is vacuous
## -----------------------------------------------
## An "absence" assertion is the classic vacuous green here: a scan that
## matches nothing reads exactly like "the bad thing is gone". So every
## absence is paired with a positive find over the SAME scan:
##
##   1. the pre-existing published record IS found, by path, before the push;
##   2. the store's record set after the push is compared to that same
##      non-empty set — unchanged, and the pre-existing record still byte-for
##      -byte pins the OLD sibling sha (published history untouched);
##   3. no record appears under ANY repo directory for this operation, checked
##      by enumerating the store's ``locks/`` tree, which is proven non-empty
##      by (1);
##   4. a SECOND membership push, after a second sibling move, also passes —
##      the property the incident actually lacked. Anchoring on the primary
##      repo passes (4) at most once and then wedges forever.
##
## The two declared repos are seeded with different content, so their commit
## SHAs differ; a fixture whose repos produce identical SHAs cannot tell a
## right anchor from a wrong one.
##
## Hermetic: fresh tempdir, local ``git init``/``--bare`` only, no network.
## Black-box: the real ``./build/bin/repro`` binary through its real
## ``check --mode=pre-push`` entry point, with the ``--pushed-refs`` stream a
## git pre-push hook supplies. No mocks — real git, real lock store, real gate.
## Skip: ``git`` missing or ``./build/bin/repro`` absent.

import std/[algorithm, json, os, osproc, sequtils, strutils, tempfiles, unittest]

const reproBinary = "./build/bin/repro"

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireRun(command: string; cwd = ""): string =
  let res = run(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc silenceLayers(scratch: string) =
  putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
  putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
  putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")

proc unsilenceLayers() =
  delEnv("REPROBUILD_SYSTEM_CONFIG")
  delEnv("REPROBUILD_USER_CONFIG")
  delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

proc lockRecords(store: string): seq[string] =
  ## Every lock record in the store, as store-relative slash paths, sorted.
  let root = store / "locks"
  if not dirExists(root): return @[]
  for path in walkDirRec(root):
    if path.endsWith(".toml"):
      result.add(path[store.len + 1 .. ^1].replace(DirSep, '/'))
  result.sort()

suite "a membership-repo push anchors no foreign lock record":

  test "t_membership_repo_push_anchors_no_foreign_lock_record":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let reproAbs = absolutePath(reproBinary)
      let scratch = createTempDir("membership-anchor-", "")
      defer: removeDir(scratch)
      silenceLayers(scratch)
      defer: unsilenceLayers()

      let git = q(gitBin)
      proc gitCfg(repo: string) =
        discard requireRun(git & " -C " & q(repo) &
          " config user.email tester@example.invalid")
        discard requireRun(git & " -C " & q(repo) &
          " config user.name \"Anchor Tester\"")

      let ws = scratch / "workspace"
      createDir(ws / "projects")
      createDir(ws / "repos")

      # Two declared repos with DIFFERENT seed content, so their HEAD SHAs
      # differ and "which repo is this record anchored at" is observable.
      proc declareRepo(name, seed: string) =
        let origin = scratch / ("origin-" & name & ".git")
        discard requireRun(git & " init -q --bare -b main " & q(origin))
        discard requireRun(git & " clone -q " & q("file://" & origin) & " " &
          q(ws / name))
        gitCfg(ws / name)
        writeFile(ws / name / "seed.txt", seed)
        discard requireRun(git & " -C " & q(ws / name) & " add -A")
        discard requireRun(git & " -C " & q(ws / name) &
          " commit -qm " & q("seed " & name))
        discard requireRun(git & " -C " & q(ws / name) & " push -q origin main")
        writeFile(ws / "repos" / (name & ".toml"),
          "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
          "[repo]\nname = \"" & name & "\"\npath = \"" & name & "\"\n" &
          "remote = \"" & name & "-origin\"\nrevision = \"main\"\n")

      writeFile(ws / "projects" / "mix.toml",
        "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "[project]\nname = \"mix\"\ndefault_revision = \"main\"\n" &
        "trunk = \"main\"\n\n" &
        "[[remote]]\nname = \"core-origin\"\nfetch = \"file://" &
          scratch / "origin-core.git" & "\"\n\n" &
        "[[remote]]\nname = \"side-origin\"\nfetch = \"file://" &
          scratch / "origin-side.git" & "\"\n\n" &
        "includes = [\n  \"repos/core.toml\",\n  \"repos/side.toml\",\n]\n")
      # ``core`` is the PROJECT-NAMED anchor candidate only because the project
      # is named ``mix`` and neither repo matches — ``pickTriggerRepo``'s
      # fallback then takes the FIRST declared repo, which is ``core``. Both
      # limbs of the fallback lead to the same wrong answer for a membership
      # push, and this fixture exercises the "first declared repo" limb.
      declareRepo("core", "core seed\n")
      declareRepo("side", "side seed\n")

      # The lock store: its own git checkout with its own bare origin.
      let store = ws / ".repro" / "manifests"
      createDir(parentDir(store))
      let storeOrigin = scratch / "origin-manifests.git"
      discard requireRun(git & " init -q --bare -b main " & q(storeOrigin))
      discard requireRun(git & " clone -q " & q("file://" & storeOrigin) &
        " " & q(store))
      gitCfg(store)
      writeFile(store / "README.md", "lock store\n")
      discard requireRun(git & " -C " & q(store) & " add -A")
      discard requireRun(git & " -C " & q(store) & " commit -qm seed")
      discard requireRun(git & " -C " & q(store) & " push -q origin main")

      writeFile(ws / ".repro" / "workspace.toml",
        "schema = \"reprobuild.workspace.local.v1\"\n\n" &
        "[workspace]\nproject = \"mix\"\nbranch = \"main\"\n")

      # An EXPLICIT team route to that store. Without one the workspace is
      # single-tier, ``recordRoutedParticipation`` returns nothing, and the
      # per-repo participation fan-out — the path a suppressed partition write
      # re-enables — is never exercised at all. The field failure this test
      # exists for happened in a routed workspace, so the fixture is routed.
      writeFile(ws / ".repro-workspace.toml",
        "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
        "[manifest]\n" &
        "url = \"https://example.invalid/manifests.git\"\n\n" &
        "[locking]\n" &
        "route = [{ visibility = \"team\", backend = \"git-checkout\", " &
        "path = \".repro/manifests\", repos = [\"core\", \"side\"] }]\n")

      # The MEMBERSHIP repo is the workspace root itself: it carries
      # ``projects/`` and ``repos/``, which is exactly what
      # ``manifestsRoot`` recognises.
      discard requireRun(git & " init -q -b main " & q(ws))
      gitCfg(ws)
      writeFile(ws / ".gitignore", "/.repro/\n/core/\n/side/\n")
      # A non-fragment file, so the fixture can make a membership commit whose
      # scope is legitimately empty.
      writeFile(ws / "README.md", "workspace membership\n")
      discard requireRun(git & " -C " & q(ws) & " add -A")
      discard requireRun(git & " -C " & q(ws) & " commit -qm \"seed manifests\"")
      let wsOrigin = scratch / "origin-workspace.git"
      discard requireRun(git & " init -q --bare -b main " & q(wsOrigin))
      discard requireRun(git & " -C " & q(ws) & " remote add origin " &
        q("file://" & wsOrigin))
      discard requireRun(git & " -C " & q(ws) & " push -q -u origin main")

      proc headOf(repo: string): string =
        requireRun(git & " -C " & q(repo) & " rev-parse HEAD").strip()

      let coreSha = headOf(ws / "core")
      let sideSeedSha = headOf(ws / "side")
      # The falsifiability precondition: a fixture whose two repos share a SHA
      # cannot distinguish a right anchor from a wrong one.
      check coreSha != sideSeedSha

      var pushCount = 0
      proc membershipPush(marker: string;
                          touchFragment = true): tuple[code: int; output: string] =
        ## Commit a membership edit and run the gate the way git's pre-push
        ## hook runs it: from the membership repo, with the real refs stream.
        ##
        ## ``touchFragment`` decides the gate's SCOPE, which is the repos whose
        ## `repos/<name>.toml` / `projects/<p>.toml` the pushed range modifies.
        ## `false` edits a README instead, which is the "commit touching no
        ## manifest fragment" case whose scope is legitimately EMPTY.
        inc pushCount
        let oldTip = requireRun(git & " -C " & q(ws) &
          " rev-parse origin/main").strip()
        if touchFragment:
          writeFile(ws / "repos" / "side.toml",
            readFile(ws / "repos" / "side.toml") & "\n# " & marker & "\n")
        else:
          writeFile(ws / "README.md",
            readFile(ws / "README.md") & marker & "\n")
        discard requireRun(git & " -C " & q(ws) & " add -A")
        discard requireRun(git & " -C " & q(ws) &
          " commit -qm " & q("manifests: " & marker))
        let newTip = headOf(ws)
        let refsFile = scratch / ("pushed-refs-" & $pushCount & ".txt")
        writeFile(refsFile,
          "refs/heads/main " & newTip & " refs/heads/main " & oldTip & "\n")
        let res = run(reproAbs & " check --mode=pre-push --write-report" &
          " --workspace-root=" & q(ws) &
          " --current-repo=" & q(ws) &
          " --pushed-refs=" & q(refsFile) & " --json", cwd = ws)
        if res.code == 0:
          discard requireRun(git & " -C " & q(ws) & " push -q origin main")
        res

      # ---- an EMPTY scope is a scope, and an unrelated dirty tree is not
      #      this push's business ------------------------------------------
      # A membership commit that touches no manifest fragment has a
      # legitimately EMPTY scope and "checks only the membership repo's own
      # cleanliness and publication"
      # ([Workspace-And-Develop-Mode.md] §"Gate scope when the pushed repo is
      # the membership repo"). The gate's own cleanliness stage honours that.
      # The LOCK stage received the same scope as a bare set, could not tell
      # decided-and-empty from "no scope supplied", and applied the legacy
      # whole-workspace refusal:
      #
      #   lock-failure — re-run 'repro workspace lock' to diagnose
      #   [lock writer refused: dirty siblings]
      #
      # — the exact outcome that section names as the friction its rule
      # removes: "in its worst form blocks a one-line manifest description
      # edit on an unrelated sibling's dirty tree".
      #
      # This runs FIRST, while the store still holds no record, because that
      # is what makes the lock stage actually run: with an empty scope the
      # gate observes no repo, so nothing can be found stale, and the writer
      # is reached only when there is no lock to compare against at all. Run
      # later it would report "already current", never enter the writer, and
      # pass no matter what the writer would have done — a green that proves
      # nothing.
      check lockRecords(store).len == 0
      writeFile(ws / "core" / "uncommitted.txt", "work in progress\n")
      # Positive find: the sibling really is dirty, so the assertion below is
      # about the gate's scoping and not about an unchanged tree.
      check requireRun(git & " -C " & q(ws / "core") &
        " status --porcelain").strip().len > 0
      let readmePush = membershipPush("a note in the README",
        touchFragment = false)
      checkpoint("membership push (no fragment touched): exit " &
        $readmePush.code & "\n" & readmePush.output)
      check not readmePush.output.contains("dirty siblings")
      check readmePush.code == 0
      # The out-of-scope allowance is about OTHER repos; from here on ``core``
      # is clean so it can be locked and, later, pushed.
      removeFile(ws / "core" / "uncommitted.txt")

      # ---- another session publishes the immutable record ----------------
      # Exactly what happened in the field: an anchor-less `repro workspace
      # lock` files the workspace state under the fallback repo and PUBLISHES
      # it (commit + push to the store's upstream). From here that coordinate
      # is history.
      let seedLock = run(reproAbs & " workspace lock --workspace-root=" & q(ws))
      checkpoint("seed lock: exit " & $seedLock.code & "\n" & seedLock.output)
      check seedLock.code == 0
      let burnedRecord = "locks/mix/core/" & coreSha & ".toml"
      let recordsBefore = lockRecords(store)
      checkpoint("records after seed lock: " & recordsBefore.join(" "))
      # POSITIVE find — everything below compares against a set proven
      # non-empty here, so "no new record" can never be read off an empty scan.
      check burnedRecord in recordsBefore
      check fileExists(store / burnedRecord.replace('/', DirSep))
      let burnedBodyBefore = readFile(store / burnedRecord.replace('/', DirSep))
      check burnedBodyBefore.contains(sideSeedSha)

      # ---- a sibling moves, then the membership repo is pushed -----------
      proc advanceSide(marker: string): string =
        writeFile(ws / "side" / (marker & ".txt"), marker & "\n")
        discard requireRun(git & " -C " & q(ws / "side") & " add -A")
        discard requireRun(git & " -C " & q(ws / "side") &
          " commit -qm " & q("side " & marker))
        discard requireRun(git & " -C " & q(ws / "side") & " push -q origin main")
        headOf(ws / "side")

      let sideMoved = advanceSide("moved")
      check sideMoved != sideSeedSha

      let first = membershipPush("touch side fragment")
      checkpoint("membership push #1: exit " & $first.code & "\n" & first.output)
      # The historical failure, in its own words. Kept as a NEGATIVE alongside
      # the exit-code assertion because the wording is the incident's
      # signature and a silently different refusal must not read as this one.
      check not first.output.contains("immutable lock record already exists")
      check first.code == 0

      let reportPath = ws / ".repro" / "build" / "reports" / "check-report.json"
      check fileExists(reportPath)
      let report = parseFile(reportPath)
      check report["failures"].len == 0

      # ---- the store is exactly as it was --------------------------------
      let recordsAfter = lockRecords(store)
      checkpoint("records after membership push: " & recordsAfter.join(" "))
      # No record was borrowed from another repo's directory...
      check recordsAfter == recordsBefore
      # ...and the published record is untouched history: it still pins the
      # sibling at the sha it was published with, not the one that just moved.
      check readFile(store / burnedRecord.replace('/', DirSep)) ==
        burnedBodyBefore
      check not readFile(store / burnedRecord.replace('/', DirSep))
        .contains(sideMoved)

      # ---- and it is not wedged -------------------------------------------
      # The property the incident actually lacked. Anchoring at the primary
      # repo survives at most one membership push; the second one recomputes
      # the same key, sees the siblings have moved again, and refuses.
      let sideMovedTwice = advanceSide("moved-again")
      check sideMovedTwice != sideMoved
      let second = membershipPush("touch side fragment again")
      checkpoint("membership push #2: exit " & $second.code & "\n" &
        second.output)
      check not second.output.contains("immutable lock record already exists")
      check second.code == 0
      check lockRecords(store) == recordsBefore

      # ---- a DECLARED repo still anchors normally --------------------------
      # The fix must not have turned the anchor off for everyone. Pushing a
      # declared repo writes the trigger-keyed record it always did — a
      # positive find at a path derived from that repo's own commit.
      let coreOldTip = requireRun(git & " -C " & q(ws / "core") &
        " rev-parse origin/main").strip()
      writeFile(ws / "core" / "work.txt", "core work\n")
      discard requireRun(git & " -C " & q(ws / "core") & " add -A")
      discard requireRun(git & " -C " & q(ws / "core") & " commit -qm \"core work\"")
      let coreNew = headOf(ws / "core")
      discard requireRun(git & " -C " & q(ws / "core") & " push -q origin main")
      let coreRefs = scratch / "core-refs.txt"
      writeFile(coreRefs,
        "refs/heads/main " & coreNew & " refs/heads/main " & coreOldTip & "\n")
      let corePush = run(reproAbs & " check --mode=pre-push --write-report" &
        " --workspace-root=" & q(ws) &
        " --current-repo=" & q(ws / "core") &
        " --pushed-refs=" & q(coreRefs) & " --json", cwd = ws / "core")
      checkpoint("declared-repo push: exit " & $corePush.code & "\n" &
        corePush.output)
      check corePush.code == 0
      let coreRecord = "locks/mix/core/" & coreNew & ".toml"
      let recordsFinal = lockRecords(store)
      checkpoint("records after declared-repo push: " & recordsFinal.join(" "))
      check coreRecord in recordsFinal
      check coreRecord notin recordsBefore
