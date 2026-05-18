import repro_project_dsl

export BuildActionDef

proc copyFile*(source, output: string; actionId = "";
               deps: openArray[string] = [];
               after: openArray[BuildActionDef] = [];
               cacheable = true; commandStatsId = ""):
    BuildActionDef {.discardable.} =
  repro_project_dsl.fs.copyFile(source, output, actionId = actionId,
    deps = deps, after = after, cacheable = cacheable,
    commandStatsId = commandStatsId)

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
                cacheable = true; commandStatsId = ""):
    BuildActionDef {.discardable.} =
  repro_project_dsl.fs.writeText(output, text, actionId = actionId,
    deps = deps, after = after, cacheable = cacheable,
    commandStatsId = commandStatsId)

proc stamp*(output, title: string; entries: openArray[string] = [];
            inputs: openArray[string] = []; actionId = "";
            deps: openArray[string] = [];
            after: openArray[BuildActionDef] = [];
            cacheable = true; commandStatsId = ""):
    BuildActionDef {.discardable.} =
  repro_project_dsl.fs.stamp(output, title, entries = entries, inputs = inputs,
    actionId = actionId, deps = deps, after = after, cacheable = cacheable,
    commandStatsId = commandStatsId)

proc preserveTree*(sourceRoot, outputRoot: string; actionId = "";
                   deps: openArray[string] = [];
                   after: openArray[BuildActionDef] = [];
                   commandStatsId = ""):
    BuildActionDef {.discardable.} =
  repro_project_dsl.fs.preserveTree(sourceRoot, outputRoot,
    actionId = actionId, deps = deps, after = after,
    commandStatsId = commandStatsId)
