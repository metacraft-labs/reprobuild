import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]
import repro_project_dsl/install_mirror_runtime

when defined(linux):
  proc cleanEnv(): StringTableRef =
    result = newStringTable(modeCaseSensitive)
    for key, value in envPairs():
      if key notin ["LD_LIBRARY_PATH", "LIBRARY_PATH", "LD_PRELOAD"]:
        result[key] = value
    result["REPRO_M9R30_NEEDED_CHECK"] = "0"

  proc runTool(command: string; args: openArray[string];
               env: StringTableRef): tuple[output: string, exitCode: int] =
    let child = startProcess(command, args = args, env = env,
      options = {poUsePath, poStdErrToStdOut})
    defer: child.close()
    child.inputStream.close()
    result.output = child.outputStream.readAll()
    result.exitCode = child.waitForExit()

  proc noPatchTemps(root: string): bool =
    for path in walkDirRec(root):
      if ".repro-patch." in extractFilename(path):
        return false
    true

  suite "atomic install mirror ELF normalization":
    test "a selected source patchelf can normalize its own mirror":
      let original = findExe("patchelf")
      require original.len > 0
      let scratch = createTempDir("repro-self-patchelf-", "")
      defer: removeDir(scratch)
      let mirror = scratch / "path with spaces" / "usr"
      let executable = mirror / "bin" / "patchelf"
      createDir(parentDir(executable))
      copyFileWithPermissions(original, executable)
      setFilePermissions(executable, getFilePermissions(executable) +
        {fpUserWrite})
      let fixtureEnv = cleanEnv()
      let oldRpath = runTool(original, @["--print-rpath", original], fixtureEnv)
      require oldRpath.exitCode == 0
      var deps: seq[string]
      for path in oldRpath.output.strip().split(':'):
        if path.isAbsolute: deps.add(path)
      fixtureEnv["PATH"] = parentDir(executable) & ":" & fixtureEnv["PATH"]
      let script = m9r14fEmitRpathPatchScript(mirror, deps)
      let normalized = runTool("sh", @["-ec", script], fixtureEnv)
      checkpoint normalized.output
      check normalized.exitCode == 0
      let rpath = runTool(original, @["--print-rpath", executable], fixtureEnv)
      check rpath.exitCode == 0
      check "$ORIGIN/../lib" in rpath.output
      let version = runTool(executable, @["--version"], fixtureEnv)
      checkpoint version.output
      check version.exitCode == 0
      check "patchelf " in version.output
      check noPatchTemps(scratch)

    test "a failed patch preserves the original ELF and fails the action":
      let original = findExe("patchelf")
      require original.len > 0
      let scratch = createTempDir("repro-failed-patchelf-", "")
      defer: removeDir(scratch)
      let mirror = scratch / "usr"
      let executable = mirror / "bin" / "sample"
      let fakeBin = scratch / "tools"
      createDir(parentDir(executable))
      createDir(fakeBin)
      copyFileWithPermissions(original, executable)
      setFilePermissions(executable, getFilePermissions(executable) +
        {fpUserWrite})
      let originalBytes = readFile(executable)
      let fakeTool = fakeBin / "patchelf"
      writeFile(fakeTool, "#!/bin/sh\n" &
        "case \"$1\" in --set-rpath)\n" &
        "  for target do :; done\n" &
        "  printf 'partial patch' > \"$target\"\n" &
        "  exit 42;;\n" &
        "esac\nexit 0\n")
      setFilePermissions(fakeTool, {fpUserRead, fpUserWrite, fpUserExec})
      let fixtureEnv = cleanEnv()
      fixtureEnv["PATH"] = fakeBin & ":" & fixtureEnv["PATH"]
      let normalized = runTool("sh", @["-ec",
        m9r14fEmitRpathPatchScript(mirror, @[])], fixtureEnv)
      checkpoint normalized.output
      check normalized.exitCode != 0
      let originalPreserved = readFile(executable) == originalBytes
      check originalPreserved
      check noPatchTemps(scratch)

    test "loader normalization preserves symlinks and read-only permissions":
      let original = findExe("patchelf")
      require original.len > 0
      let fixtureEnv = cleanEnv()
      let interpreter = runTool(original, @["--print-interpreter", original],
        fixtureEnv)
      require interpreter.exitCode == 0
      require fileExists(interpreter.output.strip())
      let scratch = createTempDir("repro-loader-patching-", "")
      defer: removeDir(scratch)
      let mirror = scratch / "usr"
      let loader = mirror / "lib" / "ld-fixture.so"
      let alias = mirror / "lib" / "ld-alias.so"
      createDir(parentDir(loader))
      copyFileWithPermissions(interpreter.output.strip(), loader)
      setFilePermissions(loader, getFilePermissions(loader) + {fpUserWrite})
      let seeded = runTool(original, @["--set-rpath", "/unused-runtime",
        loader], fixtureEnv)
      require seeded.exitCode == 0
      let readOnly = {fpUserRead, fpUserExec, fpGroupRead, fpGroupExec,
        fpOthersRead, fpOthersExec}
      setFilePermissions(loader, readOnly)
      createSymlink(extractFilename(loader), alias)
      let normalized = runTool("sh", @["-ec",
        m9r14fEmitRpathPatchScript(mirror, @[])], fixtureEnv)
      checkpoint normalized.output
      check normalized.exitCode == 0
      check symlinkExists(alias)
      check expandSymlink(alias) == extractFilename(loader)
      check getFilePermissions(loader) == readOnly
      let rpath = runTool(original, @["--print-rpath", alias], fixtureEnv)
      check rpath.exitCode == 0
      check rpath.output.strip().len == 0
      check noPatchTemps(scratch)
