## ``isonim_ssg`` — the static-site-generator (SSG) render edge for
## code-authored isonim sites.
##
## An isonim static site ships a rendered ``dist/`` tree produced by RUNNING a
## compiled static-export binary (``src/static_export.nim`` compiled with
## ``nim.c`` — the hermetic, cross-OS-verifiable half). This helper is the
## second half: a **run edge** that executes that exporter and declares its
## emitted ``dist/`` directory as a **directory output** (a cached build
## product), so ``repro build`` / ``repro export`` materialise the site the
## same way any other artifact is produced — content-addressed, incremental,
## re-run only when an input changes.
##
## Usage in a site's ``repro.nim``::
##
##   import repro_dsl_stdlib/isonim_ssg
##
##   let compileEdge = nim.c(
##     source = "src/static_export.nim", binary = "build/static_export",
##     defines = @["isServer", "release"], mm = "orc", paths = @["src"],
##     extraInputs = @["src"], actionId = "site.export.compile")
##
##   let renderEdge = buildIsonimStaticSite.build(
##     exporter = "build/static_export",   # the binary compileEdge produced
##     outputDir = "dist",                 # the directory it emits
##     after = @[compileEdge],             # sequence AFTER the compile
##     actionId = "site.export.render")
##
##   discard collect("build", @[compileEdge])
##   discard target("export", renderEdge)
##
## The run edge declares ``exporter`` as an input (so the engine builds it
## first and re-runs when its content changes) and ``outputDir`` as an output
## (the engine classifies it as a directory at revalidate time and captures the
## tree). The default working directory is the recipe root, which is where the
## exporter writes ``dist/``.

import repro_project_dsl
export repro_project_dsl

const IsonimStaticSiteToolId* = "repro_dsl_stdlib.buildIsonimStaticSite"
  ## Stable identity string for ``repro why`` / explainer ``provider:`` lines.

type
  BuildIsonimStaticSite* = object
    ## Namespace value for ``buildIsonimStaticSite.build(...)``. The empty
    ## object exists so the call shape stays a valid Nim UFCS expression —
    ## ``buildIsonimStaticSite.build(arg)`` dispatches as
    ## ``build(buildIsonimStaticSite, arg)``.

const buildIsonimStaticSite* = BuildIsonimStaticSite()
  ## The namespace value a site's ``repro.nim`` writes
  ## ``buildIsonimStaticSite.build(exporter = ..., outputDir = ...)`` against.

proc build*(tool: BuildIsonimStaticSite;
            exporter: string;
            outputDir = "dist";
            args: seq[string] = @[];
            actionId = "";
            deps: openArray[string] = [];
            after: openArray[BuildActionDef] = [];
            extraInputs: openArray[string] = [];
            extraOutputs: openArray[string] = [];
            extraEnv: openArray[(string, string)] = [];
            cacheable = true;
            dependencyPolicy = automaticMonitorPolicy();
            actionCachePolicy = defaultActionCachePolicy()):
    BuildActionDef {.discardable.} =
  ## Emit one run edge that executes the compiled ``exporter`` and captures the
  ## ``outputDir`` tree it emits as a declared directory output.
  ##
  ## ``exporter`` — path to the compiled static-export binary (the output of a
  ## sibling ``nim.c(...)`` compile edge). Recorded as a declared input so the
  ## action cache keys on the binary's content and the engine builds it first.
  ##
  ## ``outputDir`` — the directory the exporter writes (default ``"dist"``).
  ## Declared as an output; the engine classifies it as a directory at
  ## revalidate time (``ffkDirectory``) and captures the tree. Relative to the
  ## recipe root, which is the run edge's default working directory — matching
  ## where the exporter's ``createDir(OutputDir)`` lands.
  ##
  ## ``args`` — extra argv appended after the exporter binary (most exporters
  ## take none; provided for exporters that accept an output-dir flag etc.).
  ##
  ## ``after`` — build edges to sequence this run AFTER (typically the compile
  ## edge); folded into ``deps``. ``deps`` — additional dependency action ids.
  ##
  ## ``dependencyPolicy`` defaults to ``automaticMonitorPolicy()`` so the
  ## engine's io-monitor records every file the exporter actually reads
  ## (pages/components/assets it pulls in), invalidating the render whenever any
  ## of them change — not just when ``exporter`` itself does.
  discard tool

  var argv = @[exporter]
  for a in args:
    if a.len > 0: argv.add a
  let call = inlineExecCall(argv)

  let selectedActionId =
    if actionId.len > 0: actionId
    else: defaultToolActionId(call)

  # The exporter binary is a declared input (build it first, key on content);
  # `after`/`deps` additionally order the run edge behind the compile edge.
  var allInputs: seq[string] = @[exporter]
  for path in extraInputs:
    if path.len > 0: allInputs.add path

  # `outputDir` is the captured directory output; callers may declare extra
  # outputs (e.g. a sitemap emitted outside `dist/`).
  var allOutputs: seq[string] = @[outputDir]
  for path in extraOutputs:
    if path.len > 0: allOutputs.add path

  result = recordCommandAction(
    selectedActionId, call,
    deps = combineActionDeps(deps, after),
    extraInputs = allInputs,
    extraOutputs = allOutputs,
    cacheable = cacheable,
    dependencyPolicy = dependencyPolicy,
    actionCachePolicy = actionCachePolicy,
    extraEnv = extraEnv)
