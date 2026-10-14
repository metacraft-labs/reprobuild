## The per-workspace push-gateway opt-out is a declared settings key.
##
## Push-Gateway-Wiring-And-Policy.md §7.4 puts the per-workspace opt-out in the
## workspace settings file: `push_gateway = "off"`. Workspace-Settings-Files.md
## §3 carries that key over unchanged from the old bootstrap config, as a
## top-level key of the SHARED file; §4 keeps it out of the local file, which
## carries `[[manifest]]` layers only (the opt-out is per-workspace policy, not
## per-person). The strict settings readers must therefore accept it in both
## schemas, refuse a value §7.4 does not define, and refuse it in the local
## file — and the gateway report must read it through those readers, not
## through a private scan of its own.
##
## Every leg runs the REAL `repro` binary against a real workspace root
## (`projects/demo.toml` declares `core`; a `local_path` layer adds `pextra`;
## both are real `file://` remotes):
##
##   1. `repro-workspace.toml` (settings.v1) declaring the layer AND
##      `push_gateway = "off"`: `sync --dry-run`, `workspace list demo` and
##      `ws status` exit 0 and still see the layer's `pextra`; after
##      `ws enable demo` materializes both repos, `repro health --json`'s
##      `push-gateway` row reports the per-workspace opt-out and counts both
##      repos `opted-out`, and has no `workspace-settings` failure row.
##      Control: the same root without the key reports `0 opted-out` and no
##      opt-out in force.
##   2. The old `.repro-workspace.toml` (bootstrap.v1) with
##      `push_gateway = "off"`: the same three verbs exit 0, and health
##      reports the opt-out.
##   3. A value §7.4 does not define (`"on"` in settings.v1, `"disabled"` in
##      bootstrap.v1): `workspace list demo` (which resolves without any state
##      file, so its exit code is about the settings file alone) exits
##      non-zero naming the file and `push_gateway`.
##   4. `push_gateway` in `repro-workspace.local.toml`: `workspace list demo`
##      exits non-zero naming the LOCAL file and `push_gateway`.
##
## What each assertion guards: leg 1's exit codes fail when the key is not in
## the settings.v1 top-level key set (the strict reader then refuses the file);
## leg 2's when the bootstrap.v1 record has no field for it; legs 1–2's
## `opted-out` assertions when the gateway report ignores the typed value;
## leg 3 when the value is not checked; leg 4 when the local file accepts it.
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
  # The fixture's settings files must be found by discovery, and the
  # per-machine opt-out must not mask the per-workspace one under test.
  env.del("REPRO_WORKSPACE_CONFIG")
  env.del("REPRO_PUSH_GATEWAY")
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

proc seedRoot(base, fetch: string): string =
  ## `<base>/ws` declares `demo` = `core`; `<base>/partner` adds `pextra`.
  result = base / "ws"
  let partner = base / "partner"
  createDir(result / "projects")
  createDir(result / "repos")
  writeFile(result / "projects" / "demo.toml", projectToml(fetch, "core"))
  writeFile(result / "repos" / "core.toml", fragmentToml("core"))
  createDir(partner / "projects")
  createDir(partner / "repos")
  writeFile(partner / "projects" / "demo.toml", projectToml(fetch, "pextra"))
  writeFile(partner / "repos" / "pextra.toml", fragmentToml("pextra"))

proc settingsText(pushGateway: string): string =
  result = "schema = \"reprobuild.workspace.settings.v1\"\n"
  if pushGateway.len > 0:
    result.add("push_gateway = \"" & pushGateway & "\"\n")
  result.add("\n[[manifest]]\nlocal_path = \"../partner\"\n" &
    "visibility = \"public\"\n")

proc bootstrapText(pushGateway: string): string =
  "schema = \"reprobuild.workspace.bootstrap.v1\"\npush_gateway = \"" &
    pushGateway & "\"\n\n[manifest]\n" &
    "url = \"https://git.example.invalid/acme/records.git\"\n"

proc gatewayRow(root: string): tuple[detail: string; settingsRows: int] =
  let res = runRepro(["health", "--json", "--workspace-root=" & root])
  checkpoint("health exit=" & $res.code & "\nstdout: " & res.stdout &
    "\nstderr: " & res.stderr)
  for row in parseJson(res.stdout)["checks"]:
    case row["name"].getStr()
    of "push-gateway": result.detail = row["detail"].getStr()
    of "workspace-settings": inc result.settingsRows
    else: discard

proc checkResolves(label, root: string; expectPextra: bool) =
  for args in [@["sync", "--dry-run"], @["workspace", "list", "demo"],
               @["ws", "status"]]:
    let res = runRepro(args & @["--workspace-root=" & root])
    checkpoint(label & ": " & args.join(" ") & " exit=" & $res.code &
      "\nstdout: " & res.stdout & "\nstderr: " & res.stderr)
    check res.code == 0
    check "push_gateway" notin res.stderr
    if expectPextra and args[0] == "workspace":
      check "pextra" in res.stdout

proc checkRefused(label: string; res: tuple[code: int; stdout, stderr: string];
                  file: string) =
  checkpoint(label & " exit=" & $res.code & "\nstdout: " & res.stdout &
    "\nstderr: " & res.stderr)
  check res.code != 0
  check file in res.stderr
  check "push_gateway" in res.stderr

suite "the per-workspace push-gateway opt-out is a settings key":

  test "t_push_gateway_opt_out_is_a_settings_key":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH — the members are real repositories whose " &
        "push paths the gateway report reads")
    else:
      let scratch = createTempDir("repro-push-gateway-key-", "")
      defer: removeDir(scratch)
      let remotes = scratch / "remotes"
      createDir(remotes)
      seedBareRepo(gitBin, scratch, remotes / "core")
      seedBareRepo(gitBin, scratch, remotes / "pextra")
      let fetch = fileUrl(remotes)

      # Leg 1 — settings.v1 with the opt-out.
      let offRoot = seedRoot(scratch / "off", fetch)
      writeFile(offRoot / "repro-workspace.toml", settingsText("off"))
      let enabled = runRepro(["ws", "enable", "demo",
        "--workspace-root=" & offRoot])
      checkpoint("enable: " & enabled.stdout & enabled.stderr)
      require enabled.code == 0
      checkResolves("settings.v1 off", offRoot, expectPextra = true)
      let offRow = gatewayRow(offRoot)
      check "a per-workspace opt-out is in force" in offRow.detail
      check "2 opted-out" in offRow.detail
      check offRow.settingsRows == 0

      # Control — the same workspace without the key.
      let onRoot = seedRoot(scratch / "default", fetch)
      writeFile(onRoot / "repro-workspace.toml", settingsText(""))
      require runRepro(["ws", "enable", "demo",
        "--workspace-root=" & onRoot]).code == 0
      let onRow = gatewayRow(onRoot)
      check "0 opted-out" in onRow.detail
      check "opt-out is in force" notin onRow.detail

      # Leg 2 — the old bootstrap.v1 file with the opt-out.
      let legacyRoot = seedRoot(scratch / "legacy", fetch)
      writeFile(legacyRoot / ".repro-workspace.toml", bootstrapText("off"))
      require runRepro(["ws", "enable", "demo",
        "--workspace-root=" & legacyRoot]).code == 0
      checkResolves("bootstrap.v1 off", legacyRoot, expectPextra = false)
      let legacyRow = gatewayRow(legacyRoot)
      check "a per-workspace opt-out is in force" in legacyRow.detail
      check "1 opted-out" in legacyRow.detail
      check legacyRow.settingsRows == 0

      # Leg 3 — a value §7.4 does not define, in either schema.
      let badRoot = seedRoot(scratch / "bad", fetch)
      writeFile(badRoot / "repro-workspace.toml", settingsText("on"))
      checkRefused("settings.v1 on", runRepro(["workspace", "list", "demo",
        "--workspace-root=" & badRoot]), badRoot / "repro-workspace.toml")
      let badLegacyRoot = seedRoot(scratch / "bad-legacy", fetch)
      writeFile(badLegacyRoot / ".repro-workspace.toml",
        bootstrapText("disabled"))
      checkRefused("bootstrap.v1 disabled", runRepro(["workspace", "list", "demo",
        "--workspace-root=" & badLegacyRoot]),
        badLegacyRoot / ".repro-workspace.toml")

      # Leg 4 — the local file may not set it.
      let localRoot = seedRoot(scratch / "local", fetch)
      writeFile(localRoot / "repro-workspace.toml", settingsText(""))
      writeFile(localRoot / "repro-workspace.local.toml",
        "schema = \"reprobuild.workspace.settings-local.v1\"\n" &
        "push_gateway = \"off\"\n")
      checkRefused("local file", runRepro(["workspace", "list", "demo",
        "--workspace-root=" & localRoot]),
        localRoot / "repro-workspace.local.toml")
