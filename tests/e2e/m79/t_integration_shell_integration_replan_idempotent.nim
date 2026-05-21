## M79 gate: `integration_shell_integration_replan_idempotent`.
##
## Per the M79 milestone verification block:
##
##   A `shell.integration` resource applied once and then re-planned
##   with no change re-plans as `no-op` (a clean cache-hit), not
##   `update` — proving apply idempotency. A deliberate edit of the
##   managed block's content between apply and re-plan is still
##   detected as drift.
##
## Root cause M79 fixes: `digestOfResource`'s `rkShellIntegration`
## branch hashed the shell-integration block content VERBATIM, but
## the shared managed-block writer appends a trailing `\n` to a
## non-empty body. The desired-state digest (content) therefore never
## equalled the on-disk observed digest (content + `\n`), so an
## unchanged `shell.integration` resource re-planned as `update` on
## every `repro home apply`. The fix mirrors the trailing-newline
## normalization the `rkFsManagedBlock` branch already applied.
##
## The gate drives the REAL `repro` binary against a fixture profile
## whose `resources:` block declares a `shell.integration` resource
## (M78 production source — no `REPRO_TEST_RESOURCES` seam). It runs
## in an isolated `$HOME` / state-dir / store so the real environment
## is never touched. The fixture's block content deliberately does
## NOT end with `\n` so the writer's normalization is exercised.
##
## Strong assertions: the gate asserts the EXACT per-resource action
## reported by `repro home plan` (`no-op` vs `update` vs drift) — it
## does not merely check that apply exits 0. Without the M79 fix the
## re-plan asserts would genuinely fail (the resource line would read
## `update`, not `no-op`).

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_home_generations
import repro_home_resources

const ProjectRoot = currentSourcePath().parentDir().parentDir()
  .parentDir().parentDir()
const FixtureSrc = currentSourcePath().parentDir().parentDir()
  .parentDir() / "fixtures" / "m79" / "shell_integration_idempotent"

proc reproBinary(): string =
  let exeName = when defined(windows): "repro.exe" else: "repro"
  let candidate = ProjectRoot / "build" / "bin" / exeName
  doAssert fileExists(candidate),
    "repro binary not found at " & candidate &
    "; build with `just build` first"
  candidate

proc writeFixtureExe(path: string) =
  when defined(windows):
    writeFile(path,
      "@echo off\r\n" &
      "if /I \"%1\"==\"--version\" (\r\n" &
      "  echo m79-fixture 1.0.0\r\n" &
      "  exit /b 0\r\n" &
      ")\r\n" &
      "exit /b 0\r\n")
  else:
    writeFile(path, "#!/bin/sh\necho fixture\n")

proc runRepro(envOverrides: openArray[tuple[k, v: string]];
              args: openArray[string]):
    tuple[exitCode: int; output: string] =
  var processEnv = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    processEnv[k] = v
  for kv in envOverrides:
    processEnv[kv.k] = kv.v
  let p = startProcess(reproBinary(), args = @args, env = processEnv,
    options = {poUsePath, poStdErrToStdOut})
  let stream = p.outputStream()
  var combined = ""
  while not stream.atEnd():
    let chunk = stream.readAll()
    if chunk.len == 0: break
    combined.add chunk
  let code = p.waitForExit()
  p.close()
  result = (exitCode: code, output: combined)

proc resourcePlanLine(planOutput, address: string): string =
  ## Extract the `repro home plan` per-resource line for `address`.
  ## `renderPlan` (`repro_home_resources/plan.nim`) emits one line per
  ## resource of the form
  ##   `  <action>    <address> (<kind>)`
  ## (the action verb / address / kind come from `lifecycle.summarize`).
  ## Returns the trimmed line, or "" if no line for that address was
  ## found.
  for rawLine in planOutput.splitLines():
    let trimmed = rawLine.strip()
    if trimmed.len == 0:
      continue
    # The first whitespace-delimited token is the action verb; the
    # second is the resource address.
    let fields = trimmed.splitWhitespace()
    if fields.len >= 2 and fields[1] == address:
      return trimmed
  ""

# The `shell.integration` resource declared in the fixture's
# `resources:` block. The content deliberately has NO trailing `\n`.
const
  ShellRcRel = ".m79-shell-integration-rc"
  ShellBlockId = "m79-shell-block"
  ShellBlockBody = "eval \"$(repro hook init)\""
  ShellAddress = "shellHook"

suite "M79 gate: integration_shell_integration_replan_idempotent":
  test "an unchanged `shell.integration` resource re-plans as no-op; " &
       "a content edit still drifts":
    when not defined(windows):
      checkpoint "platform-skip: M79 gate exercises the Windows leg " &
        "(the shell.integration driver uses the PowerShell-profile " &
        "managed-block writer on Windows)"
      check true
      return

    let tempRoot = createTempDir("repro-m79-gate-", "")
    defer:
      try: removeDir(tempRoot) except OSError: discard
    let stateDir = tempRoot / "state"
    let storeRoot = tempRoot / "store"
    let profileDir = tempRoot / "profile"
    let homeDir = tempRoot / "home"
    let fixtureDir = tempRoot / "fixtures"
    createDir(stateDir); createDir(storeRoot); createDir(homeDir)
    createDir(profileDir); createDir(fixtureDir)
    copyFile(FixtureSrc / "home.nim", profileDir / "home.nim")
    let exe = fixtureDir / "m79-fixture.cmd"
    writeFixtureExe(exe)

    # NOTE: REPRO_TEST_RESOURCES is deliberately NOT set — the
    # `resources:` block in the fixture profile is the sole source
    # of the `shell.integration` resource (M78 production path).
    let baseEnv = @[
      (k: "REPRO_HOME_PROFILE_DIR", v: profileDir),
      (k: "REPRO_HOME_STATE_DIR", v: stateDir),
      (k: "REPRO_STORE_ROOT", v: storeRoot),
      (k: "HOME", v: homeDir),
      (k: "USERPROFILE", v: homeDir),
      (k: "REPRO_HOST", v: "m79-gate-host"),
      (k: "REPRO_HOME_PACKAGE_CATALOG", v: "m79-fixture"),
      (k: "REPRO_TEST_PACKAGE_SOURCE", v: "m79-fixture=" & exe)]

    let shellRc = homeDir / ShellRcRel

    # ---- Apply 1: materializes the shell.integration resource ----
    let r1 = runRepro(baseEnv, ["home", "apply"])
    check r1.exitCode == 0
    check r1.output.contains("applied generation ")

    # The shell-integration managed block is written with its
    # repro-managed sentinels and its body.
    check fileExists(shellRc)
    let rcContent = readFile(shellRc)
    check rcContent.contains("repro-managed:" & ShellBlockId)
    check rcContent.contains(ShellBlockBody)
    # The writer normalizes the body to end with a single `\n`; the
    # fixture content deliberately lacks one, so the on-disk body
    # is content + "\n" — exactly the bytes M79 makes the digest
    # hash. (Confirms the writer/digest symmetry the gate verifies.)
    let openS = "# >>> repro-managed:" & ShellBlockId & " >>>"
    let closeS = "# <<< repro-managed:" & ShellBlockId & " <<<"
    block confirmTrailingNewline:
      let openIdx = rcContent.find(openS)
      let closeIdx = rcContent.find(closeS)
      check openIdx >= 0
      check closeIdx > openIdx
      let lineEnd = rcContent.find('\n', openIdx)
      check lineEnd >= 0
      var closeLineStart = closeIdx
      while closeLineStart > 0 and rcContent[closeLineStart - 1] != '\n':
        dec closeLineStart
      let onDiskBody = rcContent[lineEnd + 1 ..< closeLineStart]
      check onDiskBody == ShellBlockBody & "\n"

    # ---- Re-plan with NO change: the resource is a clean no-op ----
    # `repro home plan` renders one line per resource with the EXACT
    # action verb (from `lifecycle.summarize`). The M79 fix makes this
    # `no-op`; before the fix the verbatim-content digest mismatched
    # the on-disk (content + `\n`) digest and this line read `update`
    # instead — so this assertion genuinely fails on the unfixed code.
    let planNoChange = runRepro(baseEnv, ["home", "plan"])
    check planNoChange.exitCode == 0
    let noChangeLine = resourcePlanLine(planNoChange.output, ShellAddress)
    check noChangeLine.len > 0
    # STRONG assertion on the exact action — not just "exits 0".
    check noChangeLine.startsWith("no-op")
    check not noChangeLine.startsWith("update")
    check not noChangeLine.startsWith("DRIFT")
    # The whole plan settles to zero drift.
    check planNoChange.output.contains("0 drift(s)")

    # ---- Re-apply with NO change: a clean cache-hit no-op ----
    let r2 = runRepro(baseEnv, ["home", "apply"])
    check r2.exitCode == 0
    check r2.output.contains("no-op")
    # The live block is byte-identical to apply 1's output.
    check readFile(shellRc) == rcContent

    # ---- Deliberate edit of the managed block content -> drift ----
    # Edit the managed-block BODY (between the sentinels) out-of-band.
    # This is a genuine content change: the digests must differ and
    # the resource must be detected as drift (M72/M68 drift contract
    # unchanged — M79 must NOT weaken drift detection).
    let driftOrig = readFile(shellRc)
    let driftOpenIdx = driftOrig.find(openS)
    let driftCloseIdx = driftOrig.find(closeS)
    check driftOpenIdx >= 0
    check driftCloseIdx > driftOpenIdx
    let driftLineEnd = driftOrig.find('\n', driftOpenIdx)
    let edited = driftOrig[0 .. driftLineEnd] &
      "USER MUTATED THE SHELL HOOK\n" & driftOrig[driftCloseIdx .. ^1]
    writeFile(shellRc, edited)

    # `repro home plan` surfaces the drift on the shell.integration
    # resource — EXACT action assertion (`DRIFT`), not a generic
    # "non-zero exit". A genuine content change MUST still drift; the
    # M79 fix does not weaken the M72/M68 drift contract.
    let driftPlan = runRepro(baseEnv, ["home", "plan"])
    check driftPlan.exitCode != 0
    let driftLine = resourcePlanLine(driftPlan.output, ShellAddress)
    check driftLine.len > 0
    check driftLine.startsWith("DRIFT")
    check not driftLine.startsWith("no-op")
    check not driftLine.startsWith("update")
    check driftPlan.output.contains("1 drift(s)")

    # `repro home apply` fails closed on the drift (does NOT silently
    # overwrite the user's edit).
    let r3 = runRepro(baseEnv, ["home", "apply"])
    check r3.exitCode != 0
    check (r3.output.contains("drift detected") or
           r3.output.contains("DRIFT") or
           r3.output.contains("drift"))
    # The user's out-of-band edit is left intact (fail-closed).
    check readFile(shellRc).contains("USER MUTATED THE SHELL HOOK")

    # ---- --reconcile-drift collapses the drift back to managed state
    let r4 = runRepro(baseEnv & @[
      (k: "REPRO_HOME_APPLY_RECONCILE_DRIFT", v: "1")], ["home", "apply"])
    check r4.exitCode == 0
    check readFile(shellRc).contains(ShellBlockBody)
    check not readFile(shellRc).contains("USER MUTATED THE SHELL HOOK")

    # ---- Re-plan after reconcile: back to a clean no-op ----
    # Proves idempotency holds again after the reconcile write — the
    # reconciled on-disk bytes digest-match the desired state.
    let planAfterReconcile = runRepro(baseEnv, ["home", "plan"])
    check planAfterReconcile.exitCode == 0
    let reconciledLine = resourcePlanLine(
      planAfterReconcile.output, ShellAddress)
    check reconciledLine.len > 0
    check reconciledLine.startsWith("no-op")
    check not reconciledLine.startsWith("update")
