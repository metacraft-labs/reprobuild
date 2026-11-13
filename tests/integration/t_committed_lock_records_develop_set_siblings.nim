## The committed ``repro.lock`` records the revisions of the develop-set
## siblings a repo is built and tested against
## (Unified-Locking-And-Hooks.md §14, "The default: the committed lock records
## the develop set") — and that set is exactly what the repo's ``repro.nim``
## derives, transitively (owner decision 2026-11-05, §14.2 / §14.9: "the lock
## file includes only the transitive set of dependencies derived from
## repro.nim files").
##
## WHY THIS EXISTS. A lock used to get a self-only ``deps`` from ``repro lock
## refresh`` for siblings that reach the build outside the solved graph, so
## "which sibling revisions was this commit built against" had no committed
## answer. That gap was first closed by folding the workspace manifest's
## ``depends`` closure into the lock; the owner then decided that a manifest
## declares no dependency at all, so the gap is closed by declaring the
## sibling in ``repro.nim`` (``uses:``), and this test now asserts both halves:
## the recipe's transitive closure IS recorded, a manifest edge is NOT.
##
## Fixture (built ``./build/bin/repro``, black-box; real git, real filesystem):
##
##   <scratch>/workspace/                 a manifest workspace
##     projects/app.toml, repos/*.toml    membership only; app's fragment also
##                                        carries a legacy ``depends = ["lib-d"]``
##     app/    repro.nim `uses: "lib-b"`  (git, published)
##     lib-b/  repro.nim `uses: "lib-c"`  lib-c/ and lib-d/ carry library
##                                        recipes; lib-d is used by nobody
##
## Asserts (test 1):
##   1. ``repro lock refresh app`` records lib-b AND lib-c (the TRANSITIVE
##      closure of the recipes' ``uses:``) as ``deps`` entries named
##      ``lib-b`` / ``lib-c`` with VCS coordinates, the sibling's HEAD as
##      ``revision`` and a ``git-sha1:<HEAD>`` integrity, and no checkout
##      ``path`` (a lock pins identity only — Workspace-Manifests.md §"The
##      committed lock carries the full set (schema v3)"); the root entry
##      (``self = "true"``) ``depends`` on lib-b, its direct dependency, and
##      lib-b's entry on lib-c (the lock records the graph). lib-d — named only by the
##      app fragment's ``depends`` — is NOT recorded.
##   2. After lib-b advances by a published commit, a second refresh re-pins
##      lib-b at its new HEAD (an observation of the checkout, not a copy of the
##      old pin).
##   3. Outside a workspace: a fresh standalone clone of app with no sibling
##      checkouts cannot be refreshed — app's recipe uses lib-b, whose recipe
##      is absent, so the solve would be partial — and the refresh refuses
##      (exit 5) leaving the committed pins byte-identical. A refresh must never
##      silently DROP a sibling pin merely because it cannot see the sibling.
##      (This case used to assert a successful carry-forward of the committed
##      pins: app then had a `repro.solver` sidecar, which uses no sibling.
##      With the dependency declared in app's recipe, the solve needs lib-b's
##      recipe, so the refusal is what protects the pins here.)
##   4. A dev-env-only recipe (a `repro.nim` with nothing to solve and no
##      ``uses:``) still gets a committed lock instead of "no solver inputs
##      found" — and records no sibling, because it declares none.
##
## Test 2 (removals): a recipe that stops using two siblings makes the next
## refresh drop their pins and name each, with the reason "no repro.nim ...
## declares", from the HEAD-committed lock as well as the working copy. A
## manifest checkout that is BEHIND its upstream no longer matters: the
## stale-manifest refusal (exit 6) is retired with the manifest edges it
## guarded, ``behindManifests`` stays empty, and ``--allow-stale-manifest`` is
## accepted with a deprecation notice. This replaces the test that expected
## exit 6.
##
## Test 3 (targeted re-pin over a catalog alias): a working lock that names a
## catalog checkout by its MEMBERSHIP alias (`catalog-y`, kept at
## `catalog-x`) is re-pinned with `--repin`; the final merged set keeps the
## alias, drops the generated `catalog-x` and names that committed pin. It
## used to be refused by the stale-manifest rule (exit 6) first; now it writes.
##
## Falsifiability: against the manifest-folding writer (reprobuild
## ``01f362f1``) assertion (1)'s ``lib-d notin body`` fails (the fragment edge
## is recorded) and test 2 exits 6.
##
## NO MOCKS. Every repository is a real local git repository with a real bare
## origin; the manifest is a real on-disk manifest the production resolver
## reads; every recipe is compiled by the real provider path. Nothing touches
## $HOME or the network.
##
## Skip rule: ``git`` missing on PATH.

import std/[os, osproc, strutils, tempfiles, unittest, json]
import repro_test_support/reasoned_skip

import repro_test_support
import repro_test_support/recipe_dependencies
import repro_workspace_manifests

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc capture(command, scratch: string): tuple[code: int; output, errors: string] =
  let outputPath = scratch / "stdout.txt"
  let errorPath = scratch / "stderr.txt"
  let child = execCmdEx(command & " > " & q(outputPath) & " 2> " & q(errorPath))
  (child.exitCode, readFile(outputPath), readFile(errorPath))

proc requireGit(command: string; cwd = ""): string =
  let res = runCmd(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

const fixtureUses = [("app", @["lib-b"]), ("lib-b", @["lib-c"])]
  ## The recipes' `uses:` at seed time; every other repo is a library that
  ## uses nothing.

proc usesOf(name: string): seq[string] =
  for (repo, uses) in fixtureUses:
    if repo == name: return uses

proc configureIdentity(gitBin, work: string) =
  discard requireGit(q(gitBin) & " -C " & q(work) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(work) &
    " config user.name \"Lock Tester\"")

proc seedPublished(gitBin, scratch, workspace, name: string): string =
  ## A bare origin plus a checkout of it at ``workspace/name`` with one
  ## published commit. Returns the origin path.
  let origin = scratch / ("origin-" & name & ".git")
  let work = workspace / name
  discard requireGit(q(gitBin) & " init --bare -b main " & q(origin))
  discard requireGit(q(gitBin) & " clone " & q(fileUrl(origin)) & " " & q(work))
  configureIdentity(gitBin, work)
  writeFile(work / "README.md", name & " fixture\n")
  # The app/lib repos carry the recipes that declare the graph; any other
  # seeded repo (a catalog) keeps exactly the content its case writes.
  if name == "app" or name.startsWith("lib-"):
    writeDependencyRecipe(work, usesOf(name), library = name != "app")
  discard requireGit(q(gitBin) & " -C " & q(work) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(work) & " commit -m seed")
  discard requireGit(q(gitBin) & " -C " & q(work) & " push origin main")
  origin

proc fragment(name: string; depends: seq[string]): string =
  result = "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\n" &
    "name = \"" & name & "\"\npath = \"" & name & "\"\n" &
    "remote = \"" & name & "-origin\"\nmainline = \"main\"\n"
  if depends.len > 0:
    result.add("depends = [")
    for i, d in depends:
      if i > 0: result.add(", ")
      result.add("\"" & d & "\"")
    result.add("]\n")

proc headOf(gitBin, work: string): string =
  requireGit(q(gitBin) & " -C " & q(work) & " rev-parse HEAD").strip()

proc depLineFor(lockBody, name: string): string =
  ## The inline-table text of the ``deps`` entry named ``name``, or "" when
  ## there is none. Entries are found by NAME: a lock records no checkout
  ## path.
  # After `deps = [`: a `packages` entry starts with the same prefix.
  let at = lockBody.find("{ name = \"" & name & "\"",
    max(0, lockBody.find("deps = [")))
  if at < 0: return ""
  let close = lockBody.find('}', at)
  if close < 0: return ""
  lockBody[at .. close]

proc rootLineFor(lockBody: string): string =
  ## The inline-table text of the lock's own entry (``self = "true"``).
  let at = lockBody.find("self = \"true\"")
  if at < 0: return ""
  let open = lockBody.rfind('{', 0, at)
  let close = lockBody.find('}', at)
  if open < 0 or close < 0: return ""
  lockBody[open .. close]

suite "the committed lock records the develop-set siblings":

  test "t_committed_lock_records_develop_set_siblings":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      let reproBin = reproBinary()
      let scratch = createTempDir("repro-lock-develop-set-", "")
      defer: removeDir(scratch)
      let workspace = scratch / "workspace"
      createDir(workspace)

      var origins: seq[(string, string)] = @[]
      for name in ["app", "lib-b", "lib-c", "lib-d"]:
        origins.add((name, seedPublished(gitBin, scratch, workspace, name)))

      createDir(workspace / "projects")
      createDir(workspace / "repos")
      var project = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "[project]\nname = \"app\"\n" &
        "\n"
      for (name, origin) in origins:
        project.add("[[remote]]\nname = \"" & name & "-origin\"\nfetch = \"" &
          fileUrl(origin) & "\"\n\n")
      project.add("includes = [\n  \"repos/app.toml\",\n" &
        "  \"repos/lib-b.toml\",\n  \"repos/lib-c.toml\",\n" &
        "  \"repos/lib-d.toml\",\n]\n")
      writeFile(workspace / "projects" / "app.toml", project)
      # The legacy `depends` key on app names lib-d; nothing in a recipe does.
      writeFile(workspace / "repos" / "app.toml", fragment("app", @["lib-d"]))
      writeFile(workspace / "repos" / "lib-b.toml", fragment("lib-b", @[]))
      writeFile(workspace / "repos" / "lib-c.toml", fragment("lib-c", @[]))
      writeFile(workspace / "repos" / "lib-d.toml", fragment("lib-d", @[]))
      writeWorkspaceBranch(workspace, project = "app", branch = "main")

      let app = workspace / "app"
      let libBHead = headOf(gitBin, workspace / "lib-b")
      let libCHead = headOf(gitBin, workspace / "lib-c")

      # ---- (1) the transitive develop set is recorded, and nothing else. ----
      let refresh = runCmd(q(reproBin) & " lock refresh " & q(app))
      checkpoint(refresh.output)
      check refresh.code == 0
      let body = readFile(app / "repro.lock")
      checkpoint(body)
      let libB = depLineFor(body, "lib-b")
      let libC = depLineFor(body, "lib-c")
      check libB.len > 0
      check libC.len > 0
      check "name = \"lib-b\"" in libB
      check "coord_kind = \"vcs\"" in libB
      check ("revision = \"" & libBHead & "\"") in libB
      check ("integrity = \"git-sha1:" & libBHead & "\"") in libB
      check ("revision = \"" & libCHead & "\"") in libC
      check ("integrity = \"git-sha1:" & libCHead & "\"") in libC
      check "path =" notin body
      check depLineFor(body, "lib-d").len == 0
      check "lib-d" notin body
      # The lock records the GRAPH: the root entry's `depends` names app's
      # DIRECT dependency, and lib-b's entry names its own (§14.2). Both
      # entries are still recorded, so the set is the transitive closure.
      let root = rootLineFor(body)
      check "depends = \"lib-b\"" in root
      check "depends = \"lib-c\"" in libB
      check "depends = \"\"" in libC

      # ---- (2) a sibling that moved is re-pinned from its checkout. ----
      let libBDir = workspace / "lib-b"
      writeFile(libBDir / "change.txt", "advance\n")
      discard requireGit(q(gitBin) & " -C " & q(libBDir) & " add change.txt")
      discard requireGit(q(gitBin) & " -C " & q(libBDir) & " commit -m advance")
      discard requireGit(q(gitBin) & " -C " & q(libBDir) & " push origin main")
      let libBNext = headOf(gitBin, libBDir)
      check libBNext != libBHead
      let again = runCmd(q(reproBin) & " lock refresh " & q(app))
      checkpoint(again.output)
      check again.code == 0
      let body2 = readFile(app / "repro.lock")
      check ("revision = \"" & libBNext & "\"") in depLineFor(body2, "lib-b")
      check ("revision = \"" & libCHead & "\"") in depLineFor(body2, "lib-c")

      # Commit + publish the lock so a fresh clone carries it.
      discard requireGit(q(gitBin) & " -C " & q(app) & " add repro.lock")
      discard requireGit(q(gitBin) & " -C " & q(app) & " commit -m lock")
      discard requireGit(q(gitBin) & " -C " & q(app) & " push origin main")

      # ---- (3) outside any workspace, with no sibling checkouts, a refresh
      # never drops the committed sibling pins: the recipe that names lib-b
      # cannot be solved without lib-b's recipe, so the refresh REFUSES (exit
      # 5) and the lock is left byte-identical.
      let lone = scratch / "standalone" / "app"
      createDir(scratch / "standalone")
      var appOrigin = ""
      for (name, origin) in origins:
        if name == "app": appOrigin = origin
      discard requireGit(q(gitBin) & " clone " & q(fileUrl(appOrigin)) & " " &
        q(lone))
      configureIdentity(gitBin, lone)
      check not dirExists(scratch / "standalone" / "lib-b")
      let committedLone = readFile(lone / "repro.lock")
      let loneRefresh = runCmd(q(reproBin) & " lock refresh " & q(lone))
      checkpoint(loneRefresh.output)
      check loneRefresh.code == 5
      check "lib-b" in loneRefresh.output
      let body3 = readFile(lone / "repro.lock")
      check body3 == committedLone
      check ("revision = \"" & libBNext & "\"") in depLineFor(body3, "lib-b")
      check ("revision = \"" & libCHead & "\"") in depLineFor(body3, "lib-c")

      # ---- (4) a recipe with nothing to solve still gets a lock, and records
      # no sibling: it uses none.
      let recipeOnly = workspace / "app"
      removeFile(recipeOnly / "repro.lock")
      writeFile(recipeOnly / "repro.nim",
        "import repro_project_dsl\nimport repro_dsl_stdlib/foreign_env\n\n" &
        "package appEnvironment:\n  devEnv:\n    useFlakeDevShell()\n")
      let noSolve = runCmd(q(reproBin) & " lock refresh " & q(recipeOnly))
      checkpoint(noSolve.output)
      check noSolve.code == 0
      check "no solver inputs found" notin noSolve.output
      let body4 = readFile(recipeOnly / "repro.lock")
      checkpoint(body4)
      check depLineFor(body4, "lib-b").len == 0
      check depLineFor(body4, "lib-d").len == 0
      check "packages = []" in body4

  test "refresh names removed committed pins and ignores behind manifests":
    let gitBin = findExe("git")
    require gitBin.len > 0
    let reproBin = reproBinary()
    let scratch = createTempDir("repro-lock-develop-set-", "")
    defer: removeDir(scratch)
    let workspace = scratch / "workspace"
    createDir(workspace)

    var origins: seq[(string, string)] = @[]
    for name in ["app", "lib-b", "lib-c", "lib-d", "lib-e"]:
      origins.add((name, seedPublished(gitBin, scratch, workspace, name)))

    createDir(workspace / "projects")
    createDir(workspace / "repos")
    var project = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
      "[project]\nname = \"app\"\n" &
      "\n"
    for (name, origin) in origins:
      project.add("[[remote]]\nname = \"" & name & "-origin\"\nfetch = \"" &
        fileUrl(origin) & "\"\n\n")
    project.add("includes = [\n  \"repos/app.toml\",\n" &
      "  \"repos/lib-b.toml\",\n  \"repos/lib-c.toml\",\n" &
      "  \"repos/lib-d.toml\",\n  \"repos/lib-e.toml\",\n]\n")
    writeFile(workspace / "projects" / "app.toml", project)
    for name in ["app", "lib-b", "lib-c", "lib-d", "lib-e"]:
      writeFile(workspace / "repos" / (name & ".toml"), fragment(name, @[]))
    writeWorkspaceBranch(workspace, project = "app", branch = "main")

    let app = workspace / "app"
    # The flat manifest checkout is BEHIND a locally known newer commit — the
    # state that used to refuse a removal (exit 6). It is irrelevant now.
    discard requireGit(q(gitBin) & " init -q -b main " & q(workspace))
    configureIdentity(gitBin, workspace)
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " add projects repos")
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " commit -qm narrow")
    let narrow = headOf(gitBin, workspace)
    writeFile(workspace / "repos/README.md", "a newer manifest commit\n")
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " add repos")
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " commit -qm wider")
    let wider = headOf(gitBin, workspace)
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " remote add origin " & q(scratch / "unused-origin"))
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " update-ref refs/remotes/origin/main " & wider)
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " config branch.main.remote origin")
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " config branch.main.merge refs/heads/main")
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " reset -q --hard " & narrow)

    # app uses lib-b, lib-d and lib-e; the committed lock pins all of them.
    writeDependencyRecipe(app, ["lib-b", "lib-d", "lib-e"], library = false)
    let initial = runCmd(q(reproBin) & " lock refresh " & q(app))
    checkpoint(initial.output)
    require initial.code == 0
    let original = readFile(app / "repro.lock")
    require depLineFor(original, "lib-d").len > 0
    require depLineFor(original, "lib-e").len > 0
    discard requireGit(q(gitBin) & " -C " & q(app) & " add -A")
    discard requireGit(q(gitBin) & " -C " & q(app) & " commit -qm lock")

    # The recipe stops using lib-d and lib-e: the next refresh drops both
    # pins, names each with its reason, and does not consult the manifest.
    writeDependencyRecipe(app, ["lib-b"], library = false)
    discard requireGit(q(gitBin) & " -C " & q(app) & " commit -qam narrower")
    let dropped = capture(q(reproBin) & " lock refresh " & q(app) & " --json",
      scratch)
    checkpoint(dropped.output & dropped.errors)
    check dropped.code == 0
    check "dropping sibling 'lib-d'" in dropped.errors
    check "dropping sibling 'lib-e'" in dropped.errors
    check "no repro.nim" in dropped.errors
    check narrow notin dropped.errors
    check wider notin dropped.errors
    require dropped.code == 0
    let report = parseJson(dropped.output)
    check report["status"].getStr() == "ok"
    check report["behindManifests"].len == 0
    require report["droppedPins"].len == 2
    let pin = report["droppedPins"][0]
    check pin["name"].getStr() == "lib-d"
    check pin["revision"].getStr() == headOf(gitBin, workspace / "lib-d")
    check pin["committed"].getBool()
    check "no repro.nim" in pin["reason"].getStr()
    check report["droppedPins"][1]["name"].getStr() == "lib-e"
    let narrowed = readFile(app / "repro.lock")
    check depLineFor(narrowed, "lib-d").len == 0
    check depLineFor(narrowed, "lib-e").len == 0
    check depLineFor(narrowed, "lib-b") == depLineFor(original, "lib-b")
    when not defined(windows):
      # Git prints a canonical top-level path; invoking through a workspace
      # symlink must still compare against the same HEAD-committed lock.
      writeFile(app / "repro.lock", original)
      let alias = scratch / "workspace-alias"
      createSymlink(workspace, alias)
      let aliased = capture(q(reproBin) & " lock refresh " & q(alias / "app") &
        " --json", scratch)
      checkpoint(aliased.output & aliased.errors)
      check aliased.code == 0
      check parseJson(aliased.output)["droppedPins"].len == 2
      check parseJson(aliased.output)["droppedPins"][0]["committed"].getBool()
      # The selected lock and the invoking project may independently use
      # either spelling. Both directions must read the same committed pins.
      for (projectPath, selectedLock) in [
          (alias / "app", app / "repro.lock"),
          (app, alias / "app/repro.lock")]:
        writeFile(app / "repro.lock", original)
        let mixed = capture(q(reproBin) & " lock refresh " & q(projectPath) &
          " --lock " & q(selectedLock) & " --json", scratch)
        checkpoint(mixed.output & mixed.errors)
        check mixed.code == 0
        check parseJson(mixed.output)["droppedPins"][0]["committed"].getBool()
    # A targeted re-pin carries the working lock's sibling pins forward, so it
    # removes nothing from its actual output.
    writeFile(app / "repro.lock", original)
    let targeted = capture(q(reproBin) & " lock refresh " & q(app) &
      " --json --repin=app", scratch)
    checkpoint(targeted.output & targeted.errors)
    check targeted.code == 0
    if targeted.code == 0:
      check parseJson(targeted.output)["droppedPins"].len == 0
      check parseJson(targeted.output)["behindManifests"].len == 0
      for name in ["lib-b", "lib-c", "lib-d", "lib-e"]:
        check depLineFor(readFile(app / "repro.lock"), name) == depLineFor(original, name)
    # `--allow-stale-manifest` is accepted, says it does nothing, and the
    # refresh is the ordinary one.
    writeFile(app / "repro.lock", original)
    let allowed = capture(q(reproBin) & " lock refresh " & q(app) &
      " --allow-stale-manifest --json", scratch)
    checkpoint(allowed.output & allowed.errors)
    check allowed.code == 0
    check "--allow-stale-manifest is deprecated and has no effect" in
      allowed.errors
    check depLineFor(readFile(app / "repro.lock"), "lib-d").len == 0

    # The removal report survives the retired exit 6: what follows used to be
    # asserted through that refusal and is asserted here through the report
    # of a refresh that writes.
    #
    # The comparison uses HEAD's committed lock even after a working-copy
    # refresh already dropped the pins.
    let narrowedWorking = readFile(app / "repro.lock")
    let repeated = capture(q(reproBin) & " lock refresh " & q(app) &
      " --json", scratch)
    checkpoint(repeated.output & repeated.errors)
    require repeated.code == 0
    let repeatedReport = parseJson(repeated.output)
    require repeatedReport["droppedPins"].len == 2
    check repeatedReport["droppedPins"][0]["name"].getStr() == "lib-d"
    check repeatedReport["droppedPins"][0]["committed"].getBool()
    check "dropping sibling 'lib-d'" in repeated.errors
    # A targeted re-pin keeps the selected (already narrowed) working lock's
    # set, not HEAD's larger one, and still names the committed pins that set
    # lacks.
    writeFile(app / "repro.lock", narrowedWorking)
    let narrowedRepin = capture(q(reproBin) & " lock refresh " & q(app) &
      " --json --repin=app", scratch)
    checkpoint(narrowedRepin.output & narrowedRepin.errors)
    require narrowedRepin.code == 0
    check parseJson(narrowedRepin.output)["droppedPins"].len == 2
    check depLineFor(readFile(app / "repro.lock"), "lib-d").len == 0
    check depLineFor(readFile(app / "repro.lock"), "lib-b") ==
      depLineFor(narrowedWorking, "lib-b")
    # Provisioning re-selection takes the full-refresh writer even when
    # --repin is also present, and audits the set THAT writer would land:
    # both drops are named before the re-selection runs. (This fixture
    # declares no catalog imports, so the re-selection itself then refuses
    # and writes nothing; the audit is what is under test here.)
    writeFile(app / "repro.lock", original)
    let provisioning = capture(q(reproBin) & " lock refresh " & q(app) &
      " --repin=app --provisioning --json", scratch)
    checkpoint(provisioning.output & provisioning.errors)
    check "dropping sibling 'lib-d'" in provisioning.errors
    check "dropping sibling 'lib-e'" in provisioning.errors
    check "re-selection refused" in provisioning.errors
    check provisioning.code != 0
    check readFile(app / "repro.lock") == original
    # Once the narrowed lock is committed, a pin present only in the working
    # copy is reported as dropped, but not as a committed pin.
    writeFile(app / "repro.lock", narrowedWorking)
    discard requireGit(q(gitBin) & " -C " & q(app) & " add repro.lock")
    discard requireGit(q(gitBin) & " -C " & q(app) & " commit -qm narrower-lock")
    writeFile(app / "repro.lock", original)
    let workingOnly = capture(q(reproBin) & " lock refresh " & q(app) &
      " --json", scratch)
    checkpoint(workingOnly.output & workingOnly.errors)
    require workingOnly.code == 0
    let workingOnlyReport = parseJson(workingOnly.output)
    require workingOnlyReport["droppedPins"].len == 2
    check not workingOnlyReport["droppedPins"][0]["committed"].getBool()
    check "lib-d" in workingOnly.errors
    # --lock selects the comparison baseline as well as the output path: a
    # lock committed with the wider set reports its committed pins, though
    # `repro.lock` at HEAD no longer carries them.
    let customLock = app / "custom.lock"
    writeFile(customLock, original)
    discard requireGit(q(gitBin) & " -C " & q(app) & " add custom.lock")
    discard requireGit(q(gitBin) & " -C " & q(app) & " commit -qm custom-lock")
    writeFile(customLock, narrowedWorking)
    let custom = capture(q(reproBin) & " lock refresh " & q(app) &
      " --lock " & q(customLock) & " --json", scratch)
    checkpoint(custom.output & custom.errors)
    require custom.code == 0
    let customReport = parseJson(custom.output)
    require customReport["droppedPins"].len == 2
    check customReport["droppedPins"][0]["committed"].getBool()
    check depLineFor(readFile(customLock), "lib-d").len == 0

  test "targeted repin audits the final catalog and manifest alias merge":
    let gitBin = findExe("git")
    require gitBin.len > 0
    let reproBin = reproBinary()
    let scratch = createTempDir("repro-lock-develop-set-", "")
    defer: removeDir(scratch)
    let workspace = scratch / "workspace"
    createDir(workspace)
    let appOrigin = seedPublished(gitBin, scratch, workspace, "app")
    let initialOrigin = seedPublished(gitBin, scratch, workspace, "catalog-x")
    # Catalog identity comes from origin's basename, while manifest identity
    # is independently allowed to name the very same checkout catalog-y.
    let catalogOrigin = scratch / "catalog-x.git"
    moveDir(initialOrigin, catalogOrigin)
    let catalog = workspace / "catalog-x"
    discard requireGit(q(gitBin) & " -C " & q(catalog) &
      " remote set-url origin " & q(fileUrl(catalogOrigin)))
    let interfaceDir = catalog / "packages/interfaces/aliasfixture"
    createDir(interfaceDir)
    writeFile(interfaceDir / "repro.nim", """
import repro_project_dsl

package aliasfixture:
  provisioning:
    tarball url = "https://example.invalid/aliasfixture.zip",
      sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
      archiveType = "zip",
      executablePath = "aliasfixture",
      packageId = "aliasfixture@1.0",
      lockIdentity = "tarball:aliasfixture@1.0:sha256:0000000000000000000000000000000000000000000000000000000000000000"
""")
    discard requireGit(q(gitBin) & " -C " & q(catalog) & " add packages")
    discard requireGit(q(gitBin) & " -C " & q(catalog) & " commit -qm catalog")
    discard requireGit(q(gitBin) & " -C " & q(catalog) & " push origin main")
    let app = workspace / "app"
    removeFile(app / "repro.solver")
    writeFile(app / "repro.nim", """
import repro_project_dsl

package app:
  defaultToolProvisioning "path"
  uses:
    "aliasfixture"
  build:
    discard aggregate("app", actions = @[])
""")
    createDir(workspace / "projects")
    createDir(workspace / "repos")
    writeFile(workspace / "projects/app.toml",
      "schema = \"reprobuild.workspace.project.v1\"\n\n" &
      "[project]\nname = \"app\"\n\n" &
      "[[remote]]\nname = \"app-origin\"\nfetch = \"" & fileUrl(appOrigin) & "\"\n\n" &
      "[[remote]]\nname = \"catalog-y-origin\"\nfetch = \"" & fileUrl(catalogOrigin) & "\"\n\n" &
      "includes = [\"repos/app.toml\", \"repos/catalog-y.toml\"]\n")
    # catalog-y is a MEMBER kept at catalog-x: membership says where a repo
    # is, which is what lets the writer recognise one checkout under two
    # names. It is no dependency of app (a fragment edge to it used to be).
    writeFile(workspace / "repos/app.toml", fragment("app", @[]))
    writeFile(workspace / "repos/catalog-y.toml",
      fragment("catalog-y", @[]).replace("path = \"catalog-y\"", "path = \"catalog-x\""))
    writeWorkspaceBranch(workspace, project = "app", branch = "main")
    discard requireGit(q(gitBin) & " init -q -b main " & q(workspace))
    configureIdentity(gitBin, workspace)
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " add projects repos")
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " commit -qm manifest")
    let manifestHead = headOf(gitBin, workspace)
    writeFile(workspace / "newer.txt", "fetched manifest advancement\n")
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " add newer.txt")
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " commit -qm newer")
    let newer = headOf(gitBin, workspace)
    discard requireGit(q(gitBin) & " -C " & q(workspace) &
      " remote add origin " & q(scratch / "unused-origin"))
    discard requireGit(q(gitBin) & " -C " & q(workspace) &
      " update-ref refs/remotes/origin/main " & newer)
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " config branch.main.remote origin")
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " config branch.main.merge refs/heads/main")
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " reset -q --hard " & manifestHead)
    let oldCatalog = getEnv("REPROBUILD_PACKAGES_ROOT")
    let hadCatalog = existsEnv("REPROBUILD_PACKAGES_ROOT")
    putEnv("REPROBUILD_PACKAGES_ROOT", catalog)
    defer:
      if hadCatalog: putEnv("REPROBUILD_PACKAGES_ROOT", oldCatalog)
      else: delEnv("REPROBUILD_PACKAGES_ROOT")
    let initial = capture(q(reproBin) & " lock refresh " & q(app) & " --json", scratch)
    checkpoint(initial.output & initial.errors)
    require initial.code == 0
    let original = readFile(app / "repro.lock")
    require depLineFor(original, "catalog-x").len > 0
    require depLineFor(original, "catalog-y").len == 0
    discard requireGit(q(gitBin) & " -C " & q(app) & " add repro.lock")
    discard requireGit(q(gitBin) & " -C " & q(app) & " commit -qm lock")
    # The selected working lock already uses the manifest alias. Its locally
    # placed path matches generated catalog-x, so the writer carries y and
    # deduplicates x. Merely unioning their names predicts the wrong output.
    let aliased = original.replace("\"catalog-x\"", "\"catalog-y\"")
    writeFile(app / "repro.lock", aliased)
    # The manifest checkout is behind its upstream, which used to refuse this
    # removal (exit 6); a manifest decides no pin now, so the targeted re-pin
    # writes and still names the committed pin it drops.
    let repinned = capture(q(reproBin) & " lock refresh " & q(app) &
      " --repin=app --json", scratch)
    checkpoint(repinned.output & repinned.errors)
    check repinned.code == 0
    let report = parseJson(repinned.output)
    check report["behindManifests"].len == 0
    require report["droppedPins"].len == 1
    check report["droppedPins"][0]["name"].getStr() == "catalog-x"
    check report["droppedPins"][0]["committed"].getBool()
    check "catalog-x" in repinned.errors
    check "repro sync" notin repinned.errors
    check depLineFor(readFile(app / "repro.lock"), "catalog-x").len == 0
    check depLineFor(readFile(app / "repro.lock"), "catalog-y").len > 0
    writeFile(app / "repro.lock", aliased)
    let allowed = capture(q(reproBin) & " lock refresh " & q(app) &
      " --repin=app --json --allow-stale-manifest", scratch)
    checkpoint(allowed.output & allowed.errors)
    require allowed.code == 0
    check "--allow-stale-manifest is deprecated and has no effect" in
      allowed.errors
    require parseJson(allowed.output)["droppedPins"].len == 1
    check parseJson(allowed.output)["droppedPins"][0]["name"].getStr() == "catalog-x"
    check depLineFor(readFile(app / "repro.lock"), "catalog-x").len == 0
    check depLineFor(readFile(app / "repro.lock"), "catalog-y").len > 0
