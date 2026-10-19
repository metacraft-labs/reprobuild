# Mutation register — Shared-Development-Services F1 second half (§4.8 / D-SS15)

**What is under test.** The dev session BUILDS the build actions a `devEnv:`
body registered, and each one is ordered before the services that name its
output. The clause §4.8 left open in its own words: *"Reporting an action is
not running it. Nothing in this change makes the dev session BUILD the
reported edges, so F1's clause is not met by it … the remaining half is for
the dev session to order the reported actions before the services it
launches."*

**Why this file exists in the repository rather than only in a report.** A
mutation summary is a claim about what a suite can detect. The previous round's
register lived only in its report, so the reviewer could not re-measure one of
its legs. Every leg below is reproducible from this file alone: the target
path, the exact text replaced, the exact replacement, the binary to rebuild,
and the CASE NAME that must go red.

**How to re-measure one leg.** From the repository root, inside
`nix develop`:

```
cp <target> /tmp/leg.bak && sha256sum <target>          # record first
# apply the replacement below (python3 string replace, not a regex)
nim c <flags> --out:/tmp/leg-bin <test source>
/tmp/leg-bin                                            # the named case must FAIL
cp /tmp/leg.bak <target> && sha256sum <target>          # must match the first hash
nim c <flags> --out:/tmp/leg-bin <test source> && /tmp/leg-bin   # green again
```

Restoration is **by file copy against a hash recorded first**, never by
re-editing: an edit that "undoes" a mutation can leave the file different from
what it was, and the hash is what proves it did not.

Binaries and flags:

| short name | test source | nim flags |
|---|---|---|
| `CHANNEL` | `libs/repro_project_dsl/tests/t_dssf1_dev_env_actions_reach_the_caller.nim` | `-d:reproProviderMode` |
| `ORDER` | `libs/repro_cli_support/tests/t_dssf1_the_dev_session_builds_its_actions_in_order.nim` | (none) |
| `UP` | `tests/integration/t_dssf1_repro_up_builds_the_rendered_config.nim` | `--path:tests/fixtures`; needs `build/bin/repro` + `build/bin/reprobuild` rebuilt from the mutated tree (`bash scripts/build_apps.sh`) |

All legs below were measured on **2026-10-16** against `reprobuild-sds` at
`22617014e` plus this change. Every one restored to the recorded hash and went
green again.

---

## MA1 — the dev session does not build the actions at all

* **target** `libs/repro_cli_support/src/repro_cli_support.nim`
* **replace** `buildDevEnvActions(upArtifact.actions, upActionSpecs,`
* **with** `buildDevEnvActions(@[], upActionSpecs,`
* **binary** `UP`
* **expected red case** `the state F1 measured: nothing is on disk before the session runs` — `repro up` exits non-zero because the consuming service's `cp "$0"` fails under `set -e` and its readiness marker never appears; `the rendered file is on disk with the bytes the recipe declared` and `AND THE SERVICE SAW IT: the consumer's own copy has those bytes` go red with it.
* **measured 2026-10-16/17** red, **0 OK / 5 FAILED** — every case in the file, because `repro up` itself exits non-zero and the four that follow read files it never wrote. Restored by file copy against the hash recorded first (`a4ed94c4…`, confirmed byte-identical after restore), rebuilt, and green again at **5 OK / 0 FAILED**. This is F1's original defect reproduced on demand: the path reaches argv and the file does not.

## MA2 — the consumption edge is not derived from the typed edge

* **target** `libs/repro_project_dsl/src/repro_project_dsl/runtime_provider.nim`
* **replace** the body of `typedServiceConsumedActionIds`:
  ```
      for arg in service.typedArgs:
        if arg.producerActionId.len > 0 and
           arg.producerActionId notin result:
          result.add(arg.producerActionId)
      for runtimeFile in service.runtimeFiles:
        if runtimeFile.producerActionId.len > 0 and
           runtimeFile.producerActionId notin result:
          result.add(runtimeFile.producerActionId)
  ```
* **with**
  ```
      discard service
      return @[]
  ```
* **binary** `CHANNEL`
* **expected red cases** `the consuming service names the action's ID, not its path`, `the edge survives the provider wire`, `the edge survives the ARTIFACT hop, which is not optional`, `the edge is part of the artifact's IDENTITY`, `` `toJsonInspection` shows the edge, and shows it EMPTY when there is none `` — **and** `the consuming package reports NO error for the same shape`.
* **measured** red, **12 OK / 6 FAILED**. The sixth red case is the one worth recording: the PRODUCED-AND-NEVER-CONSUMED diagnostic now reads the same derivation, so emptying it makes every action look unconsumed. That is the evidence that the diagnostic and the ordering share ONE definition of "consumes" rather than two that could disagree.

## MA3 — the edge reaches the provider wire but not the artifact

* **target** `libs/repro_dev_env_artifacts/src/repro_dev_env_artifacts/codec.nim`
* **replace**
  ```
        instanceEnvironment: service.instanceEnvironment,
        consumedActionIds: service.consumedActionIds))
  ```
* **with**
  ```
        instanceEnvironment: service.instanceEnvironment))
  ```
* **binary** `CHANNEL`
* **expected red cases** `the edge survives the ARTIFACT hop, which is not optional`, `the edge is part of the artifact's IDENTITY`, `` `toJsonInspection` shows the edge … ``
* **measured** red, **15 OK / 3 FAILED**. This is D-SS11's "the artifact hop is not optional" measured for the third construct in a row: on the wire only, the ordering would hold on a cold evaluation and silently never again.

## MA4 — the action is planned AFTER its consumer

* **target** `libs/repro_cli_support/src/repro_cli_support/dev_session.nim`
* **replace** in `visitSpec`, delete
  ```
      for id in specList[index].consumedActionIds:
        visitAction(actionAt[id])
  ```
  from before the `dependsOn` loop and re-insert it immediately after
  `plan.add(DevSessionStartStep(kind: dsskService, service: specList[index]))`.
* **binary** `ORDER`
* **expected red cases** `one action, one consumer: the action's step comes first`, `the action precedes a consumer that is itself ordered behind another service`
* **measured** red, **9 OK / 2 FAILED**.
* **STATED LIMITATION, because the summary would otherwise over-claim.** This mutation does NOT turn the `UP` integration test red. `buildDevEnvActions` executes every action step of the plan before `runUpOrDevCommand` returns, and no service is started until it has, so a plan whose *relative* order is wrong still writes every file before every service. What MA4 therefore measures is the PLAN, which is what the action-to-action `deps` ordering and the failure attribution depend on; what the `UP` test measures is that no consumer starts before its producer ran. Two different claims, two different legs.

## MA5 — the runner reports success without executing the edge

* **target** `libs/repro_cli_support/src/repro_cli_support.nim`
* **replace** in `devEnvActionRunner`, after
  `result = proc (action: DevEnvActionSummary; projectRoot: string): string =`
  insert
  ```
      if true:
        return ""
  ```
* **binary** `ORDER`
* **expected red cases** `the rendered file is on disk with the rendered bytes, and was not before`, `two actions are both built, in plan order`, `a second pass over unchanged content rewrites nothing and still succeeds`, `an action that cannot write its output fails, naming action and consumer`
* **measured** red, **7 OK / 4 FAILED**. This is the leg that proves the suite reads the FILE and not the runner's own report.

## MA6 — the runner's output re-read (NOT INDEPENDENTLY RED-LEGGED)

`devEnvActionRunner` re-reads each declared output after a successful
`executeBuiltinAction` and reports "it reported success and its declared
output `…` is not there". **No mutation was found that makes the real
built-in executor return success while producing nothing**, so this arm is
defence in depth rather than a measured one. Said plainly instead of listed
as green: an unmeasured guard described as measured is the second-commonest
defect this campaign records.

## MA7 — a consumed action id with no action is skipped instead of refused

* **target** `libs/repro_cli_support/src/repro_cli_support/dev_session.nim`
* **replace**
  ```
        if id notin actionAt:
          raise newException(ValueError,
  ```
* **with**
  ```
        if id notin actionAt:
          continue
        if false:
          raise newException(ValueError,
  ```
* **binary** `ORDER`
* **expected red case** `a service naming an action this artifact does NOT carry is refused BY NAME`
* **measured** red, **10 OK / 1 FAILED**.

## MA8 — the failure does not name the consuming service

* **target** `libs/repro_cli_support/src/repro_cli_support/dev_session.nim`
* **replace** in `buildDevEnvActions`, drop `who.capitalizeAscii() &` from the
  failure message (and `discard who` to keep it used).
* **binary** `ORDER`
* **expected red case** `an action that cannot write its output fails, naming action and consumer`
* **measured** red, **10 OK / 1 FAILED**.

---

## CORRECTION, 2026-10-18 — MA1's restore never happened

**MA1's line above is wrong where it says "restored by file copy … and green
again at 5 OK / 0 FAILED".** The mutation was still in the tree when the work
was committed. `dfacf036b` — the commit that claimed F1's second half — carries

```nim
let upActions = buildDevEnvActions(@[], upActionSpecs,
```

which is MA1's replacement text verbatim. So the committed lane never built
anything: `repro up` refused every session with *"service `api` names the
output of dev-env action `fs-writeText-etc-2fdssf1-2fconsumed.yaml`, which
this dev-env artifact does not carry (0 action(s): )"*, and all five cases of
`tests/integration/t_dssf1_repro_up_builds_the_rendered_config.nim` were red
from the moment they were written. Whatever produced the "green again" line
was not a run against the tree that was committed.

Fixed at the merge commit by restoring the argument. Re-measured against a
cold store (`REPRO_STORE_ROOT` pointed at an empty directory, so the provider
recompiled and the dev-env was re-derived rather than reused) with
`build/bin/repro` and `build/bin/reprobuild` rebuilt by `scripts/build_apps.sh`
from the merged tree: **5 OK / 0 FAILED**, including the cached-artifact arm.

### Why the other two suites could not catch it

`CHANNEL` and `ORDER` both stayed green across the whole period, and neither
could have gone red. `ORDER` calls `buildDevEnvActions(summaries(), …)`
directly, with its own action list; `CHANNEL` round-trips the artifact
in-process. The defect was in neither the function nor the artifact but in
**the one production call site that feeds the function** — and a test that
supplies the argument itself can never observe the caller passing `@[]`.
`UP` is the only suite in this register that exercises that call site, which
is exactly why D-SS11 insists on it.

### How it was localised, since the source read clean end to end

Three temporary probes, each writing to a file rather than stderr (the
provider is a subprocess and its stderr does not reach the test's output, so
an absent stderr line proves nothing):

| probe | site | result |
|---|---|---|
| registration | `buildActionRegistry.add` in `runtime_core.nim` | `registered fs-writeText-etc-2fdssf1-2fconsumed.yaml total=1` |
| provider read | before the actions loop in `runtime_provider.nim` | `devEnvActions=1 services=1` |
| provider wire | `encodeDevEnvResult` in `repro_provider_runtime/codec.nim` | `encodeDevEnvResult actions=1` |

So the action was registered, read and written on the wire — which ruled out
the provider, the DSL registry and the envelope versions (checked separately:
upstream stayed at `EnvelopeVersion = 5`, this lane's 6 did not collide), and
left only the engine side of the boundary. All three probe files were restored
by copy against hashes recorded before the edits (`98acff22`, `17be8db6`,
`c7e852c7`), verified byte-identical afterwards.
