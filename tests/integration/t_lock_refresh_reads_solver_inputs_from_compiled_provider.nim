## Workspace-Manifest-Optional MO-12 — ``repro lock refresh`` sources its
## solver inputs from the COMPILED PROJECT PROVIDER (the same ``solve()`` the
## DSL runs via ``finalizeVariants()``), NOT the ``repro.solver`` sidecar.
##
## The fixture deliberately makes the provider's solve DIFFER from the sidecar:
##
##   * ``repro.nim`` declares ``uses: "nim >=2.4.0 <3.0.0"`` — so the compiled
##     provider's solve concretizes ``nim`` to ``2.4.0``.
##   * A STALE ``repro.solver`` sidecar pins ``nim`` to ``2.2.0``.
##
## Asserts:
##   1. Default ``repro lock refresh`` (provider-sourced) writes a lock pinning
##      ``nim 2.4.0`` — the PROVIDER's solve — and NOT ``2.2.0`` (the sidecar).
##   2. The same refresh with an explicit ``--inputs <sidecar>`` override pins
##      ``2.2.0`` — proving the sidecar path is still reachable and that the
##      default path genuinely differs from it (the provider really drove (1)).
##
## Falsifiability: if refresh reverted to sidecar-sourcing by default, (1) would
## pin ``2.2.0`` (the sidecar) and the ``"2.4.0"`` / not-``"2.2.0"`` asserts
## FAIL; the two refresh results would be identical, collapsing the contrast in
## (2). Conversely if the provider path emitted nothing, refresh would fall back
## to the sidecar and (1) would again pin ``2.2.0``.
##
## Hermetic: a fresh tempdir project. Skip rule: repro unbuilt.

import std/[os, osproc, strutils, unittest]

const ReprobuildRepoRoot = currentSourcePath().parentDir().parentDir().parentDir()
  ## The reprobuild checkout root, resolved from THIS SOURCE FILE's path
  ## rather than from the process working directory.
  ##
  ## The previous spelling (``"./build/bin/" & addFileExt("repro", ExeExt)``)
  ## made the working directory an unstated fixture input: from the repo root
  ## the case ran, from any other directory ``fileExists`` was false and it
  ## SKIPPED, and from a scratch directory that happened to carry a staged
  ## ``build/bin/repro`` it ran against THAT binary and reported failures that
  ## read as product refusals. ``currentSourcePath()`` is absolute on both
  ## platforms, so this constant is the same from every cwd.
const reproBinary = ReprobuildRepoRoot / "build/bin/repro".addFileExt(ExeExt)

# The recipe's ``uses:`` drives the provider's solve to ``nim 2.4.0``.
const providerRecipe = """
import repro_project_dsl

package app:
  uses:
    "nim >=2.4.0 <3.0.0"
  build:
    discard aggregate("app-aggregate", actions = @[])
"""

const fromSourceConsumerRecipe = """
import repro_project_dsl

package app:
  defaultToolProvisioning "from-source"
  uses:
    "producer"
    "leaf"
  build:
    discard aggregate("app-aggregate", actions = @[])
"""

const fromSourceProducerRecipe = """
import repro_project_dsl

package producerSource:
  buildDeps:
    "leaf >=10.34"
  library producer:
    discard
  build:
    discard aggregate("producer-aggregate", actions = @[])
"""

# A STALE sidecar that pins a DIFFERENT version (``nim 2.2.0``).
const staleSidecar = """
package app
versions: 0.1.0
depends: nim >=2.2.0 <3.0.0

package nim
versions: 2.2.0
"""

proc q(value: string): string = quoteShell(value)

proc run(command: string): tuple[code: int; output: string] =
  let res = execCmdEx(command)
  (code: res.exitCode, output: res.output)

suite "MO-12: lock refresh sources solver inputs from the compiled provider":

  test "t_lock_refresh_reads_solver_inputs_from_compiled_provider":
    if not fileExists(reproBinary):
      skip()
    else:
      let projectDir = getTempDir() / "mo12-provider-" & $getCurrentProcessId()
      removeDir(projectDir)
      createDir(projectDir)
      defer: removeDir(projectDir)

      writeFile(projectDir / "repro.nim", providerRecipe)
      writeFile(projectDir / "repro.solver", staleSidecar)

      # (1) Default refresh sources from the COMPILED PROVIDER → nim 2.4.0.
      let refresh = run(reproBinary & " lock refresh " & q(projectDir))
      checkpoint("refresh exit=" & $refresh.code)
      checkpoint(refresh.output)
      check refresh.code == 0
      check fileExists(projectDir / "repro.lock")
      let lockBody = readFile(projectDir / "repro.lock")
      check "version = \"2.4.0\"" in lockBody     # the PROVIDER's solved version
      check "version = \"2.2.0\"" notin lockBody  # NOT the stale sidecar's

      # (2) The same refresh forced onto the sidecar (--inputs) pins 2.2.0 —
      # proving the sidecar path is reachable and the default path differs (the
      # provider genuinely drove (1), not the sidecar that sits right there).
      let sidecarLock = projectDir / "repro.sidecar.lock"
      let viaSidecar = run(reproBinary & " lock refresh " & q(projectDir) &
        " --inputs " & q(projectDir / "repro.solver") &
        " --lock " & q(sidecarLock))
      check viaSidecar.code == 0
      let sidecarBody = readFile(sidecarLock)
      check "version = \"2.2.0\"" in sidecarBody  # the sidecar's stale version
      check "version = \"2.4.0\"" notin sidecarBody

      # The two locks genuinely differ: the default lock is provider-sourced.
      check lockBody != sidecarBody

  test "lock refresh folds constraints from selected from-source producers":
    if not fileExists(reproBinary):
      skip()
    else:
      let scratch = getTempDir() / "mo12-source-closure-" &
        $getCurrentProcessId()
      let projectDir = scratch / "consumer"
      let sourceRoot = scratch / "source-catalog"
      let producerDir = sourceRoot / "producer"
      removeDir(scratch)
      createDir(projectDir)
      createDir(producerDir)
      defer: removeDir(scratch)

      writeFile(projectDir / "repro.nim", fromSourceConsumerRecipe)
      writeFile(producerDir / "repro.nim", fromSourceProducerRecipe)

      let previousSourceRoot = getEnv("REPRO_FROM_SOURCE_ROOT")
      putEnv("REPRO_FROM_SOURCE_ROOT", sourceRoot)
      defer:
        if previousSourceRoot.len > 0:
          putEnv("REPRO_FROM_SOURCE_ROOT", previousSourceRoot)
        else:
          delEnv("REPRO_FROM_SOURCE_ROOT")

      let refresh = run(reproBinary & " lock refresh " & q(projectDir))
      checkpoint("from-source closure refresh exit=" & $refresh.code)
      checkpoint(refresh.output)
      check refresh.code == 0
      let lockBody = readFile(projectDir / "repro.lock")

      # The root declares `leaf` without a range (synthetic 1.0.0), while the
      # selected producer requires >=10.34. Reverting the source-closure fold
      # makes this assertion fail with the stale 1.0.0 pin ReproOS observed.
      check "name = \"leaf\", version = \"10.34.0\"" in lockBody
      check "name = \"leaf\", version = \"1.0.0\"" notin lockBody
      # Lock refresh is metadata-only; it must not execute the producer graph.
      check not dirExists(producerDir / ".repro" / "output")
