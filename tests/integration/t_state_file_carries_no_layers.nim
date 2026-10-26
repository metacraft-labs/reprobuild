## The state file carries no manifest layers: a `[[manifest]]` in
## `.repro/workspace-state.toml` is rejected, and the layers of the old
## `.repro/workspace.toml` are moved to `repro-workspace.local.toml` — by
## `repro health --fix`, or by the first state write.
##
## Workspace-Settings-Files.md §5 (the state file is the `[workspace]` table
## "without the layer list, which moved to the two settings files"), §8 step 2
## (`repro health --fix` moves a checkout's state file and moves any
## `[[manifest]]` layers found in it to `repro-workspace.local.toml`) and §9
## (`state_file_carries_no_layers`).
##
## The fixture is a real workspace root: `projects/demo.toml` declares `core`,
## and a second manifest directory `layer-a/` declares `extra` for the same
## project. The OLD state file lists both as layers — the root as `.` and
## `layer-a` — with a comment, the way a pre-settings-file workspace recorded
## them. Every leg goes through the real `repro`:
##
## `health_fix_moves_the_old_state_file_and_its_layers`
##   1. before: `workspace list` composes `core` and `extra`; `repro health`
##      fails the `workspace-state-file` row, fixable, remedy `health --fix`;
##   2. `repro health --fix`: the old file is gone, `workspace-state.toml` is
##      `state.v1` with the `[workspace]` table and the comment and NO
##      `[[manifest]]`; `repro-workspace.local.toml` is `settings-local.v1`
##      with the `layer-a` layer (the `.` layer is dropped: the root is the
##      base layer anyway); `workspace list` still composes both repos; the
##      row is `ok`;
##   3. after: a `[[manifest]]` written into `workspace-state.toml` makes
##      `workspace list` fail naming that file and the key `manifest`;
##   4. `repro health --fix` moves it again — found already present in the
##      local file, so not written twice — and the verb works again.
##
## `first_state_write_moves_the_layers`
##   `repro ws enable other --no-sync` (membership only: the fixture's remotes
##   are not reachable) on a checkout with only the old file writes the new
##   one WITHOUT layers and moves them to the local file (the old file is left
##   for older repro builds, as §8 step 1 requires); `repro health --fix` then
##   removes the left-over old file and its migration snapshot without
##   duplicating the layer.
##
## `a_write_that_records_nothing_new_does_not_migrate`
##   `repro ws enable demo --no-sync` re-records the project the old file
##   already records: nothing is written, so the layers are not moved (and the
##   way the workspace composes does not change) behind the operator's back.
##
## `conflicting_local_layer_is_refused`
##   the local file already declares `layer-a` with another visibility:
##   `repro health --fix` refuses, names both files, and changes NOTHING.
##
## No mocks: real files and directories, the real binary. Skip rule: none —
## nothing here needs git or the network.

import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_test_support

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

proc projectToml(repo: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\nincludes = [\"repos/" &
    repo & ".toml\"]\n\n[project]\nname = \"demo\"\n" &
    "default_revision = \"main\"\ntrunk = \"main\"\n\n[[remote]]\n" &
    "name = \"acme\"\nfetch = \"https://example.invalid/acme\"\n"

proc fragmentToml(name: string): string =
  "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\nname = \"" & name &
    "\"\npath = \"" & name & "\"\nremote = \"acme\"\nmainline = \"main\"\n"

const oldState = "schema = \"reprobuild.workspace.local.v1\"\n\n" &
  "# recorded by an older repro\n[workspace]\nproject = \"demo\"\n\n" &
  "[[manifest]]\nlocal_path = \".\"\nvisibility = \"public\"\n\n" &
  "[[manifest]]\nlocal_path = \"layer-a\"\nvisibility = \"public\"\n"

proc fixture(scratch: string): string =
  result = scratch / "ws"
  for dir in [result / "projects", result / "repos", result / ".repro",
              result / "layer-a" / "projects", result / "layer-a" / "repos"]:
    createDir(dir)
  writeFile(result / "projects" / "demo.toml", projectToml("core"))
  writeFile(result / "projects" / "other.toml",
    projectToml("core").replace("name = \"demo\"", "name = \"other\""))
  writeFile(result / "repos" / "core.toml", fragmentToml("core"))
  writeFile(result / "layer-a" / "projects" / "demo.toml",
    projectToml("extra"))
  writeFile(result / "layer-a" / "repos" / "extra.toml",
    fragmentToml("extra"))
  writeFile(result / ".repro" / "workspace.toml", oldState)

proc listed(root: string): tuple[code: int; stdout, stderr: string] =
  result = runRepro(["workspace", "list", "--workspace-root=" & root])
  checkpoint("workspace list exit=" & $result.code & "\nstdout: " &
    result.stdout & "\nstderr: " & result.stderr)

proc stateRow(root: string): JsonNode =
  ## The `workspace-state-file` row of `repro health --json`.
  let health = runRepro(["health", "--json", "--offline",
    "--workspace-root=" & root])
  checkpoint("health --json exit=" & $health.code & "\nstdout: " &
    health.stdout & "\nstderr: " & health.stderr)
  for row in parseJson(health.stdout)["checks"]:
    if row["name"].getStr() == "workspace-state-file":
      return row
  newJNull()

proc fix(root: string): tuple[code: int; stdout, stderr: string] =
  result = runRepro(["health", "--fix", "--offline",
    "--workspace-root=" & root])
  checkpoint("health --fix exit=" & $result.code & "\nstdout: " &
    result.stdout & "\nstderr: " & result.stderr)

suite "the state file carries no manifest layers":

  test "health_fix_moves_the_old_state_file_and_its_layers":
    let scratch = createTempDir("repro-state-layers-", "")
    defer: removeDir(scratch)
    let root = fixture(scratch)
    let oldPath = root / ".repro" / "workspace.toml"
    let statePath = root / ".repro" / "workspace-state.toml"
    let localPath = root / "repro-workspace.local.toml"

    # Leg 1 — before the migration the old file's layers compose.
    let before = listed(root)
    check before.code == 0
    check "core" in before.stdout
    check "extra" in before.stdout
    let pending = stateRow(root)
    require pending.kind == JObject
    check pending["status"].getStr() == "fail"
    check pending["fixable"].getBool()
    check "health --fix" in pending["remedy"].getStr()
    check oldPath in pending["detail"].getStr()
    check "2 `[[manifest]]` layer(s)" in pending["detail"].getStr()

    # Leg 2 — `health --fix` moves the file and the layers.
    let fixed = fix(root)
    check "moved the state file" in fixed.stdout
    check "moved manifest layer local_path 'layer-a'" in fixed.stdout
    check "dropped manifest layer local_path '.'" in fixed.stdout
    # The composition change is stated: the root is now the base layer and
    # so the lock record store unless `[records]` says otherwise.
    check "lock record store" in fixed.stdout
    check "[records]" in fixed.stdout
    check not fileExists(oldPath)
    require fileExists(statePath)
    let state = readFile(statePath)
    checkpoint("state file:\n" & state)
    # PRIMARY: the migrated state file carries no layer.
    check "[[manifest]]" notin state
    check "schema = \"reprobuild.workspace.state.v1\"" in state
    check "# recorded by an older repro" in state
    check "project = \"demo\"" in state
    require fileExists(localPath)
    let local = readFile(localPath)
    checkpoint("local file:\n" & local)
    check "schema = \"reprobuild.workspace.settings-local.v1\"" in local
    check local.count("[[manifest]]") == 1
    check "local_path = \"layer-a\"" in local
    check "visibility = \"public\"" in local
    let after = listed(root)
    check after.code == 0
    check "core" in after.stdout
    check "extra" in after.stdout
    let done = stateRow(root)
    require done.kind == JObject
    check done["status"].getStr() == "ok"

    # Leg 3 — a layer in the state file is now refused, naming file and key.
    writeFile(statePath, state &
      "\n[[manifest]]\nlocal_path = \"layer-a\"\nvisibility = \"public\"\n")
    let refused = listed(root)
    check refused.code != 0
    check statePath in refused.stderr
    check "'manifest'" in refused.stderr
    check "repro health --fix" in refused.stderr

    # Leg 4 — `health --fix` moves it out again, without a duplicate.
    let again = fix(root)
    check "already in the settings files" in again.stdout
    check "[[manifest]]" notin readFile(statePath)
    check readFile(localPath).count("[[manifest]]") == 1
    let restored = listed(root)
    check restored.code == 0
    check "extra" in restored.stdout

  test "first_state_write_moves_the_layers":
    let scratch = createTempDir("repro-state-layers-write-", "")
    defer: removeDir(scratch)
    let root = fixture(scratch)
    let oldPath = root / ".repro" / "workspace.toml"
    let statePath = root / ".repro" / "workspace-state.toml"
    let snapshot = root / ".repro" / "workspace.toml.at-migration"
    let localPath = root / "repro-workspace.local.toml"

    let enabled = runRepro(["ws", "enable", "other", "--no-sync",
      "--workspace-root=" & root])
    checkpoint("enable exit=" & $enabled.code & "\nstdout: " &
      enabled.stdout & "\nstderr: " & enabled.stderr)
    check enabled.code == 0
    require fileExists(statePath)
    check "[[manifest]]" notin readFile(statePath)
    require fileExists(localPath)
    check "local_path = \"layer-a\"" in readFile(localPath)
    # The old file is left for older repro builds, byte for byte.
    check readFile(oldPath) == oldState
    check fileExists(snapshot)
    check "now live in " & localPath in enabled.stderr
    check "lock record store" in enabled.stderr
    let composed = listed(root)
    check composed.code == 0
    check "extra" in composed.stdout

    let row = stateRow(root)
    require row.kind == JObject
    check row["status"].getStr() == "fail"
    check "left over" in row["detail"].getStr()
    let fixed = fix(root)
    check not fileExists(oldPath)
    check not fileExists(snapshot)
    check readFile(localPath).count("[[manifest]]") == 1
    let done = stateRow(root)
    require done.kind == JObject
    check done["status"].getStr() == "ok"
    discard fixed

  test "a_write_that_records_nothing_new_does_not_migrate":
    # Re-recording the project the old file already records changes nothing,
    # so it must not move the layers (and so change how the workspace
    # composes) behind the operator's back: nothing is written at all.
    let scratch = createTempDir("repro-state-layers-noop-", "")
    defer: removeDir(scratch)
    let root = fixture(scratch)
    let enabled = runRepro(["ws", "enable", "demo", "--no-sync",
      "--workspace-root=" & root])
    checkpoint("enable exit=" & $enabled.code & "\nstdout: " &
      enabled.stdout & "\nstderr: " & enabled.stderr)
    check enabled.code == 0
    check readFile(root / ".repro" / "workspace.toml") == oldState
    check not fileExists(root / ".repro" / "workspace-state.toml")
    check not fileExists(root / "repro-workspace.local.toml")

  test "conflicting_local_layer_is_refused":
    let scratch = createTempDir("repro-state-layers-conflict-", "")
    defer: removeDir(scratch)
    let root = fixture(scratch)
    let oldPath = root / ".repro" / "workspace.toml"
    let localPath = root / "repro-workspace.local.toml"
    let localText = "schema = \"reprobuild.workspace.settings-local.v1\"\n\n" &
      "[[manifest]]\nlocal_path = \"layer-a\"\nvisibility = \"team\"\n"
    writeFile(localPath, localText)

    let fixed = fix(root)
    check "could NOT migrate" in fixed.stdout
    check oldPath in fixed.stdout
    check localPath in fixed.stdout
    # Nothing changed.
    check readFile(oldPath) == oldState
    check readFile(localPath) == localText
    check not fileExists(root / ".repro" / "workspace-state.toml")
    let row = stateRow(root)
    require row.kind == JObject
    check row["status"].getStr() == "fail"
