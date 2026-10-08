## Shared-Development-Services L1 — a service's rendered configuration is
## a CACHED BUILD OUTPUT: a second reconcile with nothing changed reports a
## cache hit and does not re-render.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## The recipe is a real ``package`` block whose ``service`` declares a real
## rendering helper; the graph is lowered by the real
## ``lowerProviderSnapshot`` the ``repro build`` CLI uses; the builds are
## the real ``runBuild`` scheduler against the real per-edge
## ``ActionCache`` + CAS in ``repro_local_store``, writing real files into a
## real temporary directory. A fake store or a stubbed executor would make
## this vacuous: the property under test is exactly what the engine decides
## about an edge the DSL emitted, so both halves must be the production
## ones.
##
## Governing spec text:
##
## * ``Shared-Development-Services.md`` §2 — "Because ``service`` takes no
##   ``config:`` block and consumes a rendered ``BuildOutput`` instead, a
##   service's expensive setup becomes an ordinary cached edge. This
##   matters immediately: today the identity provider's configuration and
##   steps files are written by a shell script at run time, so its
##   first-boot schema migration and instance bootstrap — tens of seconds —
##   are an uncacheable runtime side effect redone on every reset.
##   Declared as build outputs they are keyed like anything else."
## * ``Package-Model.md`` §Collections — "rendering helpers
##   (``literalConfigFile``, ``configFile``, etc.) produce a
##   ``BuildOutput``, and the service consumes that output".
## * ``Incremental-Invalidation.md`` §"Validation Criteria" — "a warm
##   re-run of an unchanged graph still executes zero actions" and
##   "changing a read input invalidates the action".
##
## FIVE CASES, AND WHY EACH IS NEEDED. ``launched`` is the engine's own
## record of whether it ran the action body, and for a ``writeText`` edge
## it is the only observable: the builtin skips a write whose bytes already
## match, so the filesystem looks identical whether or not the body
## executed. The controls are therefore what make case 2 mean something.
##
##   1. cold          — the edge runs and the file holds the rendered bytes.
##   2. unchanged     — cache HIT, NOT launched.  (the gate's claim)
##   3. cold cache    — same graph, same file still on disk, a FRESH cache
##                      root: the edge runs again. So case 2 is the action
##                      cache's doing and not an unconditional
##                      "the output exists, skip it".
##   4. output gone   — the edge runs again. So a hit never leaves the
##                      service without its configuration.
##   5. content moved — one configurable's value changes, the same action
##                      id and the same output path: the edge runs and the
##                      file holds the NEW bytes. So the key tracks the
##                      rendered bytes rather than the path.

import std/[os, tempfiles, unittest]

import repro_project_dsl
import repro_provider_runtime
import repro_cli_support
import repro_tool_profiles
import repro_build_engine

## Both decisions mean "the recorded result is still valid, do not
## re-execute". ``cdHybridCutoff`` is the hybrid policy's form of a hit:
## input metadata moved but the content hash matched
## (``Incremental-Invalidation.md`` §"File Fingerprint Policies").
const ReuseDecisions = {cdHit, cdHybridCutoff}

const
  ConfigPath = "etc/sso/config.toml"
  RenderActionId = "render-sso-config"

var devConfig: BuildOutput
var prodConfig: BuildOutput

proc renderedConfig(issuerKey: string): string =
  "issuer = \"" & readConfigurable[string](issuerKey) & "\"\n"

## The owner. One service, whose configuration is NOT a `config:` setter on
## the service -- it is a package configurable, rendered to a build output,
## reached on argv and declared as a runtime file.
package ssoDevPkg:
  config:
    issuer: string = "http://localhost:8080"

  executable zitadelBin:
    build:
      output("bin/zitadel")

  build:
    devConfig = renderConfigFile(ConfigPath,
      renderedConfig("ssoDevPkg.issuer"), actionId = RenderActionId)

  service sso:
    executable zitadelBin
    args "start-from-init", "--config", devConfig.path
    runtimeFile devConfig

## Case 5's graph. The SAME output path and the SAME action id -- only the
## configurable's value differs, so the only thing that can invalidate the
## edge is the rendered bytes.
package ssoProdPkg:
  config:
    issuer: string = "https://login.metacraft-labs.test"

  build:
    prodConfig = renderConfigFile(ConfigPath,
      renderedConfig("ssoProdPkg.issuer"), actionId = RenderActionId)

proc renderEdges(): seq[BuildActionDef] =
  ## The two ``render-sso-config`` edges, in registration order: the dev
  ## one first (its package is declared first), then the production one.
  for action in registeredBuildActions():
    if action.id == RenderActionId:
      result.add(action)

proc loweredGraph(action: BuildActionDef; projectRoot: string): BuildGraph =
  ## Lower one DSL-registered edge the way ``repro build`` does: wrap it in
  ## a provider-graph fragment and hand it to ``lowerProviderSnapshot``.
  ## That is the production lowering, including the ``bakWriteText``
  ## builtin mapping and the weak fingerprint derived from the encoded
  ## payload.
  var fragment = StoredGraphFragment(namespace: "sso-l1")
  fragment.nodes.add(GraphNode(
    id: "sso-l1:action:" & action.id,
    kind: gnkAction,
    stableName: action.id,
    payload: actionPayload(action)))
  let snapshot = ProviderGraphSnapshot(fragments: @[fragment])
  let lowered = lowerProviderSnapshot(snapshot, PathOnlyBuildIdentity(),
    projectRoot, "")
  graph(lowered.actions)

proc warmConfig(cacheRoot: string): BuildEngineConfig =
  ## Exactly the mode ``repro build`` runs in — see the note in
  ## ``libs/repro_build_engine/tests/t_zero_output_edge_is_cacheable.nim``.
  result = defaultBuildEngineConfig(cacheRoot)
  result.rebuildMissingOutputsOnCacheHit = true
  result.deferLocalOutputBlobs = true
  result.bypassRunQuota = true
  result.maxParallelism = 1'u32

proc only(res: BuildRunResult): ActionResult =
  doAssert res.results.len == 1, "expected one edge, got " & $res.results.len
  res.results[0]

proc describe(tag: string; r: ActionResult): string =
  tag & ": status=" & $r.status & " decision=" & $r.cacheDecision &
    " launched=" & $r.launched & " reason=" & r.reason

suite "L1 — the service declares the rendered config it consumes":

  test "the service's argv and runtimeFile both name the rendered output":
    var sso: DslServiceDef
    for svc in registeredServices("ssoDevPkg"):
      if svc.serviceName == "sso":
        sso = svc
    check sso.serviceName == "sso"
    check sso.args == @["start-from-init", "--config", ConfigPath]
    check sso.typedArgs[2].kind == svakBuildOutput
    check sso.typedArgs[2].producerActionId == RenderActionId
    check sso.runtimeFiles.len == 1
    check sso.runtimeFiles[0].producerActionId == RenderActionId

  test "the rendering helper registered exactly one edge per package":
    let edges = renderEdges()
    check edges.len == 2
    # Same id, same declared output, different rendered bytes. That is
    # what makes case 5 below a test of the CONTENT and not of the id.
    check edges[0].id == edges[1].id
    check edges[0].outputs == @[ConfigPath]
    check edges[1].outputs == @[ConfigPath]
    check edges[0].cacheable
    check edges[0].call.subcommand == "writeText"

suite "L1 — the rendered config is a cached build output":

  test "the five cases, in order, on one temporary project root":
    let edges = renderEdges()
    require edges.len == 2
    let root = createTempDir("repro-sso-config-cache-", "")
    defer: removeDir(root)
    let configFilePath = root / ConfigPath
    let devGraph = loweredGraph(edges[0], root)
    let config = warmConfig(root / "cache")

    # 1. cold.
    let first = (devGraph.runBuild(config)).only()
    checkpoint(describe("1 cold", first))
    check first.status == asSucceeded
    check first.launched
    check readFile(configFilePath) == "issuer = \"http://localhost:8080\"\n"

    # 2. unchanged — the gate's claim.
    let second = (devGraph.runBuild(config)).only()
    checkpoint(describe("2 unchanged", second))
    check second.cacheDecision in ReuseDecisions
    check second.status in {asCacheHit, asUpToDate}
    check not second.launched

    # ... and a third warm pass stays a hit, so the hit does not depend on
    # the record having been written by the immediately preceding run.
    let third = (devGraph.runBuild(config)).only()
    checkpoint(describe("2b third pass", third))
    check third.cacheDecision in ReuseDecisions
    check not third.launched

    # 3. a FRESH cache root, with the output still on disk. If case 2 were
    # an unconditional "the declared output exists, skip it" this would
    # also skip — it must run.
    check fileExists(configFilePath)
    let coldCache = (devGraph.runBuild(warmConfig(root / "cache-cold"))).only()
    checkpoint(describe("3 cold cache root", coldCache))
    check coldCache.cacheDecision notin ReuseDecisions
    check coldCache.launched

    # Back to a hit against the original cache, so the following cases
    # start from a known-warm state.
    check not (devGraph.runBuild(config)).only().launched

    # 4. the output is gone. A hit must not leave the service without its
    # configuration.
    removeFile(configFilePath)
    let restored = (devGraph.runBuild(config)).only()
    checkpoint(describe("4 output deleted", restored))
    check restored.launched
    check readFile(configFilePath) == "issuer = \"http://localhost:8080\"\n"

    # 5. the configurable moved. Same action id, same output path, new
    # rendered bytes.
    let prodGraph = loweredGraph(edges[1], root)
    let moved = (prodGraph.runBuild(config)).only()
    checkpoint(describe("5 content moved", moved))
    check moved.cacheDecision notin ReuseDecisions
    check moved.launched
    check readFile(configFilePath) ==
      "issuer = \"https://login.metacraft-labs.test\"\n"

    # ... and the new state is itself cacheable, which is what makes the
    # whole sequence a steady state rather than a one-shot.
    let settled = (prodGraph.runBuild(config)).only()
    checkpoint(describe("5b settled", settled))
    check settled.cacheDecision in ReuseDecisions
    check not settled.launched
