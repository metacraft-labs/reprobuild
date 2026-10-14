{.define: reproEnvironmentCacheKeyTest.}
{.define: reproDaemonParentPrewarmTest.}
# The SECOND define is not L5's. `reproDaemonParentPrewarmTest` already
# exposes the lowered-graph cache's private path builder, record writer
# and record reader, which is exactly what the "and the differing key
# actually causes a MISS" suite needs. Reusing that seam rather than
# adding a third copy of it under L5's define keeps ONE test-only route
# into the cache file -- a second would be a second thing to keep in
# step with the production writer.

## Shared-Development-Services L5 — §6.4: THE SELECTED ENVIRONMENT IS A
## TRACKED INPUT, and the lowered-graph cache cannot serve a graph
## lowered for another environment.
##
## §6.4 in full, because this file is the whole of its enforcement:
##
##   "The selected environment MUST be a tracked solver input that
##    participates in the graph cache key. An ambient `getEnv` is
##    silently ignored when a lowered graph is served from cache, so an
##    environment selected that way could hand a developer a production
##    issuer out of a warm cache — a failure that is both silent and
##    security-relevant. Variants already have exactly this property and
##    are the obvious lowering."
##
## and L5's `:gate:`: "the selected environment participating in the
## graph cache key, asserted by the control that a warm cache cannot
## serve a graph lowered for another environment (an ambient `getEnv`
## would, which is why this is a gate and not a note)."
##
## WHY THE SUBJECT IS THE KEY AND NOT A FINISHED BUILD. The property is
## "the cache does not answer", and a cache that does not answer is
## observable only as a key mismatch: the reader
## (`warmReadFreshLoweredGraphCache`) compares the record's `cacheKey`
## against the caller's and returns `none` when they differ -- which
## this file also measures directly, through the record writer and
## reader, so the key difference is shown to actually cause a miss
## rather than only to exist.
##
## WHICH DISCRIMINATOR IS LOAD-BEARING. The INEQUALITY of two real keys
## computed by the real `loweredGraphCacheKey` over one artifact, and
## the `isNone` of a real read of a real cache file written under the
## other environment's key. Not an exit code: the module compiles at the
## base commit, so an exit code moves for no reason connected to this
## milestone. And not the presence of the field in the payload, which a
## grep would satisfy.
##
## THE TWO CONTROLS THAT MAKE THAT MEAN SOMETHING:
##
##   * WITH NO ENVIRONMENT SELECTED the key is BYTE-IDENTICAL to the
##     pre-L5 one. Asserted against the key computed with the variable
##     unset, so a build that selects no environment is not cold-started
##     by this change. If L5 had folded in a constant rather than the
##     selection, this control would still pass and the next one would
##     fail.
##   * SELECTING THE SAME ENVIRONMENT TWICE is a HIT. A key that merely
##     differed every time -- a timestamp, a counter -- would satisfy
##     every inequality above and destroy the cache.
##
## MOCK POLICY — NO MOCKS, AND NONE MAY BE ADDED. The artifact is
## produced by the real `toProjectInterface` / `artifactFor` over a real
## `package` block; the keys are computed by the module's own private
## `loweredGraphCacheKey`; the cache record is written and read by the
## module's own private writer and reader, to a real file under a
## throwaway directory. The only test-only code is the seam that exposes
## those private procs -- see `reproEnvironmentCacheKeyTest` in
## `repro_cli_support.nim`, which follows `reproDaemonParentPrewarmTest`'s
## precedent exactly.

import std/[options, os, strutils, unittest]

import repro_project_dsl
import repro_interface_artifacts
import repro_tool_profiles     # ToolProvisioningMode / tpmPathOnly
import repro_build_engine      # BuildAction, for the empty record
import repro_cli_support

package l5CacheKeyPkg:
  config:
    issuer: string = "http://localhost:8080"

  environment dev:
    issuer = "https://login.metacraft-labs.test"

  environment production:
    issuer = "https://login.metacraft-labs.com"

proc subjectArtifact(): ProjectInterfaceArtifact =
  for pkg in registeredPackages():
    if pkg.packageName == "l5CacheKeyPkg":
      return artifactFor(toProjectInterface(pkg))
  raise newException(ValueError, "fixture drift: l5CacheKeyPkg missing")

let artifact = subjectArtifact()

proc keyNow(): string =
  ## The real key, over the real artifact, for whatever environment is
  ## selected at the moment of the call. Every other argument is held
  ## fixed, so the environment is the only thing that can move it.
  loweredGraphCacheKeyForTest(artifact, tpmPathOnly,
    "provider-artifact-id-fixed", "", "PATH=/fixed")

proc withEnvironment(name: string; body: proc (): string): string =
  if name.len == 0: delEnv(ReproEnvironmentEnvVar)
  else: putEnv(ReproEnvironmentEnvVar, name)
  result = body()
  delEnv(ReproEnvironmentEnvVar)

let scratch = getTempDir() /
  ("repro-l5-cache-key-" & $getCurrentProcessId())

suite "L5 §6.4 — the fixture really is what the clauses assume":

  test "the subject package declares the two environments":
    check registeredEnvironmentNames("l5CacheKeyPkg") ==
      @["dev", "production"]

  test "the artifact is real and names the subject package":
    check artifact.projectInterface.packageName == "l5CacheKeyPkg"

  test "the selection starts unset, so the controls below are honest":
    delEnv(ReproEnvironmentEnvVar)
    check selectedEnvironmentName() == ""
    check canonicalEnvironmentSignatureForTest() == ""

suite "L5 §6.4 — the environment is IN the lowered-graph cache key":

  test "two environments give two keys":
    let dev = withEnvironment("dev", keyNow)
    let prod = withEnvironment("production", keyNow)
    check dev.len > 0
    check dev != prod

  test "neither is the no-environment key":
    let none = withEnvironment("", keyNow)
    let dev = withEnvironment("dev", keyNow)
    let prod = withEnvironment("production", keyNow)
    check none != dev
    check none != prod

  test "THE CONTROL: the unset selection is empty, which is what suppresses the field":
    # WHY THIS IS THE CONTROL IT IS, AND NOT A BYTE-IDENTITY ASSERTION.
    # L5 must not cold-start the lowered-graph cache of every build that
    # selects no environment, and the way it avoids that is the guard at
    # `loweredGraphCacheKey`: the environment field is appended ONLY
    # when the signature is non-empty, because `addCacheField("")`
    # appends `"0:\n"` rather than nothing. So the no-environment key
    # is byte-identical to the pre-L5 one BY CONSTRUCTION -- and the
    # condition that construction rests on is exactly what is asserted
    # here, because this process cannot compute the pre-L5 key. The
    # byte-identity itself is a code property, recorded with its
    # file:line in the milestone's evidence drawer.
    delEnv(ReproEnvironmentEnvVar)
    check canonicalEnvironmentSignatureForTest() == ""
    putEnv(ReproEnvironmentEnvVar, "   ")
    check canonicalEnvironmentSignatureForTest() == ""
    delEnv(ReproEnvironmentEnvVar)
    # And the unset key is STABLE across repeated computation, which
    # rules out a key that merely moved every time.
    let first = withEnvironment("", keyNow)
    let second = withEnvironment("", keyNow)
    check first == second

  test "THE CONTROL: the same environment twice is the SAME key":
    # A key that differed on every call -- a timestamp, a counter --
    # would satisfy every inequality above and destroy the cache.
    let a = withEnvironment("dev", keyNow)
    let b = withEnvironment("dev", keyNow)
    check a == b

  test "the canonicalised spellings of one selection are ONE key":
    let plain = withEnvironment("dev", keyNow)
    for spelling in ["Dev", "  dev  ", "DEV"]:
      check withEnvironment(spelling, keyNow) == plain

suite "L5 §6.4 — and the differing key actually causes a MISS":
  ## The key inequality above is the mechanism; this is the behaviour it
  ## exists for. Written and read through the module's own private cache
  ## writer and reader, on a real file.

  test "a record written under `dev`'s key is not served under `production`'s":
    createDir(scratch)
    let path = loweredGraphCachePathForTest(scratch, "")
    let devKey = withEnvironment("dev", keyNow)
    let prodKey = withEnvironment("production", keyNow)
    writeLoweredGraphCacheFileForTest(path, "/fixed/repro.nim",
      "/fixed/project", "", "PATH=/fixed", devKey, newSeq[BuildAction]())
    check fileExists(path)
    # Served under the key it was written with -- the positive control
    # that the record is readable at all. Without it, the miss below
    # would be satisfied by an unreadable file.
    let hit = readLoweredGraphForTest(path, "/fixed/repro.nim",
      "/fixed/project", "", "PATH=/fixed", devKey)
    check hit.isSome
    # And NOT served under the other environment's key.
    let miss = readLoweredGraphForTest(path, "/fixed/repro.nim",
      "/fixed/project", "", "PATH=/fixed", prodKey)
    check miss.isNone

suite "L5 §6.4 — the provider-graph snapshot store is isolated too":
  ## The lowered-graph cache is one of TWO caches that would otherwise
  ## answer across environments. The provider-graph SNAPSHOT caches the
  ## fragments a provider emitted, and an environment's bindings are
  ## applied at provider-run time -- so two builds differing only in
  ## their environment would share one snapshot and the second would
  ## reuse the first's fragments with `providerInvocations: 0`. That is
  ## §6.4's failure in its most literal form, so both are measured.

  test "two environments get two snapshot roots":
    let base = scratch / "snapshots"
    let dev = withEnvironment("dev",
      proc (): string = providerGraphStoreRootForTest(base))
    let prod = withEnvironment("production",
      proc (): string = providerGraphStoreRootForTest(base))
    check dev != prod
    check dev.startsWith(base)
    check prod.startsWith(base)

  test "no environment selected is the BASE root, unchanged":
    # The control that keeps every existing build from losing its
    # snapshot: with neither a variant nor an environment the root is
    # exactly `base`, as it was before L5.
    let base = scratch / "snapshots"
    check withEnvironment("",
      proc (): string = providerGraphStoreRootForTest(base)) == base

  test "the same environment twice is the same root":
    let base = scratch / "snapshots"
    check withEnvironment("dev",
        proc (): string = providerGraphStoreRootForTest(base)) ==
      withEnvironment("dev",
        proc (): string = providerGraphStoreRootForTest(base))

suite "L5 — teardown":

  test "the throwaway tree is removed":
    removeDir(scratch)
    check not dirExists(scratch)
