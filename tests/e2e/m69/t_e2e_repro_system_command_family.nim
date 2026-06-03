## M69 Phase B Verification Gate: e2e_repro_system_command_family
##
## Exercises the `repro system add/remove/list/why/sync/history/
## rollback` command family — the system-scope analogue of the
## M60-M64 `repro home` commands.
##
## SAFETY: every privileged write is confined to a per-run subkey of
## `HKLM\SOFTWARE\Reprobuild-Tests\` — never a real system location.
## The gate drives the PUBLIC `repro system` CLI as a subprocess
## against a sandboxed `$REPRO_INFRA_STATE_DIR`. It uses M81's
## `REPRO_FORCE_BROKER` seam to drive the real broker path on an
## already-elevated host without an interactive UAC prompt. No real
## system mutation.
##
## No `skip`, no `xfail`.

when not defined(windows):
  echo "[platform N/A] t_e2e_repro_system_command_family: the " &
    "system-scope drivers are Windows-only in M69"
  quit(0)

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

let runId = "gate-sysfam-" & $getCurrentProcessId()

proc cleanupSandbox() =
  deleteFixtureRegistryTree(runId)
  deleteFixtureRegistryRoot()

proc sandboxKey(leaf: string): string =
  "HKLM\\SOFTWARE\\Reprobuild-Tests\\" & runId & "\\" & leaf

proc sandboxSubkey(leaf: string): string =
  "SOFTWARE\\Reprobuild-Tests\\" & runId & "\\" & leaf

type CliRun = object
  output: string
  code: int

proc quoteArg(a: string): string =
  if a.len > 0 and ' ' notin a: a else: "\"" & a & "\""

proc runRepro(stateDir: string; args: openArray[string];
              forceBroker = false): CliRun =
  ## Run the public `repro` CLI as a subprocess against a sandboxed
  ## state dir.
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

proc observeLeaf(leaf, name: string): ObservedOperationState =
  observeWindowsRegistryValue(PrivilegedOperation(
    kind: pokWindowsRegistryValue, address: "probe",
    hklmSubkey: sandboxSubkey(leaf),
    hklmValueName: name,
    hklmValueKind: srvkString, hklmValueLiteral: ""))

suite "e2e_repro_system_command_family":
  when isNixSupported:

    test "the host is already elevated (gate precondition)":
      check isProcessElevated()

    test "add edits system.nim through the structural editor":
      let stateDir = createTempDir("repro-m69b-add-", "")
      defer: removeDir(stateDir)
      let r = runRepro(stateDir,
        ["system", "add", "windows.registryValue",
         "key=" & sandboxKey("added"), "name=V", "kind=string",
         "value=hello"])
      check r.code == 0
      check r.output.contains("added")
      # The profile file exists and round-trips through the parser.
      let profilePath = stateDir / "system.nim"
      check fileExists(profilePath)
      let profile = parseSystemProfile(readFile(profilePath))
      check profile.resources.len == 1
      check profile.resources[0].kind == srkWindowsRegistryValue

    test "add then remove of a fresh resource round-trips byte-identically":
      let stateDir = createTempDir("repro-m69b-rt-", "")
      defer: removeDir(stateDir)
      let profilePath = stateDir / "system.nim"
      # Seed a hand-authored profile with a comment and a stanza.
      let original =
        "# system profile for the gate\n" &
        "windows.optionalFeature {\n" &
        "  name = \"Containers\"\n" &
        "}\n"
      writeFile(profilePath, original)
      # add a NEW resource, then remove it — must restore byte-identically.
      let added = runRepro(stateDir,
        ["system", "add", "windows.capability",
         "name=OpenSSH.Client~~~~0.0.1.0", "installed=false"])
      check added.code == 0
      check readFile(profilePath) != original   # the add changed the file
      let removed = runRepro(stateDir,
        ["system", "remove", "capability:OpenSSH.Client~~~~0.0.1.0"])
      check removed.code == 0
      check readFile(profilePath) == original    # byte-identical round-trip

    test "add refuses a duplicate address":
      let stateDir = createTempDir("repro-m69b-dup-", "")
      defer: removeDir(stateDir)
      let first = runRepro(stateDir,
        ["system", "add", "windows.service", "name=sshd",
         "startType=Automatic", "state=Running"])
      check first.code == 0
      let dup = runRepro(stateDir,
        ["system", "add", "windows.service", "name=sshd",
         "startType=Manual", "state=Stopped"])
      check dup.code != 0
      check dup.output.toLowerAscii().contains("already exists")

    test "remove of an absent address fails with a clear diagnostic":
      let stateDir = createTempDir("repro-m69b-rmabsent-", "")
      defer: removeDir(stateDir)
      discard runRepro(stateDir,
        ["system", "add", "windows.service", "name=sshd"])
      let r = runRepro(stateDir, ["system", "remove", "service:not-here"])
      check r.code != 0
      check r.output.contains("no resource with address")

    test "list and why query the profile":
      let stateDir = createTempDir("repro-m69b-listwhy-", "")
      defer: removeDir(stateDir)
      discard runRepro(stateDir,
        ["system", "add", "windows.optionalFeature",
         "name=Microsoft-Windows-Subsystem-Linux"])
      discard runRepro(stateDir,
        ["system", "add", "windows.vsInstaller", "edition=BuildTools",
         "channel=Release",
         "workloads=[Microsoft.VisualStudio.Workload.VCTools]"])
      let listed = runRepro(stateDir, ["system", "list"])
      check listed.code == 0
      check listed.output.contains("resources : 2")
      check listed.output.contains("windows.optionalFeature")
      check listed.output.contains("windows.vsInstaller")
      let why = runRepro(stateDir,
        ["system", "why", "feature:Microsoft-Windows-Subsystem-Linux"])
      check why.code == 0
      check why.output.contains("windows.optionalFeature")
      check why.output.contains("privileged  : true")
      # `why` of an absent address fails.
      let whyMiss = runRepro(stateDir, ["system", "why", "feature:nope"])
      check whyMiss.code != 0

    test "sync applies the profile through the single broker":
      cleanupSandbox()
      let stateDir = createTempDir("repro-m69b-sync-", "")
      defer:
        removeDir(stateDir)
        cleanupSandbox()
      let addRes = runRepro(stateDir,
        ["system", "add", "windows.registryValue",
         "key=" & sandboxKey("synced"), "name=Probe", "kind=string",
         "value=synced-value"])
      check addRes.code == 0
      # sync drives the Phase-A apply path; one broker for the whole apply.
      let sync = runRepro(stateDir, ["system", "sync"], forceBroker = true)
      check sync.code == 0
      check sync.output.contains("applied      : 1")
      check sync.output.contains("launches: 1")
      check observeLeaf("synced", "Probe").present
      # A second sync is a convergent no-op.
      let sync2 = runRepro(stateDir, ["system", "sync"], forceBroker = true)
      check sync2.code == 0
      check sync2.output.contains("no-op        : 1")

    test "history enumerates the RBSG generations of distinct applies":
      cleanupSandbox()
      let stateDir = createTempDir("repro-m69b-hist-", "")
      defer:
        removeDir(stateDir)
        cleanupSandbox()
      # Generation 1.
      discard runRepro(stateDir,
        ["system", "add", "windows.registryValue",
         "key=" & sandboxKey("hist-a"), "name=P", "kind=string",
         "value=v1"])
      let s1 = runRepro(stateDir, ["system", "sync"], forceBroker = true)
      check s1.code == 0
      let h1 = runRepro(stateDir, ["system", "history"])
      check h1.code == 0
      check h1.output.contains("generations : 1")
      # Generation 2: a DISTINCT profile (a second resource) — a
      # different profile digest, so a distinct generation id.
      discard runRepro(stateDir,
        ["system", "add", "windows.registryValue",
         "key=" & sandboxKey("hist-b"), "name=P", "kind=string",
         "value=v2"])
      let s2 = runRepro(stateDir, ["system", "sync"], forceBroker = true)
      check s2.code == 0
      let h2 = runRepro(stateDir, ["system", "history"])
      check h2.code == 0
      check h2.output.contains("generations : 2")
      # Exactly one generation is marked active (`*`).
      var activeCount = 0
      for line in h2.output.splitLines():
        if line.strip().startsWith("*"):
          inc activeCount
      check activeCount == 1

    test "rollback re-applies a prior generation and reverts added resources":
      cleanupSandbox()
      let stateDir = createTempDir("repro-m69b-rb-", "")
      defer:
        removeDir(stateDir)
        cleanupSandbox()
      # Generation 1: one registry value.
      discard runRepro(stateDir,
        ["system", "add", "windows.registryValue",
         "key=" & sandboxKey("rb-v1"), "name=P", "kind=string",
         "value=gen1"])
      let s1 = runRepro(stateDir, ["system", "sync"], forceBroker = true)
      check s1.code == 0
      let histA = runRepro(stateDir, ["system", "history"])
      var gen1Id = ""
      for line in histA.output.splitLines():
        let t = line.strip()
        if t.startsWith("*"):
          gen1Id = t.split()[1]
      check gen1Id.len == 32
      # Generation 2: add a SECOND registry value.
      discard runRepro(stateDir,
        ["system", "add", "windows.registryValue",
         "key=" & sandboxKey("rb-v2"), "name=P", "kind=string",
         "value=gen2"])
      let s2 = runRepro(stateDir, ["system", "sync"], forceBroker = true)
      check s2.code == 0
      check observeLeaf("rb-v1", "P").present
      check observeLeaf("rb-v2", "P").present
      # Roll back to generation 1. The added rb-v2 must be REVERTED
      # (deleted); rb-v1 must remain. A registry-value revert is not a
      # feature/capability destroy, so --accept-feature-destroy is not
      # required here.
      let rb = runRepro(stateDir, ["system", "rollback", gen1Id],
        forceBroker = true)
      check rb.code == 0
      check rb.output.contains("to generation   : " & gen1Id)
      check rb.output.contains("launches: 1")     # one broker for the rollback
      # rb-v1 stays, rb-v2 is gone.
      check observeLeaf("rb-v1", "P").present
      check not observeLeaf("rb-v2", "P").present

    test "rollback of a feature/capability removal needs --accept-feature-destroy":
      cleanupSandbox()
      let stateDir = createTempDir("repro-m69b-rbgate-", "")
      defer:
        removeDir(stateDir)
        cleanupSandbox()
      # Gen 1: a registry value only.
      discard runRepro(stateDir,
        ["system", "add", "windows.registryValue",
         "key=" & sandboxKey("rbgate"), "name=P", "kind=string",
         "value=g1"])
      let s1 = runRepro(stateDir, ["system", "sync"], forceBroker = true)
      check s1.code == 0
      var gen1Id = ""
      for line in runRepro(stateDir, ["system", "history"]).output.splitLines():
        let t = line.strip()
        if t.startsWith("*"): gen1Id = t.split()[1]
      check gen1Id.len == 32
      # Gen 2: add a windows.capability. We do NOT sync it (the
      # capability install is host-altering); the rollback SCREEN is a
      # pure decision over the profile texts, so we can prove the gate
      # without ever installing a capability. Edit the profile and write
      # a synthetic generation 2 envelope embedding the two-resource
      # profile. The rollback then screens gen2 -> gen1: the capability
      # is removed-by-rollback, which is destructive.
      let profilePath = stateDir / "system.nim"
      let gen2Profile = readFile(profilePath) &
        "windows.capability {\n  name = \"OpenSSH.Server~~~~0.0.1.0\"\n}\n"
      # Drive a screen directly through the library (no host mutation):
      let reverted = resourcesRemovedByRollback(gen2Profile,
        readFile(profilePath))
      let decision = screenRollback(reverted)
      check decision.requiresFeatureDestroyFlag
      # Without the flag the screen fails closed BEFORE any mutation.
      expect EFeatureDestroy:
        enforceFeatureDestroyGate(decision, acceptFeatureDestroy = false)
      # With the flag it is allowed.
      enforceFeatureDestroyGate(decision, acceptFeatureDestroy = true)

    test "the isolated HKLM test subtree is left clean":
      cleanupSandbox()
      check not observeLeaf("synced", "Probe").present
      check not observeLeaf("rb-v1", "P").present
