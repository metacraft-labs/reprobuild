## The record-only graph-production edge's process: run cargo's whole
## schedule in record mode, compiling nothing, and write the plan.
##
##   repro-rustc-wrapper --cargo-plan --plan FILE --scratch DIR
##       --cargo CARGO --rustc RUSTC [--store-root DIR] -- [CARGO ARGS...]
##
## It runs in the workspace root (the edge's working directory) and does, in
## order:
##
## 1. Prepares the edge-private directories inside the scratch directory
##    (which the engine empties before the edge runs): the record directory,
##    an empty `CARGO_HOME` and an empty `HOME`. Each must be absent or empty:
##    a recording left by an earlier run would enter this run's plan, and no
##    single wrapper process can tell where a run starts, so the edge checks.
##    cargo never sees the user's `~/.cargo` or home directory.
## 2. Refuses a `Cargo.lock` that holds a package with a `source`: such a
##    package (a registry or git dependency) would have to reach cargo through
##    a source replacement over the fetched store prefixes, which this edge
##    does not write yet.
## 3. Saves `cargo metadata --offline --locked --format-version 1` for the
##    recording stub, which reads each package's targets from it.
## 4. Runs `cargo build --offline --locked -j 1 --target-dir <scratch>/target`
##    with the given arguments (the build's profile, target and package
##    selection), the record wrapper as `build.rustc-wrapper` and the given
##    rustc as `build.rustc`, both through `--config` so that neither reaches
##    a compile unit's environment as a variable of this run. `-j 1` makes the
##    `NUM_JOBS` cargo gives each build script the same on every host.
## 5. Derives the plan from the recordings (`cargo_plan.derivePlan`) and
##    writes it to the plan file, the edge's one declared output.
##
## The recordings name paths against the roots `project` (the working
## directory), `target` (the scratch target directory), `scratch`, and, when
## given, `store`. Only the plan leaves the edge; the scratch directory, the
## recordings with it, is the engine's to empty.
##
## A variable that would make cargo run another compiler or wrapper than the
## record wrapper (`RUSTC`, `RUSTC_WRAPPER`, `RUSTC_WORKSPACE_WRAPPER` and
## their `CARGO_BUILD_*` spellings) is refused: an environment variable
## outranks `--config`, so the record run would compile for real.
##
## Exit codes: 0 with the plan written, 2 usage, 1 any other failure (the
## message names it). POSIX only, as record mode is.

import std/[algorithm, os, strutils]
when defined(posix):
  import std/posix

import repro_core/cargo_lock

import ./[cargo_plan, record_mode]

const
  PlanRunFlag* = "--cargo-plan"
    ## The wrapper's argv[1] that selects this command. Cargo runs the
    ## wrapper with a rustc path there, never with this flag.
  PlanRunUsage* = "usage: repro-rustc-wrapper " & PlanRunFlag &
    " --plan FILE --scratch DIR --cargo CARGO --rustc RUSTC " &
    "[--store-root DIR] -- [CARGO ARGS...]\n"
  RecordSubdir* = "record"
  TargetSubdir* = "target"
  CargoHomeSubdir* = "cargo-home"
  HomeSubdir* = "home"
  MetadataFile* = "metadata.json"
  OverridingVariables* = ["RUSTC", "RUSTC_WRAPPER", "RUSTC_WORKSPACE_WRAPPER",
    "CARGO_BUILD_RUSTC", "CARGO_BUILD_RUSTC_WRAPPER",
    "CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER"]

type
  PlanRunOptions* = object
    planFile*, scratch*: string
    cargo*, rustc*: string
    storeRoot*: string
    cargoArgs*: seq[string]

  PlanRunError* = object of CatchableError

proc fail(msg: string) {.noreturn.} =
  raise newException(PlanRunError, msg)

proc parsePlanRunArgs*(args: openArray[string]): PlanRunOptions =
  ## The options after `--cargo-plan`. Raises `PlanRunError` on a usage error.
  var i = 0
  while i < args.len:
    let a = args[i]
    if a == "--":
      result.cargoArgs = @(args[i + 1 .. ^1])
      break
    if i + 1 >= args.len:
      fail("the option " & a & " takes a value")
    let value = args[i + 1]
    case a
    of "--plan": result.planFile = value
    of "--scratch": result.scratch = value
    of "--cargo": result.cargo = value
    of "--rustc": result.rustc = value
    of "--store-root": result.storeRoot = value
    else: fail("unexpected argument '" & a & "'")
    i += 2
  for (name, value) in [("--plan", result.planFile),
      ("--scratch", result.scratch), ("--cargo", result.cargo),
      ("--rustc", result.rustc)]:
    if value.len == 0: fail(name & " is required")

proc emptyOrAbsent(dir, what: string) =
  if fileExists(dir) or symlinkExists(dir):
    fail(what & " " & dir & " is not a directory")
  if dirExists(dir):
    for _ in walkDir(dir):
      fail(what & " " & dir & " is not empty at the start of the run")
  createDir(dir)

when defined(posix):
  var environ {.importc, header: "<unistd.h>".}: cstringArray

  proc spawnWait(argv: openArray[string]; stdoutFile = ""): int =
    ## Run `argv` (argv[0] a path) with this process's environment and
    ## standard streams, standard output redirected to `stdoutFile` when one
    ## is given, and wait for it. Returns its exit status (128 + the signal
    ## when it was killed).
    var actions: Tposix_spawn_file_actions
    if posix_spawn_file_actions_init(actions) != 0:
      fail("posix_spawn_file_actions_init failed")
    defer: discard posix_spawn_file_actions_destroy(actions)
    var fd: cint = -1
    if stdoutFile.len > 0:
      fd = posix.open(stdoutFile.cstring, O_WRONLY or O_CREAT or O_TRUNC,
        0o644)
      if fd < 0: fail("cannot create " & stdoutFile)
      if posix_spawn_file_actions_adddup2(actions, fd, 1) != 0:
        fail("posix_spawn_file_actions_adddup2 failed")
    defer:
      if fd >= 0: discard posix.close(fd)
    let cargv = allocCStringArray(argv)
    defer: deallocCStringArray(cargv)
    var attr: Tposix_spawnattr
    if posix_spawnattr_init(attr) != 0:
      fail("posix_spawnattr_init failed")
    defer: discard posix_spawnattr_destroy(attr)
    var pid: Pid
    let rc = posix_spawn(pid, argv[0].cstring, actions, attr, cargv,
      environ)
    if rc != 0:
      fail("cannot start " & argv[0] & ": " & $strerror(rc))
    var status: cint
    while waitpid(pid, status, 0) < 0:
      if errno != EINTR: fail("waitpid failed for " & argv[0])
    if WIFEXITED(status): int(WEXITSTATUS(status))
    elif WIFSIGNALED(status): 128 + int(WTERMSIG(status))
    else: 1

proc tomlString(s: string): string =
  ## A TOML basic string for a `--config` value.
  result = "\""
  for ch in s:
    case ch
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    else: result.add ch
  result.add "\""

proc runCargoPlan*(opts: PlanRunOptions): int =
  ## The edge's process (see the module docstring). Raises `PlanRunError`
  ## (or `CargoPlanError`, `RecordModeError`) on failure.
  when not defined(posix):
    fail("the record run is not supported on this platform")
  else:
    let project = getCurrentDir()
    let scratch = absolutePath(opts.scratch)
    if project == scratch or project.startsWith(scratch & "/"):
      fail("the scratch directory " & scratch & " contains the workspace")
    for name in OverridingVariables:
      if existsEnv(name):
        fail("the environment sets " & name & ", which outranks the " &
          "record run's own compiler and wrapper; the record run cannot " &
          "honour it")
    createDir(scratch)
    let recordDirPath = scratch / RecordSubdir
    emptyOrAbsent(recordDirPath, "the record directory")
    let cargoHome = scratch / CargoHomeSubdir
    emptyOrAbsent(cargoHome, "the edge-private CARGO_HOME")
    let home = scratch / HomeSubdir
    emptyOrAbsent(home, "the edge-private HOME")
    let targetDir = scratch / TargetSubdir

    if fileExists(project / "Cargo.lock"):
      var sourced: seq[string]
      for pkg in parseCargoLock(readFile(project / "Cargo.lock")):
        if pkg.source.len > 0:
          sourced.add pkg.name & "@" & pkg.version & " (" & pkg.source & ")"
      if sourced.len > 0:
        sourced.sort()
        fail("Cargo.lock holds packages that are not workspace members: " &
          sourced.join(", ") & "; the record run serves cargo no source " &
          "replacement over their store prefixes yet")

    putEnv("CARGO_HOME", cargoHome)
    putEnv("HOME", home)

    var rootLines = @["project=" & project, TargetRootLabel & "=" & targetDir,
      ScratchRootLabel & "=" & scratch]
    if opts.storeRoot.len > 0:
      rootLines.add "store=" & absolutePath(opts.storeRoot)
    let roots = withResolvedSpellings(parseRecordRoots(rootLines.join("\n")))

    # The record run's own environment, as the recordings will name it: the
    # base every recorded environment is stored as a difference from.
    var baseEnv: seq[(string, string)]
    for name, value in envPairs():
      if not recordedEnvSkipped(name):
        baseEnv.add (name, logicalize(roots, value))
    baseEnv.sort(proc (a, b: (string, string)): int = cmp(a[0], b[0]))

    let metadataPath = scratch / MetadataFile
    let metaCode = spawnWait([opts.cargo, "metadata", "--offline", "--locked",
      "--format-version", "1"], stdoutFile = metadataPath)
    if metaCode != 0:
      fail("cargo metadata failed with exit status " & $metaCode)

    let wrapper = getAppFilename()
    putEnv(RecordDirEnv, recordDirPath)
    putEnv(RecordRootsEnv, rootLines.join("\n"))
    putEnv(RecordMetadataEnv, metadataPath)
    var build = @[opts.cargo,
      "--config", "build.rustc=" & tomlString(opts.rustc),
      "--config", "build.rustc-wrapper=" & tomlString(wrapper),
      "build", "--offline", "--locked", "-j", "1",
      "--target-dir", targetDir]
    build.add opts.cargoArgs
    let code = spawnWait(build)
    delEnv(RecordDirEnv)
    delEnv(RecordRootsEnv)
    delEnv(RecordMetadataEnv)
    if code != 0:
      fail("the record run's cargo build failed with exit status " & $code)

    let recordings = readRecordings(recordDirPath)
    let plan = derivePlan(recordings, baseEnv, logicalize(roots, wrapper))
    let planPath = absolutePath(opts.planFile)
    createDir(parentDir(planPath))
    writeCargoPlan(planPath, plan)
    0

proc runPlanCommand*(args: openArray[string]): int =
  ## `args` are the arguments after `--cargo-plan`.
  var opts: PlanRunOptions
  try:
    opts = parsePlanRunArgs(args)
  except PlanRunError as err:
    stderr.writeLine "repro-rustc-wrapper " & PlanRunFlag & ": " & err.msg
    stderr.write PlanRunUsage
    return 2
  try:
    runCargoPlan(opts)
  except CatchableError as err:
    stderr.writeLine "repro-rustc-wrapper " & PlanRunFlag & ": " & err.msg
    1
