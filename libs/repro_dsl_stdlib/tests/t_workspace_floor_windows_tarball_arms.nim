## Every tool in the metacraft workspace dev-env floor can be provisioned by
## `tarball` on Windows x86_64.
##
## The workspace `repro.nim` declares
## `defaultToolProvisioning(when defined(windows): tarball else: nix)` and a
## `uses:` floor of git, just, gh, nim, python3 and gcc. A floor tool with no
## Windows `tarball` arm is not an error at declaration time: the dev env
## warns "does not declare provisioning: tarball metadata" and falls back to
## whatever is on the host PATH. On a Windows host without the DIY `env.ps1`
## that is nothing, and the fallback is exactly the dependency the
## reprobuild-adoption campaign is removing.
##
## That is how `gh` went unnoticed. Its package carried an M68 catalog slice,
## which reads like Windows coverage but feeds the `repro home apply` adapter
## chain, not project provisioning. Its only project arm was `nixPackage`.
## This test reads the arms project provisioning actually consumes.
##
## The floor list is copied from the workspace recipe, which lives in another
## repository and so cannot be imported here. Keep the two in step: a tool
## added to that `uses:` block belongs in `WorkspaceFloor` below.
##
## No mocks: it inspects the real registered package definitions.

import std/[strutils, unittest]

import repro_project_dsl
# Aliased: each `package <name>:` block emits a const of that name, which a
# plain import would shadow with the module name (see t_nim_c_cpu_flag.nim).
import repro_dsl_stdlib/packages/git as git_pkg
import repro_dsl_stdlib/packages/just as just_pkg
import repro_dsl_stdlib/packages/gh as gh_pkg
import repro_dsl_stdlib/packages/nim as nim_pkg
import repro_dsl_stdlib/packages/python3 as python3_pkg
import repro_dsl_stdlib/packages/gcc as gcc_pkg

const WorkspaceFloor = ["git", "just", "gh", "nim", "python3", "gcc"]

proc packageNamed(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError, "package not registered: " & name)

proc windowsX64Arms(pkg: PackageDef): seq[TarballProvisioningDef] =
  for arm in pkg.tarballProvisioning:
    if arm.os.toLowerAscii == "windows" and
       arm.cpu.toLowerAscii in ["x86_64", "amd64", "x64"]:
      result.add(arm)

suite "workspace dev-env floor is tarball-provisionable on Windows x86_64":

  for tool in WorkspaceFloor:
    test tool & " declares a Windows x86_64 tarball arm":
      let arms = windowsX64Arms(packageNamed(tool))
      check arms.len > 0

    test tool & "'s Windows arm is pinned and names its executable":
      # An arm with no digest cannot be verified and an arm with no executable
      # path cannot be put on PATH; either would pass the check above and
      # still fail in the dev env.
      for arm in windowsX64Arms(packageNamed(tool)):
        check arm.sha256.len == 64
        check arm.executablePath.len > 0
        check arm.executablePath.toLowerAscii.endsWith(".exe")
