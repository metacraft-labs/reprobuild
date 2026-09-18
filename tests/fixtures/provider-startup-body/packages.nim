## Fixture packages for
## ``tests/unit/t_provider_startup_body_containment.nim``.
##
## Deliberately NOT named ``t_*`` / ``test_*``: the test-edge generator
## discovers Nim tests by stem, and this module declares packages rather
## than cases. It must always be IMPORTED and never compiled as the main
## module, because the ``package`` macro's ``isMainModule`` arm turns a
## main module into a provider protocol binary under
## ``-d:reproProviderMode``.
##
## The order of the two declarations is load-bearing. Module
## initialisation is a sequence of statements, so the package whose body
## raises is declared FIRST: if the raise were not contained it would
## abort initialisation there, and the second package's body -- and every
## case in the test -- would never run.

import repro_project_dsl

const
  StartupBodyRaiseSentinel* =
    "provider startup body fixture: deliberate failure 7b1e"
    ## Distinctive enough that no other refusal in the tree can satisfy a
    ## substring check for it.
  StartupBodyShellCommand* = "echo provider-startup-body-fixture"
  StartupBodyDefectSentinel* =
    "provider startup body fixture: deliberate defect 9c4a"
    ## The same distinctiveness requirement as the raise sentinel, and for
    ## the same reason: two refusals that share a substring are one
    ## measurement, not two.

var
  startupBodyRefusesRuns* = 0
  startupBodyDefectsRuns* = 0
  startupBodyRegistersRuns* = 0
  startupBodyActiveSeenByRefuses*: seq[bool] = @[]
  startupBodyRootSeenByRefuses*: seq[string] = @[]

package startupBodyRefuses:
  ## A body that cannot run without a request. Every recipe that resolves
  ## an input path against the project root has this shape; resolving one
  ## during the startup pass raises, because there is no root yet.
  build:
    inc startupBodyRefusesRuns
    startupBodyActiveSeenByRefuses.add(providerStartupBodyActive())
    startupBodyRootSeenByRefuses.add(activeProviderProjectRoot())
    raise newException(ValueError, StartupBodyRaiseSentinel)

package startupBodyRaisesDefect:
  ## A body that fails the way a recipe running without a project root
  ## most often actually fails: not with a raise, but by indexing a path
  ## that is empty because the root it was built from is empty. In Nim
  ## that is an ``IndexDefect``, not a ``CatchableError``, so a
  ## containment written for the second alone does not cover it.
  ##
  ## Declared BEFORE ``startupBodyRegisters`` for the same reason the
  ## raising package is: module initialisation is a sequence, so an
  ## uncontained defect here would stop every declaration after it, and
  ## the suite would report nothing rather than a failure.
  build:
    inc startupBodyDefectsRuns
    raise newException(IndexDefect, StartupBodyDefectSentinel)

package startupBodyRegisters:
  ## A body that CAN run without a request, and the reason the startup
  ## pass exists at all: its ``shell(...)`` row has to be in the registry
  ## before a convention decides whether it can claim the recipe.
  build:
    inc startupBodyRegistersRuns
    shell(StartupBodyShellCommand, id = "startupBodyRegisters.probe")
