import repro_project_dsl

package sh:
  provisioning:
    nixPackage "nixpkgs#bash", executablePath = "bin/sh"

  executable sh:
    cli:
      dependencyPolicy automaticMonitor

      call:
        flag command is string,
          alias = "-c",
          required = true
        pos args is seq[string],
          position = 0,
          required = false

proc shell*(command: string; args: seq[string] = @[]; actionId = "";
            deps: openArray[string] = [];
            after: openArray[BuildActionDef] = [];
            extraInputs: openArray[string] = [];
            extraOutputs: openArray[string] = [];
            depfile = ""; cacheable = true;
            actionCachePolicy = defaultActionCachePolicy();
            commandStatsId = ""): BuildActionDef {.discardable.} =
  let call = publicCliCall("sh", "sh", "", "sh.sh.call", @[
    cliArg("command", command, cpkFlag, 0, "-c"),
    cliArgSeq("args", args, cpkPositional, 0)
  ])
  let selectedActionId =
    if actionId.len > 0: actionId else: defaultToolActionId(call)
  recordToolInvocation(selectedActionId, call,
    deps = combineActionDeps(deps, after),
    extraInputs = extraInputs,
    extraOutputs = extraOutputs,
    depfile = depfile,
    cacheable = cacheable,
    commandStatsId = commandStatsId,
    dependencyPolicy = automaticMonitorPolicy(),
    actionCachePolicy = actionCachePolicy)
