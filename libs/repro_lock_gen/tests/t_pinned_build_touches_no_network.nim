## A pinned build reaches the network zero times.
##
## Named-Lock-Files NLF-M5. Corpus case **NLF-GEN-7**: "With a committed lock
## and the network unavailable, `repro build` succeeds and attempts no
## metadata fetch."
##
## `Repository-And-Index-Format.md` §"Refresh Is Performed By Graph Edges"
## (amended 2026-08-21) states the requirement:
##
## > **A pinned build refreshes nothing.** A lock file pins the *result* of
## > these fetches. Once pinned, a build consumes the lock and evaluates no
## > metadata-fetch edge, so a `repro build` against a committed lock must
## > succeed with the network unavailable. Refresh exists on the generation
## > path only.
##
## and `Sandbox-And-Monitoring.md` §"The Network Dimension" rule 3 says the
## same thing from the policy side: "A non-hermetic edge is never a silent
## input to a build that believes itself pinned."
##
## ## Why "the build succeeded" is not the assertion
##
## A build can succeed for reasons that have nothing to do with the property.
## It can fetch, ignore the result and use the lock anyway; it can fetch, fail,
## swallow the failure and fall back to the lock; it can succeed because the
## fixture was too small to need anything. All three satisfy "succeeds with the
## network unavailable" and all three are the defect. So the assertions here
## are positive and counted:
##
##   1. **No attempt was made.** `metadataFetchAttempts()` counts ATTEMPTS —
##      it is incremented before the socket is opened — so a fetch that tried
##      and failed is distinguished from one that never tried. Zero is the
##      claim.
##   2. **The far side agrees.** The loopback listener counts requests it
##      answered. Two independent counters on opposite sides of a real socket;
##      a fetch that bypassed `fetchMetadataObject` would still move the
##      server's.
##   3. **The unpinned path DOES fetch, over the same fixture.** Without this
##      control, zero attempts is satisfied by a fixture that never needed
##      metadata at all.
##   4. **The network really is unavailable.** The test proves it by trying:
##      after the listener is stopped, a direct fetch against the same URL must
##      raise. Otherwise a machine on which the port silently accepted would
##      pass (1) for the wrong reason.
##   5. **The pinned answer is the pinned answer.** The solved graph the build
##      gets back is the one in the lock, so "no fetch" was not bought by
##      returning nothing.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## Real loopback TCP, real HTTP/1.1, real in-process `http_pool` client, real
## `runBuild`, real clingo, real `repro_lock` writer/reader. See
## `loopback_metadata_server`'s header for the full statement, including why a
## mocked HTTP client would have made this case vacuous.

import std/[os, strutils, tables, tempfiles, unittest]

import repro_build_engine
import repro_lock
import repro_lock_gen
import repro_solver

import ./loopback_metadata_server

const
  App = "app"
  LibFoo = "libfoo"
  Published = ["1.2.0", "1.4.0", "1.9.0"]

proc request(endpointUrl, workDir: string): LockGenerationRequest =
  LockGenerationRequest(
    variants: @[],
    packages: @[
      newPackage(App, @["1.0.0"], @[newDependency(LibFoo, ">=1.2 <2.0")]),
      newPackage(LibFoo, @["0.1.0"])],
    inputsText: "nlf-gen-7 fixture",
    platform: currentPlatformId(),
    strategy: lsDefault,
    endpoints: @[endpointUrl],
    workDir: workDir,
    entryPoint: lgeImplicitBuildSolve)

suite "NLF-GEN-7 a pinned build attempts no metadata fetch":

  test "generate with the network up, then build pinned with it down":
    let scratch = createTempDir("repro-nlf-gen7-", "")
    defer: removeDir(scratch)
    let committedLock = scratch / "repro.lock"

    # ---- phase A: the generation path, with the registry reachable --------
    let server = startMetadataServer(scratch / "registry")
    server.publish(App, ["1.0.0"])
    server.publish(LibFoo, Published)
    let endpointUrl = server.endpoint()
    let probeUrl = metadataObjectUrl(endpointUrl, LibFoo)

    resetMetadataFetchAttempts()
    let unpinned = resolveSolvedGraph(committedLock,
      request(endpointUrl, scratch / "gen"))

    # (3) the control: over THIS fixture, an unpinned build genuinely fetches.
    check unpinned.source == sgsGenerated
    check metadataFetchAttempts() > 0
    check server.requestsServed() > 0
    check unpinned.solution.packages[LibFoo] in Published

    writeFile(committedLock,
      readFile(unpinned.lockPath))
    let servedDuringGeneration = server.requestsServed()

    # ---- the network goes away -------------------------------------------
    server.stop()

    # (4) prove it. A direct fetch against the same URL must now fail; if it
    # did not, "no attempt" below would be unfalsifiable.
    resetMetadataFetchAttempts()
    var refused = false
    try:
      discard fetchMetadataObject(probeUrl)
    except MetadataFetchError:
      refused = true
    check refused
    check metadataFetchAttempts() == 1  # the probe itself, and only it

    # ---- phase B: the pinned build ---------------------------------------
    resetMetadataFetchAttempts()
    let pinned = resolveSolvedGraph(committedLock,
      request(endpointUrl, scratch / "pinned"))

    # (1) the claim.
    check metadataFetchAttempts() == 0
    # (2) the far side agrees: not one further request was answered.
    check server.requestsServed() == servedDuringGeneration
    # (5) and the answer is the pinned one, not an empty graph.
    check pinned.source == sgsPinnedLock
    check pinned.lockPath == committedLock
    check pinned.solution.packages == unpinned.solution.packages
    check pinned.solution.variants == unpinned.solution.variants
    check pinned.identity == unpinned.identity
    # The generation wave left no artifacts under the pinned run's workDir:
    # the fetch edges were never constructed, not merely never executed.
    check not dirExists(scratch / "pinned" / "metadata")

  test "the graph the pinned path avoided is genuinely a fetching graph":
    # The last check above says the wave was not constructed. This says what
    # would have been in it: `netFetch` edges naming a real destination. A
    # generation path that had quietly stopped emitting fetch edges would pass
    # every zero-attempt assertion in this file for the wrong reason.
    let scratch = createTempDir("repro-nlf-gen7-shape-", "")
    defer: removeDir(scratch)
    let server = startMetadataServer(scratch / "registry")
    defer: server.stop()
    server.publish(LibFoo, Published)

    let wave = generationWaveOne(request(server.endpoint(), scratch / "gen"))
    var fetchEdges = 0
    var solveEdges = 0
    for a in wave:
      case a.kind
      of bakMetadataFetch:
        inc fetchEdges
        check a.networkMode == netFetch
        check a.netDestinations.len == 1
        check a.netDestinations[0].startsWith("http://127.0.0.1:")
        check a.cacheable
      of bakSolveLock:
        inc solveEdges
        # Rule 3 again, from the other side: the solve consumes what the
        # fetches retrieved and reaches nothing itself.
        check a.networkMode == netDenied
        check a.netDestinations.len == 0
      else:
        check false
    check fetchEdges == 2
    check solveEdges == 1

suite "NLF-GEN-7 the non-hermetic edge exists on the generation path only":

  test "a request naming no registry emits no netFetch edge at all":
    # §5.6: "The non-hermetic edge exists only on the generation path." The
    # sharpest form of that is a generation which needs no registry: it must
    # produce a lock with the network dimension never engaged.
    let scratch = createTempDir("repro-nlf-gen7-hermetic-", "")
    defer: removeDir(scratch)
    var req = request("", scratch / "gen")
    req.endpoints = @[]
    req.packages[1] = newPackage(LibFoo, @["1.4.0"])

    resetMetadataFetchAttempts()
    let generated = runLockSolve(req, "")
    check metadataFetchAttempts() == 0
    check generated.fetchWaves.len == 0
    let sol = lockToSolution(parseSolvedGraphLock(generated.lockDocument))
    check sol.packages[LibFoo] == "1.4.0"

    for a in generationWaveOne(req):
      check a.networkMode == netDenied
