## Named-Targets M1 test fixtures for
## ``t_engine_implicit_target_name_hook_overrides_canonical``.
##
## The fixture defines an ``executable cmakeBuild:`` whose ``cli:``
## carries both an ``outputs target`` statement and an
## ``implicitTargetName(call: CmakeBuildCall): string`` hook returning
## ``"cmake-" & call.target``. The M1 wrapper invokes the hook at the
## call site and replaces the canonical (first) entry of
## ``targetNames`` with the hook's return; the auxiliary names from
## additional ``outputs`` flags survive.
##
## ``CmakeBuildCall`` declares ``target`` AND ``aux`` so the wrapper
## constructs ``CmakeBuildCall(target: target, aux: aux)`` at every
## call site (the M1 wrapper maps each CLI param to a same-named field
## on the user-declared call-record type). ``aux`` exercises the
## "additional outputs survive" rule from the M1 spec.

import repro_project_dsl
import repro_dsl_stdlib/types

type
  CmakeBuildCall* = object
    target*: string
    aux*: string

# The fixture is defined as a ``package`` with no ``build:`` body so
# ``recordActions = true`` and the typed-tool wrapper proc returns
# ``BuildActionDef`` (which is what the M1 wiring suffix attaches the
# ``targetNames`` to).

package tEngineHookTool:
  uses:
    "nim >=2.2 <3.0"
  executable cmakeBuild:
    cli:
      subcmd "build":
        flag target is string,
          alias = "--target",
          required = true
        flag aux is string,
          alias = "--aux",
          role = output
        outputs target aux

    implicitTargetName(call: CmakeBuildCall): string =
      "cmake-" & call.target

# A consumer package that calls the typed-tool wrapper from a
# ``build:`` body. The wrapper proc — defined inside
# ``tEngineHookTool`` — returns a ``BuildActionDef`` (because
# ``recordActions = true`` was emitted there) and the M1 wiring
# suffix populates ``targetNames`` and the export rows.

package tEngineHookConsumer:
  uses:
    "nim >=2.2 <3.0"
  build:
    discard t_engine_hook_tool.build(target = "kernel",
      aux = "build/kernel.aux.o", actionId = "cmake-build-kernel")

export CmakeBuildCall
export t_engine_hook_tool
export buildTEngineHookConsumerPackage
