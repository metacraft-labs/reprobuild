## `repro health` tells a manifest that fails on ONE declared role of the
## root repository from one that fails everywhere.
##
## The workspace root repository declares several roles that all carry
## manifests (Workspace-Branch-Roles.md §3.4: here `mainline = dev`,
## `unstable = agents`). A manifest migration can land on one branch only.
## The measured case: `[project] trunk` was retired and deleted from
## `projects/back-office.toml` on `dev` and not on `agents`. A workspace on
## `agents`, already at the tip of `origin/agents`, that enabled the project
## got `manifest fail` with the remedy `repro workspace sync` — a no-op there —
## and no hint that `dev` loads. Workspaces that did not enable the project
## read green, so nothing flagged the branch.
##
## The fixture is a real root repository (`projects/demo.toml`, one fragment,
## a real bare `origin`) with the two branches. `agents` carries the retired
## `trunk` key and declares `unstable = agents`; `dev` has neither. Membership is recorded on `dev`, where the
## project still loads, then the checkout moves to `agents`. Against the REAL
## binary, `repro health --json`:
##
##   1. At the tip of `origin/agents`: the `manifest` row fails, its detail
##      names the branch it read ('agents'), that this is the tip of
##      origin/agents, and that role mainline (branch 'dev') resolves; its
##      remedy does NOT offer `workspace sync` (a no-op) and names where the
##      fix is.
##   2. The new `root-role-manifests` row fails (the checked-out role is the
##      broken one) naming `agents` and `projects/demo.toml`.
##   3. On `dev` the same defect is a `warn` on that row (the broken role is
##      not the checked-out one), and `manifest` is ok: the defect is
##      reported although the checkout is green. `dev`'s own settings file
##      declares only a mainline, as the real root's does; the `agents`
##      branch is found through the settings file published on
##      `origin/agents`.
##   4. Control, so legs 1-2 cannot pass by never offering `workspace sync`:
##      when the broken checkout is BEHIND origin/agents (the fix is already
##      published there), the remedy is still `workspace sync`, and the
##      detail says it is behind.
##
## No mocks: real git repositories and the real `repro` binary. Skip rule:
## skip only when `git` is missing from PATH.

import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/reasoned_skip

proc q(value: string): string = quoteShell(value)

proc reproBinary(): string =
  requireBinary(currentSourcePath().parentDir.parentDir.parentDir / "build" /
    "bin" / addFileExt("repro", ExeExt), "reprobuild.apps.repro")

proc runRepro(args: openArray[string]):
    tuple[code: int; stdout, stderr: string] =
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    env[k] = v
  env.del("REPRO_WORKSPACE_CONFIG")
  let p = startProcess(reproBinary(), args = @args, env = env, options = {})
  let o = p.outputStream.readAll()
  let e = p.errorStream.readAll()
  result = (code: p.waitForExit(), stdout: o, stderr: e)
  p.close()

proc sh(command: string) =
  let res = execCmdEx(command)
  if res.exitCode != 0:
    checkpoint("command failed: " & command & "\n" & res.output)
    quit 1

proc gitIn(gitBin, dir, args: string) =
  sh(q(gitBin) & " -C " & q(dir) & " " & args)

proc seedBareRepo(gitBin, scratch, barePath: string) =
  let work = scratch / ("seed-" & extractFilename(barePath))
  sh(q(gitBin) & " init -q -b main " & q(work))
  gitIn(gitBin, work, "config user.email tester@example.invalid")
  gitIn(gitBin, work, "config user.name Tester")
  writeFile(work / "README", "fixture\n")
  gitIn(gitBin, work, "add -A")
  gitIn(gitBin, work, "commit -q -m fixture")
  sh(q(gitBin) & " clone -q --bare " & q(work) & " " & q(barePath))

proc projectToml(fetch: string; retiredTrunk: bool): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "includes = [\"repos/core.toml\"]\n\n[project]\nname = \"demo\"\n" &
    (if retiredTrunk: "trunk = \"dev\"\n" else: "") &
    "\n[[remote]]\nname = \"acme\"\nfetch = \"" & fetch & "\"\n"

const fragmentToml =
  "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\nname = \"core\"\n" &
  "path = \"core\"\nremote = \"acme\"\nmainline = \"main\"\n"

const
  devSettingsToml =
    "schema = \"reprobuild.workspace.settings.v1\"\n\n[workspace]\n" &
    "mainline = \"dev\"\n"
    ## `dev` declares only its mainline, as the real root's `dev` does.
  agentsSettingsToml =
    "schema = \"reprobuild.workspace.settings.v1\"\n\n[workspace]\n" &
    "mainline = \"dev\"\nunstable = \"agents\"\n"
    ## `agents` also declares the `unstable` role that names itself.

proc rowNamed(doc: JsonNode; name: string): JsonNode =
  var found: seq[JsonNode]
  for row in doc["checks"]:
    if row["name"].getStr() == name:
      found.add(row)
  if found.len == 1: found[0] else: nil

proc healthDoc(root: string): JsonNode =
  let res = runRepro(["health", "--json", "--workspace-root=" & root])
  checkpoint("health --json exit=" & $res.code & "\nstdout: " & res.stdout &
    "\nstderr: " & res.stderr)
  try:
    result = parseJson(res.stdout)
  except CatchableError:
    checkpoint("health --json printed no JSON document")
    check false

suite "repro health on a root whose declared roles disagree":

  test "t_health_reports_a_manifest_that_loads_on_one_root_role_only":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH — the root and the members are real repositories")
    else:
      let scratch = createTempDir("repro-health-root-roles-", "")
      defer: removeDir(scratch)
      let remotes = scratch / "remotes"
      createDir(remotes)
      seedBareRepo(gitBin, scratch, remotes / "core")
      let fetch = fileUrl(remotes)
      let root = scratch / "ws"
      let origin = scratch / "origin.git"
      createDir(root / "projects")
      createDir(root / "repos")
      gitIn(gitBin, scratch, "init -q -b dev " & q(root))
      gitIn(gitBin, root, "config user.email tester@example.invalid")
      gitIn(gitBin, root, "config user.name Tester")
      writeFile(root / "repro-workspace.toml", devSettingsToml)
      writeFile(root / "repos" / "core.toml", fragmentToml)
      writeFile(root / "projects" / "demo.toml", projectToml(fetch, false))
      writeFile(root / ".gitignore", ".repro/\ncore/\n")
      gitIn(gitBin, root, "add -A")
      gitIn(gitBin, root, "commit -q -m dev")
      sh(q(gitBin) & " init -q --bare " & q(origin))
      gitIn(gitBin, root, "remote add origin " & q(origin))
      gitIn(gitBin, root, "push -q -u origin dev")

      # Membership is recorded on `dev`, where the project loads.
      let enabled = runRepro(["ws", "enable", "demo",
        "--workspace-root=" & root])
      checkpoint("enable: " & enabled.stdout & enabled.stderr)
      require enabled.code == 0

      # `agents`: the same tree plus the retired key.
      gitIn(gitBin, root, "checkout -q -b agents")
      writeFile(root / "repro-workspace.toml", agentsSettingsToml)
      writeFile(root / "projects" / "demo.toml", projectToml(fetch, true))
      gitIn(gitBin, root, "commit -q -am agents-with-retired-trunk")
      gitIn(gitBin, root, "push -q -u origin agents")

      # Leg 3 first half: on `dev`, green checkout, broken sibling role.
      gitIn(gitBin, root, "checkout -q dev")
      var doc = healthDoc(root)
      if not doc.isNil:
        let manifest = rowNamed(doc, "manifest")
        check not manifest.isNil
        if not manifest.isNil:
          check manifest["status"].getStr() == "ok"
        let roles = rowNamed(doc, "root-role-manifests")
        check not roles.isNil
        if not roles.isNil:
          check roles["status"].getStr() == "warn"
          check "agents" in roles["detail"].getStr()
          check "projects/demo.toml" in roles["detail"].getStr()
          check "trunk" in roles["detail"].getStr()

      # Legs 1-2: on `agents`, at the tip of origin/agents.
      gitIn(gitBin, root, "checkout -q agents")
      doc = healthDoc(root)
      if not doc.isNil:
        let manifest = rowNamed(doc, "manifest")
        check not manifest.isNil
        if not manifest.isNil:
          check manifest["status"].getStr() == "fail"
          let detail = manifest["detail"].getStr()
          check "trunk" in detail
          check "branch 'agents'" in detail
          check "tip of origin/agents" in detail
          check "branch 'dev'" in detail
          check "resolves" in detail
          let remedy = manifest["remedy"].getStr()
          check "workspace sync" in remedy   # named only to say it is a no-op
          check "changes nothing" in remedy
          check "'dev'" in remedy
          check not remedy.endsWith("workspace sync")
        let roles = rowNamed(doc, "root-role-manifests")
        check not roles.isNil
        if not roles.isNil:
          check roles["status"].getStr() == "fail"
          check "projects/demo.toml" in roles["detail"].getStr()

      # Leg 4 (control): the fix is published on origin/agents and this
      # checkout is behind it, so `workspace sync` is the remedy again.
      writeFile(root / "projects" / "demo.toml", projectToml(fetch, false))
      gitIn(gitBin, root, "commit -q -am agents-fixed")
      gitIn(gitBin, root, "push -q origin agents")
      gitIn(gitBin, root, "reset -q --hard HEAD~1")
      doc = healthDoc(root)
      if not doc.isNil:
        let manifest = rowNamed(doc, "manifest")
        check not manifest.isNil
        if not manifest.isNil:
          check manifest["status"].getStr() == "fail"
          check "behind origin/agents" in manifest["detail"].getStr()
          check manifest["remedy"].getStr().endsWith("workspace sync")
