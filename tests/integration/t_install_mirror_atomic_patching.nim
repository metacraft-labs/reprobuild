import std/[dynlib, os, osproc, streams, strtabs, strutils, tempfiles, unittest]
import repro_project_dsl/install_mirror_runtime
import repro_project_dsl/install_mirror_relocation
import repro_test_support

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
    test "shared-only mirrors retain their declared prelinked C runtime":
      let original = graphArtifactPath(
        "build/test-fixtures/install-mirror-runtime/libc-probe.so")
      requireBinary(original, "reprobuild.test_fixtures.install_mirror_libc_library")
      let scratch = createTempDir("repro-shared-libc-", "")
      defer: removeDir(scratch)
      let fixtureEnv = cleanEnv()
      let runtime = runTool("gcc", @["-print-file-name=libc.so.6"], fixtureEnv)
      require runtime.exitCode == 0
      require runtime.output.strip().isAbsolute()
      require fileExists(runtime.output.strip())
      let runtimeDir = runtime.output.strip().parentDir
      let priorRpath = runTool("patchelf", @["--print-rpath", original], fixtureEnv)
      require priorRpath.exitCode == 0
      require runtimeDir in priorRpath.output.strip().split(':')
      let needed = runTool("patchelf", @["--print-needed", original], fixtureEnv)
      require needed.exitCode == 0
      require "libc.so.6" in needed.output.splitLines()
      require runTool("patchelf", @["--print-interpreter", original], fixtureEnv).exitCode != 0
      let declared = scratch / "declared runtime"
      createSymlink(runtimeDir, declared)
      let unrelated = scratch / "unrelated runtime"
      createDir(unrelated)
      copyFile(runtime.output.strip(), unrelated / "libc.so.6")
      var loader = ""
      for path in walkFiles(runtimeDir / "ld-linux-*.so.*"):
        loader = path
        break
      require loader.len > 0
      copyFileWithPermissions(loader, unrelated / loader.extractFilename())
      let mirror = scratch / "usr"
      let libraryPath = mirror / "lib" / "libc-probe.so"
      createDir(libraryPath.parentDir)
      copyFileWithPermissions(original, libraryPath)
      fixtureEnv["LIBRARY_PATH"] = unrelated & ":" & declared
      fixtureEnv["REPRO_M9R30_NEEDED_CHECK"] = "1"
      let normalized = runTool("sh", @["-ec",
        m9r14fEmitRpathPatchScript(mirror, @[],
          ownManifestPath = scratch / "runtime-dirs", packageName = "sharedLibc")], fixtureEnv)
      checkpoint normalized.output
      require normalized.exitCode == 0
      let rpath = runTool("patchelf", @["--print-rpath", libraryPath], fixtureEnv)
      require rpath.exitCode == 0
      check declared in rpath.output.strip().split(':')
      check unrelated notin rpath.output.strip().split(':')
      check runTool("patchelf", @["--print-interpreter", libraryPath], fixtureEnv).exitCode != 0
      block:
        let library = loadLib(libraryPath)
        require library != nil
        defer: unloadLib(library)
        let probe = cast[proc(): cint {.cdecl.}](symAddr(library, "repro_libc_probe"))
        require probe != nil
        check probe() == 0
      copyFileWithPermissions(original, libraryPath)
      fixtureEnv["LIBRARY_PATH"] = unrelated
      let undeclared = runTool("sh", @["-ec",
        m9r14fEmitRpathPatchScript(mirror, @[],
          ownManifestPath = scratch / "undeclared-dirs", packageName = "undeclaredLibc")], fixtureEnv)
      checkpoint undeclared.output
      check undeclared.exitCode == 75
      check "soname=libc.so.6" in undeclared.output
      check noPatchTemps(scratch)
      copyFileWithPermissions(original, libraryPath)
      let secondLibrary = mirror / "lib" / "other-runtime.so"
      copyFileWithPermissions(original, secondLibrary)
      require runTool("patchelf", @["--set-rpath", unrelated, secondLibrary], fixtureEnv).exitCode == 0
      let originalBytes = readFile(libraryPath)
      let secondBytes = readFile(secondLibrary)
      fixtureEnv["LIBRARY_PATH"] = unrelated & ":" & declared
      let conflicting = runTool("sh", @["-ec",
        m9r14fEmitRpathPatchScript(mirror, @[],
          ownManifestPath = scratch / "conflicting-dirs", packageName = "conflictingLibc")], fixtureEnv)
      checkpoint conflicting.output
      check conflicting.exitCode == 75
      check "conflicting linked runtime loaders" in conflicting.output
      check readFile(libraryPath) == originalBytes
      check readFile(secondLibrary) == secondBytes
      check noPatchTemps(scratch)

    test "OpenMP runtime is resolved through the declared compiler":
      let original = graphArtifactPath(
        "build/test-fixtures/install-mirror-runtime/openmp-probe")
      requireBinary(original, "reprobuild.test_fixtures.install_mirror_openmp_probe")
      let scratch = createTempDir("repro-openmp-runtime-", "")
      defer: removeDir(scratch)
      let mirror = scratch / "usr"
      let executable = mirror / "bin" / "openmp-probe"
      createDir(executable.parentDir)
      copyFileWithPermissions(original, executable)
      let fixtureEnv = cleanEnv()
      let interpreter = runTool("patchelf", @["--print-interpreter", original], fixtureEnv)
      require interpreter.exitCode == 0
      fixtureEnv["LIBRARY_PATH"] = interpreter.output.strip().parentDir
      fixtureEnv["REPRO_M9R30_NEEDED_CHECK"] = "1"
      let runtime = runTool("gcc", @["-print-file-name=libgomp.so.1"], fixtureEnv)
      require runtime.exitCode == 0
      require runtime.output.strip().isAbsolute()
      require fileExists(runtime.output.strip())
      let normalized = runTool("sh", @["-ec",
        m9r14fEmitRpathPatchScript(mirror, @[],
          ownManifestPath = scratch / "manifest", packageName = "openmpProbe")], fixtureEnv)
      checkpoint normalized.output
      require normalized.exitCode == 0
      let rpath = runTool("patchelf", @["--print-rpath", executable], fixtureEnv)
      require rpath.exitCode == 0
      check runtime.output.strip().parentDir in rpath.output.strip().split(':')
      let executed = runTool(executable, @[], fixtureEnv)
      checkpoint executed.output
      check executed.exitCode == 0
      check noPatchTemps(scratch)

      let dependencyLib = scratch / "source dependency" / "lib"
      createDir(dependencyLib)
      copyFile(runtime.output.strip(), dependencyLib / "libgomp.so.1")
      copyFileWithPermissions(original, executable)
      let withDependency = runTool("sh", @["-ec",
        m9r14fEmitRpathPatchScript(mirror, @[dependencyLib])], fixtureEnv)
      checkpoint withDependency.output
      require withDependency.exitCode == 0
      let dependencyRpath = runTool("patchelf", @["--print-rpath", executable], fixtureEnv)
      require dependencyRpath.exitCode == 0
      check dependencyLib in dependencyRpath.output.strip().split(':')
      check runtime.output.strip().parentDir notin dependencyRpath.output.strip().split(':')
      check runTool(executable, @[], fixtureEnv).exitCode == 0

      let fakeBin = scratch / "tools"
      createDir(fakeBin)
      let fakeGcc = fakeBin / "gcc"
      writeFile(fakeGcc, "#!/bin/sh\nprintf '%s\\n' libgomp.so.1\n")
      setFilePermissions(fakeGcc, {fpUserRead, fpUserWrite, fpUserExec})
      fixtureEnv["PATH"] = fakeBin & ":" & fixtureEnv["PATH"]
      let missingManifest = scratch / "missing-runtime-manifest"
      let completion = scratch / "published"
      copyFileWithPermissions(original, executable)
      let missing = runTool("sh", @["-ec",
        m9r14fEmitRpathPatchScript(mirror, @[],
          ownManifestPath = missingManifest, packageName = "missingOpenmp") &
          "printf '%s\\n' published > " & quoteShell(completion)], fixtureEnv)
      checkpoint missing.output
      check missing.exitCode == 75
      check "soname=libgomp.so.1" in missing.output
      check not fileExists(completion)
      check "libgomp.so.1" in readFile(missingManifest & ".m9r30_unresolved")
      check noPatchTemps(scratch)

    test "static executables are left byte-identical without a runtime path":
      let original = graphArtifactPath(
        "build/test-fixtures/install-mirror-runtime/static-probe")
      requireBinary(original, "reprobuild.test_fixtures.install_mirror_static_probe")
      let scratch = createTempDir("repro-static-elf-", "")
      defer: removeDir(scratch)
      let mirror = scratch / "usr"
      let executable = mirror / "bin" / "static-probe"
      createDir(parentDir(executable))
      copyFileWithPermissions(original, executable)
      let originalBytes = readFile(executable)
      let normalized = runTool("sh", @["-ec",
        m9r14fEmitRpathPatchScript(mirror, @[])], cleanEnv())
      checkpoint normalized.output
      check normalized.exitCode == 0
      let originalPreserved = readFile(executable) == originalBytes
      check originalPreserved
      check noPatchTemps(scratch)

    test "ELF inspection errors fail before changing the original":
      let original = findExe("patchelf")
      require original.len > 0
      let originalGrep = findExe("grep")
      require originalGrep.len > 0
      for tool in ["readelf", "grep"]:
        checkpoint tool
        let scratch = createTempDir("repro-elf-inspection-", "")
        defer: removeDir(scratch)
        let mirror = scratch / "usr"
        let executable = mirror / "bin" / "sample"
        let fakeBin = scratch / "tools"
        createDir(parentDir(executable))
        createDir(fakeBin)
        copyFileWithPermissions(original, executable)
        let originalBytes = readFile(executable)
        let fakeTool = fakeBin / tool
        let fakeScript = if tool == "readelf":
          "printf '%s\\n' 'unreadable ELF program headers' >&2\nexit 42\n"
        else:
          "if [ \"${1-}\" = -E ] && " &
          "[ \"${2-}\" = '^[[:space:]]*(DYNAMIC|INTERP)[[:space:]]' ]; then\n" &
          "  exit 42\nfi\nexec " & quoteShell(originalGrep) & " \"$@\"\n"
        writeFile(fakeTool, "#!/bin/sh\n" & fakeScript)
        setFilePermissions(fakeTool, {fpUserRead, fpUserWrite, fpUserExec})
        let fixtureEnv = cleanEnv()
        fixtureEnv["PATH"] = fakeBin & ":" & fixtureEnv["PATH"]
        let normalized = runTool("sh", @["-ec",
          m9r14fEmitRpathPatchScript(mirror, @[])], fixtureEnv)
        checkpoint normalized.output
        check normalized.exitCode == 42
        let originalPreserved = readFile(executable) == originalBytes
        check originalPreserved
        check noPatchTemps(scratch)

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

    test "a published mirror survives being restored under a DIFFERENT checkout":
      ## The failure this reproduces was found by a full from-source image
      ## build and by nothing cheaper: a cached binary whose ``PT_INTERP``
      ## and ``DT_RUNPATH`` named the checkout it was BUILT under. Testing at
      ## the producing path proves nothing, which is exactly how it survived
      ## publication — so this test MOVES the whole recipes root before it
      ## asks anything.
      ##
      ## NO MOCKS: a real gcc builds a real shared library and a real
      ## executable, a real copy of this host's dynamic loader is placed in
      ## the dependency mirror, and the executable is really run.
      let scratch = createTempDir("repro-mirror-restore-", "")
      defer: removeDir(scratch)
      let fixtureEnv = cleanEnv()
      let producer = scratch / "checkout-a" / "packages" / "source"
      let mirrorOf = proc (root, package: string): string =
        root / package / ".repro" / "output" / "install"
      let depLib = mirrorOf(producer, "reprofixturedep") / "usr" / "lib"
      let pkgBin = mirrorOf(producer, "reprofixtureapp") / "usr" / "bin"
      createDir(depLib)
      createDir(pkgBin)

      let libSource = scratch / "dep.c"
      writeFile(libSource, "int repro_fixture_answer(void) { return 7; }\n")
      let libPath = depLib / "librepro_mirror_dep.so.1"
      require runTool("gcc", @["-shared", "-fPIC",
        "-Wl,-soname,librepro_mirror_dep.so.1", "-o", libPath, libSource],
        fixtureEnv).exitCode == 0
      let appSource = scratch / "app.c"
      writeFile(appSource,
        "extern int repro_fixture_answer(void);\n" &
        "int main(void) { return repro_fixture_answer(); }\n")
      let appPath = pkgBin / "repro-mirror-app"
      require runTool("gcc", @["-o", appPath, appSource, libPath],
        fixtureEnv).exitCode == 0

      # Give the app a loader that lives inside the DEPENDENCY mirror, which
      # is what a from-source libc produces and what makes PT_INTERP
      # checkout-shaped in the first place.
      let hostLoader = runTool("patchelf",
        @["--print-interpreter", appPath], fixtureEnv)
      require hostLoader.exitCode == 0
      let loaderName = extractFilename(hostLoader.output.strip())
      let mirrorLoader = depLib / loaderName
      copyFileWithPermissions(expandFilename(hostLoader.output.strip()),
        mirrorLoader)
      require runTool("patchelf", @["--set-interpreter", mirrorLoader,
        "--set-rpath", depLib, appPath], fixtureEnv).exitCode == 0
      # At the producing path it works. This is the whole of the evidence
      # publication ever had.
      check runTool(appPath, @[], fixtureEnv).exitCode == 7

      let consumer = scratch / "checkout-b" / "packages" / "source"
      createDir(parentDir(consumer))
      moveDir(producer, consumer)
      let movedApp = mirrorOf(consumer, "reprofixtureapp") / "usr" / "bin" /
        "repro-mirror-app"
      let movedDepLib = mirrorOf(consumer, "reprofixturedep") / "usr" / "lib"
      require fileExists(movedApp)
      # Moved, it cannot start at all: the kernel resolves PT_INTERP before
      # the process exists, so this is the ``exit 127`` on a file that is
      # plainly there.
      let beforeRepair = runTool("sh", @["-c",
        quoteShell(movedApp) & "; echo exit=$?"], fixtureEnv)
      checkpoint beforeRepair.output
      check "exit=127" in beforeRepair.output

      let audit = auditInstallMirrorRelocatability(
        mirrorOf(consumer, "reprofixtureapp"), consumer)
      check audit.elfCount == 1
      var interpreterFindings = 0
      var runPathFindings = 0
      for finding in audit.findings:
        check finding.verdict == rvRemappable
        case finding.field
        of rpfInterpreter:
          inc interpreterFindings
          check finding.remapped == movedDepLib / loaderName
        of rpfRunPath:
          inc runPathFindings
          check finding.remapped == movedDepLib
      # Each field is counted on its own: one of them is a hard refusal to
      # start and the other is a library that goes missing halfway in, and a
      # repair that fixed only one would still look green on a total.
      check interpreterFindings == 1
      check runPathFindings == 1

      let patchRunner = proc (executable: string; args: seq[string]):
          tuple[output: string, exitCode: int] =
        runTool(executable, args, fixtureEnv)
      let repaired = relocateInstallMirror(
        mirrorOf(consumer, "reprofixtureapp"), consumer,
        findExe("patchelf"), patchRunner)
      checkpoint repaired.error
      check repaired.ok
      check repaired.patchedObjects == 1
      check repaired.audit.findings.len == 0
      check runTool(movedApp, @[], fixtureEnv).exitCode == 7
      # Relocation is idempotent: a second pass over an already-local mirror
      # finds nothing and rewrites nothing.
      let second = relocateInstallMirror(
        mirrorOf(consumer, "reprofixtureapp"), consumer,
        findExe("patchelf"), patchRunner)
      check second.ok
      check second.patchedObjects == 0
      check noPatchTemps(scratch)

    test "a dependency loader reached through a store symlink is recorded by its store name":
      ## PT_INTERP is the one field that cannot be made relative — the kernel
      ## does no ``$ORIGIN`` expansion — so whichever absolute name is chosen
      ## here is baked into a published artifact. A dependency mirror's
      ## loader is routinely a symlink into a content-addressed store, and
      ## the two names are NOT equally good: one is valid only under the
      ## producing checkout.
      let original = findExe("patchelf")
      require original.len > 0
      let fixtureEnv = cleanEnv()
      let hostLoader = runTool(original, @["--print-interpreter", original],
        fixtureEnv)
      require hostLoader.exitCode == 0
      let loaderPath = expandFilename(hostLoader.output.strip())
      var storeName = ""
      for storeRoot in ImmutableStoreRoots:
        if loaderPath.startsWith(storeRoot): storeName = loaderPath
      require storeName.len > 0
      let scratch = createTempDir("repro-loader-alias-", "")
      defer: removeDir(scratch)
      let depLib = scratch / "dep" / ".repro" / "output" / "install" /
        "usr" / "lib"
      createDir(depLib)
      # The alias: a checkout-local name for a file that lives in the store.
      let alias = depLib / extractFilename(loaderPath)
      createSymlink(loaderPath, alias)
      let mirror = scratch / "usr"
      let executable = mirror / "bin" / "sample"
      createDir(parentDir(executable))
      copyFileWithPermissions(original, executable)
      setFilePermissions(executable, getFilePermissions(executable) +
        {fpUserWrite})
      # The dependency mirror is listed FIRST so the alias, not the store
      # directory the real runtime also lives in, is what the loader scan
      # selects. Otherwise both names would be produced by the same search
      # and the test would pass whether or not the repair is present.
      let priorRpath = runTool(original, @["--print-rpath", original],
        fixtureEnv)
      require priorRpath.exitCode == 0
      var deps = @[depLib]
      for path in priorRpath.output.strip().split(':'):
        if path.isAbsolute and path notin deps: deps.add(path)
      let normalized = runTool("sh", @["-ec",
        m9r14fEmitRpathPatchScript(mirror, deps)], fixtureEnv)
      checkpoint normalized.output
      require normalized.exitCode == 0
      let interpreter = runTool(original, @["--print-interpreter", executable],
        fixtureEnv)
      require interpreter.exitCode == 0
      check interpreter.output.strip() == storeName
      check interpreter.output.strip() != alias
      check runTool(executable, @["--version"], fixtureEnv).exitCode == 0
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
