## TI1 (Project-Provider-Runtime-Protocol.milestones.org) — a producer's
## interface LIFT is a first-class, cached, content-addressed BUILD EDGE.
##
## Spec: Project-Interface-Artifacts-And-Import-Modes.md §"Automatic Interface
## Lifting" / §"Interface Identity And Invalidation" (InterfaceFingerprint vs
## ProviderFingerprint). Mirrors RP1's provider-compile edge model
## (``t_rp1_provider_compile_edge_materializes``).
##
## This drives the REAL Nim interface lift for representative small producers
## in a tempdir (nothing touches $HOME) against ``getCurrentDir()`` (the
## reprobuild repo root, so the DSL ``import repro`` + lib-path flags resolve).
## It proves three load-bearing properties:
##
##   1. **Cached interface-artifact edge.** A producer's interface is
##      materialized ONCE as a cached ``ProjectInterfaceArtifact`` keyed by the
##      InterfaceFingerprint + an InterfaceLiftActionKey. A 2nd lift with an
##      UNCHANGED public interface is a cache HIT — the lift edge is NOT re-run
##      (asserted via the action-key stability + the freshness short-circuit +
##      an artifact-mtime witness). Changing a PUBLIC decl re-keys the lift AND
##      re-materializes a new InterfaceFingerprint. NON-VACUOUS.
##
##   2. **InterfaceFingerprint EXCLUDES the impl.** Changing a producer's
##      ``build:`` / DRIVER BODY (private implementation) does NOT change the
##      InterfaceFingerprint; changing a PUBLIC decl DOES. This is the
##      TI3-readiness property.
##
##   3. **Producer-declared resource module.** A producer declaring a SEPARATE
##      resource module (like vm-harness's ``resources.nim``) lifts
##      ``publicResources`` with the REAL resource types (typeId / determinism
##      / typed attrs / entry-point ids) from that module.

import std/[options, os, sequtils, strutils, unittest]

import repro_interface_artifacts
import repro_core

# ---------------------------------------------------------------------------
# (1)/(2) A producer whose PUBLIC surface is a ``cli:`` executable and whose
# PRIVATE implementation is a ``build:`` body — the split TI3 builds on.
# ---------------------------------------------------------------------------

const producerPublicA = """
import repro_project_dsl

package ti1widget:
  executable ti1cli:
    name: "ti1"
    cli:
      subcmd "bundle":
        flag output is string
  build:
    discard
"""

# Same PUBLIC surface as producerPublicA, but a DIFFERENT ``build:`` body
# (private implementation). The InterfaceFingerprint MUST be identical.
const producerPrivateEditA = """
import repro_project_dsl

package ti1widget:
  executable ti1cli:
    name: "ti1"
    cli:
      subcmd "bundle":
        flag output is string
  build:
    let x = 41
    discard x + 1
"""

# A PUBLIC decl change (a new CLI flag). The InterfaceFingerprint MUST change.
const producerPublicEditA = """
import repro_project_dsl

package ti1widget:
  executable ti1cli:
    name: "ti1"
    cli:
      subcmd "bundle":
        flag output is string
        flag format is string
  build:
    discard
"""

proc writeProject(root, source: string): string =
  createDir(extendedPath(root))
  let modulePath = root / "reprobuild.nim"
  writeFile(extendedPath(modulePath), source)
  modulePath

# ---------------------------------------------------------------------------
# (3) A producer that declares a SEPARATE resource module — its ``resourceType``
# blocks live in ``repro/resources.nim``, NOT in the project's ``repro.nim``.
# The lift must import that module (so its module-init registrations run) and
# reflect the REAL resource types in ``publicResources``.
# ---------------------------------------------------------------------------

const resourceModuleSource = """
import repro_project_dsl
import repro_resources
import std/options

type
  ContainerAttrs = object
    image*: string
    cpus*: int

proc cIdentity(inst: ResourceInstance): string {.nimcall.} =
  "container:" & inst.address

proc cDigest(inst: ResourceInstance): Digest256 {.nimcall.} =
  digestString(inst.address)

proc cObserve(inst: ResourceInstance;
              recorded: Option[ResourceBinding]): ObservedState {.nimcall.} =
  result.present = false

proc cApply(inst: ResourceInstance; action: ResourceActionKind;
            observed: ObservedState): ResourceBinding {.nimcall.} =
  ResourceBinding(address: inst.address, typeId: inst.typeId,
    resourceId: cIdentity(inst), present: true)

let containerDriver = ResourceProviderDriver(
  identity: cIdentity, digest: cDigest, observe: cObserve, apply: cApply)

resourceType "vm_harness.container":
  attrs: ContainerAttrs
  wrapper: container
  determinism: rdVolatile
  driver: containerDriver
  attr image: string
  attr cpus: int
"""

# The producer's own project file declares only a package/executable — the
# resource types come from the SEPARATE module above.
const resourceProducerRepro = """
import repro_project_dsl

package ti1vmharness:
  executable placeholder:
    discard
"""

suite "TI1: interface-artifact edge (cached, content-addressed lift)":

  test "t_ti1_interface_artifact_edge_caches_and_rekeys":
    let tempRoot = getTempDir() / "ti1-edge-" & $getCurrentProcessId()
    removeDir(extendedPath(tempRoot))
    let projectRoot = tempRoot / "project"
    let outDir = tempRoot / "out"
    createDir(extendedPath(outDir))
    defer: removeDir(extendedPath(tempRoot))

    let modulePath = writeProject(projectRoot, producerPublicA)
    let artifactPath = outDir / "ti1-interface.rbsz"
    let stubPath = outDir / "ti1-interface.nim"

    # ---- (1) COLD lift: materializes the artifact + records the action key.
    let plan = interfaceLiftPlan(modulePath, artifactPath, stubPath,
      workDir = getCurrentDir())
    # The engine edge is keyed by the InterfaceLiftActionKey.
    check plan.liftEdge.actionFingerprint == plan.interfaceLiftActionKey
    check plan.interfaceLiftActionKey.bytes.len == 32
    check not interfaceArtifactFresh(plan)     # nothing on disk yet

    let cold = liftInterfaceArtifact(plan)
    check fileExists(extendedPath(artifactPath))
    check fileExists(extendedPath(interfaceLiftActionKeyPath(artifactPath)))
    let coldFingerprint = cold.interfaceFingerprint
    check coldFingerprint.bytes.len == 32
    # The persisted artifact round-trips through the existing codec.
    let roundTrip = readInterfaceArtifact(artifactPath)
    check roundTrip.interfaceFingerprint == coldFingerprint
    check roundTrip.projectInterface.projectName == "ti1widget"

    # ---- (1) WARM lift with an UNCHANGED public interface: cache HIT.
    # The lift edge is NOT re-run: the plan is fresh, the action key is stable,
    # and the artifact file is byte-identical (its mtime does not advance).
    let coldMtime = getLastModificationTime(extendedPath(artifactPath))
    check interfaceArtifactFresh(plan)
    let planAgain = interfaceLiftPlan(modulePath, artifactPath, stubPath,
      workDir = getCurrentDir())
    check planAgain.interfaceLiftActionKey == plan.interfaceLiftActionKey
    let warm = liftInterfaceArtifact(planAgain)
    check warm.interfaceFingerprint == coldFingerprint
    check getLastModificationTime(extendedPath(artifactPath)) == coldMtime

    # ---- (1) NON-VACUITY: a PUBLIC decl change re-keys the lift AND
    # re-materializes a NEW InterfaceFingerprint.
    writeFile(extendedPath(modulePath), producerPublicEditA)
    let planPublic = interfaceLiftPlan(modulePath, artifactPath, stubPath,
      workDir = getCurrentDir())
    check planPublic.interfaceLiftActionKey != plan.interfaceLiftActionKey
    check not interfaceArtifactFresh(planPublic)   # stale ⇒ edge re-runs
    let afterPublic = liftInterfaceArtifact(planPublic)
    check afterPublic.interfaceFingerprint != coldFingerprint

  test "t_ti1_interface_fingerprint_excludes_impl":
    ## The load-bearing TI3-readiness property: a PRIVATE ``build:`` body edit
    ## does NOT change the InterfaceFingerprint; a PUBLIC decl edit DOES.
    let tempRoot = getTempDir() / "ti1-fp-" & $getCurrentProcessId()
    removeDir(extendedPath(tempRoot))
    let projectRoot = tempRoot / "project"
    let outDir = tempRoot / "out"
    createDir(extendedPath(outDir))
    defer: removeDir(extendedPath(tempRoot))

    let modulePath = writeProject(projectRoot, producerPublicA)
    let artifactPath = outDir / "ti1-fp.rbsz"
    let stubPath = outDir / "ti1-fp.nim"

    let base = liftInterfaceArtifact(interfaceLiftPlan(modulePath, artifactPath,
      stubPath, workDir = getCurrentDir()))
    let baseFingerprint = base.interfaceFingerprint

    # PRIVATE ``build:`` body edit — the InterfaceFingerprint is UNCHANGED.
    # (The lift edge DOES re-run — the action key is input-keyed — but its
    # OUTPUT identity, the public-surface fingerprint, is stable.)
    writeFile(extendedPath(modulePath), producerPrivateEditA)
    let privArtifactPath = outDir / "ti1-fp-priv.rbsz"
    let privStubPath = outDir / "ti1-fp-priv.nim"
    let privPlan = interfaceLiftPlan(modulePath, privArtifactPath, privStubPath,
      workDir = getCurrentDir())
    # NON-VACUITY of the re-run: the lift action key DID move on the private
    # edit (the source content changed), so this is not a trivially cached
    # no-op — the lift genuinely re-ran and STILL produced the same fingerprint.
    let basePlan = interfaceLiftPlan(
      writeProject(tempRoot / "project-base", producerPublicA),
      outDir / "ti1-fp-base.rbsz", outDir / "ti1-fp-base.nim",
      workDir = getCurrentDir())
    check privPlan.interfaceLiftActionKey != basePlan.interfaceLiftActionKey
    let afterPriv = liftInterfaceArtifact(privPlan)
    check afterPriv.interfaceFingerprint == baseFingerprint

    # PUBLIC decl edit — the InterfaceFingerprint DOES change.
    writeFile(extendedPath(modulePath), producerPublicEditA)
    let pubArtifactPath = outDir / "ti1-fp-pub.rbsz"
    let pubStubPath = outDir / "ti1-fp-pub.nim"
    let afterPub = liftInterfaceArtifact(interfaceLiftPlan(modulePath,
      pubArtifactPath, pubStubPath, workDir = getCurrentDir()))
    check afterPub.interfaceFingerprint != baseFingerprint

  test "t_ti1_producer_resource_module_lifts_public_resources":
    ## A producer declaring a SEPARATE resource module lifts publicResources
    ## with the REAL resource types (typeId / determinism / typed attrs /
    ## entry-point ids) from that module.
    let tempRoot = getTempDir() / "ti1-resmod-" & $getCurrentProcessId()
    removeDir(extendedPath(tempRoot))
    let projectRoot = tempRoot / "project"
    let outDir = tempRoot / "out"
    createDir(extendedPath(outDir))
    defer: removeDir(extendedPath(tempRoot))

    # The project file and the resource module in a producer-side layout.
    let modulePath = writeProject(projectRoot, resourceProducerRepro)
    let resourceDir = projectRoot / "repro"
    createDir(extendedPath(resourceDir))
    let resourceModule = resourceDir / "resources.nim"
    writeFile(extendedPath(resourceModule), resourceModuleSource)

    let artifactPath = outDir / "ti1-resmod-interface.rbsz"
    let stubPath = outDir / "ti1-resmod-interface.nim"

    # WITHOUT the resource module, the lift yields NO resources (control).
    let controlPlan = interfaceLiftPlan(modulePath,
      outDir / "ti1-resmod-control.rbsz", outDir / "ti1-resmod-control.nim",
      workDir = getCurrentDir())
    let control = liftInterfaceArtifact(controlPlan)
    check control.projectInterface.publicResources.len == 0

    # WITH the producer-declared resource module, publicResources carries the
    # REAL type. The declaration = (resourceModule, extraPaths) — the extra
    # ``--path`` is the producer's own src so the resource module resolves its
    # sibling imports.
    let plan = interfaceLiftPlan(modulePath, artifactPath, stubPath,
      resourceModule = resourceModule, extraPaths = @[projectRoot],
      workDir = getCurrentDir())
    let artifact = liftInterfaceArtifact(plan)
    let resources = artifact.projectInterface.publicResources
    check resources.len == 1
    let res = resources[0]
    check res.typeId == "vm_harness.container"
    check res.determinism == irdVolatile
    # The typed attribute schema — the wrapper formals a consumer binds.
    check res.attributes.len == 2
    check res.attributes[0].name == "image"
    check res.attributes[0].nimType == "string"
    check res.attributes[1].name == "cpus"
    check res.attributes[1].nimType == "int"
    # The entry-point descriptors (ids) crossed — the driver value did NOT.
    check res.entrypoints.observe == "vm_harness.container.observe"
    check res.entrypoints.plan == "vm_harness.container.plan"
    check res.entrypoints.apply == "vm_harness.container.apply"

    # The resource module is part of the lift's input identity: declaring it
    # produces a DIFFERENT action key than the resource-free control lift.
    check plan.interfaceLiftActionKey != controlPlan.interfaceLiftActionKey

  test "t_ti1_extra_path_dependency_content_rekeys_lift":
    ## TI2 residual fix (b): the ``InterfaceLiftActionKey`` must capture the
    ## CONTENT of files reachable ONLY via ``extraPaths`` (a real cross-directory
    ## resource-module dependency), not just their basenames — so a content
    ## change to such a file re-keys the lift and no stale artifact is served.
    let tempRoot = getTempDir() / "ti1-extrapath-" & $getCurrentProcessId()
    removeDir(extendedPath(tempRoot))
    let projectRoot = tempRoot / "project"
    let outDir = tempRoot / "out"
    createDir(extendedPath(outDir))
    defer: removeDir(extendedPath(tempRoot))

    # The producer project + its resource module (in a producer-side layout).
    let modulePath = writeProject(projectRoot, resourceProducerRepro)
    let resourceDir = projectRoot / "repro"
    createDir(extendedPath(resourceDir))
    let resourceModule = resourceDir / "resources.nim"

    # A helper module living in a SEPARATE directory, reachable ONLY via an
    # extra ``--path`` (not the producer's own project root, not the resource
    # module's dir). The resource module imports it by its bare module name, so
    # it resolves solely through the extra ``--path`` root.
    let extraDir = tempRoot / "extra-dep"
    createDir(extendedPath(extraDir))
    let helperModule = extraDir / "ti1_extra_helper.nim"
    writeFile(extendedPath(helperModule), "const helperTag* = 1\n")

    # The resource module imports the cross-directory helper (reachable only via
    # the extra ``--path``) so its content participates in the lift.
    writeFile(extendedPath(resourceModule),
      "import ti1_extra_helper\n" &
      "static: doAssert helperTag >= 0\n" &
      resourceModuleSource)

    let plan = interfaceLiftPlan(modulePath,
      outDir / "ti1-extrapath.rbsz", outDir / "ti1-extrapath.nim",
      resourceModule = resourceModule,
      extraPaths = @[projectRoot, extraDir], workDir = getCurrentDir())
    # The cross-directory helper entered the source closure (discovered via the
    # extra ``--path``), so its CONTENT is in the action key.
    check plan.inputSources.anyIt(it.endsWith("ti1_extra_helper.nim"))

    # Change ONLY the extra-path helper's content: the action key MUST move.
    writeFile(extendedPath(helperModule), "const helperTag* = 2\n")
    let planAfter = interfaceLiftPlan(modulePath,
      outDir / "ti1-extrapath.rbsz", outDir / "ti1-extrapath.nim",
      resourceModule = resourceModule,
      extraPaths = @[projectRoot, extraDir], workDir = getCurrentDir())
    check planAfter.interfaceLiftActionKey != plan.interfaceLiftActionKey
