## NPC-M9 verification `test_npc_m9_develop_overlay_lock`
## (Nimble-Package-Catalog.md §13.1, operator decision M9-P4; NPC-AREQ27).
##
## The index offers `results` 1.0.0 (requires `stew >= 0.1.0`), `stew`
## 0.1.0 and 0.2.0, and `extra` 1.0.0. The project requires `results`; its
## lock pins `results` 1.0.0 and `stew` 0.2.0. A recorded override of
## `results` names a checkout whose `.nimble` changes `stew`'s range to
## `< 0.2.0` and adds `extra >= 1.0`, which the index offers.
##
## 1. The build refuses: re-lock required, naming `repro nimble develop
##    --relock`.
## 2. `repro nimble develop --relock` writes `.repro/develop.lock`, whose
##    base is the `blake3` digest of the committed lock's bytes, prints the
##    rows that differ (`stew` moved, `extra` added, `results`' edges), and
##    leaves `repro.lock` byte-identical.
## 3. The build reads the overlay and says so: the checkout compiles
##    against `stew` 0.1.0 and `extra` 1.0.0.
## 4. `--locked` never reads it: the store trees the committed lock pins.
## 5. A new base (an edit of `repro.lock`) or a change of the checkout's
##    requirements makes the build refuse, naming what changed.
## 6. A requirement no index offers is refused by `--relock`, naming it.
## 7. A pushed commit that tracks the overlay is what the pre-push gate
##    refuses (``trackedDevelopOverlays``, in process).
## 8. With the override dropped, `--relock` removes the overlay.
##
## Falsifying mutation (recorded in the plan): reading an overlay whose
## `base` is not the committed lock's digest builds from a stale re-lock,
## and step 5 fails.
##
## No mock: a real index repository, the production `repro` binary, a real
## HTTPS mirror on loopback and the host's Nim and C compiler.

import std/[os, strutils, unittest]

import blake3
import ./nimble_m7_fixtures
import ./nimble_m9_fixtures

proc served(f: Fixture; mirror: Mirror; path: string;
            versions: seq[(string, seq[FileSpec])]): seq[PublishedSource] =
  ## One served repository with a tagged commit per version.
  let work = f.newRepo(path)
  var commits: seq[string]
  for i, (tagName, files) in versions:
    commits.add commit(work, files, message = tagName,
      date = 1_700_000_000'i64 + int64(i) * 100)
    tag(work, tagName)
  publish(work)
  for c in commits:
    let s = f.sourceOf(path, c)
    mirror.putSource(s)
    result.add s

suite "NPC-M9: the develop overlay lock":
  test "re-lock, read while it matches, refused when stale, never --locked":
    var c = newCliWorld("m9-overlay")
    let f = newFixture("m9-overlay", c.mirrorRoutes)
    let r = served(f, c.mirror, "arnetheduck/nim-results.git", @[("v1.0.0", @[
      nimbleFile("results", @["stew >= 0.1.0"]),
      file("src/results.nim",
        "import stew\nproc rstamp*(): string = \"CATALOG-R-\" & sstamp()\n")])])
    let s = served(f, c.mirror, "status-im/nim-stew.git", @[
      ("v0.1.0", @[nimbleFile("stew"),
        file("src/stew.nim", "proc sstamp*(): string = \"S010\"\n")]),
      ("v0.2.0", @[nimbleFile("stew"),
        file("src/stew.nim", "proc sstamp*(): string = \"S020\"\n")])])
    let e = served(f, c.mirror, "someone/extra.git", @[("v1.0.0", @[
      nimbleFile("extra"),
      file("src/extra.nim", "proc estamp*(): string = \"E100\"\n")])])
    discard c.w.publish(@[
      f.envelope("results", @[f.recordOf("results", r[0], "v1.0.0",
        @[req("stew", ">= 0.1.0")])], r[0]),
      f.envelope("stew", @[f.recordOf("stew", s[0], "v0.1.0"),
        f.recordOf("stew", s[1], "v0.2.0")], s[0]),
      f.envelope("extra", @[f.recordOf("extra", e[0], "v1.0.0")], e[0])],
      daysAgo(1), "generation 1", extraFiles = @[("nimble-sources.toml",
        sourceSetText(@[f.ipMirrorUrl("/mirror/")]))])
    let dir = c.w.writeCliProject("app", @[("results", "")],
      "import results\nwriteFile(\"build/app-out.txt\", rstamp())\n")
    let env = cliEnv(c.w, f)
    let refreshed = runRepro(env, dir, @["lock", "refresh", dir, "--inputs",
      dir / "repro.solver", "--provisioning"])
    checkpoint refreshed.output
    check refreshed.rc == 0
    let lockPath = dir / "repro.lock"
    let lockBytes = readFile(lockPath)
    checkpoint lockBytes
    check s[1].commit in lockBytes
    let outFile = dir / "build" / "app-out.txt"
    let catalog = runRepro(env, dir, BuildArgs)
    checkpoint catalog.output
    check catalog.rc == 0
    check readFile(outFile) == "CATALOG-R-S020"

    # The checkout: another range for stew, and extra.
    let sibling = parentDir(dir) / "nim-result"
    checkoutAt(sibling, f.url("arnetheduck/nim-results.git"), @[
      ("results.nimble", nimbleText(@["stew < 0.2.0", "extra >= 1.0"])),
      ("src/results.nim", "import stew, extra\nproc rstamp*(): string = " &
        "\"SIBLING-\" & sstamp() & \"-\" & estamp()\n")])
    let recorded = runRepro(env, dir, @["nimble", "develop", "results"])
    checkpoint recorded.output
    check recorded.rc == 0

    # 1. Refused until re-locked.
    let refused = runRepro(env, dir, BuildArgs)
    checkpoint refused.output
    check refused.rc != 0
    check "re-lock required" in refused.output
    check "repro nimble develop --relock" in refused.output
    check "+ requires \"stew < 0.2.0\"" in refused.output

    # 2. The re-lock.
    let overlay = dir / ".repro" / "develop.lock"
    let relocked = runRepro(env, dir, @["nimble", "develop", "--relock"])
    checkpoint relocked.output
    check relocked.rc == 0
    check fileExists(overlay)
    check readFile(lockPath) == lockBytes
    check "~ nimble:stew 0.2.0 -> 0.1.0" in relocked.output
    check "+ nimble:extra 1.0.0" in relocked.output
    check "~ nimble:results 1.0.0 depends on nimble:extra, nimble:stew" in
      relocked.output
    let overlayText = readFile(overlay)
    checkpoint overlayText
    let base = "blake3:" & toHexLower(blake3.digest(lockBytes))
    check ("# develop-overlay-base: " & base & "\n") in overlayText
    check "# develop-overlay-override: nimble:results\t" & sibling &
      "\trecorded override\tblake3:" in overlayText
    check s[0].commit in overlayText
    check e[0].commit in overlayText
    check s[1].commit notin overlayText

    # 3. Read while it matches.
    let fromOverlay = runRepro(env, dir, BuildArgs)
    checkpoint fromOverlay.output
    check fromOverlay.rc == 0
    check readFile(outFile) == "SIBLING-S010-E100"
    check ("building from the develop overlay lock (3 rows differ from " &
      lockPath & ")") in fromOverlay.output

    # 4. --locked never reads it.
    let lockedBuild = runRepro(env, dir, BuildArgs & @["--locked"])
    checkpoint lockedBuild.output
    check lockedBuild.rc == 0
    check readFile(outFile) == "CATALOG-R-S020"
    check ("--locked: the develop overlay lock " & overlay & " is not read") in
      lockedBuild.output

    # 5. A new base: the committed lock's bytes changed.
    writeFile(lockPath, lockBytes & "# edited\n")
    removeFile(outFile)
    let staleBase = runRepro(env, dir, BuildArgs)
    checkpoint staleBase.output
    check staleBase.rc != 0
    check "re-lock required" in staleBase.output
    check "the committed lock changed since the re-lock" in staleBase.output
    check not fileExists(outFile)
    writeFile(lockPath, lockBytes)
    # ... and a change of the checkout's requirements.
    writeFile(sibling / "results.nimble",
      nimbleText(@["stew < 0.2.0", "extra >= 0.9"]))
    let staleReqs = runRepro(env, dir, BuildArgs)
    checkpoint staleReqs.output
    check staleReqs.rc != 0
    check ("the requirements of " & sibling & " (nimble:results) changed " &
      "since the re-lock") in staleReqs.output

    # 6. A requirement no imported index offers.
    writeFile(sibling / "results.nimble",
      nimbleText(@["stew < 0.2.0", "extra >= 1.0", "ghostpkg"]))
    let ghost = runRepro(env, dir, @["nimble", "develop", "--relock"])
    checkpoint ghost.output
    check ghost.rc == 1
    check "requires \"ghostpkg\", which no imported index offers" in
      ghost.output
    check readFile(overlay) == overlayText
    writeFile(sibling / "results.nimble",
      nimbleText(@["stew < 0.2.0", "extra >= 1.0"]))

    # 7. A pushed commit tracking the overlay is refused by the gate.
    let pushed = c.w.root / "pushed"
    createDir(pushed / "sub" / ".repro")
    discard sh(["git", "init", "-q", "-b", "main", pushed])
    writeFile(pushed / "sub" / ".repro" / "develop.lock", overlayText)
    writeFile(pushed / "README", "x\n")
    gitCommitAll(pushed, "tracks the overlay")
    let sha = gitHead(pushed)
    let refs = c.w.root / "pushed-refs"
    writeFile(refs, "refs/heads/main " & sha & " refs/heads/main " &
      repeat('0', 40) & "\n")
    let tracked = trackedDevelopOverlays("git", pushed, refs)
    checkpoint $tracked
    check tracked.len == 1
    if tracked.len == 1:
      check tracked[0].sha == sha
      check tracked[0].path == "sub/.repro/develop.lock"
    discard sh(["git", "-C", pushed, "rm", "-q", "--cached",
      "sub/.repro/develop.lock"])
    removeFile(pushed / "sub" / ".repro" / "develop.lock")
    gitCommitAll(pushed, "untracked")
    writeFile(refs, "refs/heads/main " & gitHead(pushed) &
      " refs/heads/main " & sha & "\n")
    check trackedDevelopOverlays("git", pushed, refs).len == 0
    # Both commits pushed as a new ref: the tip no longer tracks it, and
    # the commit before it, which the push also publishes, still does.
    writeFile(refs, "refs/heads/main " & gitHead(pushed) &
      " refs/heads/main " & repeat('0', 40) & "\n")
    let published = trackedDevelopOverlays("git", pushed, refs)
    checkpoint $published
    check published.len == 1
    if published.len == 1:
      check published[0].sha == sha
      check published[0].path == "sub/.repro/develop.lock"

    # 8. No override, nothing to re-lock: the overlay is removed.
    removeFile(dir / ".repro" / "develop-overrides.toml")
    let dropped = runRepro(env, dir, @["nimble", "develop", "--relock"])
    checkpoint dropped.output
    check dropped.rc == 0
    check ("removed " & overlay) in dropped.output
    check not fileExists(overlay)
    check readFile(lockPath) == lockBytes
