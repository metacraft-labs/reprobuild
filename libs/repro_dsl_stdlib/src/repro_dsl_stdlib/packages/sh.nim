import repro_project_dsl

package sh:
  provisioning:
    nixPackage "nixpkgs#bash", executablePath = "bin/sh",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
    # Windows: `sh` ships with Git for Windows (PortableGit) at
    # `bin/sh.exe`. Resolving the `sh` selector via Scoop installs
    # `main/git` and exposes the same bin tree on PATH.
    scoopApp(bucket = "main", app = "git",
      preferredVersion = ">=2", executablePath = "bin/sh.exe",
      requiresExecutionProfileChecksum = false)
    # Direct-download: PortableGit ships sh.exe at `bin/sh.exe`.
    tarball url = "https://github.com/git-for-windows/git/releases/download/v2.54.0.windows.1/PortableGit-2.54.0-64-bit.7z.exe",
      sha256 = "bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311",
      archiveType = "7z.exe",
      executablePath = "bin/sh.exe",
      packageId = "git@2.54.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:git@2.54.0:sha256:bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311"

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
            ignoredInputPrefixes: openArray[string] = [];
            depfile = ""; cacheable = true;
            actionCachePolicy = defaultActionCachePolicy();
            commandStatsId = "";
            dependencyPolicy = automaticMonitorPolicy()): BuildActionDef
    {.discardable.} =
  ## ``dependencyPolicy`` selects how the engine gathers this shell
  ## action's dependency evidence. It defaults to
  ## ``automaticMonitorPolicy()`` — automatic monitoring is the spec
  ## baseline for opaque tools (Reprobuild-Development.milestones.org
  ## M17). Recipes wrapping a toolchain that emits its own recognized
  ## dependency reports (e.g. a ``bash -c '... cargo build ...'``
  ## indirection where cargo writes ``.d`` depfiles) should pass an
  ## explicit ``makeDepfilePolicy(...)`` / recognized-report policy so
  ## the engine still collects real evidence. There is intentionally NO
  ## declared-only opt-out: a "track only declared inputs, mark complete
  ## anyway" policy is a soundness hole and was removed (M17). An action
  ## that genuinely cannot be monitored and has no other evidence must be
  ## made non-cacheable (``cacheable = false``) per
  ## Monitor-Hook-Shim.md:501, never marked complete-on-declared-inputs.
  ##
  ## ``ignoredInputPrefixes`` is merged into the supplied policy so
  ## callers can keep using the convenience parameter without having
  ## to build the policy object themselves; an explicit
  ## ``ignoredInputPrefixes`` on the policy is preserved and the two
  ## sets are unioned.
  var resolvedPolicy = dependencyPolicy
  for prefix in ignoredInputPrefixes:
    if prefix.len > 0 and prefix notin resolvedPolicy.ignoredInputPrefixes:
      resolvedPolicy.ignoredInputPrefixes.add(prefix)
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
    dependencyPolicy = resolvedPolicy,
    actionCachePolicy = actionCachePolicy)
