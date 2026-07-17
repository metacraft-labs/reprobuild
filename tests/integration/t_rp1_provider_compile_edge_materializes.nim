## RP1 (Project-Provider-Runtime-Protocol.milestones.org) — the provider
## compile is a first-class, content-addressed build edge.
##
## This is the REAL-materialization gate: it drives the actual Nim provider
## compile for a representative small project and proves
##
##   1. the edge materializes a provider binary + provider-compile artifact;
##   2. a second realization with UNCHANGED source is a cache HIT — the
##      provider is NOT recompiled (proven via the freshness short-circuit
##      returning the byte-identical cached artifact and the same
##      ProviderCompileActionKey), while a KEYED-input change (a source-body
##      edit) moves the ProviderArtifactId / ActionKey — NON-VACUOUS;
##   3. the plan's engine edge is keyed by the v1 ProviderCompileActionKey.
##
## Modelled on ``tests/integration/t_dev_env_artifact.nim`` — the real
## provider compile needs ``workDir = getCurrentDir()`` (the reprobuild
## repo root) so the DSL ``import repro`` and lib-path flags resolve.

import std/[options, os, unittest]

import repro_interface_artifacts
import repro_core

const providerBody = """
import repro_project_dsl

package rp1widget:
  build:
    discard
"""

proc writeProject(root: string): string =
  createDir(extendedPath(root))
  let modulePath = root / "reprobuild.nim"
  writeFile(extendedPath(modulePath), providerBody)
  modulePath

suite "RP1 provider-compile edge materializes + caches":

  test "materializes a provider binary and a second build is a cache HIT":
    let tempRoot = getTempDir() / "rp1-compile-" & $getCurrentProcessId()
    removeDir(extendedPath(tempRoot))
    let projectRoot = tempRoot / "project"
    let outDir = tempRoot / "out"
    createDir(extendedPath(outDir))
    defer: removeDir(extendedPath(tempRoot))

    let modulePath = writeProject(projectRoot)
    let interfacePath = outDir / "rp1-interface.rbsz"
    let stubPath = outDir / "rp1-interface.nim"
    let artifact = extractInterfaceFromModule(modulePath, interfacePath,
      stubPath, getCurrentDir())

    let binPath = outDir / "rp1-provider"
    let compilePath = outDir / "rp1-provider-compile.rbsz"

    # First realization: cold compile — materializes the binary + artifact.
    let plan = providerCompilePlan(modulePath, binPath,
      artifact.interfaceFingerprint, getCurrentDir())
    # The engine edge is keyed by the v1 ProviderCompileActionKey.
    check plan.providerCompileActionKey == plan.compileEdge.actionFingerprint
    check plan.providerArtifactId.bytes.len == 32

    let first = compileProviderBinary(modulePath, binPath,
      artifact.interfaceFingerprint, compilePath, getCurrentDir())
    check fileExists(extendedPath(first.outputBinaryPath))
    check fileExists(extendedPath(compilePath))
    let firstBinaryFp = first.outputBinaryFingerprint

    # Second realization with UNCHANGED source: cache HIT. The freshness
    # layer returns the byte-identical cached artifact without recompiling
    # (same output-binary fingerprint), and the recomputed ActionKey is
    # stable, so the engine action-cache would report the same key.
    let second = compileProviderBinary(modulePath, binPath,
      artifact.interfaceFingerprint, compilePath, getCurrentDir())
    check second.outputBinaryFingerprint == firstBinaryFp
    check providerCompileArtifactFresh(compilePath, binPath,
      artifact.interfaceFingerprint, plan.providerFingerprint, getCurrentDir())
    let planAgain = providerCompilePlan(modulePath, binPath,
      artifact.interfaceFingerprint, getCurrentDir())
    check planAgain.providerCompileActionKey == plan.providerCompileActionKey
    check planAgain.providerArtifactId == plan.providerArtifactId

    # NON-VACUITY: a material source-body edit moves the ProviderArtifactId
    # and the ActionKey (⇒ the edge would be re-executed).
    writeFile(extendedPath(modulePath), providerBody & "\n# edit\n")
    let planEdited = providerCompilePlan(modulePath, binPath,
      artifact.interfaceFingerprint, getCurrentDir())
    check planEdited.providerArtifactId != plan.providerArtifactId
    check planEdited.providerCompileActionKey != plan.providerCompileActionKey
    check not providerCompileArtifactFresh(compilePath, binPath,
      artifact.interfaceFingerprint, planEdited.providerFingerprint,
      getCurrentDir())
