## Generated shell requirements must be available during interface extraction,
## before a recipe's build body can run.

import repro_project_dsl
import repro_project_dsl/install_mirror_resolver
import ./configurables/variants
import ./packages/sh as sh_module
import ./packages/host_system_tools

package `repro-install-mirror-publish`:
  ## Reprobuild's own helper, shipped in the same `bin/` as `repro` (every
  ## `scripts/build_apps.sh` build and the packaged release): what a
  ## cross build's install-mirror action runs for the object check
  ## (`emitInstallMirrorTargetCheck`). No provisioning arm: it comes from
  ## the PATH `repro` itself is on, never from a catalog.
  discard

proc installMirrorActionTools(packageName: string): seq[string] =
  ## The commands the generated install-mirror script runs. The publish
  ## helper is among them only when the script calls it, i.e. under
  ## `--target` (the object check).
  result = typedInstallMirrorShellTools(packageName)
  if effectiveInstallMirrorTarget().len > 0:
    result.add(InstallMirrorPublishToolName)

proc registerInstallMirrorTools*(packageName, sourceFile: string;
                                sourceLine: int) =
  for toolName in installMirrorActionTools(packageName):
    if registerPackageNativeTool(packageName, sourceFile, sourceLine, PackageUseDef(
        rawConstraint: toolName, packageSelector: toolName,
        executableName: toolName, depKind: DepKindNative)):
      # ``registerGeneratedToolDep``, not ``registerPackageDep``: these are
      # the commands the GENERATED install-mirror script runs, not a claim
      # about the recipe's build system. See the accessor pair on
      # ``registeredAuthoredNativeBuildDeps``.
      registerGeneratedToolDep(packageName, DepKindNative, toolName)
      registerSolverDependency(packageName, toolName, toolName,
        depKind = DepKindNative)
  # Module-init spelling: the `package` macro emits the call to this proc at
  # module scope, so it runs once per imported recipe over the same growing
  # registry the macro's own finalize does. See
  # `configurables/variants.finalizeVariantsAtModuleInit`.
  finalizeVariantsAtModuleInit()
