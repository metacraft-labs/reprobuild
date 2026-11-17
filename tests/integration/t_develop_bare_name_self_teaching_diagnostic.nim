## `repro develop <name>` when `<name>` is not a local project.
##
## The target form of `repro develop` (no `--source`, no `-- <command>`)
## takes a local project directory. A name that is not one is most often a
## dependency, or a catalog package name, so the command must not answer with
## the bare path of a project file it did not find. It exits 1 with an
## `error:` line naming the name and `tip:` lines naming the forms that work:
## inside a workspace or project, `repro develop --only=<name>` and
## `repro develop <name> --source=<path>`; outside one, the same two forms,
## plus the fact that creating a workspace from a catalog package name is not
## enabled in this build.
##
## A target written as a path (`./nope/dir`) was meant as a local project, so
## the answer is only that no project file is there: no `--only=` or
## `--source` tip, which take names. And a target that IS a local project
## still develops (the positive control: the diagnostic must not fire for a
## project that resolves).
##
## No mocks: the real built `repro` runs in real temporary directories. The
## workspace case is a directory carrying the workspace settings file, which
## is what the workspace-root discovery recognises; the project case carries
## a project file. The positive control's project is really compiled.

import std/[os, strtabs, strutils, tempfiles, unittest]

import repro_test_support

proc reproBinary(): string =
  requireBinary(getCurrentDir() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc isolatedEnv(): StringTableRef =
  ## This process's environment without the variable that names a workspace
  ## settings file explicitly, so discovery reads only the directory tree.
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value
  if result.hasKey("REPRO_WORKSPACE_CONFIG"):
    result.del("REPRO_WORKSPACE_CONFIG")

proc runDevelop(cwd, name: string;
                env: StringTableRef = isolatedEnv()): CmdSplitResult =
  runProgramSplit(reproBinary(), @["develop", name], cwd, env,
    timeoutMs = 600_000)

proc checkCommonShape(res: CmdSplitResult; name: string) =
  checkpoint(res.stderr)
  check res.code == 1
  check res.stdout.len == 0
  check res.stderr.contains("error: ")
  check res.stderr.contains("`" & name & "`")
  check res.stderr.contains("tip: ")
  check res.stderr.contains("repro develop " & name & " --source=<path>")
  # Neither the bare file-path message nor a second, generic error prefix.
  check not res.stderr.contains("develop target module not found")
  check not res.stderr.contains("repro develop: error:")
  check not res.stderr.contains("Traceback")

suite "repro develop with a name that is not a local project":
  test "inside a workspace the tips name --only and --source":
    let root = expandFilename(createTempDir("repro-develop-ws", ""))
    defer: removeDir(root)
    writeFile(root / "repro-workspace.toml", "")
    let res = runDevelop(root, "cairo")
    checkCommonShape(res, "cairo")
    check res.stderr.contains("repro develop --only=cairo")
    check not res.stderr.contains("not enabled in this build")

  test "inside a project the tips name --only and --source":
    let root = expandFilename(createTempDir("repro-develop-project", ""))
    defer: removeDir(root)
    writeFile(root / "repro.nim", "")
    let res = runDevelop(root, "cairo")
    checkCommonShape(res, "cairo")
    check res.stderr.contains("repro develop --only=cairo")

  test "outside any workspace the diagnostic says catalog creation is off":
    let root = expandFilename(createTempDir("repro-develop-empty", ""))
    defer: removeDir(root)
    let res = runDevelop(root, "firefox")
    checkCommonShape(res, "firefox")
    check res.stderr.contains("not enabled in this build")
    check res.stderr.contains("repro develop --only=<dep>")

  test "a target written as a path says only that no project is there":
    let root = expandFilename(createTempDir("repro-develop-path", ""))
    defer: removeDir(root)
    writeFile(root / "repro-workspace.toml", "")
    for target in ["./nope/dir", "nope/dir", "../nope"]:
      let res = runDevelop(root, target)
      checkpoint(target & "\n" & res.stderr)
      check res.code == 1
      check res.stdout.len == 0
      check res.stderr.contains("error: `repro develop " & target & "`")
      check res.stderr.contains("no project file found at ")
      check not res.stderr.contains("tip:")
      check not res.stderr.contains("--only=")
      check not res.stderr.contains("--source")
      check not res.stderr.contains("Traceback")

suite "repro develop with a target that is a local project":
  test "a project that resolves still develops, with no error":
    let root = expandFilename(createTempDir("repro-develop-ok", ""))
    defer: removeDir(root)
    let project = root / "project"
    createDir(project)
    writeFile(project / "reprobuild.nim",
      "import repro_project_dsl\n\n" &
      "package fixture:\n" &
      "  devEnv:\n" &
      "    activity \"default\"\n")
    let env = isolatedEnv()
    # The project file is compiled against this checkout's DSL.
    env["REPROBUILD_SOURCE_ROOT"] = getCurrentDir()
    when isIoMonitorSupported:
      let monitor = prepareMonitorTools(getCurrentDir(), root,
        "develop-positive")
      env["REPRO_MONITOR_SHIM_LIB"] = monitor.shim
    let res = runDevelop(root, project, env)
    checkpoint(res.stdout & "\n" & res.stderr)
    check res.code == 0
    check not res.stderr.contains("error:")
    check not res.stderr.contains("no project file")
