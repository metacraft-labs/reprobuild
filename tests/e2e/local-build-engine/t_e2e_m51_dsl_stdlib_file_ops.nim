import std/[json, os, osproc, strutils, tempfiles, unittest]

proc q(value: string): string =
  quoteShell(value)

proc shellCommand(args: openArray[string];
                  env: openArray[(string, string)] = []): string =
  var parts: seq[string] = @[]
  for (name, value) in env:
    parts.add(name & "=" & q(value))
  for arg in args:
    parts.add(q(arg))
  parts.join(" ")

proc runShell(command: string; cwd = getCurrentDir()):
    tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireSuccess(command: string; cwd = getCurrentDir()): string =
  let res = runShell(command, cwd)
  if res.code != 0:
    checkpoint(res.output)
  check res.code == 0
  res.output

proc pathExists(path: string): bool =
  try:
    discard getFileInfo(path, followSymlink = false)
    true
  except OSError:
    false

proc ensureRunQuotaDaemon(repoRoot: string): tuple[process: owned(Process);
    socket: string] =
  let runquotaRoot = repoRoot.parentDir / "runquota"
  let daemonBin = runquotaRoot / "build" / "bin" / "runquotad"
  if not fileExists(daemonBin):
    discard requireSuccess("cd " & q(runquotaRoot) & " && just build", repoRoot)
  let socketPath = "/tmp/repro-m51-rq-" & $getCurrentProcessId() & ".sock"
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

proc compilePublicReproTestBin(repoRoot: string): string =
  result = repoRoot / "build" / "test-bin" / "repro"
  createDir(result.splitPath.head)
  discard requireSuccess(shellCommand([
    "nim", "c", "--verbosity:0", "--hints:off",
    "--nimcache:" & repoRoot / "build" / "nimcache" /
      "m51-dsl-stdlib-repro",
    "--out:" & result,
    repoRoot / "apps" / "repro" / "repro.nim"
  ]), repoRoot)

proc build(reproBin, target, repoRoot: string): string =
  requireSuccess(shellCommand([reproBin, "build", target,
    "--tool-provisioning=path"]), repoRoot)

proc valueAfter(output, prefix: string): string =
  for line in output.splitLines:
    if line.startsWith(prefix):
      return line[prefix.len .. ^1].strip()
  ""

proc reportAction(report: JsonNode; id: string): JsonNode =
  for item in report{"actions"}:
    if item{"id"}.getStr() == id:
      return item
  newJNull()

proc assertAction(report: JsonNode; id, status: string; launched: bool) =
  let action = reportAction(report, id)
  check action.kind != JNull
  check action{"status"}.getStr() == status
  check action{"launched"}.getBool() == launched

proc writeStdlibCopyProject(path: string) =
  createDir(path.splitPath.head)
  writeFile(path,
    "import repro_dsl_stdlib\n\n" &
    "package m51Stdlib:\n" &
    "  build:\n" &
    "    let copied = fs.copyFile(\n" &
    "      source = \"src/input.txt\",\n" &
    "      output = \"out/copy.txt\")\n" &
    "    let stamped = fs.stamp(\n" &
    "      output = \"out/stamp.txt\",\n" &
    "      title = \"m51 stamp\",\n" &
    "      entries = @[\"out/copy.txt\"],\n" &
    "      inputs = @[\"out/copy.txt\"],\n" &
    "      after = @[copied])\n" &
    "    exportTarget(\"copy\", copied)\n" &
    "    defaultTarget(stamped)\n")

proc writePreserveTreeProject(path: string) =
  createDir(path.splitPath.head)
  writeFile(path,
    "import repro_dsl_stdlib\n\n" &
    "package m51Tree:\n" &
    "  build:\n" &
    "    let mirrored = fs.preserveTree(\n" &
    "      sourceRoot = \"assets\",\n" &
    "      outputRoot = \"mirror\")\n" &
    "    defaultTarget(mirrored)\n")

proc writeSymlinkOutputProject(path: string) =
  createDir(path.splitPath.head)
  writeFile(path,
    "import repro_dsl_stdlib\n\n" &
    "package m51SymlinkOutputs:\n" &
    "  build:\n" &
    "    let copied = fs.copyFile(\n" &
    "      source = \"src/input.txt\",\n" &
    "      output = \"out/link-copy.txt\")\n" &
    "    let mirrored = fs.preserveTree(\n" &
    "      sourceRoot = \"assets\",\n" &
    "      outputRoot = \"mirror\")\n" &
    "    let all = aggregate(\"all\", actions = @[copied, mirrored])\n" &
    "    defaultTarget(all)\n")

suite "m51_dsl_stdlib_file_ops":
  test "m51_stdlib_copy_and_stamp_e2e":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-m51-stdlib-copy", "")
    defer: removeDir(tempRoot)

    var daemon = ensureRunQuotaDaemon(repoRoot)
    defer:
      daemon.process.terminate()
      discard daemon.process.waitForExit()
      daemon.process.close()
      if pathExists(daemon.socket):
        removeFile(daemon.socket)

    let reproBin = compilePublicReproTestBin(repoRoot)
    let projectRoot = tempRoot / "project"
    createDir(projectRoot / "src")
    writeFile(projectRoot / "src" / "input.txt", "alpha\n")
    writeStdlibCopyProject(projectRoot / "reprobuild.nim")

    let first = build(reproBin, projectRoot, repoRoot)
    check first.contains("scheduler: actions=2")
    check first.contains("runquota=builtin")
    check not first.contains(" cp ")
    check not first.contains(" mkdir ")
    check readFile(projectRoot / "out" / "copy.txt") == "alpha\n"
    check readFile(projectRoot / "out" / "stamp.txt").contains("m51 stamp")
    let firstReport = parseFile(valueAfter(first, "buildReport:"))
    assertAction(firstReport, "copy", "asSucceeded", true)
    assertAction(firstReport, "fs-stamp-out-2fstamp.txt", "asSucceeded", true)

    let second = build(reproBin, projectRoot, repoRoot)
    let secondReport = parseFile(valueAfter(second, "buildReport:"))
    assertAction(secondReport, "copy", "asCacheHit", false)
    assertAction(secondReport, "fs-stamp-out-2fstamp.txt", "asCacheHit", false)

    writeFile(projectRoot / "src" / "input.txt", "beta\n")
    let changed = build(reproBin, projectRoot, repoRoot)
    let changedReport = parseFile(valueAfter(changed, "buildReport:"))
    assertAction(changedReport, "copy", "asSucceeded", true)
    assertAction(changedReport, "fs-stamp-out-2fstamp.txt", "asSucceeded", true)
    check readFile(projectRoot / "out" / "copy.txt") == "beta\n"

  test "m51_preserve_tree_cleanup_e2e":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-m51-preserve-tree", "")
    defer: removeDir(tempRoot)

    var daemon = ensureRunQuotaDaemon(repoRoot)
    defer:
      daemon.process.terminate()
      discard daemon.process.waitForExit()
      daemon.process.close()
      if pathExists(daemon.socket):
        removeFile(daemon.socket)

    let reproBin = compilePublicReproTestBin(repoRoot)
    let projectRoot = tempRoot / "project"
    createDir(projectRoot / "assets" / "nested")
    writeFile(projectRoot / "assets" / "keep.txt", "keep\n")
    writeFile(projectRoot / "assets" / "nested" / "drop.txt", "drop\n")
    writePreserveTreeProject(projectRoot / "reprobuild.nim")

    let first = build(reproBin, projectRoot, repoRoot)
    check first.contains("scheduler: actions=1")
    let firstReport = parseFile(valueAfter(first, "buildReport:"))
    assertAction(firstReport, "fs-preserveTree-mirror", "asSucceeded", true)
    check readFile(projectRoot / "mirror" / "keep.txt") == "keep\n"
    check readFile(projectRoot / "mirror" / "nested" / "drop.txt") == "drop\n"

    removeFile(projectRoot / "assets" / "nested" / "drop.txt")
    let second = build(reproBin, projectRoot, repoRoot)
    check second.contains("providerInvocations: 1")
    let secondReport = parseFile(valueAfter(second, "buildReport:"))
    assertAction(secondReport, "fs-preserveTree-mirror", "asSucceeded", true)
    check fileExists(projectRoot / "mirror" / "keep.txt")
    check not fileExists(projectRoot / "mirror" / "nested" / "drop.txt")

  test "m51_preserve_tree_preserves_symlinks_e2e":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-m51-preserve-tree-symlinks", "")
    defer: removeDir(tempRoot)

    var daemon = ensureRunQuotaDaemon(repoRoot)
    defer:
      daemon.process.terminate()
      discard daemon.process.waitForExit()
      daemon.process.close()
      if pathExists(daemon.socket):
        removeFile(daemon.socket)

    let reproBin = compilePublicReproTestBin(repoRoot)
    let projectRoot = tempRoot / "project"
    createDir(projectRoot / "assets" / "real-dir")
    writeFile(projectRoot / "assets" / "real-file.txt", "file target\n")
    writeFile(projectRoot / "assets" / "real-dir" / "nested.txt",
      "dir target\n")

    var symlinkOk = true
    try:
      createSymlink("real-file.txt", projectRoot / "assets" / "file-link.txt")
      createSymlink("real-dir", projectRoot / "assets" / "dir-link")
    except OSError:
      symlinkOk = false

    if not symlinkOk:
      checkpoint "platform-skip: host cannot create symlinks"
    else:
      writePreserveTreeProject(projectRoot / "reprobuild.nim")

      let first = build(reproBin, projectRoot, repoRoot)
      let firstReport = parseFile(valueAfter(first, "buildReport:"))
      assertAction(firstReport, "fs-preserveTree-mirror", "asSucceeded", true)
      check readFile(projectRoot / "mirror" / "real-file.txt") ==
        "file target\n"
      check readFile(projectRoot / "mirror" / "real-dir" / "nested.txt") ==
        "dir target\n"
      check symlinkExists(projectRoot / "mirror" / "file-link.txt")
      check symlinkExists(projectRoot / "mirror" / "dir-link")
      check expandSymlink(projectRoot / "mirror" / "file-link.txt") ==
        "real-file.txt"
      check expandSymlink(projectRoot / "mirror" / "dir-link") == "real-dir"
      check readFile(projectRoot / "mirror" / "file-link.txt") ==
        "file target\n"
      check readFile(projectRoot / "mirror" / "dir-link" / "nested.txt") ==
        "dir target\n"

      removeFile(projectRoot / "assets" / "file-link.txt")
      let second = build(reproBin, projectRoot, repoRoot)
      let secondReport = parseFile(valueAfter(second, "buildReport:"))
      assertAction(secondReport, "fs-preserveTree-mirror", "asSucceeded", true)
      check not symlinkExists(projectRoot / "mirror" / "file-link.txt")
      check symlinkExists(projectRoot / "mirror" / "dir-link")

  test "m51_builtin_file_outputs_replace_existing_symlinks":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-m51-symlink-output", "")
    defer: removeDir(tempRoot)

    var daemon = ensureRunQuotaDaemon(repoRoot)
    defer:
      daemon.process.terminate()
      discard daemon.process.waitForExit()
      daemon.process.close()
      if pathExists(daemon.socket):
        removeFile(daemon.socket)

    let reproBin = compilePublicReproTestBin(repoRoot)
    let projectRoot = tempRoot / "project"
    createDir(projectRoot / "src")
    createDir(projectRoot / "assets")
    createDir(projectRoot / "out")
    createDir(projectRoot / "mirror")
    createDir(projectRoot / "victims")
    writeFile(projectRoot / "src" / "input.txt", "copy output\n")
    writeFile(projectRoot / "assets" / "keep.txt", "tree output\n")
    let copyVictim = projectRoot / "victims" / "copy-target.txt"
    let treeVictim = projectRoot / "victims" / "tree-target.txt"
    writeFile(copyVictim, "do not mutate copy target\n")
    writeFile(treeVictim, "do not mutate tree target\n")

    var symlinkOk = true
    try:
      createSymlink(copyVictim, projectRoot / "out" / "link-copy.txt")
      createSymlink(treeVictim, projectRoot / "mirror" / "keep.txt")
    except OSError:
      symlinkOk = false

    if not symlinkOk:
      checkpoint "platform-skip: host cannot create symlinks"
    else:
      writeSymlinkOutputProject(projectRoot / "reprobuild.nim")

      let first = build(reproBin, projectRoot, repoRoot)
      let firstReport = parseFile(valueAfter(first, "buildReport:"))
      assertAction(firstReport, "fs-copyFile-out-2flink-copy.txt",
        "asSucceeded", true)
      assertAction(firstReport, "fs-preserveTree-mirror", "asSucceeded", true)
      check not symlinkExists(projectRoot / "out" / "link-copy.txt")
      check not symlinkExists(projectRoot / "mirror" / "keep.txt")
      check readFile(projectRoot / "out" / "link-copy.txt") == "copy output\n"
      check readFile(projectRoot / "mirror" / "keep.txt") == "tree output\n"
      check readFile(copyVictim) == "do not mutate copy target\n"
      check readFile(treeVictim) == "do not mutate tree target\n"
