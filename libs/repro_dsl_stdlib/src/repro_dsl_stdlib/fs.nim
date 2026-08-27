import repro_project_dsl

export BuildActionDef

proc copyFile*(source, output: string; actionId = "";
               deps: openArray[string] = [];
               after: openArray[BuildActionDef] = [];
               cacheable = true; commandStatsId = "";
               actionCachePolicy = defaultActionCachePolicy()):
    BuildActionDef {.discardable.} =
  repro_project_dsl.fs.copyFile(source, output, actionId = actionId,
    deps = deps, after = after, cacheable = cacheable,
    commandStatsId = commandStatsId, actionCachePolicy = actionCachePolicy)

proc ensureDir*(path: string; actionId = "";
                deps: openArray[string] = [];
                after: openArray[BuildActionDef] = [];
                commandStatsId = ""):
    BuildActionDef {.discardable.} =
  repro_project_dsl.fs.ensureDir(path, actionId = actionId, deps = deps,
    after = after, commandStatsId = commandStatsId)

proc writeText*(output, text: string; actionId = "";
                deps: openArray[string] = [];
                after: openArray[BuildActionDef] = [];
                cacheable = true; commandStatsId = "";
                actionCachePolicy = defaultActionCachePolicy()):
    BuildActionDef {.discardable.} =
  repro_project_dsl.fs.writeText(output, text, actionId = actionId,
    deps = deps, after = after, cacheable = cacheable,
    commandStatsId = commandStatsId, actionCachePolicy = actionCachePolicy)

proc unmonitorableActionDepfile*(output: string;
                                 inputs: openArray[string];
                                 reason: string;
                                 actionId = "";
                                 deps: openArray[string] = [];
                                 after: openArray[BuildActionDef] = []):
    BuildActionDef {.discardable.} =
  ## ESCAPE HATCH. See ``repro_project_dsl.fs.unmonitorableActionDepfile`` for
  ## the full contract — what it disables, when an action legitimately cannot
  ## be monitored, and the standing obligation to keep the input list current.
  repro_project_dsl.fs.unmonitorableActionDepfile(output, inputs, reason,
    actionId = actionId, deps = deps, after = after)

proc stamp*(output, title: string; entries: openArray[string] = [];
            inputs: openArray[string] = []; actionId = "";
            deps: openArray[string] = [];
            after: openArray[BuildActionDef] = [];
            cacheable = true; commandStatsId = "";
            actionCachePolicy = defaultActionCachePolicy()):
    BuildActionDef {.discardable.} =
  repro_project_dsl.fs.stamp(output, title, entries = entries, inputs = inputs,
    actionId = actionId, deps = deps, after = after, cacheable = cacheable,
    commandStatsId = commandStatsId, actionCachePolicy = actionCachePolicy)

proc preserveTree*(sourceRoot, outputRoot: string; actionId = "";
                   deps: openArray[string] = [];
                   after: openArray[BuildActionDef] = [];
                   excludePrefixes: openArray[string] = [];
                   commandStatsId = ""):
    BuildActionDef {.discardable.} =
  repro_project_dsl.fs.preserveTree(sourceRoot, outputRoot,
    actionId = actionId, deps = deps, after = after,
    excludePrefixes = excludePrefixes,
    commandStatsId = commandStatsId)
