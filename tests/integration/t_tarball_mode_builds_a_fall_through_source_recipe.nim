## `repro build --tool-provisioning=tarball` builds the from-source recipe of
## a package that has no tarball for the host, then uses it.
##
## reprobuild-specs Dependency-Provisioning-In-Build-Graph.md 4.3: an unbuilt
## fall-through recipe "is built by `repro build` before the consuming graph
## is resolved, by the same recursive sub-build from-source mode uses", in the
## invocation's mode. Before that rule a tarball-mode build stopped at tool
## resolution with "no tarball provisioning entry ... matches host".
##
## Black-box: a real `repro` binary (this checkout's `build/bin/repro`) builds
## a real consumer recipe against a synthetic source catalog selected with
## `REPRO_FROM_SOURCE_ROOT`. The consumer's `uses: "fsfallthrough"` names a
## package nothing provisions, so tarball mode has no tarball for any host and
## must fall through to the catalog recipe. Nothing is mocked.

import std/[os, osproc, strutils, tempfiles, unittest]

const reproBinary = "." / "build" / "bin" / addFileExt("repro", ExeExt)
const FromSourceRootEnv = "REPRO_FROM_SOURCE_ROOT"

const producerRepro = """
import repro_project_dsl

package fsfallthroughSource:
  build:
    let materialize = buildAction(
      id = "fsfallthrough-source.materialize",
      call = inlineExecCall(@[
        "sh", "-c",
        "mkdir -p .repro/output/fsfallthrough && " &
          "printf '#!/bin/sh\\necho fall-through\\n' > " &
          ".repro/output/fsfallthrough/fsfallthrough && " &
          "chmod +x .repro/output/fsfallthrough/fsfallthrough"
      ]),
      outputs = @[".repro/output/fsfallthrough/fsfallthrough"],
      cacheable = false)
    defaultTarget(target("fsfallthrough", [materialize]))
"""

const consumerRepro = """
import repro_project_dsl

package fallThroughConsumer:
  defaultToolProvisioning "tarball"

  uses:
    "fsfallthrough"

  build:
    let consumerAction = buildAction(
      id = "consumer.run",
      call = inlineExecCall(@[
        "sh", "-c", "mkdir -p build && printf ran > build/consumer-ran.txt"
      ]),
      outputs = @["build/consumer-ran.txt"],
      cacheable = false,
      toolIdentityRefs = @["fsfallthrough"])
    defaultTarget(target("consumer", [consumerAction]))
"""

suite "tarball mode builds a fall-through source recipe":
  test "an unbuilt recipe is built in tarball mode, then the consumer runs":
    # The producer's action runs `sh`, which every lane provides (Git
    # Bash on Windows); its absence is a broken host, not a reason to skip.
    check findExe("sh").len > 0
    if not fileExists(reproBinary):
      checkpoint("missing " & reproBinary & "; build reprobuild first")
      fail()
    else:
      let scratch = createTempDir("repro-tarball-fall-through-", "")
      defer: removeDir(scratch)
      let catalogRoot = scratch / "catalog"
      let producerRoot = catalogRoot / "fsfallthrough"
      let consumerRoot = scratch / "consumer"
      let cacheRoot = scratch / "action-cache"
      for dir in [producerRoot, consumerRoot, cacheRoot]:
        createDir(dir)
      writeFile(producerRoot / "repro.nim", producerRepro)
      writeFile(consumerRoot / "repro.nim", consumerRepro)

      let savedSourceRoot = getEnv(FromSourceRootEnv)
      let savedNoRunquota = getEnv("REPROBUILD_NO_RUNQUOTA")
      putEnv(FromSourceRootEnv, catalogRoot)
      putEnv("REPROBUILD_NO_RUNQUOTA", "1")
      defer:
        if savedSourceRoot.len > 0: putEnv(FromSourceRootEnv, savedSourceRoot)
        else: delEnv(FromSourceRootEnv)
        if savedNoRunquota.len > 0:
          putEnv("REPROBUILD_NO_RUNQUOTA", savedNoRunquota)
        else: delEnv("REPROBUILD_NO_RUNQUOTA")

      let producerArtifact =
        producerRoot / ".repro" / "output" / "fsfallthrough" / "fsfallthrough"
      let consumerMarker = consumerRoot / "build" / "consumer-ran.txt"
      check not fileExists(producerArtifact)

      let command = quoteShell(absolutePath(reproBinary)) & " build" &
        " --daemon=off --tool-provisioning=tarball --progress=quiet" &
        " --measure=none --action-cache-root=" & quoteShell(cacheRoot)
      let res = execCmdEx(command, workingDir = consumerRoot)
      checkpoint(res.output)
      check res.exitCode == 0
      check fileExists(producerArtifact)
      check fileExists(consumerMarker)
      check "has no tarball realization for this host" in res.output
