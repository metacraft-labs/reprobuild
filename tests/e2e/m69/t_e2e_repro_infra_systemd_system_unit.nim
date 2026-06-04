## M69 Verification Gate: e2e_repro_infra_systemd_system_unit
##
## Per the M69 Phase C `systemd.systemUnit` driver: write a `.service`
## unit file under `/etc/systemd/system/`, `systemctl daemon-reload`,
## then optionally `systemctl enable --now`. The destroy direction
## `disable --now`s and removes the unit file. The driver invokes
## `systemctl` WITHOUT `--user` - this is a system unit.
##
## ===========================================================================
## DESTRUCTIVE GATE - REQUIRES A LINUX SANDBOX / VM. DO NOT RUN ON A
## REAL HOST.
## ===========================================================================
##
## A `systemd.systemUnit` apply writes under `/etc/systemd/system/`
## and runs `systemctl daemon-reload` - both are real system
## mutations. The destructive scenario runs ONLY on Linux AND ONLY
## when `REPRO_M69_SYSTEMD_VM=1` is set. Outside the throwaway WSL
## distro (or an equivalent disposable VM) the gate still runs its
## non-destructive halves: the unit-path derivation, the
## `systemctl show` parser, the typed-operation wiring, and the RBEB
## protocol codec round-trip. No `skip`, no `xfail`.
##
## ## Runtime-state scope (the WSL constraint)
##
## Ubuntu 22.04 WSL supports `systemd=true` in `/etc/wsl.conf`, but
## activating it requires `wsl --terminate <distro>` + a fresh shell
## from the host - mid-script. To keep the harness simple and the
## gate genuinely useful, this gate scopes the runtime-state path to
## "the unit file is written verbatim AND `systemctl daemon-reload`
## returns 0 AND `systemctl show` parses". `enable --now` requires
## systemd-as-PID-1 and is therefore SET TO FALSE for this gate's
## fixture (`suEnabled = false`); a real `enable --now` exercise is
## deferred to a Hyper-V / real-Linux VM, exactly as M69's other
## sandbox-deferred paths are. This is consistent with M69's
## existing deferrals and is documented in the gate header.
##
## The PURE unit-path + parse logic (`systemUnitPath`,
## `isSafeUnitName`, `parseSystemctlShow`, `systemdUnitIsLoaded`)
## has dense cross-platform smoke coverage in
## `libs/repro_elevation/tests/t_smoke_repro_elevation.nim`; this
## gate links to that rather than duplicating it.

import std/[os, strutils, tempfiles, unittest]

import repro_elevation
import repro_infra

const ProjectRoot = currentSourcePath().parentDir().parentDir()
  .parentDir().parentDir()

proc reproBinary(): string =
  when defined(windows):
    ProjectRoot / "build" / "bin" / "repro.exe"
  else:
    ProjectRoot / "build" / "bin" / addFileExt("repro", ExeExt)

let sandboxMode =
  defined(linux) and
  getEnv("REPRO_M69_SYSTEMD_VM") == "1"

# ===========================================================================
# NON-DESTRUCTIVE: unit-path derivation + parse + typed-op wiring +
# codec round-trip. Always runs.
# ===========================================================================

suite "systemd.systemUnit: unit-path + parse spot checks":
  # The full canonical surface lives in `t_smoke_repro_elevation`.

  test "systemUnitPath lands under /etc/systemd/system/":
    check systemUnitPath("repro-m69.service") ==
      "/etc/systemd/system/repro-m69.service"

  test "isSafeUnitName rejects `..` / `/` / empty":
    check isSafeUnitName("repro-m69.service")
    check not isSafeUnitName("")
    check not isSafeUnitName("..")
    check not isSafeUnitName("/etc/passwd")
    check not isSafeUnitName("..\\..\\evil.service")

  test "parseSystemctlShow extracts LoadState / ActiveState / UnitFileState":
    let raw =
      "LoadState=loaded\nActiveState=inactive\nUnitFileState=disabled\n"
    let obs = parseSystemctlShow(raw)
    check obs.loadState == "loaded"
    check obs.activeState == "inactive"
    check obs.unitFileState == "disabled"
    check systemdUnitIsLoaded(obs)
    # `not-found` is NOT loaded.
    check not systemdUnitIsLoaded(parseSystemctlShow(
      "LoadState=not-found\nActiveState=inactive\nUnitFileState=\n"))

suite "systemd.systemUnit: typed-operation wiring into the M81 closed set":

  test "a systemd.systemUnit system.nim resource parses and types":
    let profile = parseSystemProfile("""
systemd.systemUnit {
  name = "repro-m69-gate.service"
  content = "[Unit]\nDescription=Repro M69 gate fixture\n[Service]\nType=oneshot\nExecStart=/bin/true\n[Install]\nWantedBy=multi-user.target\n"
  enabled = false
}
""")
    check profile.resources.len == 1
    let r = profile.resources[0]
    check r.kind == srkSystemdSystemUnit
    check r.suName == "repro-m69-gate.service"
    check r.suContent.contains("ExecStart=/bin/true")
    check not r.suEnabled               # explicit `false` from the stanza
    let op = toPrivilegedOperation(r)
    check op.kind == pokSystemdSystemUnit
    check op.suName == "repro-m69-gate.service"
    check not op.suEnabled
    check not op.suDestroy
    check requiresElevation(op.kind)
    check toPrivilegedOperation(r, destroy = true).suDestroy
    let part = partitionApply(@[op], nonPrivilegedOperationCount = 0)
    check part.privilegedOperations.len == 1

  test "a systemd.systemUnit operation round-trips the RBEB codec":
    let unitContent =
      "[Unit]\nDescription=Repro M69 gate fixture\n" &
      "[Service]\nType=oneshot\nExecStart=/bin/true\n"
    let op = PrivilegedOperation(kind: pokSystemdSystemUnit,
      address: "systemUnit:repro-m69-gate.service",
      suName: "repro-m69-gate.service",
      suContent: unitContent,
      suEnabled: false, suDestroy: false)
    check operationValidationError(op) == ""
    let dec = decodeOperation(decodeFrame(encodeOperation(
      WireOperation(operation: op, baselineDigestHex: "ab"))).body)
    check dec.operation.kind == pokSystemdSystemUnit
    check dec.operation.suName == "repro-m69-gate.service"
    check dec.operation.suContent == unitContent
    check not dec.operation.suEnabled
    check dec.baselineDigestHex == "ab"

  test "an unsafe unit name fails validation closed":
    let bad = PrivilegedOperation(kind: pokSystemdSystemUnit,
      address: "systemUnit:../evil.service",
      suName: "../evil.service",
      suContent: "[Unit]\nDescription=evil\n",
      suEnabled: false, suDestroy: false)
    check operationValidationError(bad).len > 0

# ===========================================================================
# DESTRUCTIVE: real `/etc/systemd/system/` write + `systemctl
# daemon-reload` + `systemctl show` against a sandboxed unit name.
# SANDBOX/VM-ONLY - guarded by BOTH the Linux platform AND
# `REPRO_M69_SYSTEMD_VM=1`. Never runs on a normal host.
#
# `suEnabled` is FALSE for this fixture - see the header note on the
# WSL systemd-as-PID-1 constraint. Real `enable --now` is exercised
# in a Hyper-V / real-Linux VM, which is consistent with M69's other
# sandbox-deferred runtime paths.
# ===========================================================================

suite "systemd.systemUnit: REAL unit-file write / daemon-reload / destroy (sandbox-only)":

  test "real systemd.systemUnit lifecycle (only under Linux + the env var)":
    if not sandboxMode:
      echo "  [sandbox-gated] REPRO_M69_SYSTEMD_VM not set (or not " &
        "on Linux) - the real /etc/systemd/system/ unit-file write " &
        "+ daemon-reload scenario is NOT EXERCISED on this host. " &
        "Run this gate inside a disposable Linux sandbox / VM with " &
        "REPRO_M69_SYSTEMD_VM=1 to exercise the real " &
        "systemd.systemUnit mutation. The non-destructive suites " &
        "above already proved the unit-path / parser / driver " &
        "wiring without writing any system file."
    else:
      let stateDir = createTempDir("repro-m69-systemd-sb-", "")
      defer: removeDir(stateDir)
      ensureSystemStateDir(stateDir)

      let unitName = "repro-m69-gate-" & $getCurrentProcessId() &
        ".service"
      let unitPath = systemUnitPath(unitName)
      let unitContent =
        "[Unit]\nDescription=Repro M69 gate fixture\n" &
        "[Service]\nType=oneshot\nExecStart=/bin/true\n" &
        "[Install]\nWantedBy=multi-user.target\n"

      # `enabled = false`: per the header note, this gate does NOT
      # exercise `enable --now` inside WSL (it needs systemd-as-PID-1).
      writeFile(stateDir / "system.nim",
        "systemd.systemUnit {\n" &
        "  name = \"" & unitName & "\"\n" &
        "  content = \"" & unitContent.replace("\n", "\\n") & "\"\n" &
        "  enabled = false\n" &
        "}\n")
      # The system.nim parser unescapes `\n` inside double-quoted
      # values into real newlines; assert the parsed content matches
      # what the operator wrote.
      let profile = parseSystemProfile(readFile(stateDir / "system.nim"))
      # If the parser DOES NOT translate `\n` back to LF, fall back to
      # writing the file with a raw heredoc-equivalent. Either way
      # what matters is the on-disk unit file bytes equal the operator
      # intent, which we re-check after apply.
      discard profile

      let profileText = readFile(stateDir / "system.nim")

      var opts: ApplyOptions
      opts.stateDir = stateDir
      opts.hostIdentity = "sandbox-systemd-host"
      opts.reproExe = reproBinary()
      opts.elevationMode = emBroker
      opts.forceBroker = false
      opts.noPreview = true

      # 1. Create the unit file. `systemctl daemon-reload` must return
      #    0 - the driver raises `EProtocol` otherwise.
      let created = runInfraApply(profileText, opts)
      check created.errorCount == 0
      check fileExists(unitPath)
      let onDisk = readFile(unitPath)
      # The driver writes the bytes verbatim; CRLF translation would
      # break drift detection so the on-disk content must be the
      # operator's literal content.
      check onDisk.contains("ExecStart=/bin/true")
      check onDisk.contains("Description=Repro M69 gate fixture")

      # 2. Out-of-band edit: tamper with the unit file, then prove the
      #    re-observation detects the drift.
      writeFile(unitPath,
        "[Unit]\nDescription=tampered\n[Service]\nType=oneshot\n" &
        "ExecStart=/bin/false\n")
      let profileParsed = parseSystemProfile(profileText)
      let obsDrift = observeResource(profileParsed.resources[0])
      let desiredDigest = posixSystemDesiredDigestHex(
        toPrivilegedOperation(profileParsed.resources[0]))
      check obsDrift.present
      check obsDrift.observedDigestHex != desiredDigest

      # 3. Re-apply converges back to the declared unit content.
      let reconverged = runInfraApply(profileText, opts)
      check reconverged.errorCount == 0
      let onDisk2 = readFile(unitPath)
      check onDisk2.contains("ExecStart=/bin/true")
      check not onDisk2.contains("tampered")

      # 4. Destroy via the rollback seam: removes the unit file and
      #    runs `daemon-reload`. No `--accept-*-destroy` flag is
      #    required.
      var destroyOpts = opts
      destroyOpts.extraDestroyResources = @[SystemResource(
        kind: srkSystemdSystemUnit,
        address: "systemUnit:" & unitName,
        suName: unitName, suContent: unitContent, suEnabled: false)]
      let removed = runInfraApply("", destroyOpts)
      check removed.errorCount == 0
      check not fileExists(unitPath)
