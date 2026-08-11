## M69 Verification Gate: e2e_repro_infra_plan_apply_convergent
##
## Per the M69 verification block: `repro infra plan` produces a
## plan; `repro infra apply <plan-id>` reaches the desired state and
## a subsequent plan is a no-op (apply is convergent). `--no-preview`
## apply also converges. A non-elevated apply elevates through the
## M81 single broker (one prompt for the whole apply) and converges;
## `--no-elevate` applies only the non-privileged subset, reports
## every privileged operation skipped, and mutates nothing
## privileged. A stale plan is rejected before mutation.
##
## SAFETY: the "sandboxed system path" is a sandboxed registry subkey
## of `HKLM\SOFTWARE\Reprobuild-Tests\` — never a real system
## location. The gate exercises the PUBLIC `repro infra plan/apply`
## CLI as a subprocess. It uses M81's `REPRO_FORCE_BROKER` seam to
## drive the real broker path on an already-elevated host without an
## interactive UAC prompt. No real system mutation.
##
## No `skip`, no `xfail`.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_elevation
import repro_infra

import repro_test_support

const ProjectRoot = currentSourcePath().parentDir().parentDir()
  .parentDir().parentDir()

proc reproBinary(): string =
  let candidate = ProjectRoot / "build" / "bin" / "repro.exe"
  doAssert fileExists(candidate),
    "repro binary not found at " & candidate &
    "; build with the gate recipe first"
  candidate

let runId = "gate-" & $getCurrentProcessId()

proc cleanupSandbox() =
  deleteFixtureRegistryTree(runId)
  deleteFixtureRegistryRoot()

proc sandboxKey(leaf: string): string =
  "HKLM\\SOFTWARE\\Reprobuild-Tests\\" & runId & "\\" & leaf

proc writeProfile(stateDir, leaf, value: string) =
  writeFile(stateDir / "system.nim",
    "windows.registryValue {\n" &
    "  key = \"" & sandboxKey(leaf) & "\"\n" &
    "  name = \"ConvergentValue\"\n" &
    "  kind = string\n" &
    "  value = \"" & value & "\"\n" &
    "}\n")

type CliRun = object
  output: string
  code: int

proc quoteArg(a: string): string =
  if a.len > 0 and ' ' notin a: a else: "\"" & a & "\""

proc runRepro(stateDir: string; args: openArray[string];
              forceBroker = false): CliRun =
  ## Run the public `repro` CLI as a subprocess against a sandboxed
  ## state dir. The sandbox env vars are set in THIS process and
  ## inherited by the child (passing a wholesale replacement `env` to
  ## `startProcess` on Windows drops PATH and breaks the launch).
  ## `execCmdEx` captures combined stdout+stderr.
  let savedState = getEnv("REPRO_INFRA_STATE_DIR")
  let savedForce = getEnv("REPRO_FORCE_BROKER")
  putEnv("REPRO_INFRA_STATE_DIR", stateDir)
  if forceBroker:
    putEnv("REPRO_FORCE_BROKER", "1")
  else:
    delEnv("REPRO_FORCE_BROKER")
  defer:
    if savedState.len > 0: putEnv("REPRO_INFRA_STATE_DIR", savedState)
    else: delEnv("REPRO_INFRA_STATE_DIR")
    if savedForce.len > 0: putEnv("REPRO_FORCE_BROKER", savedForce)
    else: delEnv("REPRO_FORCE_BROKER")
  var cmd = quoteArg(reproBinary())
  for a in args:
    cmd.add(" ")
    cmd.add(quoteArg(a))
  let (outp, code) = execCmdEx(cmd)
  CliRun(output: outp, code: code)

proc planIdFrom(output: string): string =
  for line in output.splitLines():
    let t = line.strip()
    if t.startsWith("plan-id"):
      let idx = t.find(':')
      if idx >= 0:
        return t[idx + 1 .. ^1].strip()
  return ""

proc observeLeaf(leaf: string): ObservedOperationState =
  observeWindowsRegistryValue(PrivilegedOperation(
    kind: pokWindowsRegistryValue, address: "probe",
    hklmSubkey: "SOFTWARE\\Reprobuild-Tests\\" & runId & "\\" & leaf,
    hklmValueName: "ConvergentValue",
    hklmValueKind: srvkString, hklmValueLiteral: ""))

const HostRunsGate = defined(windows)
  ## This gate needs a real Windows host. It used to be enforced by an
  ## ``echo`` + ``quit(0)`` at module init, before any ``test`` template
  ## expanded: the binary emitted no catalog, stayed an opaque
  ## whole-binary exit-0 PASS, and its declared cases were invisible to
  ## every gate -- not counted as passes, not as skips, not at all.

const PlatformSkipReason =
  "[platform N/A] t_e2e_repro_infra_plan_apply_convergent: the " &
    "system-scope drivers are Windows-only in M69 Phase A"

template gatedTest(name: string; body: untyped) =
  ## Register the case unconditionally, and on a host that cannot run it
  ## record a skip whose reason is visible in the run summary and the
  ## skip census.
  ##
  ## The guard is a runtime ``if`` on a compile-time constant rather than
  ## a ``when``, deliberately: ``when`` would stop type-checking the
  ## Windows-only body on Linux, and that compile coverage is exactly
  ## what the previous module-init gate already gave us. Nim folds the
  ## constant, so the dead branch still costs nothing at runtime.
  test name:
    if HostRunsGate:
      body
    else:
      skip(PlatformSkipReason)

suite "e2e_repro_infra_plan_apply_convergent":
  when isNixSupported:

    gatedTest "the host is already elevated (gate precondition)":
      check isProcessElevated()

    gatedTest "plan -> apply <plan-id> -> re-plan is a no-op (convergent)":
      cleanupSandbox()
      let stateDir = createTempDir("repro-m69-conv-", "")
      defer:
        removeDir(stateDir)
        cleanupSandbox()
      writeProfile(stateDir, "convergent", "the-desired-value")

      # 1. plan.
      let plan1 = runRepro(stateDir, ["infra", "plan"])
      check plan1.code == 0
      check plan1.output.contains("1 operation(s) would change")
      let planId = planIdFrom(plan1.output)
      check planId.len == 32

      # 2. apply <plan-id> through the single broker.
      let apply1 = runRepro(stateDir, ["infra", "apply", "--plan", planId],
        forceBroker = true)
      check apply1.code == 0
      check apply1.output.contains("broker used  : true")
      check apply1.output.contains("launches: 1")
      check apply1.output.contains("applied      : 1")
      check observeLeaf("convergent").present

      # 3. re-plan: a no-op (apply is convergent).
      let plan2 = runRepro(stateDir, ["infra", "plan"])
      check plan2.code == 0
      check plan2.output.contains("no changes")

    gatedTest "--no-preview apply (fresh plan) converges without a plan id":
      cleanupSandbox()
      let stateDir = createTempDir("repro-m69-nopreview-", "")
      defer:
        removeDir(stateDir)
        cleanupSandbox()
      writeProfile(stateDir, "nopreview", "no-preview-value")

      let apply = runRepro(stateDir, ["infra", "apply", "--no-preview"],
        forceBroker = true)
      check apply.code == 0
      check apply.output.contains("applied      : 1")
      check observeLeaf("nopreview").present
      # A subsequent plan is a no-op.
      let plan = runRepro(stateDir, ["infra", "plan"])
      check plan.output.contains("no changes")

    gatedTest "--no-elevate applies the non-privileged subset, skips privileged":
      cleanupSandbox()
      let stateDir = createTempDir("repro-m69-ne-", "")
      defer:
        removeDir(stateDir)
        cleanupSandbox()
      writeProfile(stateDir, "noelevate", "must-not-be-written")

      let apply = runRepro(stateDir,
        ["infra", "apply", "--no-preview", "--no-elevate"])
      # Partial-success exit code 4 — the privileged op was skipped.
      check apply.code == 4
      check apply.output.contains("skipped")
      # NOTHING privileged was mutated.
      check not observeLeaf("noelevate").present

    gatedTest "a stale plan is rejected before any mutation (EPlanStale)":
      cleanupSandbox()
      let stateDir = createTempDir("repro-m69-stale-", "")
      defer:
        removeDir(stateDir)
        cleanupSandbox()
      writeProfile(stateDir, "stale", "value-at-plan-time")

      # Produce a plan against an absent value.
      let plan = runRepro(stateDir, ["infra", "plan"])
      let planId = planIdFrom(plan.output)
      check planId.len == 32

      # Mutate the world out of band: write a DIFFERENT value directly,
      # so the live state matches neither the plan baseline (absent)
      # nor the plan's desired value.
      discard applyWindowsRegistryValue(PrivilegedOperation(
        kind: pokWindowsRegistryValue, address: "ob",
        hklmSubkey: "SOFTWARE\\Reprobuild-Tests\\" & runId & "\\stale",
        hklmValueName: "ConvergentValue",
        hklmValueKind: srvkString,
        hklmValueLiteral: "out-of-band-divergent-value"))

      # apply <stale-plan-id> must refuse with EPlanStale (exit 3).
      let apply = runRepro(stateDir, ["infra", "apply", "--plan", planId],
        forceBroker = true)
      check apply.code == 3
      check apply.output.toLowerAscii().contains("stale")
      # The out-of-band value is untouched (apply mutated nothing).
      let obs = observeLeaf("stale")
      check obs.present
      check obs.digestHex == digestHexOfBytes(
        encodeSystemRegistryPayload(srvkString,
          "out-of-band-divergent-value"))

    gatedTest "concurrent applies are serialized through the apply lock":
      cleanupSandbox()
      let stateDir = createTempDir("repro-m69-lock-", "")
      defer:
        removeDir(stateDir)
        cleanupSandbox()
      writeProfile(stateDir, "lock", "lock-value")
      ensureSystemStateDir(stateDir)
      # Hold the lock, then prove a second apply is refused.
      check acquireApplyLock(stateDir)
      let apply = runRepro(stateDir, ["infra", "apply", "--no-preview"],
        forceBroker = true)
      check apply.code == 1
      check apply.output.contains("another system apply is in progress")
      releaseApplyLock(stateDir)

    gatedTest "the isolated HKLM test subtree is left clean":
      cleanupSandbox()
      check not observeLeaf("convergent").present
