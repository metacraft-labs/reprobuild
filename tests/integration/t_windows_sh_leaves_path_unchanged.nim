## The realized Windows `sh` and `bash` run with the PATH they are given.
##
## Hermetic-Builds-And-Path-Independence.md, the PATH rule: an edge that
## declares its tools gets a PATH composed only of the directories its solved
## tool graph resolved, with no ambient contribution and no host tail. The
## engine composes that PATH and launches the shell with it, so the rule holds
## only if the shell keeps it.
##
## Both packages' Windows arms used to name `bin/sh.exe` / `bin/bash.exe` in
## the PortableGit tree. Those are Git for Windows' launchers: each rewrites
## PATH to `/mingw64/bin:/usr/bin:$HOME/bin:<incoming>` before starting the
## MSYS shell under `usr/bin/`. Every action run through `sh` then searched
## `%USERPROFILE%\bin` ahead of its declared tools, and gemini-cli's
## `node-build` could never be shared, because its portable fingerprint is
## refused for a probe outside every logical root (reprobuild-pm issues/
## 2026-11-11-windows-sh-and-bash-arms-run-the-git-wrapper-which-puts-home-bin-on-path.md).
##
## Per Windows tarball arm, this realizes the arm through
## ``conformTarballArm`` (``resolveTarballTool``, the path `repro` uses). It
## then runs the resolved executable the way the engine launches an action
## with an allowlisted environment: the host-essential variables
## (``HostEssentialEnvNames``, which carry ``USERPROFILE`` and so give the
## launcher its `$HOME`) plus a PATH this test chooses. It requires
## `echo $PATH` to print that PATH back, converted to MSYS form and nothing
## more. It then runs the shell with the environment `shell()` declares on
## its action (`ShellHostSystemEnv`, Windows: `MSYSTEM=MINGW64`, which the
## launcher used to set) and requires `uname -s` to report a MinGW host,
## because `config.guess` keys on it. The Scoop arms install the same Git for
## Windows tree, so each must name the same executable as the tarball arm that
## was run.
##
## Falsifiable: put `executablePath = "bin/sh.exe"` back on `sh`'s tarball arm
## and the first case fails with
## `/mingw64/bin:/usr/bin:/c/Users/<user>/bin:/c/repro-sh-path-probe-a:...`.
##
## A network test on Windows: the first run fetches the PortableGit archive
## (one download for both packages, keyed by its pinned digest). Point
## ``REPRO_CONFORMANCE_STORE`` at a directory that survives between runs, as
## for ``t_stdlib_catalog_tarball_arms_realize``, to pay that once per pin.

import std/unittest

when defined(windows):
  import std/[os, osproc, streams, strtabs, strutils, tempfiles]

  import repro_project_dsl
  import repro_interface_artifacts
  import repro_tool_profiles/tarball_conformance
  import repro_build_engine
  import repro_core/ambient_execution
  import repro_dsl_stdlib/packages/sh
  import repro_dsl_stdlib/packages/bash

  proc toolUseFor(packageName: string): InterfaceToolUse =
    ## The tool use a consumer declaring ``uses: "<packageName>"`` gets,
    ## built from the registered stdlib definition so the arms under test are
    ## the recipe's own.
    let iface = toProjectInterface(PackageDef(
      packageName: "windowsShellPathConsumer",
      nativeBuildDeps: @[PackageUseDef(
        rawConstraint: packageName, packageSelector: packageName,
        executableName: packageName, depKind: "native")]),
      registeredPackages())
    doAssert iface.toolUses.len == 1,
      "expected one tool use for " & packageName
    iface.toolUses[0]

  proc msysForm(windowsPath: string): string =
    ## `X:\a\b` as an MSYS shell spells it in `$PATH`: `/x/a/b`. Only for the
    ## drive-rooted, unmounted directories this test chooses.
    doAssert windowsPath.len > 2 and windowsPath[1] == ':'
    "/" & $windowsPath[0].toLowerAscii &
      windowsPath[2 .. ^1].replace('\\', '/')

  proc runShell(shellExe, givenPath, script: string;
                declared: openArray[(string, string)] = []): string =
    ## Run ``shellExe -c script`` with the host-essential environment an
    ## allowlisted action gets, the ``declared`` action variables, and
    ## ``PATH=givenPath``.
    let env = newStringTable(modeCaseInsensitive)
    for name in HostEssentialEnvNames:
      if existsEnv(name):
        env[name] = getEnv(name)
    for (name, value) in declared:
      env[name] = value
    env["PATH"] = givenPath
    # The shell was realized by ``resolveTarballTool`` above, not found on
    # the ambient PATH; it is started by absolute path, as the engine does.
    let process = uncontrolledStartProcess(shellExe,
      args = ["-c", script], env = env, options = {poStdErrToStdOut})
    defer: process.close()
    let output = process.outputStream.readAll()
    let code = process.waitForExit()
    doAssert code == 0,
      shellExe & " exited " & $code & ": " & output
    output.strip()

  suite "the realized Windows sh and bash keep the PATH they are given":
    # Publishing is irrelevant here; realize locally from upstream bytes.
    putEnv("REPRO_CACHE_DISABLE", "1")

    let persistentStore = getEnv("REPRO_CONFORMANCE_STORE")
    let scratch = createTempDir("repro-windows-sh-path-", "")
    let storeRoot =
      if persistentStore.len > 0: absolutePath(persistentStore)
      else: scratch / "store"
    # Realizing runs the package's probe, whose working directory is ours.
    let originalDir = getCurrentDir()
    setCurrentDir(scratch)

    # Directories that do not exist and that PortableGit's fstab mounts
    # nowhere, so MSYS converts them verbatim. Two, so the separator is
    # checked as well.
    let drive = getEnv("SystemDrive", "C:")
    let givenDirs = [drive & "\\repro-sh-path-probe-a",
                     drive & "\\repro-sh-path-probe-b"]
    let givenPath = givenDirs.join(";")
    let expectedPath = msysForm(givenDirs[0]) & ":" & msysForm(givenDirs[1])

    for packageName in ["sh", "bash"]:
      test packageName & " realized from its tarball arm echoes PATH unchanged":
        let useDef = toolUseFor(packageName)
        var ran = 0
        for arm in useDef.tarballProvisioning:
          if not armMatchesTarget(arm, "windows", "x86_64"): continue
          let label = describeArm(packageName, arm)
          checkpoint(label)
          let verdict = conformTarballArm(useDef, arm, storeRoot)
          checkpoint("verdict: " & $verdict.verdict & " " & verdict.detail)
          require verdict.verdict == acvOk
          let echoed = runShell(verdict.resolvedExecutablePath, givenPath,
            "echo $PATH")
          checkpoint(verdict.resolvedExecutablePath & " printed " & echoed)
          check echoed == expectedPath
          inc ran
        # Against a vacuous pass: the package must have a Windows arm to run.
        check ran > 0

      test packageName & " under shell()'s declared environment reports a MinGW host":
        # The Git launcher set MSYSTEM=MINGW64, and `config.guess` keys on
        # the `uname -s` it produces. `shell()` now declares it on the
        # action (`ShellHostSystemEnv`); with that environment the MSYS
        # shell must report MINGW64 and still keep the given PATH.
        resetBuildActionRegistry()
        let edge = shell(command = "exit 0", actionId = "msystem-probe")
        check ("MSYSTEM", "MINGW64") in edge.env
        let useDef = toolUseFor(packageName)
        var ran = 0
        for arm in useDef.tarballProvisioning:
          if not armMatchesTarget(arm, "windows", "x86_64"): continue
          let verdict = conformTarballArm(useDef, arm, storeRoot)
          require verdict.verdict == acvOk
          let reported = runShell(verdict.resolvedExecutablePath, givenPath,
            "echo $(/usr/bin/uname -s) $PATH", edge.env)
          checkpoint(verdict.resolvedExecutablePath & " printed " & reported)
          let fields = reported.split(' ')
          require fields.len == 2
          check fields[0].startsWith("MINGW64_NT-")
          check fields[1] == expectedPath
          inc ran
        check ran > 0

      test packageName & "'s Scoop arm names the executable the tarball arm runs":
        # Scoop's `main/git` installs the same Git for Windows tree, which
        # this test cannot install; it can require the same path into it.
        let useDef = toolUseFor(packageName)
        var tarballPaths: seq[string] = @[]
        for arm in useDef.tarballProvisioning:
          if armMatchesTarget(arm, "windows", "x86_64"):
            tarballPaths.add(arm.executablePath)
        require tarballPaths.len > 0
        var scoopArms = 0
        for arm in useDef.scoopProvisioning:
          if arm.app != "git": continue
          inc scoopArms
          checkpoint("scoop main/git executablePath: " & arm.executablePath)
          check arm.executablePath in tarballPaths
        check scoopArms > 0

    setCurrentDir(originalDir)
    try: removeDir(scratch) except CatchableError: discard

else:
  import repro_test_support/reasoned_skip

  suite "the realized Windows sh and bash keep the PATH they are given":
    test "Windows only":
      skip("the arms under test are declared os = \"windows\"; this host " &
        "cannot realize or run them")
