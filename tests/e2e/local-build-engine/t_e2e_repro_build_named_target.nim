## Named-Targets M2 verification: end-to-end build of a single named
## target via the existing local-build-engine fixture pattern. Asserts
## that the binary lands at the expected path AND the action-cache key
## matches the path-selector equivalent — i.e. the same edge is reached
## regardless of whether the CLI received an implicit name or the
## ``<path>#<action>`` fragment form.
##
## The fixture project defines a single typed-tool wrapper with an
## ``outputs output`` statement, so the engine's M1 wiring computes
## ``targetNames == @["app"]`` for an edge producing ``build/app``.
## The resolver in ``runBuildCommand`` should pick the edge up by the
## bare name ``app`` and route it through the same action-id path that
## ``<projectRoot>#build-app`` follows.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support

proc pathExists(path: string): bool =
  try:
    discard getFileInfo(path, followSymlink = false)
    true
  except OSError:
    false

proc ensureRunQuotaDaemon(repoRoot: string): tuple[process: owned(Process);
    socket: string] =
  let runquotaRoot = repoRoot.parentDir / "runquota"
  let daemonBin = runquotaRoot / "build" / "bin" / addFileExt("runquotad", ExeExt)
  if not fileExists(daemonBin):
    raise newException(OSError,
      "runquotad binary missing at " & daemonBin)
  let socketPath = "/tmp/repro-m2-named-rq-" & $getCurrentProcessId() & ".sock"
  if fileExists(socketPath):
    removeFile(socketPath)
  let daemon = startProcess(daemonBin, args = [
    "--socket", socketPath,
    "--cpu-milli", "16000",
    "--memory-bytes", "17179869184"
  ], options = {poUsePath})
  putEnv("RUNQUOTA_SOCKET", socketPath)
  for _ in 0 ..< 200:
    if pathExists(socketPath):
      return (process: daemon, socket: socketPath)
    sleep(25)
  daemon.terminate()
  raise newException(OSError, "runquotad socket did not appear")

proc writeExecutable(path, content: string) =
  createDir(path.splitPath.head)
  writeFile(path, content)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc writeM2Tool(binDir: string) =
  ## Tiny shell-based tool that copies the input file to the output and
  ## stamps a marker so we can assert exactly which edges fired.
  writeExecutable(binDir / "m2-tool",
    "#!/bin/sh\n" &
    "set -eu\n" &
    "if [ \"${1:-}\" = \"--version\" ]; then echo 'm2-tool 1.0.0'; exit 0; fi\n" &
    "input= output= marker=\n" &
    "while [ \"$#\" -gt 0 ]; do\n" &
    "  case \"$1\" in\n" &
    "    --input) input=$2; shift 2 ;;\n" &
    "    --output) output=$2; shift 2 ;;\n" &
    "    --marker) marker=$2; shift 2 ;;\n" &
    "    *) echo \"unknown arg $1\" >&2; exit 64 ;;\n" &
    "  esac\n" &
    "done\n" &
    "mkdir -p \"$(dirname \"$output\")\" \"$(dirname \"$marker\")\"\n" &
    "cp \"$input\" \"$output\"\n" &
    "printf '%s\\n' \"$output\" >> \"$marker\"\n")

proc writeNamedTargetProject(path: string) =
  ## The project defines a typed-tool wrapper carrying an
  ## ``outputs output`` statement so the engine records the basename of
  ## the call's ``--output`` value as the edge's implicit name. The
  ## ``build:`` body fires one call producing ``build/app``, whose
  ## implicit name becomes ``app``.
  let projectRoot = path.splitPath.head
  createDir(projectRoot / "reprobuild" / "packages")
  writeFile(projectRoot / "reprobuild" / "packages" / "m2_tool.nim",
    "import repro_project_dsl\n\n" &
    "defineCliInterface m2Tool, \"m2-tool\":\n" &
    "  call:\n" &
    "    flag input is string, alias = \"--input\", role = input, required = true\n" &
    "    flag output is string, alias = \"--output\", role = output, required = true\n" &
    "    flag marker is string, alias = \"--marker\", required = true\n" &
    "    outputs output\n")
  writeFile(path,
    "import repro_project_dsl\n\n" &
    "package m2NamedPkg:\n" &
    "  usesImportPath \"reprobuild/packages\"\n" &
    "  uses:\n" &
    "    \"m2-tool >=1.0 <2.0\"\n\n" &
    "  build:\n" &
    "    let marker = \".repro/m2-runs.log\"\n" &
    "    m2Tool(actionId = \"build-app\",\n" &
    "      input = \"src/main.txt\",\n" &
    "      output = \"build/app\",\n" &
    "      marker = marker)\n")

proc valueAfter(output, prefix: string): string =
  for line in output.splitLines:
    if line.startsWith(prefix):
      return line[prefix.len .. ^1].strip()
  ""

proc nonEmptyLines(path: string): seq[string] =
  if not fileExists(path):
    return @[]
  for line in readFile(path).splitLines:
    let stripped = line.strip()
    if stripped.len > 0:
      result.add(stripped)

proc runBuild(reproBin, repoRoot, pathValue: string;
              cwd: string;
              extraArgs: openArray[string]): string =
  ## Run ``repro build <args>`` from ``cwd`` and return the merged
  ## stdout/stderr. Asserts success so the test fails fast on any
  ## non-zero exit code.
  var args = @[reproBin, "build"]
  for a in extraArgs:
    args.add(a)
  args.add("--tool-provisioning=path")
  args.add("--log=actions")
  let entries = @[("PATH", pathValue)]
  requireSuccess(shellCommand(args, entries), cwd)

suite "t_e2e_repro_build_named_target":

  test "t_e2e_repro_build_named_target":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-m2-named-target", "")
    defer: removeDir(tempRoot)

    var daemon = ensureRunQuotaDaemon(repoRoot)
    defer:
      daemon.process.terminate()
      discard daemon.process.waitForExit()
      daemon.process.close()
      if pathExists(daemon.socket):
        removeFile(daemon.socket)

    let reproBin = tempRoot / "repro"
    discard requireSuccess(shellCommand([
      "nim", "c", "--verbosity:0", "--hints:off",
      "--nimcache:" & (tempRoot / "nimcache-repro"),
      "--out:" & reproBin,
      repoRoot / "apps" / "repro" / "repro.nim"
    ]), repoRoot)

    let binDir = tempRoot / "bin"
    writeM2Tool(binDir)
    let pathValue = binDir & $PathSep & getEnv("PATH")

    # Single project directory exercises both selector forms so the
    # action-cache key parity check below is an apples-to-apples
    # comparison: any reused cache entry must have been deposited by
    # the previous run against the SAME on-disk cache scope.
    let projectRoot = tempRoot / "project"
    createDir(projectRoot / "src")
    writeFile(projectRoot / "src" / "main.txt", "main v1\n")
    writeNamedTargetProject(projectRoot / "reprobuild.nim")

    # First run: build via path/fragment selector — the legacy form
    # already supported by ``parseBuildTarget``. This populates the
    # action cache with the ``build-app`` edge's entry under whatever
    # cache key the engine derived.
    let pathRun = runBuild(reproBin, repoRoot, pathValue, repoRoot,
      [projectRoot & "#build-app"])
    check pathRun.contains("selectedTarget: build-app")
    check pathRun.contains("scheduler: actions=1")
    check pathRun.contains(
      "action: build-app status=asSucceeded launched=true")
    check fileExists(projectRoot / "build" / "app")
    check nonEmptyLines(projectRoot / ".repro" / "m2-runs.log").len == 1

    # Second run: invoke the SAME edge by its IMPLICIT NAME (``app``)
    # via ``cd <projectRoot> && repro build app``. The M2 resolver must
    # route the bare name through the M1 target-export table to the
    # same ``build-app`` action. Because the cache was populated by the
    # path-form run above, this run must be a cache HIT — proving that
    # the action-cache key derived from the name-selector path is
    # identical to the one derived from the path/fragment selector.
    let nameRun = runBuild(reproBin, repoRoot, pathValue, projectRoot,
      ["app"])
    # ``selectedTarget`` echoes the user-facing selector
    # (``parseBuildTarget`` stashed ``app`` as the fragment) — the
    # resolver translates it to ``build-app`` only inside
    # ``lowerProviderSnapshot``. The cache-parity check below is the
    # authoritative same-edge assertion.
    check nameRun.contains("selectedTarget: app") or
      nameRun.contains("selectedTarget: build-app")
    check nameRun.contains("scheduler: actions=1")
    # asUpToDate or asCacheHit leaves launched=false. EITHER cache
    # effective status proves the previous (path-selector) run's cache
    # entry was reused — i.e. the action-cache key matched.
    check nameRun.contains(
      "action: build-app status=asCacheHit launched=false") or
      nameRun.contains(
      "action: build-app status=asUpToDate launched=false")
    check fileExists(projectRoot / "build" / "app")
    # Marker still has exactly one line — the tool was not relaunched
    # by the name-selector run.
    check nonEmptyLines(projectRoot / ".repro" / "m2-runs.log").len == 1
