## The fetch implementation's build-time requirements, available during
## interface extraction without evaluating the package's build body.

import repro_project_dsl
import ./configurables/variants
import ./packages/sh as sh_module
import ./packages/curl as curl_module
import ./packages/tar as tar_module
import ./packages/zstd as zstd_module
import ./packages/git as git_module
import ./packages/host_system_tools

proc registerSourceFetchTools*(packageName, sourceFile: string; sourceLine: int) =
  let spec = registeredFetchSpec(packageName)
  if spec.url.len == 0 or spec.hashHex.len == 0:
    return
  var tools = shellFetchToolIdentityRefs(@[sourceFetchHashTool(spec.hashAlg)],
    copiesDataFile = spec.kind == dfkDataFile, archiveUrl = spec.url)
  if spec.kind == dfkGitArchive:
    tools.add("git")
  for toolName in tools:
    if registerPackageNativeTool(packageName, sourceFile, sourceLine, PackageUseDef(
        rawConstraint: toolName, packageSelector: toolName,
        executableName: toolName, depKind: DepKindNative)):
      # ``registerGeneratedToolDep``, not ``registerPackageDep``: these are
      # the commands the GENERATED fetch script runs, not a claim about the
      # recipe's build system. The list starts with ``sh``, which the M9.R.6
      # convention narrowing reads as "shell-driver recipe".
      registerGeneratedToolDep(packageName, DepKindNative, toolName)
      registerSolverDependency(packageName, toolName, toolName,
        depKind = DepKindNative)
  finalizeVariants()
