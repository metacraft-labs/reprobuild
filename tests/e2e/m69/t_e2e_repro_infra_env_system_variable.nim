## M69 Verification Gate: e2e_repro_infra_env_system_variable
##
## Per the M69 Phase C `env.systemVariable` driver: manage a system-
## wide environment-variable fragment under `/etc/profile.d/repro-
## system-env-<name>.sh`. The gate exercises: create the fragment,
## observe post-state byte-identical, drift, rollback removes only
## this generation's contribution.
##
## ===========================================================================
## DESTRUCTIVE GATE - REQUIRES A LINUX SANDBOX / VM. DO NOT RUN ON A
## REAL HOST.
## ===========================================================================
##
## A `env.systemVariable` apply writes a file under `/etc/profile.d/`
## - a real system path. The destructive scenario runs ONLY on POSIX
## (Linux/macOS) AND ONLY when `REPRO_M69_ENV_VM=1` is set, so a
## normal dev / CI host can never mutate `/etc/profile.d/`. Outside
## the throwaway WSL distro (or an equivalent disposable VM) the gate
## still runs its non-destructive halves: the system-PATH merge logic
## (`computeMergedSystemPath`), the fragment-content generator, the
## typed-operation wiring, and the RBEB protocol codec round-trip. No
## `skip`, no `xfail`.
##
## The PURE merge / fragment-text logic
## (`computeMergedSystemPath`, `subtractSystemPathContribution`,
## `systemEnvFragmentContent`, `systemEnvFragmentPath`) has dense
## cross-platform smoke coverage in
## `libs/repro_elevation/tests/t_smoke_repro_elevation.nim`; this
## gate links to that rather than duplicating it, and adds the typed-
## op + RBEB round-trip + sandbox-mutation pieces.

import std/[os, strutils, tempfiles, unittest]

import repro_elevation
import repro_infra

const ProjectRoot = currentSourcePath().parentDir().parentDir()
  .parentDir().parentDir()

proc reproBinary(): string =
  when defined(windows):
    ProjectRoot / "build" / "bin" / "repro.exe"
  else:
    ProjectRoot / "build" / "bin" / "repro"

let sandboxMode =
  (defined(linux) or defined(macosx)) and
  getEnv("REPRO_M69_ENV_VM") == "1"

# ===========================================================================
# NON-DESTRUCTIVE: PATH-merge spot check + fragment generation + typed-
# op wiring + codec round-trip. Always runs.
# ===========================================================================

suite "env.systemVariable: PATH merge + fragment generation spot checks":
  # The canonical coverage of `computeMergedSystemPath` and the
  # fragment generator lives in `t_smoke_repro_elevation`; these
  # spots fail loudly if the contract regresses without re-stating it.

  test "computeMergedSystemPath preserves order + dedupes":
    check computeMergedSystemPath(@["/usr/bin", "/bin"],
                                  @["/opt/repro/bin", "/usr/bin"]) ==
      @["/usr/bin", "/bin", "/opt/repro/bin"]

  test "subtractSystemPathContribution keeps non-recorded entries":
    check subtractSystemPathContribution(
      @["/usr/bin", "/opt/repro/bin", "/usr/local/bin"],
      @["/opt/repro/bin"]) ==
      @["/usr/bin", "/usr/local/bin"]

  test "the /etc/profile.d/ fragment path is name-derived + lowercased":
    check systemEnvFragmentPath("REPRO_HOME") ==
      "/etc/profile.d/repro-system-env-repro_home.sh"
    check systemEnvFragmentPath("PATH") ==
      "/etc/profile.d/repro-system-env-path.sh"

  test "fragment content: PATH-list PREPENDS while preserving host PATH":
    let frag = systemEnvFragmentContent("PATH",
      @["/opt/repro/bin"], isPathList = true)
    check frag.startsWith("export PATH=/opt/repro/bin")
    check frag.contains("${PATH:+:$PATH}")

  test "fragment content: scalar exports the single value":
    let frag = systemEnvFragmentContent("REPRO_HOME",
      @["/opt/repro"], isPathList = false)
    check frag == "export REPRO_HOME=/opt/repro\n"

suite "env.systemVariable: typed-operation wiring into the M81 closed set":

  test "an env.systemVariable system.nim resource parses and types":
    let profile = parseSystemProfile("""
env.systemVariable {
  name = "REPRO_M69_GATE_VAR"
  contribute = ["/opt/repro-m69-gate"]
  isPathList = true
}
""")
    check profile.resources.len == 1
    let r = profile.resources[0]
    check r.kind == srkEnvSystemVariable
    check r.evName == "REPRO_M69_GATE_VAR"
    check r.evContribution == @["/opt/repro-m69-gate"]
    check r.evIsPathList
    let op = toPrivilegedOperation(r)
    check op.kind == pokEnvSystemVariable
    check op.evName == "REPRO_M69_GATE_VAR"
    check op.evContribution == @["/opt/repro-m69-gate"]
    check op.evIsPathList
    check not op.evDestroy
    check requiresElevation(op.kind)
    check toPrivilegedOperation(r, destroy = true).evDestroy
    let part = partitionApply(@[op], nonPrivilegedOperationCount = 0)
    check part.privilegedOperations.len == 1

  test "an env.systemVariable operation round-trips the RBEB codec":
    let op = PrivilegedOperation(kind: pokEnvSystemVariable,
      address: "systemVariable:REPRO_M69_GATE_VAR",
      evName: "REPRO_M69_GATE_VAR",
      evContribution: @["/opt/repro-m69-gate", "/opt/x"],
      evIsPathList: true, evDestroy: false)
    check operationValidationError(op) == ""
    let dec = decodeOperation(decodeFrame(encodeOperation(
      WireOperation(operation: op, baselineDigestHex: "ab"))).body)
    check dec.operation.kind == pokEnvSystemVariable
    check dec.operation.evName == "REPRO_M69_GATE_VAR"
    check dec.operation.evContribution ==
      @["/opt/repro-m69-gate", "/opt/x"]
    check dec.operation.evIsPathList
    check dec.baselineDigestHex == "ab"

# ===========================================================================
# DESTRUCTIVE: real `/etc/profile.d/` write / drift / rollback against
# a sandboxed variable name. SANDBOX/VM-ONLY - guarded by BOTH the
# POSIX platform AND `REPRO_M69_ENV_VM=1`. Never runs on a normal
# host.
# ===========================================================================

suite "env.systemVariable: REAL fragment write / drift / rollback (sandbox-only)":

  test "real env.systemVariable lifecycle (only under Linux/macOS + the env var)":
    if not sandboxMode:
      echo "  [sandbox-gated] REPRO_M69_ENV_VM not set (or not on " &
        "Linux/macOS) - the real /etc/profile.d/ fragment write / " &
        "drift / rollback scenario is NOT EXERCISED on this host. " &
        "Run this gate inside a disposable Linux sandbox / VM with " &
        "REPRO_M69_ENV_VM=1 to exercise the real env.systemVariable " &
        "mutation. The non-destructive suites above already proved " &
        "the merge logic + fragment generation + driver wiring " &
        "without writing any system file."
    else:
      let stateDir = createTempDir("repro-m69-env-sb-", "")
      defer: removeDir(stateDir)
      ensureSystemStateDir(stateDir)

      # Sandbox the variable name on the PID so concurrent runs do not
      # collide. The fragment path is name-derived.
      let varName = "REPRO_M69_GATE_VAR_" & $getCurrentProcessId()
      let contribDir = "/opt/repro-m69-gate-" & $getCurrentProcessId()
      let fragPath = systemEnvFragmentPath(varName)

      writeFile(stateDir / "system.nim",
        "env.systemVariable {\n" &
        "  name = \"" & varName & "\"\n" &
        "  contribute = [\"" & contribDir & "\"]\n" &
        "  isPathList = true\n" &
        "}\n")
      let profileText = readFile(stateDir / "system.nim")

      var opts: ApplyOptions
      opts.stateDir = stateDir
      opts.hostIdentity = "sandbox-env-host"
      opts.reproExe = reproBinary()
      opts.elevationMode = emBroker
      opts.forceBroker = false        # sandbox runs as root
      opts.noPreview = true

      # 1. Create the fragment.
      let created = runInfraApply(profileText, opts)
      check created.errorCount == 0
      check fileExists(fragPath)
      let liveContent = readFile(fragPath)
      check liveContent.startsWith("export " & varName & "=" & contribDir)
      check liveContent.contains("${" & varName & ":+:$" & varName & "}")
      # The on-disk fragment must equal the fragment generator's output
      # byte-for-byte - that is the contract `observeEnvSystemVariable`
      # asserts.
      check liveContent == systemEnvFragmentContent(varName,
        @[contribDir], isPathList = true)

      # 2. Out-of-band edit: tamper with the fragment, then prove the
      #    re-observation detects the drift (the digest no longer
      #    matches the desired digest).
      writeFile(fragPath, "# tampered\nexport " & varName & "=/bogus\n")
      let profile = parseSystemProfile(profileText)
      let obsDrift = observeResource(profile.resources[0])
      let desiredDigest = posixSystemDesiredDigestHex(
        toPrivilegedOperation(profile.resources[0]))
      check obsDrift.present
      check obsDrift.observedDigestHex != desiredDigest

      # 3. Re-apply converges back to the declared fragment.
      let reconverged = runInfraApply(profileText, opts)
      check reconverged.errorCount == 0
      check readFile(fragPath) == systemEnvFragmentContent(varName,
        @[contribDir], isPathList = true)

      # 4. Destroy via the rollback seam: removes the fragment this
      #    generation owns. No `--accept-*-destroy` flag is required;
      #    `env.systemVariable` is not under either flag's scope (the
      #    spec gates only feature/capability/VS uninstalls and user
      #    removals).
      var destroyOpts = opts
      destroyOpts.extraDestroyResources = @[SystemResource(
        kind: srkEnvSystemVariable,
        address: "systemVariable:" & varName,
        evName: varName, evContribution: @[contribDir],
        evIsPathList: true)]
      let removed = runInfraApply("", destroyOpts)
      check removed.errorCount == 0
      check not fileExists(fragPath)
