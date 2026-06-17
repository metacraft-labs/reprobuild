## DSL-port M5 acceptance — service's ``executable <ident>`` setter
## records a cross-reference to the parent ``executable`` artifact.
##
## This fixture sits next to the M3 artifact emission: the same
## package declares both an ``executable`` artifact AND a ``service``
## that names that executable. The two registry sidecars
## (``dslPortArtifactRegistry`` from M3 and the new
## ``dslPortServiceRegistry`` from M5) end up populated in lockstep so
## downstream consumers can verify the cross-reference is well-formed
## (i.e. the service's ``executableRef`` matches an artifact's
## ``artifactName`` with kind ``dakExecutable``).

import std/[unittest]

import repro_project_dsl

package refPkg:
  executable myBin:
    build:
      output("bin/myBin")
  service myService:
    executable myBin
    args "arg1", "arg2"

suite "DSL-port M5 — service references executable":
  test "service.executableRef points at declared executable":
    let svcs = registeredServices("refPkg")
    check svcs.len == 1
    check svcs[0].executableRef == "myBin"

    # Cross-check: the executable was also registered into the M3
    # artifact sidecar. Both pathways read off the same partitioned
    # section list at macro-expansion time, so the two registries
    # populate in source order.
    let arts = registeredArtifacts("refPkg")
    check arts.len == 1
    check arts[0].artifactName == "myBin"
    check arts[0].kind == dakExecutable
