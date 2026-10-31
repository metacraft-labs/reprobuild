## `down` must not mistake an inactive default record for the project's
## named session. These tests drive the real CLI over persisted session and
## shared-holder records on the real filesystem. No processes, HTTP peers or
## lease clients are mocked: this is the pre-stop selection boundary, so the
## prior history is staged as the records a supervisor/resolver leaves behind.
## Byte-for-byte preservation proves refusal happens before stop or release.

import std/[json, os, strtabs, strutils, tempfiles, unittest]

import repro_test_support

type Fixture = object
  root, binary: string
  env: StringTableRef

proc fixture(): Fixture =
  result.root = createTempDir("repro-down-activities-", "")
  writeFile(result.root / "reprobuild.nim", "import repro_project_dsl\n")
  result.binary = requireBinary(getCurrentDir() / "build" / "bin" /
    addFileExt("repro", ExeExt), "reprobuild.apps.repro")
  result.env = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    if key != "REPROBUILD_WORK_ROOT":
      result.env[key] = value

proc outDir(f: Fixture; segment: string): string =
  f.root / ".repro" / "dev-env" / segment

proc metadata(f: Fixture; segment, activity, status: string): string =
  result = f.outDir(segment) / "session" / "session.json"
  createDir(result.parentDir)
  writeFile(result, $(%*{
    "schemaId": "reprobuild.dev-session.v1", "sessionId": segment,
    "projectRoot": f.root, "activity": activity, "status": status,
    "httpBind": "127.0.0.1:1"}) & "\n")

proc ledger(f: Fixture; segment: string): string =
  result = f.outDir(segment) / "session" / "shared-instances.json"
  createDir(result.parentDir)
  writeFile(result, $(%*{
    "schemaId": "reprobuild.dev-session.shared-instances.v1",
    "holderId": "project:" & f.root,
    "instances": [{"serviceName": "sso", "keyJson": "{}",
      "address": "service:workspace:selection-probe"}]}) & "\n")

proc down(f: Fixture; args: seq[string] = @[]): CmdSplitResult =
  result = runProgramSplit(f.binary, @["down", f.root] & args,
    getCurrentDir(), f.env)
  checkpoint "down " & args.join(" ") & " exit " & $result.code &
    "\n" & result.stdout & result.stderr

suite "down: discover named sessions before default stop or release":
  test "e2e_down_refuses_named_session_with_stale_or_absent_default":
    let f = fixture()
    defer: removeDir(f.root)
    let named = f.metadata("deps_monolithSharedIdentity",
      "deps,monolithSharedIdentity", "up")
    let holders = f.ledger("deps_monolithSharedIdentity")
    let originalSession = readFile(named)
    let originalHolders = readFile(holders)
    for withDefault in [false, true]:
      if withDefault:
        discard f.metadata("default", "default", "down")
      let refused = f.down()
      check refused.code == 1
      check refused.stderr.contains("select an activity explicitly")
      check refused.stderr.contains("--activity=deps,monolithSharedIdentity")
      check refused.stderr.contains(named)
      check readFile(named) == originalSession
      check readFile(holders) == originalHolders

  test "e2e_down_refuses_all_named_sessions_before_touching_live_default":
    let f = fixture()
    defer: removeDir(f.root)
    let defaultSession = f.metadata("default", "default", "up")
    let defaultHolders = f.ledger("default")
    discard f.metadata("debug", "debug", "starting")
    discard f.metadata("tools", "tools", "stopping")
    let sessionBefore = readFile(defaultSession)
    let holdersBefore = readFile(defaultHolders)
    let refused = f.down(@["--force"])
    check refused.code == 1
    check refused.stderr.contains("--activity=debug")
    check refused.stderr.contains("--activity=tools")
    check readFile(defaultSession) == sessionBefore
    check readFile(defaultHolders) == holdersBefore
    check not fileExists(f.outDir("default") / "session" / "stop.request.json")

  test "e2e_down_discovers_named_ledger_without_session_metadata":
    let f = fixture()
    defer: removeDir(f.root)
    discard f.metadata("default", "default", "down")
    let holders = f.ledger("deps_monolithSharedIdentity")
    let original = readFile(holders)
    let refused = f.down()
    check refused.code == 1
    check refused.stderr.contains("select an activity explicitly")
    check refused.stderr.contains(holders)
    check refused.stderr.contains("deps_monolithSharedIdentity")
    check readFile(holders) == original
    # A stopped supervisor does not prove its shared holders were released.
    discard f.metadata("deps_monolithSharedIdentity",
      "deps,monolithSharedIdentity", "down")
    let stoppedWithHolders = f.down()
    check stoppedWithHolders.code == 1
    check stoppedWithHolders.stderr.contains("--activity=deps,monolithSharedIdentity")
    check readFile(holders) == original

  test "e2e_down_explicit_activity_stays_scoped_and_is_idempotent":
    let f = fixture()
    defer: removeDir(f.root)
    discard f.metadata("default", "default", "down")
    let named = f.metadata("debug", "debug", "up")
    discard f.metadata("deps_tools", "deps,tools", "down")
    let original = readFile(named)
    for args in [@["--activity=default"],
                 @["--activity", "deps", "--activity", "tools"]]:
      let scoped = f.down(args)
      check scoped.code == 0
      check scoped.stdout.contains("already down")
      check readFile(named) == original

  test "e2e_down_ignores_inactive_named_records_and_reports_already_down":
    let f = fixture()
    defer: removeDir(f.root)
    discard f.metadata("default", "default", "down")
    discard f.metadata("debug", "debug", "down")
    createDir(f.outDir("artifact-only"))
    let stopped = f.down()
    check stopped.code == 0
    check stopped.stdout.contains("already down")

  test "e2e_down_discovery_stays_in_the_selected_work_root":
    let f = fixture()
    defer: removeDir(f.root)
    discard f.metadata("default", "default", "down")
    discard f.metadata("debug", "debug", "up")
    let workRoot = f.root / "external-work"
    for explicitRoot in [true, false]:
      if not explicitRoot:
        f.env["REPROBUILD_WORK_ROOT"] = workRoot
      let missing = f.down(if explicitRoot: @["--work-root", workRoot] else: @[])
      check missing.code == 1
      check missing.stderr.contains(workRoot)
      check not missing.stderr.contains("select an activity explicitly")
      check not missing.stderr.contains("--activity=debug")

  test "e2e_down_does_not_treat_unreadable_named_records_as_inactive":
    let f = fixture()
    defer: removeDir(f.root)
    discard f.metadata("default", "default", "down")
    let named = f.metadata("debug", "debug", "up")
    writeFile(named, "this is not JSON\n")
    let corrupt = f.down()
    check corrupt.code == 1
    check corrupt.stderr.contains(named)
    check readFile(named) == "this is not JSON\n"
