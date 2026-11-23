## Named-Runnable-Edges N1 verification — `repro run <run-edge-name>`
## resolves a NAMED run-edge through the same target-export-table resolver
## `repro build` uses, materializes its dependency closure, and EXECUTES
## it. A second `repro run` of the same edge is action-cache warm on the
## build step (the tool is not relaunched).
##
## Spec cite: Named-Runnable-Edges.md §3.1 / §5; the N1 milestone
## Verification `t_e2e_repro_run_named_run_edge`.
##
## The fixture registers an ordinary `app-build` target and a separately
## named `run "app-run", build = "build-app"` run-target via the N0 DSL
## surface (`repro_resources`' `run`). `build-app` is a
## typed-tool edge that copies its input to `build/app` and appends a line
## to a marker file every time it actually fires — so the marker line count
## is an exact witness of how many times the edge was *executed* vs served
## warm from the action cache. `repro run app-run` must route the bare name
## through the `tekRunEdge` export row to that edge and run it; the second
## invocation must reuse the cache (marker stays at one line).

import std/[os, strutils, tempfiles, unittest]

import repro_test_support
import repro_interface_artifacts    # the live-provider mode compiles a REAL
                                    # provider (RP1 extract + provider compile)
import repro_hash                   # toHex, for the provider artifact id

proc reproBinary(repoRoot: string): string =
  requireBinary(repoRoot / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc writeExecutable(path, content: string) =
  createDir(path.splitPath.head)
  writeFile(path, content)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc writeRunTool(binDir: string) =
  ## Copies input to output and stamps a marker line each time it fires.
  when defined(windows):
    writeExecutable(binDir / "n1-tool.cmd",
      "@echo off\n" &
      "if \"%~1\"==\"--version\" (echo n1-tool 1.0.0& exit /b 0)\n" &
      "set \"input=\"\nset \"output=\"\nset \"marker=\"\nset \"forwarded=\"\n" &
      ":parse\n" &
      "if \"%~1\"==\"\" goto run\n" &
      "if \"%~1\"==\"--input\" set \"input=%~2\"& shift& shift& goto parse\n" &
      "if \"%~1\"==\"--output\" set \"output=%~2\"& shift& shift& goto parse\n" &
      "if \"%~1\"==\"--marker\" set \"marker=%~2\"& shift& shift& goto parse\n" &
      "if \"%~1\"==\"--forwarded\" set \"forwarded=%~2\"& shift& shift& goto parse\n" &
      "echo unknown arg %~1 1>&2\nexit /b 64\n" &
      ":run\n" &
      "set \"input=%input:/=\\%\"\n" &
      "set \"output=%output:/=\\%\"\n" &
      "set \"marker=%marker:/=\\%\"\n" &
      "for %%I in (\"%output%\") do if not exist \"%%~dpI\" mkdir \"%%~dpI\"\n" &
      "for %%I in (\"%marker%\") do if not exist \"%%~dpI\" mkdir \"%%~dpI\"\n" &
      "copy /Y \"%input%\" \"%output%\" >nul\n" &
      "if errorlevel 1 exit /b %errorlevel%\n" &
      "echo %output% %forwarded%>>\"%marker%\"\n")
  else:
    writeExecutable(binDir / "n1-tool",
      "#!/bin/sh\n" &
      "set -eu\n" &
      "if [ \"${1:-}\" = \"--version\" ]; then echo 'n1-tool 1.0.0'; exit 0; fi\n" &
      "input= output= marker= forwarded=\n" &
      "while [ \"$#\" -gt 0 ]; do\n" &
      "  case \"$1\" in\n" &
      "    --input) input=$2; shift 2 ;;\n" &
      "    --output) output=$2; shift 2 ;;\n" &
      "    --marker) marker=$2; shift 2 ;;\n" &
      "    --forwarded) forwarded=$2; shift 2 ;;\n" &
      "    *) echo \"unknown arg $1\" >&2; exit 64 ;;\n" &
      "  esac\n" &
      "done\n" &
      "mkdir -p \"$(dirname \"$output\")\" \"$(dirname \"$marker\")\"\n" &
      "cp \"$input\" \"$output\"\n" &
      "printf '%s %s\\n' \"$output\" \"$forwarded\" >> \"$marker\"\n")

# ---------------------------------------------------------------------------
# The live out-of-tree provider for the POSITIVE consumed-state mode.
#
# `n1.required`'s fake world is a FILE holding "<applyCounter>\n<value>".
# `apply` bumps the counter, `observe` reads it back — so the test can tell a
# real materialize from a reuse, and the file's existence proves the member was
# materialized BY THE PROVIDER CHILD rather than by anything in the CLI (which
# links neither this driver nor its attrs codec).
# ---------------------------------------------------------------------------

const liveProviderBody = """
import std/[options, os, strutils]
import repro_project_dsl
import repro_resources

type
  RequiredAttrs = object
    value*: string
    worldPath*: string

proc rqIdentity(inst: ResourceInstance): string {.nimcall.} =
  let a = TypedExtensionBox[RequiredAttrs](inst.attrs).val
  "n1:" & inst.address & ":" & a.worldPath

proc rqDigest(inst: ResourceInstance): Digest256 {.nimcall.} =
  let a = TypedExtensionBox[RequiredAttrs](inst.attrs).val
  digestString("n1\x00" & inst.address & "\x00" & a.value)

proc rqObserve(inst: ResourceInstance;
               recorded: Option[ResourceBinding]): ObservedState {.nimcall.} =
  let a = TypedExtensionBox[RequiredAttrs](inst.attrs).val
  if fileExists(a.worldPath):
    let lines = readFile(a.worldPath).split('\n')
    let realized = if lines.len >= 2: lines[1] else: ""
    result.present = true
    result.digest = digestString("n1\x00" & inst.address & "\x00" & realized)
  else:
    result.present = false

proc rqApply(inst: ResourceInstance; action: ResourceActionKind;
             observed: ObservedState): ResourceBinding {.nimcall.} =
  let a = TypedExtensionBox[RequiredAttrs](inst.attrs).val
  if action == rakDestroy:
    if fileExists(a.worldPath): removeFile(a.worldPath)
    return ResourceBinding(address: inst.address, typeId: inst.typeId,
      resourceId: rqIdentity(inst), present: false)
  var counter = 0
  if fileExists(a.worldPath):
    let lines = readFile(a.worldPath).split('\n')
    if lines.len >= 1:
      try: counter = parseInt(lines[0]) except ValueError: counter = 0
  inc counter
  writeFile(a.worldPath, $counter & "\n" & a.value)
  result = ResourceBinding(
    address: inst.address, typeId: inst.typeId,
    resourceId: rqIdentity(inst),
    postWriteDigest: rqDigest(inst), present: true)

let requiredDriver = ResourceProviderDriver(
  identity: rqIdentity, digest: rqDigest,
  observe: rqObserve, apply: rqApply)

resourceType "n1.required":
  attrs: RequiredAttrs
  wrapper: n1Required
  determinism: rdVolatile
  driver: requiredDriver
  attr value: string
  attr worldPath: string

package n1reqprov:
  build:
    discard
"""

proc buildLiveProvider(tempRoot: string): tuple[binary, artifactId: string] =
  ## Compile the provider the way the engine does: extract its lifted interface
  ## (RP1), then compile the provider binary against that fingerprint. The
  ## resulting absolute path + content-addressed id are what the recipe
  ## registers, so `repro run` harvests a REAL artifact rather than a literal.
  let projectRoot = tempRoot / "live-provider-src"
  let outDir = tempRoot / "live-provider-out"
  createDir(projectRoot)
  createDir(outDir)
  let modulePath = projectRoot / "reprobuild.nim"
  writeFile(modulePath, liveProviderBody)
  let interfacePath = outDir / "n1req-interface.rbsz"
  let stubPath = outDir / "n1req-interface.nim"
  let artifact = extractInterfaceFromModule(modulePath, interfacePath,
    stubPath, getCurrentDir())
  let binPath = outDir / "n1req-provider"
  let compilePath = outDir / "n1req-provider-compile.rbsz"
  let plan = providerCompilePlan(modulePath, binPath,
    artifact.interfaceFingerprint, getCurrentDir())
  let compiled = compileProviderBinary(modulePath, binPath,
    artifact.interfaceFingerprint, compilePath, getCurrentDir())
  (binary: compiled.outputBinaryPath,
   artifactId: toHex(plan.providerArtifactId.bytes))

proc writeRunEdgeProject(path: string; requiredMode = "";
                         liveProvider: tuple[binary, artifactId: string] =
                           ("", "")) =
  ## A typed-tool edge (`build-app`) plus a `run "app-run", build =
  ## "build-app"` run-target naming it. `import repro_resources` brings the
  ## N0 `run` surface into recipe scope.
  let projectRoot = path.splitPath.head
  createDir(projectRoot / "reprobuild" / "packages")
  writeFile(projectRoot / "reprobuild" / "packages" / "n1_tool.nim",
    "import repro_project_dsl\n\n" &
    "defineCliInterface n1Tool, \"n1-tool\":\n" &
    "  call:\n" &
    "    flag input is string, alias = \"--input\", role = input, required = true\n" &
    "    flag output is string, alias = \"--output\", role = output, required = true\n" &
    "    flag marker is string, alias = \"--marker\", required = true\n" &
    "    outputs output\n")
  writeFile(projectRoot / "reprobuild" / "packages" / "unused_tool.nim",
    "import repro_project_dsl\n\n" &
    "defineCliInterface unusedTool, \"unused-tool\":\n" &
    "  call:\n" &
    "    flag output is string, alias = \"--output\", role = output\n" &
    "    outputs output\n")
  var requiredState = ""
  if requiredMode == "live-provider":
    # The POSITIVE mode. Same consumer-side shape as the negative ones — the
    # attrs type and a DRIVERLESS provider def, registered in the recipe and
    # deliberately not linked into the engine, so the member is out-of-tree
    # from the CLI's point of view — but the artifact names a REAL compiled
    # provider that does serve the type. `worldPath` is absolute so the
    # provider child writes where the test can see it.
    requiredState = """
type RequiredAttrs = object
  value: string
  worldPath: string
registerExtension[RequiredAttrs]("n1.required")
registerResourceProvider(ResourceProviderDef(typeId: "n1.required",
  determinism: rdVolatile))
stateGroup "required-state":
  discard resource("n1.required", "required-member",
    RequiredAttrs(value: "up", worldPath: "@WORLD@"))
registerResourceProviderArtifact("n1.required", ResourceProviderArtifactRef(
  binaryPath: "@BINARY@", providerArtifactId: "@ARTIFACT@",
  workingDir: "@WORKDIR@"))
"""
    requiredState = requiredState
      .replace("@WORLD@", (projectRoot / "required-world.txt").replace("\\", "/"))
      .replace("@BINARY@", liveProvider.binary.replace("\\", "/"))
      .replace("@ARTIFACT@", liveProvider.artifactId)
      .replace("@WORKDIR@", getCurrentDir().replace("\\", "/"))
  elif requiredMode in ["missing-provider", "failed-provider"]:
    # Registered in the recipe, deliberately not linked into the engine.
    requiredState = """
type RequiredAttrs = object
  value: string
registerExtension[RequiredAttrs]("n1.required")
registerResourceProvider(ResourceProviderDef(typeId: "n1.required",
  determinism: rdVolatile))
stateGroup "required-state":
  discard resource("n1.required", "required-member", RequiredAttrs(value: "up"))
"""
    if requiredMode == "failed-provider":
      requiredState.add("""
registerResourceProviderArtifact("n1.required", ResourceProviderArtifactRef(
  binaryPath: "missing-required-provider", providerArtifactId: "n1-required",
  workingDir: "."))
""")
  writeFile(path,
    "import repro_project_dsl\n" &
    "import repro_resources\n\n" & requiredState & "\n" &
    "package n1RunPkg:\n" &
    "  usesImportPath \"reprobuild/packages\"\n" &
    "  uses:\n" &
    "    \"n1-tool >=1.0 <2.0\"\n" &
    "    \"unused-tool >=1.0 <2.0\"\n\n" &
    "  build:\n" &
    "    let marker = \".repro/n1-runs.log\"\n" &
    "    let app = n1Tool(actionId = \"build-app\",\n" &
    "      input = \"src/main.txt\",\n" &
    "      output = \"build/app\",\n" &
    "      marker = marker)\n" &
    "    discard target(\"app-build\", app)\n" &
    "    discard collect(\"lint\", [app])\n" &
    "    run(\"app-run\", build = \"build-app\")\n" &
    "    run(\"required-run\", build = \"build-app\",\n" &
    "      consumes = @[leased(\"required-state\", delayed(minutes = 30))])\n")

proc nonEmptyLines(path: string): seq[string] =
  if not fileExists(path):
    return @[]
  for line in readFile(path).splitLines:
    let stripped = line.strip()
    if stripped.len > 0:
      result.add(stripped)

proc runRun(reproBin, pathValue: string; cwd: string;
            extraArgs: openArray[string]): string =
  ## Run ``repro run <args>`` from ``cwd`` (asserts success). ``--daemon``
  ## is not a ``repro run`` flag; the delegated build inherits the default
  ## direct/daemon behaviour, so we pin determinism the same way the
  ## named-target build test does by forcing tool-provisioning=path via the
  ## environment the delegated ``repro build`` honours.
  var args = @[reproBin, "run"]
  for a in extraArgs:
    args.add(a)
  let entries = @[
    ("PATH", pathValue),
    ("REPRO_TOOL_PROVISIONING", "path"),
    ("REPROBUILD_NO_RUNQUOTA", "1"),
    ("REPRO_DAEMON", "off")
  ]
  requireSuccess(shellCommand(args, entries), cwd)

proc listRunTargets(reproBin, pathValue, cwd: string): string =
  requireSuccess(shellCommand(@[reproBin, "tasks"], @[
    ("PATH", pathValue),
    ("REPRO_TOOL_PROVISIONING", "path"),
    ("REPROBUILD_NO_RUNQUOTA", "1"),
    ("REPRO_DAEMON", "off")
  ]), cwd)

suite "t_e2e_repro_run_named_run_edge":

  test "t_e2e_repro_run_named_run_edge":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-n1-run-edge", "")
    defer: removeDir(tempRoot)

    let reproBin = reproBinary(repoRoot)

    let binDir = tempRoot / "bin"
    writeRunTool(binDir)
    let pathValue = binDir & $PathSep & getEnv("PATH")

    let projectRoot = tempRoot / "project"
    createDir(projectRoot / "src")
    writeFile(projectRoot / "src" / "main.txt", "main v1\n")
    writeRunEdgeProject(projectRoot / "reprobuild.nim")

    let listing = listRunTargets(reproBin, pathValue, projectRoot)
    check listing.contains("[run-edge]")
    check listing.contains("app-run")

    # First run: `repro run app-run` selects the `tekRunEdge` export name,
    # resolves it to `build-app`, then executes the tool once. The output
    # file + the single marker line are the authoritative witnesses that the
    # edge actually ran (stdout formatting is not asserted — the filesystem
    # effects are the meaningful check).
    let runArgs = ["app-run", "--", "--forwarded", "forwarded-one"]
    let firstRun = runRun(reproBin, pathValue, projectRoot, runArgs)
    checkpoint firstRun
    # ``unused-tool`` is absent from PATH and belongs to no action in this
    # closure. Focused execution must not provision unrelated project tools.
    check not firstRun.contains("unused-tool")
    checkpoint "marker: " & nonEmptyLines(
      projectRoot / ".repro" / "n1-runs.log").join(" | ")
    check fileExists(projectRoot / "build" / "app")
    check nonEmptyLines(projectRoot / ".repro" / "n1-runs.log").len == 1
    check nonEmptyLines(projectRoot / ".repro" / "n1-runs.log")[0].contains(
      "forwarded-one")

    # Second run: the build step is action-cache warm — the tool must NOT
    # be relaunched, so the marker stays at exactly one line. This proves
    # `repro run` delegated to the same action-cached build path.
    let secondRun = runRun(reproBin, pathValue, projectRoot, runArgs)
    checkpoint secondRun
    check nonEmptyLines(projectRoot / ".repro" / "n1-runs.log").len == 1

  test "required consumed state failures prevent the command from starting":
    # Named-Runnable-Edges section 3.2: required state precedes execution.
    # The SAME command without consumes remains runnable in every fixture.
    let reproBin = reproBinary(getCurrentDir())
    let tempRoot = createTempDir("repro-required-run", "")
    defer: removeDir(tempRoot)
    let binDir = tempRoot / "bin"
    writeRunTool(binDir)
    let pathValue = binDir & $PathSep & getEnv("PATH")
    let home = tempRoot / "home"
    createDir(home)
    for mode in ["missing-group", "missing-provider", "failed-provider"]:
      checkpoint mode
      let projectRoot = tempRoot / mode
      createDir(projectRoot / "src")
      writeFile(projectRoot / "src/main.txt", "required state witness\n")
      writeRunEdgeProject(projectRoot / "reprobuild.nim", mode)
      let env = @[
        ("PATH", pathValue), ("HOME", home), ("USERPROFILE", home),
        ("REPRO_TOOL_PROVISIONING", "path"),
        ("REPROBUILD_NO_RUNQUOTA", "1"), ("REPRO_DAEMON", "off")]
      let failed = runShell(shellCommand(@[reproBin, "run", "required-run"], env),
        projectRoot)
      checkpoint failed.output
      check failed.code != 0
      check failed.output.contains("repro run: error:")
      check failed.output.contains("required-run")
      case mode
      of "missing-group":
        check failed.output.contains("required-state")
        check failed.output.contains("missing, empty, or incomplete")
      of "missing-provider":
        check failed.output.contains("no provider session")
      else:
        check failed.output.contains("missing-required-provider")
      check not fileExists(projectRoot / ".repro" / "n1-runs.log")
      check not fileExists(projectRoot / "build" / "app")
      let control = requireSuccess(shellCommand(@[reproBin, "run", "app-run"], env),
        projectRoot)
      checkpoint control
      check nonEmptyLines(projectRoot / ".repro" / "n1-runs.log").len == 1

  test "a consumed out-of-tree group records its provider artifact end to end":
    ## Ephemeral-State-Leases.md §4.2 — the DURABLE half of the reap route,
    ## through the real `repro run`.
    ##
    ## This is the only case that brackets the whole chain in one pass:
    ##
    ##   recipe `registerResourceProviderArtifact`
    ##     -> the `reprobuild.resource-graph.v1` harvest
    ##     -> `resolution.providerArtifacts` in `runReproRunCommand`
    ##     -> `reconcileConsumedStateGroups`
    ##     -> `reconcileResourcesViaSession`
    ##     -> the state record's `providerArtifact`
    ##
    ## Every link had executed coverage except the hand-off from the resolution
    ## to the bridge, which was one argument at one call site covered by
    ## reading. (That argument is now a REQUIRED parameter, so dropping it is a
    ## compile error — this case is the behavioural confirmation on top.)
    ##
    ## WHY IT IS A REAL PROVIDER. The member type is served only by a binary
    ## compiled here: the `repro` CLI links neither its driver nor its attrs
    ## codec, so the member can only be materialized over a provider session,
    ## and the world file can only be written by the provider CHILD. The three
    ## negative modes above prove the failure paths; this proves the success
    ## path writes a record that names the way back.
    let repoRoot = getCurrentDir()
    let reproBin = reproBinary(repoRoot)
    let tempRoot = createTempDir("repro-live-provider-run", "")
    defer: removeDir(tempRoot)

    let provider = buildLiveProvider(tempRoot)
    check fileExists(provider.binary)
    check provider.artifactId.len > 0

    let binDir = tempRoot / "bin"
    writeRunTool(binDir)
    let pathValue = binDir & $PathSep & getEnv("PATH")
    # HOME is redirected, so the per-user lease store the run writes to is
    # under the temp root and this test can read the record back.
    let home = tempRoot / "home"
    createDir(home)
    let projectRoot = tempRoot / "live"
    createDir(projectRoot / "src")
    writeFile(projectRoot / "src/main.txt", "live provider witness\n")
    writeRunEdgeProject(projectRoot / "reprobuild.nim", "live-provider",
      provider)

    let env = @[
      ("PATH", pathValue), ("HOME", home), ("USERPROFILE", home),
      ("REPRO_TOOL_PROVISIONING", "path"),
      ("REPROBUILD_NO_RUNQUOTA", "1"), ("REPRO_DAEMON", "off")]

    let worldPath = projectRoot / "required-world.txt"
    check not fileExists(worldPath)

    # §4.3 (a) / §4.4 — SEED A RECORD THE START SWEEP MUST REPORT, in the store
    # this run will sweep. The opportunistic sweep at reconcile start
    # QUARANTINES a corrupt record as it scans, so a run that did not print its
    # findings would move the record aside and say nothing: the bytes survive,
    # but nothing tells the operator the resource that record described may now
    # be leaked with nothing naming its address. There is no daemon log behind
    # this sweep — the print in `runReproRunCommand` is the only report.
    #
    # This is the only route that covers that print: `runReproRunCommand` is
    # private, so nothing can call it directly; driving the real `repro run` is
    # what reaches it.
    let runStoreRoot = home / ".cache" / "repro" / "state"
    createDir(runStoreRoot)
    writeFile(runStoreRoot / "seeded-corrupt.rec", "\x00\x01\x02 not a record")

    let ran = runShell(shellCommand(@[reproBin, "run", "required-run"], env),
      projectRoot)
    checkpoint ran.output
    check ran.code == 0

    # THE FINDING WAS PRINTED, prefixed so its source is unambiguous.
    check ran.output.contains("repro run: lease reap:")
    check ran.output.contains("seeded-corrupt.rec")
    check ran.output.contains("quarantined")
    # ...and it did NOT change the exit code: the sweep touched state belonging
    # to a lapsed lease nobody asked for, so a stale record someone else left
    # must not fail this command (asserted by `ran.code == 0` above, with the
    # run's own work asserted below).
    # The sweep really did move it: it is out of the store root and into
    # `quarantine/`, which is what makes the printed finding actionable rather
    # than advisory.
    check not fileExists(runStoreRoot / "seeded-corrupt.rec")
    check dirExists(runStoreRoot / "quarantine")
    # The run-edge's own command fired, so the consumed state was materialized
    # BEFORE execution, as §3.2 requires.
    check nonEmptyLines(projectRoot / ".repro" / "n1-runs.log").len == 1

    # The member was materialized by the PROVIDER CHILD: the world file exists
    # and carries its apply counter. Nothing in the CLI could have written it.
    check fileExists(worldPath)
    let world = readFile(worldPath).splitLines()
    check world.len >= 2
    check world[0] == "1"
    check world[1] == "up"

    # THE RECORD NAMES THE ROUTE BACK. The per-user store under the redirected
    # HOME holds a record for the member, carrying exactly the artifact the
    # recipe registered — which is what lets a later daemon tick, `repro reap`,
    # or a reconcile-start sweep destroy it over a session, from the store
    # alone, in a process that links nothing of this provider.
    let storeRoot = home / ".cache" / "repro" / "state"
    check dirExists(storeRoot)
    var recordPaths: seq[string] = @[]
    for path in walkFiles(storeRoot / "*.rec"):
      recordPaths.add(path)
    check recordPaths.len > 0
    # The record file is named after the address; find the member's.
    var memberRecord = ""
    for path in recordPaths:
      if path.extractFilename.startsWith("required-member"):
        memberRecord = path
    check memberRecord.len > 0
    let raw = readFile(memberRecord)
    # Asserted on the BYTES, because this test links no state-store codec:
    # the record must contain the provider binary path and the artifact id the
    # recipe registered. An empty `providerArtifact` could not contain either.
    check raw.contains(provider.binary)
    check raw.contains(provider.artifactId)
    # ...and the envelope is the v5 format that can carry them.
    check raw.len > 8
    check raw[0 .. 3] == "RSST"
    check byte(raw[4]) == 5'u8
