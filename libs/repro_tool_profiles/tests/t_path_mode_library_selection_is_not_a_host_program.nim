## A package selected for its headers and libraries is not satisfied by an
## executable of the same name on PATH (reprobuild-pm issue
## 2026-11-11-path-mode-satisfies-a-development-package-selection-with-a-host-binary;
## Package-Model.md §"Environment-provided library prefixes").
##
## Real files in a real temporary directory and the real path-mode resolver;
## nothing is mocked. The library package's only arm is an archive for a
## platform no host is, so the fall-through to it fails offline, without
## touching Nix or the network: what the test observes is that the PATH
## program is not taken.

import std/[os, strutils, unittest]

import repro_interface_artifacts
import repro_project_dsl
import repro_tool_profiles

package libprobe:
  provisioning:
    tarball url = "https://example.invalid/libprobe.tar.gz",
      sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
      archiveType = "tar.gz",
      executablePath = "include/libprobe.h",
      cpu = "armv7", os = "linux"

package toolprobe:
  provisioning:
    tarball url = "https://example.invalid/toolprobe.tar.gz",
      sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
      archiveType = "tar.gz",
      executablePath = "bin/toolprobe",
      cpu = "armv7", os = "linux"

proc consumer(selector: string): ProjectInterfaceArtifact =
  ProjectInterfaceArtifact(projectInterface: toProjectInterface(PackageDef(
    packageName: "probeConsumer",
    toolUses: @[PackageUseDef(rawConstraint: selector,
      packageSelector: selector, executableName: selector,
      depKind: DepKindTarget)]), registeredPackages()))

proc hostProgramDir(root, name: string): string =
  result = root / "bin"
  createDir(result)
  writeFile(result / name, "#!/bin/sh\nexit 0\n")
  setFilePermissions(result / name,
    {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec,
     fpOthersRead, fpOthersExec})

proc freshRoot(name: string): string =
  result = getTempDir() / ("t_path_library_" & $getCurrentProcessId() & "_" & name)
  removeDir(result)
  createDir(result)

suite "path mode and a library selection":

  test "a library package is recognised by its header/library anchors":
    let lib = consumer("libprobe").projectInterface.toolUses[0]
    check selectsLibraryOutputs(lib)
    check not selectsLibraryOutputs(consumer("toolprobe").projectInterface.toolUses[0])

  test "a same-named program on PATH does not satisfy a library selection":
    let dir = hostProgramDir(freshRoot("lib"), "libprobe")
    var message = ""
    try:
      let identity = pathOnlyBuildIdentity(consumer("libprobe"), dir)
      message = "resolved: " & identity.profiles[0].resolvedExecutablePath
    except CatchableError as e:
      message = e.msg
    check not message.startsWith("resolved")
    check "libprobe" in message

  test "a program selection is still satisfied from PATH":
    let dir = hostProgramDir(freshRoot("tool"), "toolprobe")
    let identity = pathOnlyBuildIdentity(consumer("toolprobe"), dir)
    check identity.profiles[0].resolvedExecutablePath == dir / "toolprobe"
