## The synthetic project interface ``repro develop --cmake`` resolves its
## tools against. A CMake source tree carries no Reprobuild recipe, so this
## module stands in for one: it declares the three tools a CMake configure
## needs (``cmake``, ``cc``, ``c++``) and how Nix provisions each.

import std/os

import repro_interface_artifacts

proc sourceLocation(file: string): SourceLocation =
  SourceLocation(file: file, line: 1)

proc cmakeNixExecutable(name: string): string =
  # Windows: Nix store binaries have a `.exe` suffix. The forked CMake build
  # tree from `metacraft-labs/reprobuild-cmake` also produces `cmake.exe`,
  # `cc.exe`, etc. Emit relative paths with `.exe` on Windows so the path-only
  # / Nix executablePath actually points at a runnable file.
  when defined(windows):
    case name
    of "cmake":
      "bin/cmake.exe"
    of "cc":
      "bin/cc.exe"
    of "c++":
      "bin/c++.exe"
    else:
      "bin/" & name & ".exe"
  else:
    case name
    of "cmake":
      "bin/cmake"
    of "cc":
      "bin/cc"
    of "c++":
      "bin/c++"
    else:
      "bin/" & name

proc cmakeNixSelector(name: string): string =
  case name
  of "cmake":
    "nixpkgs#cmake"
  of "cc", "c++":
    "nixpkgs#clang"
  else:
    "nixpkgs#" & name

proc cmakeToolUse(sourceRoot, name: string): InterfaceToolUse =
  ## A use with NO version range. The owner of a version requirement on these
  ## tools would be the CMake project, and a CMake tree states none to
  ## Reprobuild, so a range here would be invented. It used to be the
  ## placeholder ``>=1.0 <2.0``, which PATH mode began holding against each
  ## tool's ``--version`` report and so refused every real ``cmake`` (the
  ## reprobuild-cmake fork reports 4.3) and compiler (reprobuild-pm issue
  ## 2026-11-14-t-e2e-repro-develop-cmake-fails-the-declared-cmake-version-
  ## range-against-the-fork). The version a tool reports is still probed and
  ## keyed into its profile; it is just not refused.
  let loc = sourceLocation(sourceRoot / "CMakeLists.txt")
  InterfaceToolUse(
    rawConstraint: name,
    packageSelector: name,
    executableName: name,
    nixProvisioning: @[InterfaceNixProvisioning(
      packageName: name,
      selector: cmakeNixSelector(name),
      executablePath: cmakeNixExecutable(name),
      packageId: cmakeNixSelector(name),
      lockIdentity: cmakeNixSelector(name),
      location: loc)],
    location: loc)

proc cmakeDevelopArtifact*(sourceRoot: string): ProjectInterfaceArtifact =
  artifactFor(ProjectInterface(
    projectName: "cmakeDevelop",
    packageName: "cmakeDevelop",
    toolUses: @[
      cmakeToolUse(sourceRoot, "cmake"),
      cmakeToolUse(sourceRoot, "cc"),
      cmakeToolUse(sourceRoot, "c++")
    ],
    location: sourceLocation(sourceRoot / "CMakeLists.txt")))

