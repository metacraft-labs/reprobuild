## The committed ``repro.lock`` records the revisions of the develop-set
## siblings a repo is built and tested against
## (Unified-Locking-And-Hooks.md §14, "The default: the committed lock records
## the develop set").
##
## WHY THIS EXISTS. A repo whose siblings reach its build OUTSIDE reprobuild's
## solved graph — a Rust recorder consuming ``../codetracer-trace-format``
## through cargo ``path`` dependencies is the fleet's common case — used to get
## a self-only ``deps`` from ``repro lock refresh``: the root entry and nothing
## else. The workspace manifest DID declare the edge (the pre-push gate scopes
## its clean/published checks to exactly that ``depends`` closure), but the
## lock never recorded where those siblings were, so "which sibling revisions
## was this commit built against" had no committed answer. CI then had to ask a
## separate record store for it, and a commit with no record there could not
## run at all.
##
## Fixture (built ``./build/bin/repro``, black-box; real git, real filesystem):
##
##   <scratch>/workspace/                 a manifest workspace
##     projects/app.toml, repos/*.toml    app depends on lib-b; lib-b depends on
##                                        lib-c; lib-d is unrelated (no edge)
##     .repro/workspace.toml              the workspace metadata marker
##     app/    (git, published)           carries ``repro.solver`` — the lock's
##                                        solver inputs; no recipe needed
##     lib-b/  lib-c/  lib-d/  (git, published)
##
## Asserts:
##   1. ``repro lock refresh app`` records lib-b AND lib-c (the TRANSITIVE
##      closure of the manifest ``depends`` edges) as ``deps`` entries named
##      ``lib-b`` / ``lib-c`` with VCS coordinates, the sibling's HEAD as
##      ``revision`` and a ``git-sha1:<HEAD>`` integrity, and no checkout
##      ``path`` (a lock pins identity only — Workspace-Manifests.md §"The
##      committed lock carries the full set (schema v3)"); the root entry
##      (``self = "true"``) ``depends`` on both. lib-d — in the workspace, not
##      in the closure — is NOT recorded.
##   2. After lib-b advances by a published commit, a second refresh re-pins
##      lib-b at its new HEAD (an observation of the checkout, not a copy of the
##      old pin).
##   4. A dev-env-only recipe (a `repro.nim` with nothing to solve) still gets
##      a committed lock recording its develop set, instead of "no solver
##      inputs found".
##   3. Carry-forward outside a workspace: a fresh standalone clone of app with
##      no workspace and no sibling checkouts still records lib-b and lib-c
##      after a refresh, at the committed pins. A refresh must never silently
##      DROP a sibling pin merely because it cannot see the sibling.
##
## Falsifiability (observed): against the pre-§14 ``lockedDepsForWorkspace``
## the lock carries only the root entry, so (1) fails on the absent ``lib-b``
## entry.
##
## NO MOCKS. Every repository is a real local git repository with a real bare
## origin; the manifest is a real on-disk manifest the production resolver
## reads. Nothing touches $HOME or the network.
##
## Skip rule: ``git`` missing on PATH.

import std/[os, osproc, strutils, tempfiles, unittest, json]
import repro_test_support/reasoned_skip

import repro_test_support
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

const solverInputs = """
package app
versions: 0.1.0
depends: nim >=2.2.0 <3.0.0

package nim
versions: 2.2.0
"""

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
  if name == "app":
    writeFile(work / "repro.solver", solverInputs)
    writeFile(work / ".gitignore", ".repro/\n")
  discard requireGit(q(gitBin) & " -C " & q(work) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(work) & " commit -m seed")
  discard requireGit(q(gitBin) & " -C " & q(work) & " push origin main")
  origin

proc fragment(name: string; depends: seq[string]): string =
  result = "schema = \"reprobuild.workspace.repo.v1\"\n\n[repo]\n" &
    "name = \"" & name & "\"\npath = \"" & name & "\"\n" &
    "remote = \"" & name & "-origin\"\nrevision = \"main\"\n"
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
        "[project]\nname = \"app\"\ndefault_revision = \"main\"\n" &
        "trunk = \"main\"\n\n"
      for (name, origin) in origins:
        project.add("[[remote]]\nname = \"" & name & "-origin\"\nfetch = \"" &
          fileUrl(origin) & "\"\n\n")
      project.add("includes = [\n  \"repos/app.toml\",\n" &
        "  \"repos/lib-b.toml\",\n  \"repos/lib-c.toml\",\n" &
        "  \"repos/lib-d.toml\",\n]\n")
      writeFile(workspace / "projects" / "app.toml", project)
      writeFile(workspace / "repos" / "app.toml", fragment("app", @["lib-b"]))
      writeFile(workspace / "repos" / "lib-b.toml",
        fragment("lib-b", @["lib-c"]))
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
      let root = rootLineFor(body)
      check "lib-b" in root
      check "lib-c" in root

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
      # carries the committed sibling pins forward rather than dropping them.
      let lone = scratch / "standalone" / "app"
      createDir(scratch / "standalone")
      var appOrigin = ""
      for (name, origin) in origins:
        if name == "app": appOrigin = origin
      discard requireGit(q(gitBin) & " clone " & q(fileUrl(appOrigin)) & " " &
        q(lone))
      configureIdentity(gitBin, lone)
      check not dirExists(scratch / "standalone" / "lib-b")
      let loneRefresh = runCmd(q(reproBin) & " lock refresh " & q(lone))
      checkpoint(loneRefresh.output)
      check loneRefresh.code == 0
      let body3 = readFile(lone / "repro.lock")
      checkpoint(body3)
      check ("revision = \"" & libBNext & "\"") in depLineFor(body3, "lib-b")
      check ("revision = \"" & libCHead & "\"") in depLineFor(body3, "lib-c")

      # ---- (4) a recipe with nothing to solve still records its develop set.
      let recipeOnly = workspace / "app"
      removeFile(recipeOnly / "repro.solver")
      removeFile(recipeOnly / "repro.lock")
      writeFile(recipeOnly / "repro.nim",
        "import repro_project_dsl\nimport repro_dsl_stdlib/foreign_env\n\n" &
        "package appEnvironment:\n  devEnv:\n    useFlakeDevShell()\n")
      let noSolve = runCmd(q(reproBin) & " lock refresh " & q(recipeOnly))
      checkpoint(noSolve.output)
      check noSolve.code == 0
      check "no solver inputs found" notin noSolve.output
      let body4 = readFile(recipeOnly / "repro.lock")
      check ("revision = \"" & libBNext & "\"") in depLineFor(body4, "lib-b")
      check "packages = []" in body4

  test "refresh names removed committed pins and refuses behind manifests":
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
      "[project]\nname = \"app\"\ndefault_revision = \"main\"\n" &
      "trunk = \"main\"\n\n"
    for (name, origin) in origins:
      project.add("[[remote]]\nname = \"" & name & "-origin\"\nfetch = \"" &
        fileUrl(origin) & "\"\n\n")
    project.add("includes = [\n  \"repos/app.toml\",\n" &
      "  \"repos/lib-b.toml\",\n  \"repos/lib-c.toml\",\n" &
      "  \"repos/lib-d.toml\",\n]\n")
    writeFile(workspace / "projects" / "app.toml", project)
    writeFile(workspace / "repos" / "app.toml", fragment("app", @["lib-b"]))
    writeFile(workspace / "repos" / "lib-b.toml",
      fragment("lib-b", @["lib-c"]))
    writeFile(workspace / "repos" / "lib-c.toml", fragment("lib-c", @[]))
    writeFile(workspace / "repos" / "lib-d.toml", fragment("lib-d", @[]))
    writeFile(workspace / "repos/lib-e.toml", fragment("lib-e", @[]))
    project = project.replace("  \"repos/lib-d.toml\",", "  \"repos/lib-d.toml\",\n  \"repos/lib-e.toml\",")
    writeFile(workspace / "projects/app.toml", project)
    writeWorkspaceBranch(workspace, project = "app", branch = "main")

    let app = workspace / "app"
    # Make the flat manifest checkout track a locally known newer commit.
    discard requireGit(q(gitBin) & " init -q -b main " & q(workspace))
    configureIdentity(gitBin, workspace)
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " add projects repos")
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " commit -qm narrow")
    let narrow = headOf(gitBin, workspace)
    writeFile(workspace / "repos/app.toml", fragment("app", @["lib-b", "lib-d", "lib-e"]))
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " add repos")
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " commit -qm wider")
    let wider = headOf(gitBin, workspace)
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " remote add origin " & q(scratch / "unused-origin"))
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " update-ref refs/remotes/origin/main " & wider)
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " config branch.main.remote origin")
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " config branch.main.merge refs/heads/main")
    let initial = runCmd(q(reproBin) & " lock refresh " & q(app))
    checkpoint(initial.output)
    require initial.code == 0
    let original = readFile(app / "repro.lock")
    require depLineFor(original, "lib-d").len > 0
    discard requireGit(q(gitBin) & " -C " & q(app) & " add repro.lock")
    discard requireGit(q(gitBin) & " -C " & q(app) & " commit -qm lock")
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " reset -q --hard " & narrow)
    let stale = capture(q(reproBin) & " lock refresh " & q(app) & " --json", scratch)
    checkpoint(stale.output & stale.errors)
    check stale.code == 6
    check readFile(app / "repro.lock") == original
    check "lib-d" in stale.errors
    check narrow in stale.errors
    check wider in stale.errors
    check "repro sync" in stale.errors
    check "droppedPins" in stale.output
    check "behindManifests" in stale.output
    require stale.code == 6
    let report = parseJson(stale.output)
    check report["status"].getStr() == "refused-stale-manifest"
    require report["droppedPins"].len == 2
    check report["droppedPins"][1]["name"].getStr() == "lib-e"
    check "lib-e" in stale.errors
    let pin = report["droppedPins"][0]
    check pin["name"].getStr() == "lib-d"
    check pin["revision"].getStr() == headOf(gitBin, workspace / "lib-d")
    check pin["committed"].getBool()
    check "depends closure" in pin["reason"].getStr()
    check pin["manifests"][0]["revision"].getStr() == narrow
    check report["behindManifests"][0]["revision"].getStr() == narrow
    check report["behindManifests"][0]["upstreamRevision"].getStr() == wider
    when not defined(windows):
      # Git prints a canonical top-level path; invoking through a workspace
      # symlink must still compare against the same HEAD-committed lock.
      let alias = scratch / "workspace-alias"
      createSymlink(workspace, alias)
      let aliased = capture(q(reproBin) & " lock refresh " & q(alias / "app") &
        " --json", scratch)
      checkpoint(aliased.output & aliased.errors)
      check aliased.code == 6
      check readFile(app / "repro.lock") == original
      check parseJson(aliased.output)["droppedPins"].len == 2
      check parseJson(aliased.output)["droppedPins"][0]["committed"].getBool()
      writeFile(app / "repro.lock", original)
      # The selected lock and the invoking project may independently use
      # either spelling. Both directions must read the same committed pins.
      for (projectPath, selectedLock) in [
          (alias / "app", app / "repro.lock"),
          (app, alias / "app/repro.lock")]:
        let mixed = capture(q(reproBin) & " lock refresh " & q(projectPath) &
          " --lock " & q(selectedLock) & " --json", scratch)
        checkpoint(mixed.output & mixed.errors)
        check mixed.code == 6
        check readFile(app / "repro.lock") == original
        check parseJson(mixed.output)["droppedPins"][0]["committed"].getBool()
        writeFile(app / "repro.lock", original)
    # A targeted re-pin carries the working lock's sibling pins forward.
    # A narrower manifest therefore removes nothing from its actual output.
    let targeted = capture(q(reproBin) & " lock refresh " & q(app) &
      " --json --repin=app", scratch)
    checkpoint(targeted.output & targeted.errors)
    check targeted.code == 0
    if targeted.code == 0:
      check parseJson(targeted.output)["droppedPins"].len == 0
      check parseJson(targeted.output)["behindManifests"].len == 1
      for name in ["lib-b", "lib-c", "lib-d", "lib-e"]:
        check depLineFor(readFile(app / "repro.lock"), name) == depLineFor(original, name)
    writeFile(app / "repro.lock", original)
    # Provisioning re-selection takes the full-refresh writer even when
    # --repin is also present. It must audit the set that writer will land.
    let provisioning = capture(q(reproBin) & " lock refresh " & q(app) &
      " --repin=app --provisioning --json", scratch)
    checkpoint(provisioning.output & provisioning.errors)
    check provisioning.code == 6
    check readFile(app / "repro.lock") == original
    check parseJson(provisioning.output)["droppedPins"].len == 2
    writeFile(app / "repro.lock", original)
    let allowed = capture(q(reproBin) & " lock refresh " & q(app) & " --json --allow-stale-manifest", scratch)
    checkpoint(allowed.output)
    check allowed.code == 0
    check "lib-d" in allowed.errors
    check "droppedPins" in allowed.output
    check parseJson(allowed.output)["droppedPins"][0]["name"].getStr() == "lib-d"
    check depLineFor(readFile(app / "repro.lock"), "lib-d").len == 0
    # The comparison uses HEAD's committed lock even after a working copy
    # refresh already dropped the pin.
    let repeated = runCmd(q(reproBin) & " lock refresh " & q(app))
    checkpoint(repeated.output)
    check repeated.code == 6
    check "lib-d" in repeated.output
    # Re-pin retains the selected working lock, not HEAD's larger set. A
    # prior working-copy shrink still loses real committed pins and refuses.
    let narrowed = readFile(app / "repro.lock")
    let narrowedRepin = capture(q(reproBin) & " lock refresh " & q(app) &
      " --json --repin=app", scratch)
    checkpoint(narrowedRepin.output & narrowedRepin.errors)
    check narrowedRepin.code == 6
    check readFile(app / "repro.lock") == narrowed
    check parseJson(narrowedRepin.output)["droppedPins"].len == 2

    # Divergence still lacks upstream's wider declaration, even with local
    # commits of its own. Local edits must not turn known staleness into safety.
    writeFile(workspace / "local.txt", "local manifest work\n")
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " add local.txt")
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " commit -qm local")
    let divergent = headOf(gitBin, workspace)
    let diverged = capture(q(reproBin) & " lock refresh " & q(app) & " --json", scratch)
    checkpoint(diverged.output & diverged.errors)
    check diverged.code == 6
    check parseJson(diverged.output)["behindManifests"][0]["revision"].getStr() == divergent

    # Intentional current removal is authoritative and succeeds, still naming
    # every removed committed pin and its reason, even when the working lock
    # has already lost that entry.
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " update-ref refs/remotes/origin/main " & divergent)
    let current = capture(q(reproBin) & " lock refresh " & q(app) & " --json", scratch)
    checkpoint(current.output & current.errors)
    require current.code == 0
    let currentReport = parseJson(current.output)
    check currentReport["behindManifests"].len == 0
    check currentReport["droppedPins"][0]["name"].getStr() == "lib-d"
    check "lib-d" in current.errors
    check divergent in current.errors
    discard requireGit(q(gitBin) & " -C " & q(app) & " add repro.lock")
    discard requireGit(q(gitBin) & " -C " & q(app) & " commit -qm narrower-lock")

    # A stale manifest warns even with no removals. No network can succeed:
    # the remote deliberately names a nonexistent path throughout this case.
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " update-ref refs/remotes/origin/main " & wider)
    let noDrop = capture(q(reproBin) & " lock refresh " & q(app) & " --json", scratch)
    checkpoint(noDrop.output & noDrop.errors)
    require noDrop.code == 0
    check parseJson(noDrop.output)["behindManifests"].len == 1
    check parseJson(noDrop.output)["droppedPins"].len == 0
    check "repro sync" in noDrop.errors

    # Working-copy-only pins deserve a report too, but do not masquerade as
    # committed-pin loss: no refusal applies to this uncommitted experiment.
    writeFile(app / "repro.lock", original)
    let workingOnly = capture(q(reproBin) & " lock refresh " & q(app) & " --json", scratch)
    checkpoint(workingOnly.output & workingOnly.errors)
    require workingOnly.code == 0
    check not parseJson(workingOnly.output)["droppedPins"][0]["committed"].getBool()
    check "lib-d" in workingOnly.errors

    # Without a tracking upstream, local staleness cannot be claimed.
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " config --unset branch.main.remote")
    writeFile(app / "repro.lock", original)
    let noUpstream = capture(q(reproBin) & " lock refresh " & q(app) & " --json", scratch)
    checkpoint(noUpstream.output & noUpstream.errors)
    require noUpstream.code == 0
    check parseJson(noUpstream.output)["behindManifests"].len == 0
    check parseJson(noUpstream.output)["droppedPins"].len == 2

    # A locally tracked branch is not fetched upstream evidence.
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " branch local-target " & wider)
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " config branch.main.remote .")
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " config branch.main.merge refs/heads/local-target")
    writeFile(app / "repro.lock", original)
    let localTracking = capture(q(reproBin) & " lock refresh " & q(app) & " --json", scratch)
    checkpoint(localTracking.output & localTracking.errors)
    require localTracking.code == 0
    check parseJson(localTracking.output)["behindManifests"].len == 0
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " config branch.main.merge refs/heads/main")

    # --lock selects the comparison baseline as well as the output path.
    # Neither a pre-shrunk worktree file nor a differently named lock bypasses
    # protection for that selected lock's HEAD-committed pins.
    let customLock = app / "custom.lock"
    writeFile(customLock, original)
    discard requireGit(q(gitBin) & " -C " & q(app) & " add custom.lock")
    discard requireGit(q(gitBin) & " -C " & q(app) & " commit -qm custom-lock")
    writeFile(customLock, readFile(app / "repro.lock"))
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " config branch.main.remote origin")
    let custom = capture(q(reproBin) & " lock refresh " & q(app) &
      " --lock " & q(customLock) & " --json", scratch)
    checkpoint(custom.output & custom.errors)
    require custom.code == 6
    check parseJson(custom.output)["droppedPins"].len == 2

    # The flat manifest root itself also warns, even though it has no
    # independent sibling membership and therefore cannot drop those pins.
    writeFile(workspace / "repro.solver", solverInputs)
    let rootRefresh = capture(q(reproBin) & " lock refresh " & q(workspace) & " --json", scratch)
    checkpoint(rootRefresh.output & rootRefresh.errors)
    require rootRefresh.code == 0
    check parseJson(rootRefresh.output)["behindManifests"].len == 1
    check "repro sync" in rootRefresh.errors
    removeFile(workspace / "repro.lock")
    removeFile(workspace / "repro.solver")

    # Move the exact same manifest history into a configured local layer:
    # freshness and removal checks must inspect layers as well as flat roots.
    discard requireGit(q(gitBin) & " -C " & q(workspace) & " config branch.main.remote origin")
    let layer = scratch / "manifest-layer"
    createDir(layer)
    for name in [".git", "projects", "repos"]:
      moveDir(workspace / name, layer / name)
    let state = workspaceTomlPath(workspace)
    writeFile(state, readFile(state) & "\n[[manifest]]\nlocal_path = \"" &
      layer.replace('\\', '/') & "\"\nvisibility = \"public\"\n")
    writeFile(app / "repro.lock", original)
    discard requireGit(q(gitBin) & " -C " & q(app) & " add repro.lock")
    discard requireGit(q(gitBin) & " -C " & q(app) & " commit -qm wider-lock")
    let layered = capture(q(reproBin) & " lock refresh " & q(app) & " --json", scratch)
    checkpoint(layered.output & layered.errors)
    require layered.code == 6
    check readFile(app / "repro.lock") == original
    check parseJson(layered.output)["behindManifests"][0]["checkout"].getStr() == layer
    check layer in layered.errors
    check "lib-d" in layered.errors
    check divergent in layered.errors


    # An already-acquired URL layer uses the composer's standard placement.
    # Its unusable URL makes accidental fetch/clone attempts fail visibly.
    let layerUrl = "https://invalid.example/manifests.git"
    let urlLayer = workspace / ".repro/manifests-0-https-invalid.example-manifests.git"
    moveDir(layer, urlLayer)
    writeFile(state, readFile(state).replace(
      "local_path = \"" & layer.replace('\\', '/') & "\"",
      "url = \"" & layerUrl & "\""))
    let urlRefresh = capture(q(reproBin) & " lock refresh " & q(app) & " --json", scratch)
    checkpoint(urlRefresh.output & urlRefresh.errors)
    require urlRefresh.code == 6
    check readFile(app / "repro.lock") == original
    check parseJson(urlRefresh.output)["behindManifests"][0]["checkout"].getStr() == urlLayer
    check "lib-d" in urlRefresh.errors
    check "lib-e" in urlRefresh.errors

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
      "[project]\nname = \"app\"\ndefault_revision = \"main\"\ntrunk = \"main\"\n\n" &
      "[[remote]]\nname = \"app-origin\"\nfetch = \"" & fileUrl(appOrigin) & "\"\n\n" &
      "[[remote]]\nname = \"catalog-y-origin\"\nfetch = \"" & fileUrl(catalogOrigin) & "\"\n\n" &
      "includes = [\"repos/app.toml\", \"repos/catalog-y.toml\"]\n")
    writeFile(workspace / "repos/app.toml", fragment("app", @["catalog-y"]))
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
    let refused = capture(q(reproBin) & " lock refresh " & q(app) &
      " --repin=app --json", scratch)
    checkpoint(refused.output & refused.errors)
    check refused.code == 6
    check readFile(app / "repro.lock") == aliased
    let report = parseJson(refused.output)
    require report["droppedPins"].len == 1
    check report["droppedPins"][0]["name"].getStr() == "catalog-x"
    check report["droppedPins"][0]["committed"].getBool()
    check "catalog-x" in refused.errors
    check "repro sync" in refused.errors
    writeFile(app / "repro.lock", aliased)
    let allowed = capture(q(reproBin) & " lock refresh " & q(app) &
      " --repin=app --json --allow-stale-manifest", scratch)
    checkpoint(allowed.output & allowed.errors)
    require allowed.code == 0
    require parseJson(allowed.output)["droppedPins"].len == 1
    check parseJson(allowed.output)["droppedPins"][0]["name"].getStr() == "catalog-x"
    check depLineFor(readFile(app / "repro.lock"), "catalog-x").len == 0
    check depLineFor(readFile(app / "repro.lock"), "catalog-y").len > 0
