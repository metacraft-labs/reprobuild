## `repro develop --cmake` resolves `cmake`, `cc` and `c++` against a
## synthetic project interface (`cmakeDevelopArtifact`), because a CMake
## source tree has no Reprobuild recipe of its own. Nothing in a CMake tree
## declares a version for those tools, so the synthetic interface must not
## claim one either. It used to declare `<tool> >=1.0 <2.0` as a placeholder;
## once PATH mode began holding a tool's `--version` report against the
## declared range, the placeholder refused every real tool: the
## reprobuild-cmake fork reports `cmake version 4.3.<date>` and a current gcc
## reports `14.x`, and `t_e2e_repro_develop_cmake` failed 3 of 3 at tool
## resolution (reprobuild-pm issue 2026-11-14-t-e2e-repro-develop-cmake-
## fails-the-declared-cmake-version-range-against-the-fork).
##
## No mocks: the tools are real executables on a real `$PATH`, run by the
## production resolver (`resolvePathOnlyTool`, which applies the PATH-mode
## range check). They are stand-in scripts rather than a real CMake and
## compiler only because what is under test is the version each one reports,
## and a script states that version exactly; the e2e suite runs the real fork.

import std/[os, strutils, tempfiles, unittest]

import repro_cli_support/cmake_develop_interface
import repro_interface_artifacts
import repro_tool_profiles

proc writeTool(dir, name, versionLine: string) =
  ## An executable that answers `--version` the way the real tool does.
  let path = dir / name
  writeFile(path, "#!/bin/sh\necho '" & versionLine & "'\n")
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

when not defined(windows):
  suite "repro develop --cmake tool interface":
    var root: string
    setup:
      root = createTempDir("repro-cmake-develop-tools-", "")
    teardown:
      removeDir(root)

    test "the synthetic interface declares no version range for any tool":
      # The owner of a version number for these tools would be the CMake
      # project, and it states none to Reprobuild; a range here is invented.
      let uses = cmakeDevelopArtifact(root).projectInterface.toolUses
      check uses.len == 3
      for use in uses:
        check use.rawConstraint == use.packageSelector
        check requestedUsesVersionRange(use).len == 0

    test "the fork's cmake and a current compiler resolve in PATH mode":
      let bin = root / "bin"
      createDir(bin)
      # What the reprobuild-cmake fork at 67103c8590 and the host compilers
      # actually report.
      writeTool(bin, "cmake", "cmake version 4.3.20260518")
      writeTool(bin, "cc", "gcc (GCC) 14.3.0")
      writeTool(bin, "c++", "g++ (GCC) 14.3.0")
      for use in cmakeDevelopArtifact(root).projectInterface.toolUses:
        let profile = resolvePathOnlyTool(use, bin)
        check profile.resolvedExecutablePath == bin / use.executableName
        check realizedVersionOf(profile).len > 0
        check pathToolVersionRangeRefusal(profile, use) == ""

    test "the reported version is still recorded in the tool's identity":
      # Declaring no range must not make the version invisible: two cmakes
      # reporting different versions still resolve to different profiles.
      let first = root / "first"
      let second = root / "second"
      createDir(first)
      createDir(second)
      writeTool(first, "cmake", "cmake version 4.3.20260518")
      writeTool(second, "cmake", "cmake version 3.31.6")
      var cmakeUse: InterfaceToolUse
      for use in cmakeDevelopArtifact(root).projectInterface.toolUses:
        if use.executableName == "cmake":
          cmakeUse = use
      let a = resolvePathOnlyTool(cmakeUse, first)
      let b = resolvePathOnlyTool(cmakeUse, second)
      check realizedVersionOf(a).startsWith("4.3.")
      check realizedVersionOf(b) == "3.31.6"
      check a.profileFingerprint != b.profileFingerprint
