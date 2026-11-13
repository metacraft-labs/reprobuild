## Real Autoconf configure/config.status regression for intrinsic constructor
## tools. No mocked scripts or executables: the fixture generates its upstream
## program with Autoconf and exposes real tools through a closed action PATH.

import std/[os, strtabs, strutils, tempfiles, unittest]
import repro_project_dsl
import repro_core/ambient_execution
import repro_dsl_stdlib/constructors/autotools_package

proc inlineArgv(action: BuildActionDef): seq[string] =
  for arg in action.call.arguments:
    if arg.name == "argv":
      return arg.encodedValue.split('\x1f')
  raise newException(ValueError, "missing inline argv")

suite "Autotools intrinsic configure tools":
  when not defined(windows):
    test "real config.status substitutes and compares with only declared tools":
      # No fake configure or tool executables: Autoconf generates the program,
      # and symlinks expose real tools in a deliberately closed PATH. The
      # ordinary shell utilities are fixture infrastructure; awk and diff
      # enter that PATH exclusively through the constructor's identity refs.
      let root = createTempDir("repro-autoconf-tools-", "")
      defer: removeDir(root)
      let src = root / "src"
      createDir(src)
      writeFile(src / "configure.ac", """AC_INIT([identity-tools], [1])
AC_SUBST([PROBE_VALUE], [substitution-worked])
AC_CONFIG_FILES([Makefile])
AC_CONFIG_COMMANDS([compare], [diff ../src/expected Makefile || exit 1])
AC_OUTPUT
""")
      writeFile(src / "Makefile.in", "value = @PROBE_VALUE@\n")
      writeFile(src / "expected", "value = substitution-worked\n")
      let autoconf = uncontrolledFindExe("autoconf")
      require autoconf.len > 0
      let generated = uncontrolledExecCmdEx(quoteShellCommand(@[autoconf]), workingDir = src)
      checkpoint generated.output
      require generated.exitCode == 0
      let action = autotools_package(srcDir = "src", buildDir = "build").buildEdge
      let binDir = root / "bin"
      createDir(binDir)
      for name in @["mkdir", "rm", "sed", "expr", "basename", "dirname",
          "cat", "chmod", "tr", "grep", "sort", "ls", "ln", "cp", "mv",
          "rmdir", "uname", "head", "tail", "cut", "cmp"] & action.toolIdentityRefs:
        let tool = uncontrolledFindExe(name)
        require tool.len > 0
        if not symlinkExists(binDir / name):
          createSymlink(tool, binDir / name)
      let environment = newStringTable(modeCaseSensitive)
      environment["PATH"] = binDir
      environment["CONFIG_SHELL"] = binDir / "sh"
      environment["LC_ALL"] = "C"
      let execution = uncontrolledExecCmdEx(quoteShellCommand(action.inlineArgv()),
        env = environment, workingDir = root)
      checkpoint execution.output
      require execution.exitCode == 0
      check readFile(root / "build" / "Makefile") == "value = substitution-worked\n"
      check fileExists(root / "build" / ".repro-configure.stamp")
      # Positive controls show that neither inherited host PATH nor a cached
      # generated Makefile can conceal either missing constructor tool.
      for missing in ["awk", "diff"]:
        removeFile(binDir / missing)
        let control = uncontrolledExecCmdEx(quoteShellCommand(action.inlineArgv()),
          env = environment, workingDir = root)
        checkpoint control.output
        check control.exitCode != 0
        check missing in control.output
        check not fileExists(root / "build" / ".repro-configure.stamp")
        createSymlink(uncontrolledFindExe(missing), binDir / missing)
