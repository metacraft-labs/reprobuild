## DSL-port M9.R.2b — typed ``Executable`` value layer.
##
## See [[file:Reprobuild-Standard-Library.md][Reprobuild-Standard-Library]]
## §"Typed-value layer". Mirrors ``types/library.nim`` for executables.
## The ``cli`` field is a thin metadata record (``ExecutableCliMeta``);
## the full ``cli:`` block typed surface lives on the package macro's
## generated wrapper procs (the Layer-3 surface — ``meson.setup``,
## ``cmake.configure``, ...). The metadata record here records the
## scalar lift-outs the constructors derive at call time
## (``executableName``, ``installPrefix``).

import repro_project_dsl

type
  ExecutableCliMeta* = object
    ## Minimal metadata about the executable's CLI surface. The
    ## full typed CLI lives on the auto-generated wrapper proc set
    ## emitted from the package's ``executable <name>: cli:`` block
    ## (Layer 3). This record carries only the lifted scalars the
    ## Layer-1 constructors and Layer-2 overloads need to populate
    ## install metadata.
    executableName*: string
      ## The artifact identifier (matches ``executable <name>:`` in
      ## the recipe). Empty when the executable was synthesised by a
      ## constructor (e.g. ``c_executable``) without a surrounding
      ## ``executable`` declaration.

  Executable* = object
    ## Returned by the Layer-1 high-level constructors
    ## (``c_executable``, ``nim_executable``,
    ## ``MesonPackageResult.executable``) and Layer-2 ``link``
    ## overloads when the link target is an executable.
    cli*: ExecutableCliMeta
      ## CLI metadata.
    install*: BuildActionDef
      ## The producing ``BuildEdge``.
    installPrefix*: string
      ## Relative path within the install destdir (e.g.
      ## ``"usr/bin"``). Empty when the producing edge is not a
      ## destdir-staged install action.

proc newExecutable*(install: BuildActionDef;
                    executableName = "";
                    installPrefix = ""): Executable =
  ## Convenience constructor.
  Executable(
    cli: ExecutableCliMeta(executableName: executableName),
    install: install,
    installPrefix: installPrefix)
