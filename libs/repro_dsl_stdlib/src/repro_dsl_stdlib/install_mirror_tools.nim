## Generated shell requirements must be available during interface extraction,
## before a recipe's build body can run.

import repro_project_dsl
import repro_project_dsl/install_mirror_resolver
import ./configurables/variants
import ./packages/sh as sh_module
import ./packages/host_system_tools

proc registerInstallMirrorTools*(packageName, sourceFile: string;
                                sourceLine: int) =
  for toolName in typedInstallMirrorShellTools(packageName):
    if registerPackageNativeTool(packageName, sourceFile, sourceLine, PackageUseDef(
        rawConstraint: toolName, packageSelector: toolName,
        executableName: toolName, depKind: DepKindNative)):
      registerPackageDep(packageName, DepKindNative, toolName)
      registerSolverDependency(packageName, toolName, toolName,
        depKind = DepKindNative)
  finalizeVariants()
