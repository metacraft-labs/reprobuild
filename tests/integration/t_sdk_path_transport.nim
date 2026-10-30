## Compiler-is-subject regression: the actual SDK path factory and real Nim
## config phases must retain namespace selection while shortening Windows argv.
## No compiler adapter or filesystem is mocked.
import std/[os, sets, strutils, tempfiles, unittest]
import repro_interface_artifacts/sdk_path_transport
import repro_core/file_lock
from repro_interface_artifacts import runCommand

let nimCompiler = findExe("nim")
doAssert nimCompiler.len > 0, "real Nim compiler is required by the transport regression"

proc compileCheck(command: seq[string]; cwd: string): tuple[output: string, exitCode: int] =
  let execution = runCommand(command, cwd = cwd, raiseOnFailure = false)
  (execution.output, execution.exitCode)

suite "owned SDK path transport":
  test "UTF-16 measurement includes quoting, surrogate pairs and NUL":
    check windowsCommandLineUnits(@["a", "b"]) == 4
    check windowsCommandLineUnits(@["a b"]) == 6
    check windowsCommandLineUnits(@["😀"]) == 3
    expect ValueError: discard windowsCommandLineUnits(@["a\0b"])

  test "real compiler preserves first-pass imports and final SDK namespace":
    let root = createTempDir("sdk-transport-", "")
    defer: removeDir(root)
    let runnerDir = root / "runner"
    let consumer = root / "consumer"
    createDir(runnerDir)
    createDir(consumer)
    writeFile(consumer / "selection.nim", "const selected* = 99\n")
    var protected = initHashSet[string]()
    var paths: seq[string]
    for i in 0 ..< 130:
      let path = root / ("SDK Unicode é % " & $i & repeat('x', 130))
      createDir(path)
      paths.add("--path:" & path)
      protected.incl(paths[^1])
    writeFile(paths[0][7 .. ^1] / "selection.nim", "const selected* = 1\n")
    writeFile(paths[^1][7 .. ^1] / "selection.nim", "const selected* = 2\n")
    writeFile(root / "config.nims", "import selection\ndoAssert selected == 2\nswitch(\"path\", " & consumer.escape & ")\n")
    let runner = runnerDir / "probe.nim"
    writeFile(runner, "import selection\nstatic: doAssert selected == 2\n")
    for aliasSpelling in ["", "--path:", "--PATH:", "--pa_th:"]:
      let alias = aliasSpelling.len > 0
      var command = @[nimCompiler, "check", "--hints:off", "--skipUserCfg:on"]
      if alias:
        let finalRoot = paths[^1][7 .. ^1]
        command.add(aliasSpelling & finalRoot & "/../" & finalRoot.extractFilename)
      command.add(paths & @[paths[0], runner])
      let owned = protectCompilerSdkPaths(command, runner, protected)
      when defined(windows):
        var refused = false
        try: discard compileCheck(command, root)
        except OSError as error:
          refused = true
          check "206" in error.msg
        check refused
      else:
        check compileCheck(command, root).exitCode == 0
      let plan = planOwnedSdkPathTransport(command, runner, root, owned)
      check plan.originalUnits > WindowsCommandLineLimit
      check plan.physicalUnits <= WindowsCommandLineLimit
      check plan.command.len == command.len - (if alias: 129 else: 130)
      check plan.configText.startsWith(OwnedSdkConfigHeader)
      var config = stageOwnedSdkPathConfig(runner, plan)
      try:
        let execution = compileCheck(plan.command, root)
        checkpoint execution.output
        check execution.exitCode == 0
        var contender: ReproFileLock
        check not tryAcquireExclusiveFileLock(runner & "cfg.lock", contender)
      finally:
        releaseOwnedSdkPathConfig(config)
      check not fileExists(runner & "cfg")
      # The same physical argv without its owned reset must expose the poison.
      if not alias:
        check compileCheck(plan.command, root).exitCode != 0

  test "caller exclusions and aliases remain on argv; unsupported plans refuse":
    let root = createTempDir("sdk-alias-", "")
    defer: removeDir(root)
    let runner = root / "probe.nim"
    let sdk = root / "selected"
    let selected = "--path:" & sdk
    var command = @[nimCompiler, "check", "--path:" & sdk & "/../selected",
      "--excludePath:" & root / "hidden", "--define:" & repeat('x', 33000), selected, runner]
    let owned = protectCompilerSdkPaths(command, runner, toHashSet([selected]))
    expect ValueError: discard planOwnedSdkPathTransport(command, runner, root, owned)
    # A long owned reset can shrink while an alias reset remains first-pass.
    command = @[nimCompiler, "check", "--path:" & sdk & "/../selected",
      "--excludePath:" & root / "hidden", selected]
    var flags = toHashSet([selected])
    for i in 0 ..< 150:
      let flag = "--path:" & root / ($i & repeat('x', 130))
      command.add(flag)
      flags.incl(flag)
    command.add(runner)
    let tagged = protectCompilerSdkPaths(command, runner, flags)
    let plan = planOwnedSdkPathTransport(command, runner, root, tagged)
    check "--excludePath:" & sdk in plan.command
    check "--excludePath:" & root / "hidden" in plan.command
    check "excludePath = " & sdk.escape notin plan.configText
    command.insert("--skipProjCfg:on", 2)
    expect ValueError: discard planOwnedSdkPathTransport(command, runner, root, tagged)

  test "owned config lifecycle recovers stale bytes and preserves foreign files":
    let root = createTempDir("sdk-config-", "")
    defer: removeDir(root)
    let runner = root / "probe.nim"
    writeFile(runner, "discard\n")
    let plan = SdkPathTransportPlan(configText: OwnedSdkConfigHeader & "excludePath = \"/unused\"\n")
    writeFile(runner & "cfg", OwnedSdkConfigHeader & "# interrupted prior invocation\n")
    var config = stageOwnedSdkPathConfig(runner, plan)
    check readFile(runner & "cfg") == plan.configText
    releaseOwnedSdkPathConfig(config)
    check not fileExists(runner & "cfg")
    writeFile(runner & "cfg", "# foreign sentinel\n")
    expect IOError: discard stageOwnedSdkPathConfig(runner, plan)
    check readFile(runner & "cfg") == "# foreign sentinel\n"
    removeFile(runner & "cfg")
    writeFile(runner & ".cfg", "# lower-priority foreign sentinel\n")
    expect IOError: discard stageOwnedSdkPathConfig(runner, plan)
    check readFile(runner & ".cfg") == "# lower-priority foreign sentinel\n"

  test "arbitrary exclusion keeps first-pass config import forbidden":
    let root = createTempDir("sdk-excluded-", "")
    defer: removeDir(root)
    let hidden = root / "hidden"
    let runnerDir = root / "runner"
    createDir(hidden)
    createDir(runnerDir)
    writeFile(hidden / "forbidden.nim", "const secret* = 1\n")
    writeFile(root / "config.nims", "import forbidden\n")
    let runner = runnerDir / "probe.nim"
    writeFile(runner, "discard\n")
    var command = @[nimCompiler, "check", "--hints:off", "--skipUserCfg:on",
      "--path:" & hidden, "--excludePath:" & hidden]
    var flags = initHashSet[string]()
    for i in 0 ..< 130:
      let flag = "--path:" & root / ($i & repeat('x', 140))
      flags.incl(flag)
      command.add(flag)
    command.add(runner)
    let owned = protectCompilerSdkPaths(command, runner, flags)
    when defined(windows):
      var refused = false
      try: discard compileCheck(command, root)
      except OSError as error:
        refused = true
        check "206" in error.msg
      check refused
    else:
      let original = compileCheck(command, root)
      check original.exitCode != 0
      check "cannot open file: forbidden" in original.output
    let plan = planOwnedSdkPathTransport(command, runner, root, owned)
    check "--excludePath:" & hidden in plan.command
    var config = stageOwnedSdkPathConfig(runner, plan)
    try:
      let shortened = compileCheck(plan.command, root)
      check shortened.exitCode != 0
      check "cannot open file: forbidden" in shortened.output
    finally: releaseOwnedSdkPathConfig(config)
