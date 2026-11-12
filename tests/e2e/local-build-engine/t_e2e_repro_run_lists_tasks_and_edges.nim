## Named-Runnable-Edges N1 verification — `repro run --choose` (and
## `repro tasks`) lists BOTH a declared dev-env task AND a named run-edge,
## each labelled by source (`[task]` / `[run-edge]`), in a deterministic
## order.
##
## Spec cite: Named-Runnable-Edges.md §3.1 / §5; the N1 milestone
## Verification `t_e2e_repro_run_lists_tasks_and_edges`.
##
## The fixture declares a `devEnv:` block with a `task "greet"` and a
## `run "app-run", build = "build-app"` run-target. Both `repro run
## --choose` and `repro tasks` must show the task under `[task]` and the
## run-edge under `[run-edge]` — proving the listing merges the two
## resolution sources rather than the old task-only view.

import std/[os, strutils, tempfiles, unittest]

import repro_test_support
when not defined(windows):
  import repro_test_support/per_user_runquota

proc reproBinary(repoRoot: string): string =
  requireBinary(repoRoot / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc writeExecutable(path, content: string) =
  createDir(path.splitPath.head)
  writeFile(path, content)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc writeTool(binDir: string) =
  writeExecutable(binDir / "n1-tool",
    "#!/bin/sh\n" &
    "set -eu\n" &
    "if [ \"${1:-}\" = \"--version\" ]; then echo 'n1-tool 1.0.0'; exit 0; fi\n" &
    "input= output=\n" &
    "while [ \"$#\" -gt 0 ]; do\n" &
    "  case \"$1\" in\n" &
    "    --input) input=$2; shift 2 ;;\n" &
    "    --output) output=$2; shift 2 ;;\n" &
    "    *) echo \"unknown arg $1\" >&2; exit 64 ;;\n" &
    "  esac\n" &
    "done\n" &
    "mkdir -p \"$(dirname \"$output\")\"\n" &
    "cp \"$input\" \"$output\"\n")

proc writeProject(path: string) =
  ## A dev-env task ``greet`` and a named run-edge ``app-run`` coexist.
  let projectRoot = path.splitPath.head
  createDir(projectRoot / "reprobuild" / "packages")
  writeFile(projectRoot / "reprobuild" / "packages" / "n1_tool.nim",
    "import repro_project_dsl\n\n" &
    "defineCliInterface n1Tool, \"n1-tool\":\n" &
    "  call:\n" &
    "    flag input is string, alias = \"--input\", role = input, required = true\n" &
    "    flag output is string, alias = \"--output\", role = output, required = true\n" &
    "    outputs output\n")
  writeFile(path,
    "import repro_project_dsl\n" &
    "import repro_resources\n\n" &
    "package n1ListPkg:\n" &
    "  usesImportPath \"reprobuild/packages\"\n" &
    "  uses:\n" &
    "    \"n1-tool >=1.0 <2.0\"\n\n" &
    "  devEnv:\n" &
    "    task \"greet\", command = \"echo hi\", description = \"say hi\"\n\n" &
    "  build:\n" &
    "    n1Tool(actionId = \"build-app\",\n" &
    "      input = \"src/main.txt\",\n" &
    "      output = \"build/app\")\n" &
    "    run(\"app-run\", build = \"build-app\")\n")

proc writeTaskOnlyProject(path: string) =
  writeFile(path,
    "import repro_project_dsl\n\n" &
    "package n1TaskOnlyPkg:\n" &
    "  devEnv:\n" &
    "    task \"greet\", command = \"echo task-only-hi\", " &
      "description = \"say hi without a build graph\"\n")

when not defined(windows):
  # THE LISTING CASES BELOW RUN `repro` TOO, and `repro tasks` / `repro run`
  # adopt or start the user's shared per-user `runquotad` (reprobuild-pm
  # `spec/RunQuota-Host-Configuration.md`, "The shared per-user daemon
  # (POSIX)"). Without a scratch endpoint they would start, or adopt and ask
  # to make way, the real daemon of this uid -- shared with every other
  # process of the user. One scratch directory serves every case that does
  # not need its own, and `stopListingDaemon` stops what it collected.
  let listingEndpointDir = scratchUserEndpointDir()

  proc stopListingDaemon() =
    stopUserDaemon(userSocketIn(listingEndpointDir),
      lifetimeLockHolderPid(userSocketIn(listingEndpointDir)))

proc isolatedRunQuotaEntries(): seq[(string, string)] =
  ## The variables that keep a `repro` this test starts off the real
  ## per-user `runquotad`: the scratch endpoint directory, no inherited
  ## socket that would name another daemon (an empty one counts as unset),
  ## and the default scope spelled out (an empty one is an error), because a
  ## shell `repro exec` started publishes both.
  when not defined(windows):
    @[("RUNQUOTA_USER_ENDPOINT_DIR", listingEndpointDir),
      ("RUNQUOTA_SOCKET", ""), ("RUNQUOTA_ENDPOINT_SCOPE", "host")]
  else:
    @[]

proc runRepro(reproBin, pathValue: string; cwd: string;
              subArgs: openArray[string]): string =
  var args = @[reproBin]
  for a in subArgs:
    args.add(a)
  var entries = @[
    ("PATH", pathValue),
    ("REPRO_TOOL_PROVISIONING", "path"),
    ("REPRO_DAEMON", "off")
  ]
  entries.add(isolatedRunQuotaEntries())
  requireSuccess(shellCommand(args, entries), cwd)

suite "t_e2e_repro_run_lists_tasks_and_edges":

  when not defined(windows):
    test "task_runquota_autospawn":
      let daemonBin = requireRunQuotaDaemonBin(getCurrentDir())
      let reproBin = reproBinary(getCurrentDir())
      let tempRoot = createTempDir("repro-task-runquota", "")
      setFilePermissions(tempRoot, {fpUserRead, fpUserWrite, fpUserExec})
      defer: removeDir(tempRoot)
      let projectRoot = tempRoot / "project"
      createDir(projectRoot)
      writeTaskOnlyProject(projectRoot / "repro.nim")
      let binDir = tempRoot / "bin"
      # THE SHARED PER-USER DAEMON (POSIX): `repro run` adopts or starts one
      # daemon for the user, which outlives every invocation and is adopted
      # by the next (reprobuild-pm `spec/RunQuota-Host-Configuration.md`,
      # "The shared per-user daemon (POSIX)"). A scratch endpoint directory
      # keeps this case off the real per-user daemon of this uid, and the
      # daemon's identity is the holder of the endpoint's lifetime lock.
      # `RUNQUOTAD_BIN` is the real image, not a wrapper: a wrapper's digest
      # differs from the image the daemon runs, so every adoption would ask
      # the daemon to make way for "another build".
      let endpointDir = scratchUserEndpointDir()
      let userSocket = userSocketIn(endpointDir)
      var startedPid = 0
      defer: stopUserDaemon(userSocket, startedPid)
      proc invoke(bypass: string; target = "task:greet"): CmdResult =
        runShell(shellCommand(@[reproBin, "run", target], @[
          ("PATH", binDir & $PathSep & getEnv("PATH")),
          ("RUNQUOTAD_BIN", daemonBin),
          ("RUNQUOTA_SOCKET", tempRoot / "not-running.sock"),
          ("RUNQUOTA_USER_ENDPOINT_DIR", endpointDir),
          ("REPROBUILD_AUTO_RUNQUOTA", "1"),
          ("REPROBUILD_NO_RUNQUOTA", bypass),
          ("REPRO_TOOL_PROVISIONING", "path"),
          ("REPRO_DAEMON", "off")]), projectRoot)
      proc checkSameDaemonAlive() =
        ## The daemon the first run started is the one serving now: it
        ## outlived every run, and no run started another.
        check lifetimeLockHeld(userSocket)
        when defined(linux):
          check lifetimeLockHolderPid(userSocket) == startedPid
          check pidAlive(startedPid)
      let cold = invoke("0")
      checkpoint cold.output
      check cold.code == 0
      check cold.output.contains("task-only-hi")
      check lifetimeLockHeld(userSocket)
      startedPid = lifetimeLockHolderPid(userSocket)
      when defined(linux):
        check startedPid > 0
      checkSameDaemonAlive()
      let bypassed = invoke("1")
      checkpoint bypassed.output
      check bypassed.code == 0
      check bypassed.output.contains("task-only-hi")
      checkSameDaemonAlive()
      writeFile(projectRoot / "repro.nim", "not valid Nim syntax !!!\n")
      let failed = invoke("0")
      check failed.code != 0
      check not failed.output.contains("task-only-hi")
      checkSameDaemonAlive()
      writeTool(binDir)
      createDir(projectRoot / "src")
      writeFile(projectRoot / "src" / "main.txt", "main v1\n")
      writeProject(projectRoot / "repro.nim")
      let namedRun = invoke("0", "app-run")
      checkpoint namedRun.output
      check namedRun.code == 0
      check fileExists(projectRoot / "build" / "app")
      checkSameDaemonAlive()

  test "dev-env-only recipe lists and runs its task":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-n1-task-only", "")
    defer: removeDir(tempRoot)
    when not defined(windows):
      defer: stopListingDaemon()

    let reproBin = reproBinary(repoRoot)
    let projectRoot = tempRoot / "project"
    createDir(projectRoot)
    writeTaskOnlyProject(projectRoot / "repro.nim")

    let tasksOut = runRepro(reproBin, getEnv("PATH"), projectRoot,
      ["tasks"])
    check tasksOut.contains("[task]")
    check tasksOut.contains("greet")
    check tasksOut.contains("say hi without a build graph")

    let runOut = runRepro(reproBin, getEnv("PATH"), projectRoot,
      ["run", "task:greet"])
    check runOut.contains("task-only-hi")

  test "t_e2e_repro_run_lists_tasks_and_edges":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-n1-list", "")
    defer: removeDir(tempRoot)
    when not defined(windows):
      defer: stopListingDaemon()

    let reproBin = reproBinary(repoRoot)
    let binDir = tempRoot / "bin"
    writeTool(binDir)
    let pathValue = binDir & $PathSep & getEnv("PATH")

    let projectRoot = tempRoot / "project"
    createDir(projectRoot / "src")
    writeFile(projectRoot / "src" / "main.txt", "main v1\n")
    writeProject(projectRoot / "reprobuild.nim")

    # `repro run --choose` lists both the dev-env task and the run-edge,
    # each labelled by source.
    let chooseOut = runRepro(reproBin, pathValue, projectRoot,
      ["run", "--choose"])
    check chooseOut.contains("[task]")
    check chooseOut.contains("greet")
    check chooseOut.contains("[run-edge]")
    check chooseOut.contains("app-run")

    # `repro tasks` shows the same merged, source-labelled listing.
    let tasksOut = runRepro(reproBin, pathValue, projectRoot, ["tasks"])
    check tasksOut.contains("[task]")
    check tasksOut.contains("greet")
    check tasksOut.contains("[run-edge]")
    check tasksOut.contains("app-run")

    # The documented from-source spelling must be accepted by dev-env
    # introspection, and listing the run edge must not resolve the missing
    # build-only n1-tool from PATH.
    let sourceModeOut = requireSuccess(shellCommand(
      @[reproBin, "tasks"], @[
        ("PATH", getEnv("PATH")),
        ("REPRO_TOOL_PROVISIONING", "from-source"),
      ] & isolatedRunQuotaEntries()), projectRoot)
    check sourceModeOut.contains("[task]")
    check sourceModeOut.contains("greet")
    check sourceModeOut.contains("[run-edge]")
    check sourceModeOut.contains("app-run")
