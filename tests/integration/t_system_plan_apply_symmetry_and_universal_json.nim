## `repro system plan|apply` are `repro infra plan|apply` under the `repro
## system` namespace, and the read-only inspection and plan commands of the
## machine group print one JSON document with `--json`.
##
## Against the real `build/bin/repro`, in an isolated profile sandbox
## (`profile_compile_edge_harness`):
##
## * `system_plan_matches_infra_plan`: on one fixture `system.nim` that
##   declares two system files (under a per-run
##   `/etc/repro-sysjson-test-<pid>/`, which does not exist, so each plans as
##   a `create`), `repro system plan --json` and `repro infra plan --json`
##   give the same profile digest, host and operations, and each plan id is the
##   documented derivation (`computePlanId`) of that digest, the host and the
##   plan's own creation time -- the id differs between two runs only by the
##   second it was made in. The text reports are identical once the command
##   names and the plan id are taken out, and `system plan` names `repro
##   system apply` in its `apply with:` line. Vacuity: the operations are the
##   two creates, not an empty list two empty plans would share.
## * `system_apply_applies_the_plan_system_plan_printed`: on an
##   action-edge-only `system.nim` (`/bin/sh` writes a marker file), `repro
##   system apply --plan <id>` applies the plan `repro system plan --json`
##   printed: exit 0, the marker is written, and `repro system history
##   --json` lists one active generation recording that plan id; `repro
##   system audit --json` reads its log. Negative control: an unknown plan id
##   is refused by `system apply` exactly as by `infra apply` (same exit
##   code, no generation committed).
## * `every_inspection_and_plan_command_prints_one_json_document`: `system
##   plan|list|history|audit`, `infra plan`, `home plan|list|history` and
##   `capabilities` with `--json` exit as without it and print exactly one
##   JSON document on stdout (parsed with std/json, nothing after it), whose
##   `schemaId` names the command's schema. `home plan --json` keeps its exit
##   code: after a managed block is edited out of band it exits 1 and the
##   document says `failsOnDrift`; with `--allow-drift` it exits 0.
## * `capabilities_json_yields_to_an_explicit_format`: `capabilities --json`
##   and `--format=json --json` print JSON; `--json --format=text` and
##   `--format=text --json` print the text summary.
##
## No mocks: real `repro`, real Nim compiles of real profiles, the real
## planner (read-only observation of the absent files) and a real system
## apply whose only effect is the marker file under the sandbox
## (`requiresElevation = true` hands the edge to the apply's own broker
## closure, so nothing prompts), the same arrangement as the host-identity
## gates. The home profile declares no `hosts:` block, so neither the
## registry gate nor the base check consults the machine running the test.
## The home packages are bound through the documented
## `REPRO_TEST_PACKAGE_SOURCE` seam (`fixturePackageEnv`).
##
## Platforms: Linux and macOS. The marker edge is `/bin/sh` and a system
## apply on Windows needs an elevated broker; there the cases that apply are
## skipped with that reason, and the plan and capabilities cases still run.

import std/[json, os, strutils, unittest]

import repro_infra

import ../e2e/m83/profile_compile_edge_harness
import repro_test_support/reasoned_skip

const
  Host = "sysjson-host"
  CanApply = defined(linux) or defined(macosx)
    ## The marker edge is `/bin/sh`; see the header.
  ApplySkipReason = "a system apply needs the /bin/sh marker edge and, on " &
    "Windows, an elevated broker"

const HomeProfile = """
import repro_profile

profile "sysjsonHome":
  activity default:
    `sysjson-base`

  resources:
    fsManagedBlock(hostFile = "~/.sysjson-rc",
      blockId = "sysjson-block",
      content = "export SYSJSON=1",
      address = "sysjsonRc")
"""

proc markerProfile(markerDir: string): string =
  ## An action-edge-only system profile: `/bin/sh` writes a marker. Free of
  ## double quotes so it survives into the Nim literal.
  let cmd = "mkdir -p out; printf '%s' 'sysjson' > 'out/marker.txt'"
  """
import repro_profile

profile "sysjsonApply":
  resources:
    inlineExecCall(
      argv = @["/bin/sh", "-c", "@CMD@"],
      cwd = @CWD@,
      outputs = @["out/marker.txt"],
      requiresElevation = true,
      address = "sysjsonMarker",
      commandStatsId = "sysjson.marker")
""".multiReplace(("@CMD@", cmd), ("@CWD@", escape(markerDir)))

let FixtureEtcDir = "/etc/repro-sysjson-test-" & $getCurrentProcessId()
  ## Where the planned system files would go. The drivers accept only
  ## system directories, so this cannot be the sandbox; it is only
  ## observed (read-only), never written: nothing applies `files.nim`.
  ## Named per run so that no directory a host happens to have is used.

proc filesProfile(etcDir: string): string =
  ## Two system files under `etcDir`. They do not exist, so each plans as a
  ## `create`.
  """
import repro_profile

profile "sysjsonFiles":
  resources:
    fsSystemFile(path = @A@, content = "a\n", address = "aConf")
    fsSystemFile(path = @B@, content = "b\n", address = "bConf")
""".multiReplace(("@A@", escape(etcDir / "a.conf")),
    ("@B@", escape(etcDir / "b.conf")))

type Fixture = object
  sb: ProfileSandbox
  markerDir, etcDir: string
  markerPath, filesPath, listPath: string
  stateDir: string
  env: seq[(string, string)]

proc newFixture(label: string): Fixture =
  result.sb = newProfileSandbox(label, HomeProfile)
  result.markerDir = result.sb.root / "marker"
  result.etcDir = result.sb.root / "etc-fixture"
  createDir(result.markerDir)
  result.sb.writeProfileFile("system.nim", markerProfile(result.markerDir))
  result.sb.writeProfileFile("files.nim", filesProfile(FixtureEtcDir))
  result.markerPath = result.sb.profileDir / "system.nim"
  result.filesPath = result.sb.profileDir / "files.nim"
  # `repro system list` reads the profile as text (the structural editor's
  # format, which `repro system add` writes), not through the compile.
  result.listPath = result.sb.root / "list" / "system.nim"
  result.stateDir = result.sb.root / "infra-state"
  createDir(result.stateDir)
  result.env = @[("REPROBUILD_ACTION_CACHE_ROOT",
                  result.sb.root / "action-cache")]
  result.env.add result.sb.fixturePackageEnv(["sysjson-base"])

proc run(f: Fixture; args: openArray[string]): ReproRun =
  result = f.sb.runRepro(args, host = Host, extraEnv = f.env)
  checkpoint("repro " & args.join(" ") & " -> " & $result.exitCode &
    "\n--- stdout\n" & result.stdout & "\n--- stderr\n" & result.stderr)

proc onProfile(f: Fixture; profile: string; args: openArray[string]): ReproRun =
  ## A system-scope command against `profile` and the fixture's state dir.
  f.run(@args & @["--profile", profile, "--state-dir", f.stateDir])

proc inState(f: Fixture; args: openArray[string]): ReproRun =
  ## A command that reads only the fixture's state dir (`history`, `audit`).
  f.run(@args & @["--state-dir", f.stateDir])

proc oneDocument(r: ReproRun): JsonNode =
  ## The single JSON document `r` printed on stdout. Fails the test (and
  ## returns an empty object) when stdout is not exactly one document:
  ## `parseJson` refuses trailing text after the first value.
  try:
    result = parseJson(r.stdout)
  except CatchableError as e:
    checkpoint("stdout is not one JSON document: " & e.msg)
    check false
    return newJObject()
  check result.kind == JObject

proc field(output, label: string): string =
  ## The value of a `  <label> : <value>` report line ("" when absent).
  for line in output.splitLines():
    let s = line.strip()
    if s.startsWith(label):
      let rest = s[label.len .. ^1].strip()
      if rest.startsWith(":"):
        return rest[1 .. ^1].strip()
  ""

proc operationsOf(doc: JsonNode): seq[string] =
  for op in doc{"operations"}.getElems():
    result.add op{"address"}.getStr() & " " & op{"kind"}.getStr() & " " &
      op{"action"}.getStr() & " " & op{"desiredDigest"}.getStr()

proc withoutPlanSpecifics(text, planId, namespace: string): string =
  ## A text plan report with what may differ between the two spellings
  ## taken out: the command's name and the plan id.
  text.multiReplace((planId, "<plan-id>"),
    ("repro " & namespace & " plan", "repro <ns> plan"),
    ("repro " & namespace & " apply", "repro <ns> apply"))

suite "repro system plan|apply and universal --json":

  test "system_plan_matches_infra_plan":
    let f = newFixture("sysjson-plan")
    defer: f.sb.dispose()
    # Every planned file must be absent for both to plan two creates.
    require not dirExists(FixtureEtcDir)
    let viaSystem = f.onProfile(f.filesPath, ["system", "plan", "--json"])
    let viaInfra = f.onProfile(f.filesPath, ["infra", "plan", "--json"])
    require viaSystem.exitCode == 0
    require viaInfra.exitCode == 0
    let s = viaSystem.oneDocument()
    let i = viaInfra.oneDocument()
    check s{"schemaId"}.getStr() == "reprobuild.system.plan.v1"
    check i{"schemaId"}.getStr() == "reprobuild.system.plan.v1"
    check s{"command"}.getStr() == "repro system plan"
    check i{"command"}.getStr() == "repro infra plan"
    check s{"host"}.getStr() == Host
    check i{"host"}.getStr() == Host
    # The same planned profile, and the same operations, in the same order.
    check s{"profileDigest"}.getStr().len == 64
    check s{"profileDigest"}.getStr() == i{"profileDigest"}.getStr()
    check operationsOf(s) == operationsOf(i)
    check s{"changeCount"}.getInt() == 2
    check i{"changeCount"}.getInt() == 2
    check operationsOf(s).len == 2
    for op in s{"operations"}.getElems():
      check op{"action"}.getStr() == "create"
    # Each id is the planner's derivation of that digest, the host and the
    # plan's creation second.
    for doc in [s, i]:
      check doc{"planId"}.getStr() == computePlanId(
        doc{"profileDigest"}.getStr(), Host,
        doc{"createdTimestamp"}.getBiggestInt())
    check s{"applyCommand"}.getStr() ==
      "repro system apply --plan " & s{"planId"}.getStr()
    check i{"applyCommand"}.getStr() ==
      "repro infra apply --plan " & i{"planId"}.getStr()
    # The text reports agree too, but for the command names and the id.
    let sText = f.onProfile(f.filesPath, ["system", "plan"])
    let iText = f.onProfile(f.filesPath, ["infra", "plan"])
    require sText.exitCode == 0
    require iText.exitCode == 0
    check sText.stdout.startsWith("repro system plan\n")
    check ("apply with: repro system apply --plan " &
      sText.stdout.field("plan-id")) in sText.stdout
    check withoutPlanSpecifics(sText.stdout, sText.stdout.field("plan-id"),
      "system") == withoutPlanSpecifics(iText.stdout,
      iText.stdout.field("plan-id"), "infra")

  test "system_apply_applies_the_plan_system_plan_printed":
    when CanApply:
      let f = newFixture("sysjson-apply")
      defer: f.sb.dispose()
      # Negative control first: an id no plan has is refused by both
      # spellings alike, and nothing is committed.
      let bogus = "0123456789abcdef0123456789abcdef"
      let refusedSystem = f.onProfile(f.markerPath,
        ["system", "apply", "--plan", bogus])
      let refusedInfra = f.onProfile(f.markerPath,
        ["infra", "apply", "--plan", bogus])
      check refusedSystem.exitCode != 0
      check refusedSystem.exitCode == refusedInfra.exitCode
      check "repro system apply: " in refusedSystem.stderr
      check "repro infra apply: " in refusedInfra.stderr
      let none = f.inState(["system", "history", "--json"])
      check none.exitCode == 0
      check none.oneDocument(){"generations"}.getElems().len == 0

      let plan = f.onProfile(f.markerPath, ["system", "plan", "--json"])
      require plan.exitCode == 0
      let planId = plan.oneDocument(){"planId"}.getStr()
      check planId.len == 32
      let apply = f.onProfile(f.markerPath,
        ["system", "apply", "--plan", planId])
      check apply.exitCode == 0
      check apply.stdout.startsWith("repro system apply\n")
      check apply.stdout.field("plan-id") == planId
      let generation = apply.stdout.field("generation")
      check generation.len > 0
      check fileExists(f.markerDir / "out" / "marker.txt")
      let history = f.inState(["system", "history", "--json"])
      check history.exitCode == 0
      let gens = history.oneDocument(){"generations"}.getElems()
      check gens.len == 1
      if gens.len == 1:
        check gens[0]{"generationId"}.getStr() == generation
        check gens[0]{"planId"}.getStr() == planId
        check gens[0]{"active"}.getBool()
        check gens[0]{"host"}.getStr() == Host
      let audit = f.inState(["system", "audit", "--json"])
      check audit.exitCode == 0
      let log = audit.oneDocument()
      check log{"schemaId"}.getStr() == "reprobuild.system.audit.v1"
      check log{"generation"}.getStr() == generation
      check log{"buildActionRecords"}.getInt() >= 1
      check log{"records"}.getElems().len == log{"liveStateRecords"}.getInt() +
        log{"buildActionRecords"}.getInt()
    else:
      skip(ApplySkipReason)

  test "every_inspection_and_plan_command_prints_one_json_document":
    when CanApply:
      let f = newFixture("sysjson-every")
      defer: f.sb.dispose()
      # State for the history, audit and list commands to read.
      require f.run(["home", "apply"]).exitCode == 0
      require f.onProfile(f.markerPath,
        ["system", "apply", "--no-preview"]).exitCode == 0
      require f.run(["system", "add", "fs.systemFile",
        "path=" & f.etcDir / "listed.conf", "content=listed",
        "--profile", f.listPath, "--state-dir", f.stateDir]).exitCode == 0

      for (args, schema, code) in [
          (@["system", "plan", "--profile", f.filesPath, "--state-dir",
             f.stateDir], "reprobuild.system.plan.v1", 0),
          (@["infra", "plan", "--profile", f.filesPath, "--state-dir",
             f.stateDir], "reprobuild.system.plan.v1", 0),
          (@["system", "list", "--profile", f.listPath, "--state-dir",
             f.stateDir], "reprobuild.system.list.v1", 0),
          (@["system", "history", "--state-dir", f.stateDir],
           "reprobuild.system.history.v1", 0),
          (@["system", "audit", "--state-dir", f.stateDir],
           "reprobuild.system.audit.v1", 0),
          (@["home", "plan"], "reprobuild.home.plan.v2", 0),
          (@["home", "list"], "reprobuild.home.list.v1", 0),
          (@["home", "history"], "reprobuild.home.history.v1", 0),
          (@["capabilities"], "reprobuild.capabilities.v1", 0)]:
        let text = f.run(args)
        let json = f.run(args & @["--json"])
        check text.exitCode == code
        check json.exitCode == code
        let doc = json.oneDocument()
        check doc{"schemaId"}.getStr() == schema
        # The flag changed the output: every one of these prints text by
        # default except `capabilities`, whose default is already JSON.
        if args[0] == "capabilities":
          check text.stdout == json.stdout
        else:
          check text.stdout != json.stdout

      # What the documents carry, from the state built above.
      let list = f.onProfile(f.listPath, ["system", "list", "--json"])
      let resources = list.oneDocument(){"resources"}.getElems()
      check resources.len == 1
      if resources.len == 1:
        check resources[0]{"kind"}.getStr() == "fs.systemFile"
        check resources[0]{"address"}.getStr() ==
          "systemFile:" & f.etcDir / "listed.conf"
      let homeList = f.run(["home", "list", "--json"]).oneDocument()
      check homeList{"host"}.getStr() == Host
      var packages: seq[string]
      for p in homeList{"packages"}.getElems():
        packages.add p{"package"}.getStr() & " " & p{"state"}.getStr() &
          " " & p{"activity"}.getStr()
      check packages == @["sysjson-base enabled default"]
      let homeHistory = f.run(["home", "history", "--json"]).oneDocument()
      let homeGens = homeHistory{"generations"}.getElems()
      check homeGens.len == 1
      if homeGens.len == 1:
        check homeGens[0]{"active"}.getBool()
        check homeGens[0]{"host"}.getStr() == Host

      # `home plan --json` keeps its exit code: drift exits 1, and the
      # document says why.
      let clean = f.run(["home", "plan", "--json"]).oneDocument()
      check clean{"driftCount"}.getInt() == 0
      check not clean{"failsOnDrift"}.getBool()
      let rc = f.sb.homeDir / ".sysjson-rc"
      require fileExists(rc)
      writeFile(rc, readFile(rc).replace("export SYSJSON=1",
        "export SYSJSON=edited-by-hand"))
      let drifted = f.run(["home", "plan", "--json"])
      check drifted.exitCode == 1
      let driftDoc = drifted.oneDocument()
      check driftDoc{"driftCount"}.getInt() == 1
      check driftDoc{"failsOnDrift"}.getBool()
      var driftActions: seq[string]
      for op in driftDoc{"operations"}.getElems():
        let a = op{"resource"}
        if a.kind == JObject and a{"action"}.getStr() == "drift_blocked":
          check op{"action"}.getStr() == "conflict-drift"
          driftActions.add a{"address"}.getStr()
      check driftActions == @["sysjsonRc"]
      let allowed = f.run(["home", "plan", "--json", "--allow-drift"])
      check allowed.exitCode == 0
      check not allowed.oneDocument(){"failsOnDrift"}.getBool()
      # The text form agrees on the exit code.
      check f.run(["home", "plan"]).exitCode == 1
    else:
      skip(ApplySkipReason)

  test "capabilities_json_yields_to_an_explicit_format":
    let f = newFixture("sysjson-caps")
    defer: f.sb.dispose()
    for args in [@["capabilities", "--json"],
                 @["capabilities", "--format=json", "--json"],
                 @["capabilities", "--json", "--format", "json"]]:
      let r = f.run(args)
      check r.exitCode == 0
      check r.oneDocument(){"schemaId"}.getStr() ==
        "reprobuild.capabilities.v1"
    let plainText = f.run(["capabilities", "--format=text"])
    check plainText.exitCode == 0
    check plainText.stdout.startsWith("schemaId: reprobuild.capabilities.v1")
    for args in [@["capabilities", "--json", "--format=text"],
                 @["capabilities", "--format=text", "--json"]]:
      let r = f.run(args)
      check r.exitCode == 0
      check r.stdout == plainText.stdout
