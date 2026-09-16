import std/sets

import repro_cmake_trycompile
import repro_interface_artifacts
import repro_tool_profiles

proc cmakeDirectBuildIdentity*(meta: TryCompileMetadata;
                               pathValue: string): PathOnlyBuildIdentity =
  # Inline commands already carry resolved executables. Only wrapper-backed
  # actions need the normal resolver; resolving every usedTool would also
  # reprobe compilers for each try_compile invocation.
  var required = initHashSet[string]()
  for action in meta.actions:
    if not action.inline:
      if action.toolId.len == 0 or action.toolId notin meta.usedTools:
        raise newException(ValueError,
          "CMake action " & action.id & " references undeclared tool " &
            action.toolId)
      required.incl(action.toolId)
  var project = ProjectInterface(
    projectName: TryCompileProviderPackageName,
    packageName: TryCompileProviderPackageName)
  for tool in meta.usedTools:
    if tool in required:
      project.toolUses.add(InterfaceToolUse(
        rawConstraint: tool & " >=1.0 <2.0",
        packageSelector: tool,
        executableName: tool))
      required.excl(tool)
  pathOnlyBuildIdentity(artifactFor(project), pathValue)
