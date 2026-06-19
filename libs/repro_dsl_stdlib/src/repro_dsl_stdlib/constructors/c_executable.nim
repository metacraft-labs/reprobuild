## DSL-port M9.R.2b — Layer-1 ``c_executable`` constructor.
##
## Parallel to ``c_library`` but emits a link edge with ``kind =
## lokExecutable`` and returns a typed ``Executable`` value.

import repro_project_dsl

import ../types/library
import ../types/executable
import ../types/options
import ../operations/compile
import ../operations/link

proc c_executable*(into: string;
                   sources: seq[string];
                   deps: seq[Library] = @[];
                   extraDefines: seq[string] = @[];
                   standard = "c11"): Executable =
  ## Build a C executable from ``sources``. Mirrors ``c_library``'s
  ## auto-lift + per-source compile pattern; emits ``link(kind =
  ## lkExe)`` at the end.
  var objects: seq[BuildActionDef] = @[]
  for src in sources:
    let target = src & ".o"
    var inputs: seq[LibraryApi] = @[]
    for d in deps:
      if d.api.declared: inputs.add(d.api)
    objects.add(compile(
      source = src,
      target = target,
      inputs = inputs,
      defines = extraDefines,
      standard = standard))

  let linkEdge = link(LinkOptions(
    objects: objects,
    deps: deps,
    kind: lokExecutable,
    target: into))

  newExecutable(install = linkEdge, executableName = into,
                installPrefix = "usr/bin")
