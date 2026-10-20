## `repro health` reports a malformed repo fragment instead of aborting.
##
## CLI/health.md: health "localizes the problem" — every layer is checked and a
## failure is a row with a remedy. A `repos/*.toml` fragment that the strict
## reader rejects used to escape the repo enumeration behind the hooks and
## push-gateway rows, so `repro health` printed one error line and no report.
## And when the workspace composes a settings-file layer, every verb framed the
## fragment's failure as a failure of the (valid) state file
## (`[…/.repro/workspace-state.toml] … at key 'manifest[0]'`), naming neither
## the fragment nor its key.
##
## The fixture is a real workspace root (`projects/demo.toml` declares `core`,
## a settings-file `local_path` layer adds `pextra`, both real `file://`
## remotes, membership recorded by `ws enable demo`) whose `repos/core.toml`
## then gains `zork = 1` under `[repo]`. Against the REAL binary:
##
##   1. `repro health --json` exits 1 and prints a valid report: the
##      `manifest` row fails naming the fragment and `repo.zork`, and the
##      other layers' rows are still there.
##   2. `repro health` (text) exits 1 and prints the same `manifest` row.
##   3. `repro workspace list` exits non-zero naming the FRAGMENT and
##      `repo.zork`, and does not frame it as the state file's failure.
##
## What each assertion guards: legs 1–2 fail when the fragment's error escapes
## the enumeration inside health (measured: no stdout at all); leg 3 fails when
## the composer re-raises a layer's failure as one of the state file at
## `manifest[N]` (measured: the state-file path and `manifest[0]`, no
## fragment key).
##
## No mocks. Skip rule: skip only when `git` is missing from PATH.

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

proc requireSuccess(command: string) =
  let res = execCmdEx(command)
  if res.exitCode != 0:
    checkpoint("command failed: " & command & "\n" & res.output)
    quit 1

proc seedBareRepo(gitBin, scratch, barePath: string) =
  let work = scratch / ("seed-" & extractFilename(barePath))
  requireSuccess(q(gitBin) & " init -q -b main " & q(work))
  requireSuccess(q(gitBin) & " -C " & q(work) &
    " config user.email tester@example.invalid")
  requireSuccess(q(gitBin) & " -C " & q(work) & " config user.name Tester")
  writeFile(work / "README", "fixture\n")
  requireSuccess(q(gitBin) & " -C " & q(work) & " add -A")
  requireSuccess(q(gitBin) & " -C " & q(work) & " commit -q -m fixture")
  requireSuccess(q(gitBin) & " clone -q --bare " & q(work) & " " & q(barePath))

proc projectToml(fetch, repo: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\nincludes = [\"repos/" &
    repo & ".toml\"]\n\n[project]\nname = \"demo\"\n" &
    "default_revision = \"main\"\ntrunk = \"main\"\n\n[[remote]]\n" &
    "name = \"acme\"\nfetch = \"" & fetch & "\"\n"

proc fragmentToml(name: string): string =
  "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\nname = \"" & name &
    "\"\npath = \"" & name & "\"\nremote = \"acme\"\nmainline = \"main\"\n"

suite "repro health reports a malformed repo fragment":

  test "t_health_reports_a_malformed_repo_fragment":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH — the members are real repositories")
    else:
      let scratch = createTempDir("repro-health-fragment-", "")
      defer: removeDir(scratch)
      let remotes = scratch / "remotes"
      createDir(remotes)
      seedBareRepo(gitBin, scratch, remotes / "core")
      seedBareRepo(gitBin, scratch, remotes / "pextra")
      let fetch = fileUrl(remotes)
      let root = scratch / "ws"
      let partner = scratch / "partner"
      for dir in [root / "projects", root / "repos", partner / "projects",
                  partner / "repos"]:
        createDir(dir)
      writeFile(root / "projects" / "demo.toml", projectToml(fetch, "core"))
      writeFile(root / "repos" / "core.toml", fragmentToml("core"))
      writeFile(partner / "projects" / "demo.toml",
        projectToml(fetch, "pextra"))
      writeFile(partner / "repos" / "pextra.toml", fragmentToml("pextra"))
      writeFile(root / "repro-workspace.toml",
        "schema = \"reprobuild.workspace.settings.v1\"\n\n[[manifest]]\n" &
        "local_path = \"../partner\"\nvisibility = \"public\"\n")
      let enabled = runRepro(["ws", "enable", "demo",
        "--workspace-root=" & root])
      checkpoint("enable: " & enabled.stdout & enabled.stderr)
      require enabled.code == 0
      let fragment = root / "repos" / "core.toml"
      let state = root / ".repro" / "workspace-state.toml"
      writeFile(fragment, fragmentToml("core") & "zork = 1\n")

      # Leg 1 — `health --json`: a whole report with a failing manifest row.
      let health = runRepro(["health", "--json", "--workspace-root=" & root])
      checkpoint("health --json exit=" & $health.code & "\nstdout: " &
        health.stdout & "\nstderr: " & health.stderr)
      check health.code == 1
      var doc: JsonNode
      try:
        doc = parseJson(health.stdout)
      except CatchableError:
        checkpoint("health --json printed no JSON document")
        check false
      if not doc.isNil:
        check doc["checks"].len > 5
        var manifestRows: seq[JsonNode]
        for row in doc["checks"]:
          if row["name"].getStr() == "manifest":
            manifestRows.add(row)
        check manifestRows.len == 1
        if manifestRows.len == 1:
          check manifestRows[0]["status"].getStr() == "fail"
          let detail = manifestRows[0]["detail"].getStr()
          check fragment in detail
          check "repo.zork" in detail

      # Leg 2 — the text report carries the same row.
      let text = runRepro(["health", "--workspace-root=" & root])
      checkpoint("health exit=" & $text.code & "\nstdout: " & text.stdout &
        "\nstderr: " & text.stderr)
      check text.code == 1
      check "manifest" in text.stdout
      check "repo.zork" in text.stdout

      # Leg 3 — a verb names the fragment and its key, not the state file.
      let listed = runRepro(["workspace", "list", "--workspace-root=" & root])
      checkpoint("workspace list exit=" & $listed.code & "\nstdout: " &
        listed.stdout & "\nstderr: " & listed.stderr)
      check listed.code != 0
      check fragment in listed.stderr
      check "repo.zork" in listed.stderr
      check state notin listed.stderr
      check "at key 'manifest[" notin listed.stderr
