## Unified-Locking-And-Hooks HL-2 (§10 Migration) — a workspace with a
## record-store directory but NO team route must NEVER silently go public-only.
## Locking it emits a LOUD one-time migration guidance naming ``repro locking
## adopt-manifest``, and that verb either scaffolds a WORKING team route or
## refuses — it never writes a route that records nothing.
##
## Fixtures (built ``./build/bin/repro``, black-box), each with two cloned repos,
## NO ``[locking]`` config at all, and env-silenced system/dotfiles/VCS-private
## layers:
##
## * ``t_legacy_manifest_without_team_route_warns_and_scaffolds`` — the legacy
##   shape: a plain ``.repro/manifests`` directory holding the workspace
##   metadata, NOT a git checkout.
##   1. ``repro workspace lock`` prints the LOUD guidance (mentions the missing
##      team route AND ``adopt-manifest``) — it is NOT silent.
##   2. ``repro locking adopt-manifest`` REFUSES (non-zero exit, names the
##      directory as not a git checkout and the remedy) and writes NO config:
##      a git-checkout route over a plain directory records nothing.
##   3. ``repro locking explain --json`` still resolves no repo to the team
##      tier — nothing was routed.
##
## * ``t_adopt_manifest_routes_the_record_store_checkout`` — metadata at the
##   workspace root and the record store a git checkout at ``.repro/records``.
##   1. ``repro locking adopt-manifest`` writes a team route naming every repo
##      → git-checkout at ``.repro/records`` (the checkout that exists).
##   2. ``repro locking explain --json`` resolves every repo to the TEAM tier.
##   3. ``repro workspace lock`` then WRITES a record under
##      ``.repro/records/locks/`` — the route works, not merely resolves.
##
## Falsifiability: dropping the migration guard makes the first case's (1)
## silent. Writing the scaffold for a non-checkout makes its (2) exit 0 and
## create the config. A route path that is not the checkout found (the former
## hard-coded ``.repro/manifests``) makes the second case's lock record nothing,
## which its (3) trips on. Dropping the scaffold makes its (2) resolve every
## repo to the public committed-lock default.
##
## Hermetic: fresh tempdir; env silences the other config layers. Skip: ``git``
## missing or ``./build/bin/repro`` absent.

import std/[json, os, osproc, strutils, tempfiles, unittest]
from repro_test_support import fileUrl
import repro_test_support/reasoned_skip

import repro_workspace_manifests

const ReprobuildRepoRoot = currentSourcePath().parentDir().parentDir().parentDir()
  ## The reprobuild checkout root, resolved from THIS SOURCE FILE's path
  ## rather than from the process working directory.
  ##
  ## The previous spelling (``"./build/bin/" & addFileExt("repro", ExeExt)``)
  ## made the working directory an unstated fixture input: from the repo root
  ## the case ran, from any other directory ``fileExists`` was false and it
  ## SKIPPED, and from a scratch directory that happened to carry a staged
  ## ``build/bin/repro`` it ran against THAT binary and reported failures that
  ## read as product refusals. ``currentSourcePath()`` is absolute on both
  ## platforms, so this constant is the same from every cwd.
const reproBinary = ReprobuildRepoRoot / "build/bin/repro".addFileExt(ExeExt)

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc runStdout(command: string; cwd = ""):
    tuple[code: int; output: string] =
  ## Run ``command`` capturing STDOUT ONLY; stderr stays on the test's own
  ## stderr, where the run log still records it.
  ##
  ## The caller parses the captured text, and the solver writes clingo
  ## ``info:`` notes to stderr, so the merge ``execCmdEx`` performs by
  ## default would corrupt the parse. The previous spelling appended a
  ## literal ``2>/dev/null`` to the command string — a SHELL redirect, and
  ## ``execCmdEx`` runs no shell (``poEvalCommand`` hands the string to
  ## ``CreateProcessW`` on Windows), so the token reached ``repro`` as an
  ## argument. Dropping ``poStdErrToStdOut`` expresses the intent through
  ## the API instead.
  let res = execCmdEx(command, options = {poUsePath, poEvalCommand},
                      workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  ## `doAssert`, not `check` or `quit`: this is a HELPER, outside any
  ## `test` body. `unittest.check` there cannot see the `testStatusIMPL`
  ## the `test` template injects, so it prints "Check failed" and the case
  ## still reports `[OK]`; `quit 1` tears the process down mid-case, so
  ## `unittest` emits no `[FAILED]` marker and every later case in the file
  ## silently never runs. `doAssert` raises an `AssertionDefect`, which the
  ## `test` template's own `except Exception` catches and reports as a
  ## failure from any call depth.
  let res = run(command, cwd)
  doAssert res.code == 0, "command failed: " & command & "\nexit=" &
    $res.code & "\n" & res.output
  res.output

proc seedGitOrigin(gitBin, originPath, workPath: string): string =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"HL-2 Tester\"")
  writeFile(workPath / "README.md", "legacy fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  requireGit(q(gitBin) & " -C " & q(workPath) & " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " &
    q(fileUrl(originPath)) & " " & q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name \"HL-2 Tester\"")

proc projectToml(aUrl, bUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"legacy\"\n" &
  "\n" &
  "[[remote]]\nname = \"a-origin\"\nfetch = \"" & aUrl & "\"\n\n" &
  "[[remote]]\nname = \"b-origin\"\nfetch = \"" & bUrl & "\"\n\n" &
  "includes = [\n  \"repos/a.toml\",\n  \"repos/b.toml\",\n]\n"

proc repoFragment(name, remote: string): string =
  "schema = \"reprobuild.workspace.repo.v2\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & remote & "\"\n" &
  "mainline = \"main\"\n"

proc writeMetadata(root, aOrigin, bOrigin: string) =
  createDir(root / "projects")
  createDir(root / "repos")
  writeFile(root / "projects" / "legacy.toml",
    projectToml(fileUrl(aOrigin), fileUrl(bOrigin)))
  writeFile(root / "repos" / "a.toml", repoFragment("a", "a-origin"))
  writeFile(root / "repos" / "b.toml", repoFragment("b", "b-origin"))

proc silenceConfigLayers(scratch: string): string =
  ## No ``[locking]`` table anywhere: point every other configuration layer at
  ## a file that does not exist so there is definitively NO team route.
  ## Returns the VCS-private layer path ``adopt-manifest`` writes to.
  putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
  putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
  result = scratch / "vcs-private.toml"
  putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", result)

proc restoreConfigLayers() =
  delEnv("REPROBUILD_SYSTEM_CONFIG")
  delEnv("REPROBUILD_USER_CONFIG")
  delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

proc lockRecordFiles(storeRoot: string): seq[string] =
  let locks = storeRoot / "locks"
  if dirExists(locks):
    for path in walkDirRec(locks):
      if path.endsWith(".toml"):
        result.add(path)

suite "HL-2 — legacy manifest without team route warns and scaffolds":

  test "t_legacy_manifest_without_team_route_warns_and_scaffolds":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip("needs git on PATH and a built ./build/bin/repro")
    else:
      let scratch = createTempDir("hl2-legacy-", "")
      defer: removeDir(scratch)

      let aOrigin = scratch / "origin-a.git"
      let bOrigin = scratch / "origin-b.git"
      discard seedGitOrigin(gitBin, aOrigin, scratch / "seed-a")
      discard seedGitOrigin(gitBin, bOrigin, scratch / "seed-b")

      let ws = scratch / "workspace"
      createDir(ws)
      let manifestsRoot = ws / ".repro" / "manifests"
      writeMetadata(manifestsRoot, aOrigin, bOrigin)

      cloneInto(gitBin, aOrigin, ws / "a")
      cloneInto(gitBin, bOrigin, ws / "b")
      writeWorkspaceBranch(ws, project = "legacy", branch = "main")

      let vcsPrivate = silenceConfigLayers(scratch)
      defer: restoreConfigLayers()

      # ---- (1) locking the un-routed legacy manifest WARNS loudly ------
      let lockRes = run(reproBinary & " workspace lock --workspace-root=" & q(ws))
      check lockRes.code == 0
      # The guidance is loud and names the remedy — NOT silent.
      check lockRes.output.contains("no team route") or
        lockRes.output.contains("NO team route")
      check lockRes.output.contains("adopt-manifest")

      # ---- (2) adopt-manifest REFUSES a store that is not a checkout ---
      let adoptRes = run(reproBinary & " locking adopt-manifest" &
        " --workspace-root=" & q(ws))
      checkpoint("adopt-manifest output: " & adoptRes.output)
      check adoptRes.code != 0
      check adoptRes.output.contains("is not a git checkout")
      check adoptRes.output.contains(manifestsRoot)
      check adoptRes.output.contains("[records] url")
      # Nothing was written: no route that would record nothing.
      check not fileExists(vcsPrivate)

      # ---- (3) explain routes no repo to the team tier -----------------
      let explainRes = runStdout(reproBinary &
        " locking explain --workspace-root=" & q(ws) & " --json")
      check explainRes.code == 0
      let parsed = parseJson(explainRes.output.strip())
      check parsed["repos"].len == 2
      for r in parsed["repos"]:
        check r["tier"].getStr() != "team"

  test "t_adopt_manifest_routes_the_record_store_checkout":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip("needs git on PATH and a built ./build/bin/repro")
    else:
      let scratch = createTempDir("hl2-records-", "")
      defer: removeDir(scratch)

      let aOrigin = scratch / "origin-a.git"
      let bOrigin = scratch / "origin-b.git"
      let recordsOrigin = scratch / "origin-records.git"
      discard seedGitOrigin(gitBin, aOrigin, scratch / "seed-a")
      discard seedGitOrigin(gitBin, bOrigin, scratch / "seed-b")
      discard seedGitOrigin(gitBin, recordsOrigin, scratch / "seed-records")

      let ws = scratch / "workspace"
      createDir(ws)
      writeMetadata(ws, aOrigin, bOrigin)
      let recordsRoot = ws / ".repro" / "records"
      createDir(ws / ".repro")
      cloneInto(gitBin, recordsOrigin, recordsRoot)

      cloneInto(gitBin, aOrigin, ws / "a")
      cloneInto(gitBin, bOrigin, ws / "b")
      writeWorkspaceBranch(ws, project = "legacy", branch = "main")

      let vcsPrivate = silenceConfigLayers(scratch)
      defer: restoreConfigLayers()

      # ---- (1) adopt-manifest routes the checkout that exists ----------
      let adoptRes = run(reproBinary & " locking adopt-manifest" &
        " --workspace-root=" & q(ws))
      checkpoint("adopt-manifest output: " & adoptRes.output)
      check adoptRes.code == 0
      check fileExists(vcsPrivate)
      let cfgBody = if fileExists(vcsPrivate): readFile(vcsPrivate) else: ""
      check cfgBody.contains("git-checkout")
      check cfgBody.contains("path = \".repro/records\"")
      check cfgBody.contains("\"team\"")

      # ---- (2) explain resolves every repo to the TEAM backend ---------
      let explainRes = runStdout(reproBinary &
        " locking explain --workspace-root=" & q(ws) & " --json")
      check explainRes.code == 0
      let parsed = parseJson(explainRes.output.strip())
      check parsed["repos"].len == 2
      for r in parsed["repos"]:
        check r["tier"].getStr() == "team"
        check r["backend"].getStr() == "git-checkout"
        check r["layer"].getStr() == "vcs-private"

      # ---- (3) the route WORKS: the next lock records into the store ---
      check lockRecordFiles(recordsRoot).len == 0
      let lockRes = run(reproBinary & " workspace lock --workspace-root=" & q(ws))
      checkpoint("workspace lock output: " & lockRes.output)
      check lockRes.code == 0
      check not lockRes.output.contains("failed to record")
      check lockRecordFiles(recordsRoot).len > 0
