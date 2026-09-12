import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package sh:
  provisioning:
    nixPackage "nixpkgs#bash", executablePath = "bin/sh",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
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

      # DELIBERATELY NOT BLESSED -- and note that a blessing written HERE
      # would not even reach the edges it would be written for.
      #
      # `shell(command = "bash <script>")` below is the tool identity of
      # every `bash <script>` build edge -- CodeTracer's ten shell gates
      # included -- and those edges publish no action-cache entry purely
      # because an `mrNonDeterministic` record lands in their captures. The
      # obvious fix is `nonDeterminism entropyBlessed` on this line.
      #
      # IT WOULD DO NOTHING. Measured: adding it here makes the GENERATED
      # wrapper (`sh(command = ..., args = ...)`) come back
      # `ndpEntropyBlessed`, and leaves `shell()` at `ndpUnblessed` -- the
      # blessing is spliced into the generated wrapper's
      # `recordToolInvocation` call, and `shell()` is HAND-WRITTEN and calls
      # `recordToolInvocation` itself without passing one. It is the same
      # route `dependencyPolicy` already fails to survive for `nim.c` (see
      # `tests/t_nim_entropy_blessing.nim`'s header). So an author who
      # blesses the shell here sees no change, reads it as broken plumbing,
      # and repairs it -- which is how the waiver would actually get made,
      # by someone who by then believes they are only fixing a leak.
      #
      # It is unsound. Measured with io-mon @87143d62 on both the Linux
      # `linux-preload-hooks` and the Windows `windows-interpose-hooks`
      # backend:
      #
      #   * the shell emits ZERO entropy records of its own -- `bash -c 'echo
      #     hello'` produces none on either platform, MSYS bash under
      #     `msys-2.0.dll` included;
      #   * `$RANDOM` emits ZERO records, so a script whose whole output is
      #     `echo $RANDOM > out.txt` is unreproducible and leaves no entropy
      #     evidence at all -- the signal is NOT what guards against
      #     script-level non-determinism;
      #   * every record a gate action does emit comes from a CHILD the
      #     script chose to run. Across CodeTracer's ten gates: 45 records,
      #     all `getrandom`, all from `mktemp` (23) and `git` (22) by their
      #     own pids.
      #
      # So a blessing here would waive nothing about the shell and everything
      # about strangers. The engine's policy is ACTION-scoped while the
      # evidence is PROCESS-TREE-scoped; for a compiler the two coincide (the
      # tree under `nim` is nim, gcc and ld), for an interpreter the tree is
      # chosen by the SCRIPT. And the waiver is not theoretical: a `mktemp`
      # record and a `uuidgen > out.txt` record differ in no field but the
      # emitting pid, so blessing the benign one publishes a cache entry for
      # a product that is different on every run.
      #
      # The right mechanism is to bless the tool that emitted -- `mktemp`,
      # `git` -- in its own CLI spec, and THAT MECHANISM NOW EXISTS: the
      # engine keeps `MonitorRecord.osPid` on an `EntropyObservation`,
      # resolves it against the capture's own `mrProcessExec` records, and
      # asks `repro_core/entropy_blessings.EntropyBlessedTools` about the
      # resolved image. `packages/mktemp.nim` and `packages/git.nim` carry
      # those declarations. A gate whose every entropy record belongs to a
      # blessed tool now publishes; one that also runs `uuidgen` still does
      # not, and that pair is the whole point.
      #
      # NONE OF WHICH CHANGES THIS FILE'S ANSWER. The per-image waiver is a
      # claim about ONE TOOL's randomness, made by somebody who can make it.
      # A blessing here would still be a claim about every program a script
      # chooses to run, made by somebody who cannot -- and it is now not even
      # needed for the case it was asked for.
      #
      # Guarded by `tests/t_shell_entropy_is_not_blessed.nim`, which asserts
      # BOTH wrappers separately because a blessing reaches them by
      # different routes and one assertion would leave the other open.

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
            extraEnv: openArray[(string, string)] = [];
            dependencyPolicy = automaticMonitorPolicy()): BuildActionDef
    {.discardable.} =
  ## ``extraEnv`` declares environment variables ON THIS ACTION. Two
  ## consequences, and the second is the one worth reaching for:
  ##
  ##   * the value is LAYERED OVER the inherited environment, and a
  ##     declared name REPLACES the inherited one — so the action stops
  ##     reading whatever the caller happened to export;
  ##   * the (name, value) pair is mixed into the action's weak
  ##     fingerprint by ``keyedOnActionEnvironment``, so two builds that
  ##     differ only in a declared value get different cache keys.
  ##
  ## That pairing is the whole point. An environment variable a script
  ## READS but the action does not DECLARE still reaches the script (the
  ## launcher inherits), yet contributes nothing to the key — so the
  ## engine may serve a result computed under a different value of it.
  ## Declaring it closes both halves at once.
  ##
  ## Values must be a function of the RECIPE, not of the host: the
  ## provider snapshot and the lowered-graph cache are both reused across
  ## invocations that differ only in the ambient environment, so a value
  ## read here with ``getEnv`` would be snapshotted at the first build and
  ## served to every later one. Where a build must be switchable, declare
  ## the two settings as two actions (or route the choice through a
  ## variant, which IS folded into the lowered-graph cache key).
  ##
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
  ##
  ## THIS PROC IS THE ONLY PLACE A SHELL EDGE COULD BE ENTROPY-BLESSED, and
  ## it deliberately is not: the `recordToolInvocation` call below passes no
  ## `nonDeterminism`, so every shell edge is `ndpUnblessed`. The `cli:`
  ## block above cannot do it from here -- a blessing there reaches only the
  ## GENERATED wrapper. The argument for leaving it unblessed, and the
  ## io-mon measurement it rests on, is written out at that `cli:` block;
  ## read it before adding the argument here.
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
    actionCachePolicy = actionCachePolicy,
    extraEnv = extraEnv)
