## M6 Phase-5 Gate: e2e_macos_phase5_os_hostname
##
## Per the macOS Mac-host validation checklist in
## `metacraft/reprobuild-specs/Nix-Flake-Migration-Roadmap.md` ("Drivers
## with shipped macOS arms - never E2E-validated"), the `osHostname`
## POSIX arm (in
## `libs/repro_elevation/src/repro_elevation/posix_system_driver.nim`,
## `applyPosixOsHostname`) has had only a Linux WSL gate
## (`tests/e2e/m69/t_e2e_repro_infra_os_hostname_posix_vm.nim`,
## `defined(linux)` only). On macOS the apply must write the three
## hostname slots via `scutil --set ComputerName/HostName/
## LocalHostName`; the verification reads all three back via
## `scutil --get`. This gate is the M6 macOS scaffolding; M9
## populates the concrete apply + triple-slot verification + destroy
## scenario.
##
## M6 deliverable: the non-destructive half asserts the pure
## hostname parser (`parseHostnameOutput`), the canonicalizers
## (`canonicalHostnameState`), the RFC 1123 allowlist
## (`isSafeHostname`), the typed-operation wiring, and the RBEB
## codec round-trip.
##
## ===========================================================================
## DESTRUCTIVE GATE - REQUIRES A macOS SANDBOX / VM. DO NOT RUN ON A
## REAL HOST.
## ===========================================================================
##
## The destructive half invokes `scutil --set` (requires sudo) and
## mutates all three macOS hostname slots. Guarded by BOTH
## `defined(macosx)` AND `REPRO_PHASE5_MACOS_HOSTNAME_VM=1`. The host-
## side runner cross-builds this binary, copies it into a freshly-
## cloned Tart macOS guest, and runs it under `sudo -E -n` with the
## env var set.

import std/[os, osproc, strutils, unittest]

when defined(posix):
  from std/posix import geteuid

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
  defined(macosx) and
  getEnv("REPRO_PHASE5_MACOS_HOSTNAME_VM") == "1"

# ===========================================================================
# NON-DESTRUCTIVE: pure parser + canonicalizer + RFC 1123 allowlist +
# typed-op wiring + RBEB codec. Always runs.
# ===========================================================================

suite "os.hostname: hostname parser + canonicalizer":

  test "parseHostnameOutput strips trailing whitespace":
    check parseHostnameOutput("test-host\n") == "test-host"
    check parseHostnameOutput("test-host") == "test-host"

  test "canonicalHostnameState normalizes case":
    # macOS scutil round-trips uppercase to lowercase; the canonical
    # form is lowercase so a TestHost vs testhost compare equal.
    check canonicalHostnameState("TestHost") ==
          canonicalHostnameState("testhost")

suite "os.hostname: RFC 1123 allowlist":

  test "isSafeHostname accepts RFC 1123":
    check isSafeHostname("test-host")
    check isSafeHostname("repro-m6-1")
    check not isSafeHostname("")
    check not isSafeHostname("-leading-dash")
    check not isSafeHostname("trailing-dash-")
    check not isSafeHostname("has spaces")
    check not isSafeHostname("has;semicolon")

suite "os.hostname: typed-operation wiring into the M81 closed set":

  test "an os.hostname system.nim resource parses and types":
    let profile = parseSystemProfile("""
os.hostname {
  hostname = "repro-m6-test"
}
""")
    check profile.resources.len == 1
    let r = profile.resources[0]
    check r.kind == srkOsHostname
    check r.hostnameName == "repro-m6-test"
    let op = toPrivilegedOperation(r)
    check op.kind == pokOsHostname
    check op.hostnameName == "repro-m6-test"
    check requiresElevation(op.kind)
    let part = partitionApply(@[op], nonPrivilegedOperationCount = 0)
    check part.privilegedOperations.len == 1

  test "an os.hostname operation round-trips the RBEB codec":
    let op = PrivilegedOperation(kind: pokOsHostname,
      address: "hostname:repro-m6-test",
      hostnameName: "repro-m6-test")
    check operationValidationError(op) == ""
    let dec = decodeOperation(decodeFrame(encodeOperation(
      WireOperation(operation: op, baselineDigestHex: "ab"))).body)
    check dec.operation.kind == pokOsHostname
    check dec.operation.hostnameName == "repro-m6-test"
    check dec.baselineDigestHex == "ab"

  test "an unsafe hostname fails validation closed":
    let bad = PrivilegedOperation(kind: pokOsHostname,
      address: "hostname:evil",
      hostnameName: "evil host;rm -rf /")
    check operationValidationError(bad).len > 0

# ===========================================================================
# DESTRUCTIVE: real `scutil --set ComputerName/HostName/LocalHostName`.
# SANDBOX/VM-ONLY - guarded by BOTH macOS +
# `REPRO_PHASE5_MACOS_HOSTNAME_VM=1`. The host-side runner wraps this
# binary in `sudo -E -n` inside the guest (scutil --set + the `hostname`
# CLI fallback both need root).
# ===========================================================================

when defined(macosx):

  type
    HostnameSlots = object
      computerName: string
      hostName: string
      localHostName: string

  proc scutilGet(slot: string): string =
    ## Out-of-band `scutil --get <slot>` read — independent of the
    ## driver's own observation codepath. Returns the raw value with
    ## trailing whitespace stripped. `scutil --get HostName` on a
    ## host where HostName was never set prints `HostName: not set`
    ## to stderr and exits non-zero; we capture that and return "" in
    ## that case so callers can distinguish "set to <name>" from
    ## "intentionally unset".
    let (output, code) = execCmdEx("scutil --get " & slot,
      options = {poUsePath, poStdErrToStdOut})
    if code != 0:
      return ""
    output.strip()

  proc readAllSlots(): HostnameSlots =
    HostnameSlots(
      computerName: scutilGet("ComputerName"),
      hostName: scutilGet("HostName"),
      localHostName: scutilGet("LocalHostName"))

  proc canonicalSlotsForCompare(slots: HostnameSlots):
      tuple[c, h, l: string] =
    ## scutil canonicalizes case (e.g. LocalHostName is lowercased,
    ## HostName preserves caller case). We compare via the same
    ## `canonicalHostnameState` the driver uses so a hostname like
    ## `test-host-12345` compares equal across all three slots
    ## regardless of macOS's per-slot normalization quirks.
    (c: canonicalHostnameState(slots.computerName),
     h: canonicalHostnameState(slots.hostName),
     l: canonicalHostnameState(slots.localHostName))

suite "os.hostname (macOS): REAL apply / verify / destroy (sandbox-only)":

  test "real os.hostname lifecycle (only under macOS + env var)":
    if not sandboxMode:
      echo "  [sandbox-gated] REPRO_PHASE5_MACOS_HOSTNAME_VM not " &
        "set (or not on macOS) - the real `scutil --set` triple-slot " &
        "scenario is NOT EXERCISED on this host (it needs sudo on a " &
        "real Mac and mutates the system identity). Run this gate " &
        "inside a disposable macOS VM with " &
        "REPRO_PHASE5_MACOS_HOSTNAME_VM=1 to exercise the real " &
        "`scutil` mutation. The pure-logic suites above already " &
        "proved the parser + canonicalizer + RFC 1123 allowlist + " &
        "typed-op + RBEB codec without mutating any host."
    else:
      when defined(macosx):
        # scutil --set needs root. The host-side runner uses
        # `sudo -E -n`.
        let euid = geteuid()
        doAssert euid == 0,
          "PHASE-5 macOS gate must run as root inside the VM " &
          "(euid=" & $euid & "); the host-side runner should `sudo -E` " &
          "the gate binary. `scutil --set` needs root."

        # Snapshot the prior triple-slot state for diagnostics. The
        # Tart guest is ephemeral (cloned per-gate, destroyed after) so
        # we don't strictly need to restore, but recording the prior
        # state is useful for the verbose [OK] line at the end.
        let prior = readAllSlots()

        # PID-scoped test hostname (RFC 1123 charset, ≤63 chars). The
        # `isSafeHostname` allowlist enforces leading/trailing-dash +
        # space + semicolon rejection; PID is bounded ~5 digits so the
        # total length stays well under 63.
        let pid = $getCurrentProcessId()
        let target = "repro-phase5-host-" & pid
        doAssert isSafeHostname(target),
          "test hostname '" & target & "' unexpectedly rejected by " &
          "the isSafeHostname allowlist"

        # ---------------------------------------------------------------
        # 1. APPLY: driver-direct call to applyPosixOsHostname (macOS
        #    arm does the scutil --set triple).
        # ---------------------------------------------------------------
        let opApply = PrivilegedOperation(kind: pokOsHostname,
          address: "hostname:" & target,
          hostnameName: target)
        doAssert operationValidationError(opApply).len == 0,
          "apply op rejected: " & operationValidationError(opApply)
        let post1 = applyPosixOsHostname(opApply)
        doAssert post1.present,
          "post-apply: driver reports hostname absent"

        # PASS CRITERION (db84280, osHostname macOS row): all THREE
        # slots match the requested value. We probe each slot out-of-
        # band via `scutil --get` (not via observePosixOsHostname,
        # which only reads `hostname` — a single slot). The negative
        # assertion is "no slot left unsynchronized".
        let after = readAllSlots()
        let canTarget = canonicalHostnameState(target)
        let canAfter = canonicalSlotsForCompare(after)

        doAssert canAfter.c == canTarget,
          "post-apply: ComputerName slot mismatch — got '" &
          after.computerName & "' (canonical '" & canAfter.c &
          "'), expected '" & target & "' (canonical '" & canTarget & "')"
        doAssert canAfter.h == canTarget,
          "post-apply: HostName slot mismatch — got '" &
          after.hostName & "' (canonical '" & canAfter.h &
          "'), expected '" & target & "' (canonical '" & canTarget & "')"
        doAssert canAfter.l == canTarget,
          "post-apply: LocalHostName slot mismatch — got '" &
          after.localHostName & "' (canonical '" & canAfter.l &
          "'), expected '" & target & "' (canonical '" & canTarget & "')"

        # Negative-assertion form: no slot is left at its prior value.
        # (Restating the positive assertion in failure-mode terms so
        # the diagnostic message names which slot specifically was
        # unsynchronized.)
        var unsynchronized: seq[string] = @[]
        if canAfter.c != canTarget: unsynchronized.add("ComputerName")
        if canAfter.h != canTarget: unsynchronized.add("HostName")
        if canAfter.l != canTarget: unsynchronized.add("LocalHostName")
        doAssert unsynchronized.len == 0,
          "post-apply: slots left unsynchronized: " &
          unsynchronized.join(", ")

        # Independent observe call agrees with the driver-reported
        # post-apply state. (observePosixOsHostname reads only one
        # slot — `hostname` — so this is a weaker check than the
        # triple-slot assertion above.)
        let obs1 = observePosixOsHostname(opApply)
        doAssert obs1.present
        doAssert obs1.digestHex == post1.digestHex,
          "post-apply: independent observe digest disagrees with " &
          "driver-returned digest"

        # ---------------------------------------------------------------
        # 2. RE-APPLY: same hostname. No-op from the drift-detection
        #    perspective — digest stable.
        # ---------------------------------------------------------------
        let post2 = applyPosixOsHostname(opApply)
        doAssert post2.present
        doAssert post2.digestHex == post1.digestHex,
          "re-apply: digest unexpectedly changed (was " &
          post1.digestHex[0 ..< 12] & ", now " &
          post2.digestHex[0 ..< 12] & "); re-apply should be a no-op"

        echo "  [OK] os.hostname macOS lifecycle: prior=(" &
          prior.computerName & ", " & prior.hostName & ", " &
          prior.localHostName & ") -> apply " & target &
          " — all three slots (ComputerName, HostName, LocalHostName) " &
          "verified via out-of-band `scutil --get` to match canonical " &
          "form '" & canTarget & "'; re-apply digest stable."
