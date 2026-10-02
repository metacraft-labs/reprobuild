## The shared-clone detector: what a checkout is told when something it names
## is gone, what it repairs, and what it refuses to touch.
##
## Spec: ``reprobuild-specs/spec/Shared-Clone-Pool-Integrity.md`` §4
## (SPI-AREQ-1, SPI-AREQ-3, SPI-AREQ-4, SPI-AREQ-5); milestone SPI-3.
##
## Design. Real ``git`` against real repositories: an upstream, a pool made by
## ``refreshSharedBare`` and a leaf cloned with ``git clone --reference`` and
## wired with ``wireAlternates``. Upstream then rewrites ``main`` and deletes
## ``feat``, and PURGES the old commits (reflog expiry + ``gc --prune=now``),
## so they exist nowhere. The pool is made to lose them too, deterministically
## (its packs are rebuilt from ``rev-list --objects --all``): this test is
## about what the detector does once objects are gone, not about the
## retention that normally prevents it (SPI-1 covers that). Presence probes
## run with ``GIT_NO_LAZY_FETCH=1`` so a probe cannot heal the fixture.
##
## Library cases, driving ``checkLeaf`` directly:
##
##   - ``purged_remote_ref_is_removed_with_message_a`` — a remote-tracking ref
##     whose commit is purged is removed, logged, and explained in exactly
##     §4.4's message A; afterwards ``git fetch`` succeeds even with
##     ``fetch.hideRefs`` taken away, so it is the repair that fixed it.
##   - ``local_work_on_purged_commits_gets_message_b_and_is_untouched`` — a
##     checked-out ``main`` whose own commit is purged, and a branch
##     ``mywork`` whose own commit is intact but whose parent is purged (in a
##     rewrite that kept every file's content), each get message B; no local
##     ref moves, and the remote-tracking refs whose commits those branches
##     need are NOT removed (message A would claim "none of your branches
##     depend on it"). Then the commands message B prints are run, as
##     printed, and they work: that is what "copy-pasteable" means
##     (SPI-AREQ-1). The spec's ``rebase --onto <new-base> <missing>
##     <branch>`` fails while the commit it names is missing ("invalid
##     upstream", measured on git 2.54.0), so the printed recovery grafts the
##     oldest own commit first.
##   - ``lost_content_gets_the_fetch_first_message_b`` — the same, but the
##     rewrite changed file contents, so files inside the user's own commit
##     existed only in the purged history. "Your own commits are intact"
##     would be false and the graft cannot replay them; the message says so
##     and offers the recovery that works — fetch the old commit from another
##     checkout, then the spec's ``rebase --onto`` — which the case runs.
##   - ``refillable_object_gets_no_message`` — an object gone from leaf and
##     pool that upstream still serves comes back through the chain; the
##     detector reports nothing and the ref stays.
##   - ``report_mode_changes_nothing`` — the same purged ref in report mode is
##     reported with its removal command and left in place.
##
## CLI case, driving the built ``repro`` against a workspace made by
## ``repro workspace init`` with ``REPRO_WORKSPACE_CLONES`` in the temp root:
##
##   - ``cli_health_status_and_sync_report_and_repair`` — three dangling
##     remote-tracking refs. ``repro health`` and ``repro workspace status``
##     report them and change nothing; ``status --fix`` removes them, and
##     with one put back ``health --fix`` removes it, and with another put
##     back ``repro workspace sync`` does, each printing message A; ``health``
##     is then ok. The init clone itself must have registered the leaf with
##     its pool.
##
## No mocks. Hermetic: one ``createTempDir`` root, a private
## ``GIT_CONFIG_GLOBAL``, ``file://`` URLs. Skip rule: ``git`` missing on
## PATH; the CLI case additionally needs the built ``repro``.

import std/[json, os, osproc, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_test_support
import shared_clones

proc q(value: string): string = quoteShell(value)

proc run(cwd: string; lazy: bool; args: varargs[string]):
    tuple[code: int; output: string] =
  var cmd = (if lazy: "env -u GIT_NO_LAZY_FETCH " else: "GIT_NO_LAZY_FETCH=1 ") &
    "git -C " & q(cwd)
  for a in args:
    cmd.add(" " & q(a))
  let res = execCmdEx(cmd)
  (code: res.exitCode, output: res.output.strip())

proc gitIn(cwd: string; args: varargs[string]): tuple[code: int;
                                                      output: string] =
  run(cwd, false, args)

proc must(cwd: string; args: varargs[string]): string =
  let res = gitIn(cwd, args)
  if res.code != 0:
    checkpoint("git " & args.join(" ") & " in " & cwd & " failed: " &
      res.output)
  doAssert res.code == 0, "fixture git command failed: " & args.join(" ")
  res.output

proc commitFile(work, name, body: string) =
  writeFile(work / name, body)
  discard must(work, "add", name)
  discard must(work, "commit", "-q", "-m", name)

proc has(repo, id: string): bool =
  gitIn(repo, "cat-file", "-e", id).code == 0

proc refExists(repo, refName: string): bool =
  gitIn(repo, "rev-parse", "-q", "--verify", refName).code == 0

proc erasePoolUnreachable(pool: string) =
  ## Rebuild the pool's object store from exactly what its refs reach.
  let objects = must(pool, "rev-list", "--objects", "--all")
  var ids = ""
  for line in objects.splitLines():
    let id = line.split(' ')[0].strip()
    if id.len > 0: ids.add(id & "\n")
  let packDir = pool / "objects" / "pack"
  let packed = execCmdEx("GIT_NO_LAZY_FETCH=1 git -C " & q(pool) &
    " pack-objects -q " & q(packDir / "fresh"), input = ids)
  doAssert packed.exitCode == 0, packed.output
  let keep = "fresh-" & packed.output.strip()
  for kind, f in walkDir(packDir):
    if not f.lastPathPart.startsWith(keep):
      removeFile(f)
  for kind, d in walkDir(pool / "objects"):
    if kind == pcDir and d.lastPathPart.len == 2:
      removeDir(d)

proc purge(repo: string) =
  ## Make an upstream forget every commit no ref reaches.
  discard must(repo, "reflog", "expire", "--expire=now", "--all")
  discard must(repo, "gc", "-q", "--prune=now")

const GlobalConfig = """
[user]
  name = SPI Tester
  email = tester@example.invalid
[init]
  defaultBranch = main
"""

proc useGlobalConfig(root: string) =
  writeFile(root / "gitconfig", GlobalConfig)
  putEnv("GIT_CONFIG_GLOBAL", root / "gitconfig")
  putEnv("GIT_CONFIG_NOSYSTEM", "1")

proc tearDown() =
  delEnv("GIT_CONFIG_GLOBAL")
  delEnv("GIT_CONFIG_NOSYSTEM")

type Fixture = object
  root, up, cache, pool, leaf, gitBin: string

proc setUp(root: string): Fixture =
  result.root = root
  result.gitBin = findExe("git")
  result.up = root / "up"
  result.cache = root / "cache"
  useGlobalConfig(root)
  createDir(result.up)
  discard must(result.up, "init", "-q")
  for i in 1 .. 3:
    commitFile(result.up, "m" & $i, $i & "\n")
  for br in ["feat", "keep"]:
    discard must(result.up, "checkout", "-q", "-b", br, "main")
    commitFile(result.up, br & ".txt", br & "\n")
  discard must(result.up, "checkout", "-q", "main")
  let created = refreshSharedBare(result.gitBin, result.cache,
    "file://" & result.up)
  doAssert created.ok, created.diagnostic
  result.pool = created.sharedBarePath
  result.leaf = root / "ws" / "up"
  createDir(result.leaf.parentDir)
  discard must(root, "clone", "-q", "--reference", result.pool,
    "file://" & result.up, result.leaf)
  let wired = wireAlternates(result.leaf, result.pool, result.gitBin)
  doAssert wired.ok, wired.diagnostic

proc refreshAndErase(f: Fixture) =
  let refreshed = refreshSharedBare(f.gitBin, f.cache, "file://" & f.up)
  doAssert refreshed.ok, refreshed.diagnostic
  erasePoolUnreachable(f.pool)

proc abbrev(id: string): string = id[0 ..< 7]

proc writeDanglingRef(repo, refName, id: string) =
  ## ``git update-ref`` refuses a missing object, which is the point of the
  ## fixture; write the loose ref the way an older checkout would hold it.
  let path = repo / ".git" / refName
  createDir(path.parentDir)
  writeFile(path, id & "\n")

type LocalWork = object
  own, featTip, oldMain, newMain, headsBefore: string

proc setUpLocalWork(f: Fixture; preserveContent: bool): LocalWork =
  ## A branch ``mywork`` with a commit of the leaf's own on top of upstream's
  ## ``feat``, and ``main`` checked out at upstream's main. Upstream then
  ## replaces main's last commit, deletes ``feat`` (and ``keep``, which also
  ## descends from the old main) and purges the old commits; the pool loses
  ## them. With ``preserveContent`` the rewrite keeps every file's content
  ## (a history cleanup that only rewrites commits): the new main carries the
  ## same ``m3`` and ``feat.txt``. Without it, those files' old contents
  ## existed only in the purged history.
  discard must(f.leaf, "checkout", "-q", "-b", "mywork", "origin/feat")
  commitFile(f.leaf, "mine.txt", "mine\n")
  result.own = must(f.leaf, "rev-parse", "HEAD")
  result.featTip = must(f.leaf, "rev-parse", "HEAD~1")
  discard must(f.leaf, "checkout", "-q", "main")
  result.oldMain = must(f.leaf, "rev-parse", "main")
  discard must(f.up, "reset", "-q", "--hard", "HEAD~1")
  if preserveContent:
    writeFile(f.up / "m3", "3\n")
    writeFile(f.up / "feat.txt", "feat\n")
    discard must(f.up, "add", "m3", "feat.txt")
    discard must(f.up, "commit", "-q", "-m", "m3 and feat, rewritten")
  else:
    commitFile(f.up, "m3-rewritten", "r\n")
  discard must(f.up, "branch", "-q", "-D", "feat", "keep")
  purge(f.up)
  result.newMain = must(f.up, "rev-parse", "main")
  refreshAndErase(f)
  doAssert not has(f.leaf, result.oldMain) and not has(f.leaf, result.featTip)
  doAssert has(f.leaf, result.own)
  result.headsBefore = must(f.leaf, "for-each-ref",
    "--format=%(objectname) %(refname)", "refs/heads/")

proc expectedMainMessage(f: Fixture; w: LocalWork): string =
  let l = f.leaf
  "repro: " & l & ": your branch 'main' points at " & abbrev(w.oldMain) &
    ", which no longer\n" &
  "exists here, in the shared cache (" & f.pool & "), or upstream.\n" &
  "  Why:  upstream rewrote its history and the old commits were removed everywhere this\n" &
  "        machine can reach. Commits that existed only on this ref and were never\n" &
  "        pushed are gone from this checkout too.\n" &
  "  Fix:  - if another machine or checkout still has " & abbrev(w.oldMain) &
    ", fetch it from there:\n" &
  "            git -C " & l & " fetch <that-checkout> " & w.oldMain & "\n" &
  "        - otherwise point it at the rewritten history (your working tree and\n" &
  "          index are left as they are):\n" &
  "            git -C " & l & " update-ref refs/heads/main " & w.newMain & "\n" &
  "          then, because it is checked out, re-read the index from it\n" &
  "          (files in the working tree are not touched):\n" &
  "            git -C " & l & " reset -q\n" &
  "          (" & abbrev(w.newMain) & " is upstream's current 'main', already in the shared cache)\n" &
  "  Nothing was changed."

proc recoverMain(f: Fixture; w: LocalWork) =
  ## Run message B's commands for ``main``, as printed, then -- the user's
  ## own decision, which the message leaves to them -- drop the old main's
  ## files from the working tree so the next recovery starts clean.
  for cmd in [@["update-ref", "refs/heads/main", w.newMain], @["reset", "-q"]]:
    let r = run(f.leaf, true, cmd)
    checkpoint("git " & cmd.join(" ") & ": " & $r.code & " " & r.output)
    doAssert r.code == 0
  doAssert must(f.leaf, "rev-parse", "main") == w.newMain
  discard must(f.leaf, "checkout", "-q", "--", ".")
  discard must(f.leaf, "clean", "-fdq")

suite "SPI-3: detector, repair and messages":

  test "purged_remote_ref_is_removed_with_message_a":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    else:
      let root = createTempDir("repro-spi3-a-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      let old = must(f.leaf, "rev-parse", "refs/remotes/origin/feat")
      discard must(f.up, "branch", "-q", "-D", "feat")
      purge(f.up)
      refreshAndErase(f)
      doAssert not has(f.leaf, old) and not has(f.up, old)

      let report = checkLeaf(f.gitBin, f.leaf, lcmRepair, f.cache)
      check report.pool == f.pool
      check report.registered and report.configured
      var stale: seq[LeafFinding]
      for x in report.findings:
        check x.kind in {lfkStaleRemoteRef}
        if x.kind == lfkStaleRemoteRef: stale.add(x)
      check stale.len == 1
      let logPath = f.leaf / ".git" / "repro" / "dropped-refs.log"
      # §4.4 message A, with the leaf, ref, id and pool filled in. The pool
      # path is named too: §4.4 requires it of every message.
      let expected =
        "repro: " & f.leaf & ": removed refs/remotes/origin/feat (" &
          abbrev(old) & ")\n" &
        "  Upstream rewrote or deleted that branch, and the old commit no longer exists\n" &
        "  upstream or in the shared cache (" & f.pool & "). The ref was only a copy of upstream; none of\n" &
        "  your branches depend on it. The next fetch recreates it if the branch still exists.\n" &
        "  Logged in " & logPath
      if stale.len == 1:
        check stale[0].removed
        check stale[0].message == expected
        checkpoint(stale[0].message)
      check not refExists(f.leaf, "refs/remotes/origin/feat")
      check fileExists(logPath)
      let logLine = readFile(logPath).strip()
      check logLine.split('\t').len == 4
      check "\trefs/remotes/origin/feat\t" & old & "\t" & f.pool in logLine
      # The repair, not fetch.hideRefs, is what makes the next fetch work.
      discard must(f.leaf, "config", "--unset-all", "fetch.hideRefs")
      let fetched = run(f.leaf, true, "fetch", "origin")
      checkpoint("fetch after repair: " & fetched.output)
      check fetched.code == 0

  test "local_work_on_purged_commits_gets_message_b_and_is_untouched":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    else:
      let root = createTempDir("repro-spi3-b-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      let w = setUpLocalWork(f, preserveContent = true)
      let report = checkLeaf(f.gitBin, f.leaf, lcmRepair, f.cache)
      var byRef: seq[(string, LeafFinding)]
      var removedRemote: seq[string]
      for x in report.findings:
        if x.message.len == 0:
          continue
        checkpoint(x.message)
        if x.kind == lfkStaleRemoteRef:
          if x.removed: removedRemote.add(x.refName)
        else:
          byRef.add((x.refName, x))
      # Message B for exactly the two refs of the user's. The remote-tracking
      # refs naming the same commits are kept for message B to explain; only
      # origin/keep, which no branch of the user's needs, is removed.
      check byRef.len == 2
      check removedRemote == @["refs/remotes/origin/keep"]
      check must(f.leaf, "for-each-ref", "--format=%(objectname) %(refname)",
        "refs/heads/") == w.headsBefore
      check refExists(f.leaf, "refs/remotes/origin/main")
      check refExists(f.leaf, "refs/remotes/origin/feat")

      let l = f.leaf
      let cache = "the shared cache (" & f.pool & ")"
      let expectedMywork =
        "repro: " & l & ": your branch 'mywork' is built on " & abbrev(w.featTip) &
          ", which no\n" &
        "longer exists here, in " & cache & ", or upstream.\n" &
        "  Why:  upstream rewrote its history and the old commits were removed everywhere this\n" &
        "        machine can reach. Your own commits on 'mywork' are intact; their parents are gone.\n" &
        "  Fix:  - if another machine or checkout still has " & abbrev(w.featTip) &
          ", fetch it from there:\n" &
        "            git -C " & l & " fetch <that-checkout> " & w.featTip & "\n" &
        "        - otherwise move your commits onto the rewritten history:\n" &
        "            git -C " & l & " replace --graft " & w.own & " <new-base>\n" &
        "            git -C " & l & " rebase --force-rebase <new-base> mywork\n" &
        "            git -C " & l & " replace -d " & w.own & "\n" &
        "          (<new-base> is the rewritten counterpart of " & abbrev(w.featTip) &
          ", usually origin/<branch>)\n" &
        "  Nothing was changed."
      for (refName, x) in byRef:
        if refName == "refs/heads/mywork":
          check x.kind == lfkLocalHistoryMissing
          check x.objectId == w.featTip
          check x.childId == w.own
          check x.message == expectedMywork
        elif refName == "refs/heads/main":
          check x.kind == lfkLocalTipMissing
          check x.message == expectedMainMessage(f, w)
        else:
          checkpoint("unexpected finding for " & refName)
          check false

      # The printed recovery commands work as printed, run as a user runs
      # them (lazy fetching enabled). ``main`` first: its command needs
      # nothing but the pool's current tip.
      recoverMain(f, w)
      # Then mywork, with <new-base> = the rewritten counterpart of feat,
      # which in this rewrite is the new main.
      for cmd in [@["replace", "--graft", w.own, w.newMain],
                  @["rebase", "-q", "--force-rebase", w.newMain, "mywork"],
                  @["replace", "-d", w.own]]:
        let r = run(f.leaf, true, cmd)
        checkpoint("git " & cmd.join(" ") & ": " & $r.code & " " & r.output)
        check r.code == 0
      check must(f.leaf, "rev-parse", "mywork~1") == w.newMain
      check must(f.leaf, "diff", "--name-only", "mywork~1", "mywork") ==
        "mine.txt"
      check readFile(f.leaf / "mine.txt") == "mine\n"

  test "lost_content_gets_the_fetch_first_message_b":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    else:
      let root = createTempDir("repro-spi3-b2-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      # Another checkout that still has the old history.
      let other = root / "other"
      discard must(root, "clone", "-q", "file://" & f.up, other)
      let w = setUpLocalWork(f, preserveContent = false)
      let report = checkLeaf(f.gitBin, f.leaf, lcmRepair, f.cache)
      var mywork: seq[LeafFinding]
      for x in report.findings:
        if x.refName == "refs/heads/mywork": mywork.add(x)
      check mywork.len == 1
      let l = f.leaf
      let expected =
        "repro: " & l & ": your branch 'mywork' is built on " & abbrev(w.featTip) &
          ", which no\n" &
        "longer exists here, in the shared cache (" & f.pool & "), or upstream.\n" &
        "  Why:  upstream rewrote its history and the old commits were removed everywhere this\n" &
        "        machine can reach. Your own commits on 'mywork' are still here, but some of\n" &
        "        the files in them existed only in that old history and are gone as well, so\n" &
        "        they cannot be replayed onto the rewritten history from this machine alone.\n" &
        "  Fix:  - fetch " & abbrev(w.featTip) & " from another machine or checkout that still has it:\n" &
        "            git -C " & l & " fetch <that-checkout> " & w.featTip & "\n" &
        "          and then move your commits onto the rewritten history:\n" &
        "            git -C " & l & " rebase --onto <new-base> " & w.featTip & " mywork\n" &
        "          (<new-base> is the rewritten counterpart of " & abbrev(w.featTip) &
          ", usually origin/<branch>)\n" &
        "  Nothing was changed."
      if mywork.len == 1:
        checkpoint(mywork[0].message)
        check mywork[0].message == expected
      # The commands, as printed, with <that-checkout> = the other clone.
      recoverMain(f, w)
      for cmd in [@["fetch", "-q", other, w.featTip],
                  @["rebase", "-q", "--onto", w.newMain, w.featTip, "mywork"]]:
        let r = run(f.leaf, true, cmd)
        checkpoint("git " & cmd.join(" ") & ": " & $r.code & " " & r.output)
        check r.code == 0
      check must(f.leaf, "rev-parse", "mywork~1") == w.newMain
      check must(f.leaf, "diff", "--name-only", "mywork~1", "mywork") ==
        "mine.txt"

  test "refillable_object_gets_no_message":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    else:
      let root = createTempDir("repro-spi3-refill-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      let keepTip = must(f.leaf, "rev-parse", "refs/remotes/origin/keep")
      # The pool loses keep; upstream still has it.
      discard must(f.pool, "update-ref", "-d", "refs/heads/keep")
      erasePoolUnreachable(f.pool)
      doAssert not has(f.leaf, keepTip) and has(f.up, keepTip)
      let report = checkLeaf(f.gitBin, f.leaf, lcmRepair, f.cache)
      var refilled = 0
      for x in report.findings:
        check x.message.len == 0
        if x.kind == lfkRefilled: inc refilled
      check refilled == 1
      check refExists(f.leaf, "refs/remotes/origin/keep")
      check has(f.leaf, keepTip)
      check has(f.pool, keepTip)

  test "report_mode_changes_nothing":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    else:
      let root = createTempDir("repro-spi3-report-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      let old = must(f.leaf, "rev-parse", "refs/remotes/origin/feat")
      discard must(f.up, "branch", "-q", "-D", "feat")
      purge(f.up)
      refreshAndErase(f)
      let report = checkLeaf(f.gitBin, f.leaf, lcmReport, f.cache)
      var stale = 0
      for x in report.findings:
        if x.kind == lfkStaleRemoteRef:
          inc stale
          check not x.removed
          check ("git -C " & f.leaf & " update-ref -d refs/remotes/origin/feat " &
            old) in x.message
      check stale == 1
      check refExists(f.leaf, "refs/remotes/origin/feat")
      check not fileExists(f.leaf / ".git" / "repro" / "dropped-refs.log")

# ---- CLI --------------------------------------------------------------------

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc projectToml(libUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"spiproj\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"lib-origin\"\nfetch = \"" & libUrl & "\"\n\n" &
  "includes = [\n  \"repos/lib.toml\",\n]\n"

const libFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib"
path = "lib"
remote = "lib-origin"
revision = "main"
"""

suite "SPI-3: the detector behind repro health, workspace status and sync":

  test "cli_health_status_and_sync_report_and_repair":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    else:
      let reproBin = requireBinary(repoRoot() / "build" / "bin" /
        addFileExt("repro", ExeExt), "reprobuild.apps.repro")
      let root = createTempDir("repro-spi3-cli-", "")
      defer:
        tearDown()
        removeDir(root)
      useGlobalConfig(root)
      let gitBin = findExe("git")
      # Upstream: a bare origin with main and three branches.
      let origin = root / "origin.git"
      let work = root / "seed"
      discard must(root, "init", "-q", "--bare", origin)
      createDir(work)
      discard must(work, "init", "-q")
      commitFile(work, "a", "a\n")
      discard must(work, "remote", "add", "origin", origin)
      discard must(work, "push", "-q", "origin", "main")
      for br in ["f1", "f2", "f3"]:
        discard must(work, "checkout", "-q", "-b", br, "main")
        commitFile(work, br, br & "\n")
        discard must(work, "push", "-q", "origin", br)
      discard must(work, "checkout", "-q", "main")
      let ws = root / "ws"
      createDir(ws / "projects")
      createDir(ws / "repos")
      writeFile(ws / "projects" / "spiproj.toml",
        projectToml(fileUrl(origin)))
      writeFile(ws / "repos" / "lib.toml", libFragmentToml)
      let env = @[("REPRO_WORKSPACE_CLONES", root / "cache")]
      let init = runShell(shellCommand(@[reproBin, "workspace", "init",
        "spiproj", "--workspace-root=" & ws], env))
      checkpoint("init: " & init.output)
      check init.code == 0
      let leaf = ws / "lib"
      var pools: seq[string]
      for p in walkDirRec(root / "cache", yieldFilter = {pcDir}):
        if p.endsWith(".git") and dirExists(p / "objects"): pools.add(p)
      check pools.len == 1
      let pool = pools[0]
      # The init clone registered the leaf and configured it.
      check readBorrowers(pool) == @[leaf]
      check must(leaf, "config", "--get-all", "fetch.hideRefs") ==
        LeafHiddenFetchRefs
      var tips: seq[string]
      for br in ["f1", "f2", "f3"]:
        tips.add(must(leaf, "rev-parse", "refs/remotes/origin/" & br))
      # Upstream deletes and purges the three; the pool loses them.
      for br in ["f1", "f2", "f3"]:
        discard must(origin, "update-ref", "-d", "refs/heads/" & br)
      purge(origin)
      for br in ["f1", "f2", "f3"]:
        discard must(pool, "update-ref", "-d", "refs/heads/" & br)
      erasePoolUnreachable(pool)
      for t in tips: doAssert not has(leaf, t)

      # health: report-only.
      let health = runShell(shellCommand(@[reproBin, "health", "spiproj",
        "--workspace-root=" & ws], env))
      checkpoint("health: " & health.output)
      check "shared-clone-leaves" in health.output
      check "3 stale remote-tracking ref(s)" in health.output
      check "refs/remotes/origin/f1 (" & abbrev(tips[0]) & ") is a stale copy of upstream" in
        health.output
      for br in ["f1", "f2", "f3"]:
        check refExists(leaf, "refs/remotes/origin/" & br)

      # status --json: report-only.
      let status = runShell(shellCommand(@[reproBin, "workspace", "status",
        "spiproj", "--workspace-root=" & ws, "--json"], env))
      checkpoint("status: " & status.output)
      check status.code == 0
      var findings = 0
      try:
        let start = status.output.find('{')
        let js = parseJson(status.output[start .. ^1])
        for x in js["sharedCloneFindings"]:
          check x["kind"].getStr() == "lfkStaleRemoteRef"
          check not x["removed"].getBool()
          inc findings
      except CatchableError as e:
        checkpoint("status JSON: " & e.msg)
      check findings == 3
      for br in ["f1", "f2", "f3"]:
        check refExists(leaf, "refs/remotes/origin/" & br)

      # status --fix removes all three.
      let fixed = runShell(shellCommand(@[reproBin, "workspace", "status",
        "spiproj", "--workspace-root=" & ws, "--fix"], env))
      checkpoint("status --fix: " & fixed.output)
      for i, br in ["f1", "f2", "f3"]:
        check ("removed refs/remotes/origin/" & br & " (" & abbrev(tips[i]) &
          ")") in fixed.output
        check not refExists(leaf, "refs/remotes/origin/" & br)
      # health --fix: one dangling ref back; removed and announced.
      writeDanglingRef(leaf, "refs/remotes/origin/f2", tips[1])
      let hfix = runShell(shellCommand(@[reproBin, "health", "spiproj",
        "--workspace-root=" & ws, "--fix"], env))
      checkpoint("health --fix: " & hfix.output)
      check "fix: removed refs/remotes/origin/f2" in hfix.output
      check not refExists(leaf, "refs/remotes/origin/f2")
      # sync: the detector runs in the leaf before its fetch.
      writeDanglingRef(leaf, "refs/remotes/origin/f3", tips[2])
      let sync = runShell(shellCommand(@[reproBin, "workspace", "sync",
        "spiproj", "--workspace-root=" & ws], env))
      checkpoint("sync: " & sync.output)
      check ("removed refs/remotes/origin/f3 (" & abbrev(tips[2]) & ")") in
        sync.output
      check "bad object" notin sync.output
      check "did not send all necessary objects" notin sync.output
      check not refExists(leaf, "refs/remotes/origin/f3")
      let after = runShell(shellCommand(@[reproBin, "health", "spiproj",
        "--workspace-root=" & ws], env))
      checkpoint("health after: " & after.output)
      var okLine = false
      for line in after.output.splitLines():
        if line.startsWith("shared-clone-leaves") and " ok " in line:
          okLine = true
      check okLine
