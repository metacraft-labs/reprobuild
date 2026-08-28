## Shared scaffolding for the NLF-M6 materiality and strategy tests.
##
## Not named `t_*` / `test_*`, so `scripts/generate_test_edges.nim` does not
## register it as a test binary of its own.
##
## ## Test-double policy — read this before reaching for a mock
##
## There are NO mocks, stubs, fakes or doubles anywhere below, and none in any
## test that imports this file. Concretely:
##
##   * the registry is a real TCP listener on `127.0.0.1` speaking real
##     HTTP/1.1 (`loopback_metadata_server`, whose own header states the policy
##     in full), served to by the real in-process `http_pool` client;
##   * the edges are real `BuildAction`s executed by the real `runBuild`;
##   * the answers come from a real clingo solve through the real
##     `{.dynlib.}` FFI;
##   * the locks are written by the real `repro_lock` writer and read back by
##     the real `parseLockedDependencies`;
##   * the path-set store is a real directory tree on a real filesystem.
##
## What IS synthetic is the CONTENT — the version lists and the four other
## metadata objects are written into a directory by the test rather than
## published by a real registry. That is fixture data, not a double, and it
## bounds what these tests may conclude: they conclude things about whether the
## network was reached, whether the solve ran and what invalidated, because all
## three are real; they conclude nothing about any particular upstream
## registry's behaviour, and none of them try to.
##
## ## Why each generation gets a FRESH workDir but a SHARED path-set root
##
## This is the load-bearing detail of the whole file, so it is stated rather
## than left to be inferred from the code.
##
## A `bakMetadataFetch` edge declares no file inputs. The engine's ordinary
## action cache therefore serves it from a previous record whenever the weak
## fingerprint matches — which is correct (that is what `repro lock refresh`
## exists to override) and fatal to a materiality test, because the metadata
## object on disk would be RESTORED to its old contents and the registry
## mutation the test just performed would be invisible to the solve.
##
## So `generate` gives every invocation a fresh `workDir`, and therefore a
## fresh engine cache, so the fetch genuinely re-runs against the live server.
## The §5.7 path-set store is what persists, via `cacheRoot`. That separation is
## also the honest one: the wave's artifacts are scratch that the CLI deletes,
## while the path-set store is exactly the thing that must survive between
## invocations.

import std/[algorithm, os, tables, times]

import repro_lock
import repro_lock_gen
import repro_solver

import ./loopback_metadata_server

export loopback_metadata_server
# `repro_lock` is re-exported so a test that compares two `LockIdentity`
# values gets the `==` that library defines for it. Without this the
# comparison resolves to no overload and fails to compile inside `unittest`'s
# `check`, which is a confusing way to learn that an import is missing.
export repro_lock

type
  Registry* = ref object
    ## A running loopback registry plus the scratch tree around it.
    scratch*: string
    server*: MetadataServer
    generations*: int

proc startRegistry*(tag: string): Registry =
  let scratch = getTempDir() / ("repro-nlf-m6-" & tag & "-" &
    $getCurrentProcessId() & "-" & $epochTime().int64)
  createDir(scratch)
  Registry(scratch: scratch, server: startMetadataServer(scratch / "registry"),
    generations: 0)

proc shutdown*(reg: Registry) =
  if reg.isNil: return
  reg.server.stop()
  reg.server.destroyMetadataServer()
  try: removeDir(reg.scratch)
  except CatchableError: discard

proc pathSetRoot*(reg: Registry): string =
  reg.scratch / "path-sets"

proc request*(reg: Registry; packages: seq[PackageDecl];
              strategy: LockStrategy;
              variants: seq[VariantDecl] = @[];
              kinds: set[MetadataObjectKind] = {};
              inputsText = "nlf-m6 fixture"): LockGenerationRequest =
  ## A generation request against this registry, with a FRESH work directory
  ## and the SHARED path-set root. See the header for why those differ.
  inc reg.generations
  LockGenerationRequest(
    variants: variants,
    packages: packages,
    inputsText: inputsText,
    platform: currentPlatformId(),
    strategy: strategy,
    endpoints: @[reg.server.endpoint()],
    workDir: reg.scratch / ("gen-" & $reg.generations),
    entryPoint: lgeLockSolve,
    objectKinds: kinds,
    cacheRoot: reg.pathSetRoot())

proc generate*(reg: Registry; packages: seq[PackageDecl];
               strategy: LockStrategy;
               variants: seq[VariantDecl] = @[];
               kinds: set[MetadataObjectKind] = {}):
                 LockGenerationResult =
  runLockSolve(reg.request(packages, strategy, variants, kinds), "")

proc resolved*(r: LockGenerationResult): Table[string, string] =
  ## The solved version per package, read back OUT OF THE LOCK DOCUMENT rather
  ## than off an in-memory solution. A test that asserted on the in-memory
  ## answer would pass against a generation whose lock document said something
  ## else, which is the writer/reader drift PR #87 removed.
  lockToSolution(parseSolvedGraphLock(r.lockDocument)).packages

proc observedPackages*(r: LockGenerationResult): seq[string] =
  ## The package names the recorded path set carries an observation for,
  ## sorted.
  result = @[]
  for obs in r.pathSet.observations:
    if obs.kind == mokVersionList:
      result.add(obs.subject)
  result.sort()

proc observationFor*(r: LockGenerationResult;
                     packageName: string): SolveObservation =
  for obs in r.pathSet.observations:
    if obs.kind == mokVersionList and obs.subject == packageName:
      return obs
  SolveObservation()

proc intervalOf*(r: LockGenerationResult; packageName: string): string =
  ## `"[low, high]"` / `"[low, high)"` for a recorded interval, `"raw"` for the
  ## fallback, `"absent"` when nothing was recorded for the package.
  let obs = r.observationFor(packageName)
  if obs.memberDigest.len == 0: return "absent"
  if obs.filter == mfRaw: return "raw"
  "[" & (if obs.low.len > 0: obs.low else: "-inf") & ", " &
    (if obs.high.len > 0: obs.high else: "+inf") &
    (if obs.highInclusive: "]" else: ")")

proc kindsObserved*(r: LockGenerationResult): seq[string] =
  result = @[]
  for obs in r.pathSet.observations:
    let k = $obs.kind
    if k notin result: result.add(k)
  result.sort()
