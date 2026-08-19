import std/[os, tempfiles, unittest]

import repro_build_engine
import repro_hash
import repro_local_store

proc weak(name: string): ContentDigest =
  weakFingerprintFromText("dependency-rerun." & name)

suite "dependency rerun cache lookup":
  test "byte-identical producer rerun keeps checksum consumer cached":
    let tempRoot = createTempDir("repro-dependency-rerun-cache", "")
    defer: removeDir(tempRoot)

    let workRoot = tempRoot / "work"
    let cacheRoot = tempRoot / "cache"
    let sourcePath = workRoot / "src" / "input.txt"
    let generatedPath = workRoot / "generated" / "stable.txt"
    let consumerPath = workRoot / "out" / "consumer.txt"
    createDir(sourcePath.parentDir)
    writeFile(sourcePath, "stable input\n")

    let producer = builtinAction(bakCopyFile, "always-produce",
      cwd = workRoot,
      inputs = ["src/input.txt"],
      outputs = ["generated/stable.txt"],
      cacheable = false)
    let consumer = builtinAction(bakCopyFile, "checksum-consumer",
      cwd = workRoot,
      deps = [producer.id],
      inputs = ["generated/stable.txt"],
      outputs = ["out/consumer.txt"],
      cacheable = true,
      weakFingerprint = weak("checksum-consumer"),
      actionCachePolicy = ffpChecksum)
    var config = defaultBuildEngineConfig(cacheRoot)
    config.rebuildMissingOutputsOnCacheHit = true
    config.bypassRunQuota = true

    let first = runBuild(graph([producer, consumer]), config)
    check first.results[0].status == asSucceeded
    check first.results[1].status == asSucceeded

    let second = runBuild(graph([producer, consumer]), config)
    check second.results[0].status == asSucceeded
    check second.results[0].launched
    check second.results[1].status in {asCacheHit, asUpToDate}
    check second.results[1].cacheDecision == cdHit
    check not second.results[1].launched
    check readFile(consumerPath) == "stable input\n"
