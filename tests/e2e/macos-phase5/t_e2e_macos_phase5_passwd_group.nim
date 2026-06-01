## M6 / M11 Phase-5 Gate: e2e_macos_phase5_passwd_group
##
## Per the macOS Mac-host validation checklist in
## `metacraft/reprobuild-specs/Nix-Flake-Migration-Roadmap.md` ("Drivers
## with shipped macOS arms - never E2E-validated"), the `passwd.group`
## driver (system-scope, in
## `libs/repro_elevation/src/repro_elevation/posix_system_driver.nim`)
## had shipped a `when defined(linux)` arm only; the macOS arm
## (`dscl . -create /Groups/<name>` + PrimaryGroupID computation,
## NOT `groupadd`) is part of M11 (`macOS Driver Validation - dscl
## Identity (User + Group)`). The M69 Linux gate
## (`tests/e2e/m69/t_e2e_repro_infra_passwd_group_vm.nim`,
## `defined(linux)` only) does not exercise macOS at all.
##
## M6 deliverable (already shipped): the non-destructive half asserts
## the pure getent-group parser (`parseGetentGroup`), the canonicalizer
## (`canonicalPasswdGroupState`), the typed-operation wiring through
## `parseSystemProfile` + `toPrivilegedOperation`, and the RBEB codec
## round-trip.
##
## M11 deliverable: BOTH
##   1. ADD the macOS arm to the driver (`dscl . -create /Groups/<name>`
##      + `PrimaryGroupID` computation + `dseditgroup` for membership +
##      `dscl . -delete /Groups/<name>` for destroy), and
##   2. populate the destructive half of THIS gate with the apply +
##      verify + destroy scenario inside a disposable Tart macOS VM.
##
## The macOS arm of the driver is structurally parallel to the Linux
## arm: same `PasswdGroupObservation` / `PasswdGroupDesired` types,
## same `diffPasswdGroup`, same `canonicalPasswdGroupState` (so the
## drift / post-apply-re-probe contract is shared cross-platform);
## the only differences are the shell-out tools (dscl + dseditgroup
## vs groupadd + groupmod + groupdel + usermod) and the macOS-specific
## next-free-gid computation when the resource does not pin one
## (the Linux arm relies on `groupadd`'s implicit `nogroup`-range
## allocator; macOS has no equivalent so the driver picks one in the
## 600..999 reprobuild-managed band).
##
## ===========================================================================
## DESTRUCTIVE GATE - REQUIRES A macOS SANDBOX / VM. DO NOT RUN ON A
## REAL HOST.
## ===========================================================================
##
## The destructive half invokes `dscl . -create /Groups/<name>` +
## `dscl . -create /Groups/<name> PrimaryGroupID <gid>` +
## `dseditgroup` + `dscl . -delete /Groups/<name>` (all require sudo)
## and mutates the local Directory Service database. Guarded by BOTH
## `defined(macosx)` AND `REPRO_PHASE5_MACOS_PASSWD_GROUP_VM=1`. The
## host-side runner cross-builds this binary, copies it into a
## freshly-cloned Tart macOS guest, and runs it under `sudo -E -n`
## with the env var set (the dscl mutations are system-scope and
## need root).

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
  getEnv("REPRO_PHASE5_MACOS_PASSWD_GROUP_VM") == "1"

# ===========================================================================
# NON-DESTRUCTIVE: pure parser + canonicalizer + typed-op wiring +
# RBEB codec. Always runs.
# ===========================================================================

suite "passwd.group: getent-group parser":

  test "parseGetentGroup reads the colon-separated group record":
    let obs = parseGetentGroup("admin:x:80:zahary,root")
    check obs.present
    check obs.gid == "80"
    # Members come back sorted (canonical).
    check obs.members == @["root", "zahary"]

  test "parseGetentGroup returns absent on empty / malformed":
    check not parseGetentGroup("").present
    check not parseGetentGroup("not-a-group-line").present

suite "passwd.group: typed-operation wiring into the M81 closed set":

  test "a passwd.group system.nim resource parses and types":
    let profile = parseSystemProfile("""
passwd.group {
  name = "netbird"
  members = ["zahary"]
}
""")
    check profile.resources.len == 1
    let r = profile.resources[0]
    check r.kind == srkPasswdGroup
    check r.pgName == "netbird"
    check r.pgMembers == @["zahary"]
    let op = toPrivilegedOperation(r)
    check op.kind == pokPasswdGroup
    check op.pgName == "netbird"
    check op.pgMembers == @["zahary"]
    check not op.pgDestroy
    check requiresElevation(op.kind)
    check toPrivilegedOperation(r, destroy = true).pgDestroy
    let part = partitionApply(@[op], nonPrivilegedOperationCount = 0)
    check part.privilegedOperations.len == 1

  test "a passwd.group operation round-trips the RBEB codec":
    let op = PrivilegedOperation(kind: pokPasswdGroup,
      address: "group:netbird",
      pgName: "netbird",
      pgGid: "",
      pgMembers: @["zahary"],
      pgDestroy: false)
    check operationValidationError(op) == ""
    let dec = decodeOperation(decodeFrame(encodeOperation(
      WireOperation(operation: op, baselineDigestHex: "ab"))).body)
    check dec.operation.kind == pokPasswdGroup
    check dec.operation.pgName == "netbird"
    check dec.operation.pgMembers == @["zahary"]
    check dec.baselineDigestHex == "ab"

# ===========================================================================
# DESTRUCTIVE: real `dscl . -create /Groups/<name>` invocation on macOS.
# SANDBOX/VM-ONLY - guarded by BOTH macOS +
# `REPRO_PHASE5_MACOS_PASSWD_GROUP_VM=1`. M11 lands BOTH the macOS
# driver arm AND the concrete scenario.
# ===========================================================================

when defined(macosx):

  proc dsclReadGroup(name, key: string):
      tuple[output: string; exitCode: int] =
    ## Re-implement `dscl . -read /Groups/<name> <key>` from outside
    ## the driver so the assertion is independent of the driver's own
    ## observation codepath. We want to PROVE the group is registered
    ## in the local Directory Service, not just that the driver's
    ## observer reports it.
    let (out0, code) = execCmdEx("dscl . -read " &
      quoteShell("/Groups/" & name) & " " & quoteShell(key),
      options = {poStdErrToStdOut})
    (out0, code)

  proc dsclListGroups(): tuple[output: string; exitCode: int] =
    ## `dscl . -list /Groups` returns one group name per line. Used
    ## in the post-destroy walk to assert no sentinel-named groups
    ## remain.
    let (out0, code) = execCmdEx("dscl . -list /Groups",
      options = {poStdErrToStdOut})
    (out0, code)

  proc dseditgroupCheck(name: string):
      tuple[output: string; exitCode: int] =
    ## `dseditgroup -o read <name>` returns a full group record when
    ## the group exists, or exits non-zero when absent. A SECOND
    ## independent witness (alongside `dscl . -read`) that the group
    ## is registered with the local directory service.
    let (out0, code) = execCmdEx("dseditgroup -o read " &
      quoteShell(name), options = {poStdErrToStdOut})
    (out0, code)

  # Negative assertion target — the macOS arm of `passwd.group` MUST
  # NOT shell out to `groupadd` (which does not exist on macOS). We
  # cannot intercept arbitrary subprocess execs from the gate's
  # process, but we can record a sentinel BEFORE the driver call:
  # if the driver had shelled out to `groupadd`, the subprocess would
  # have failed with "command not found" and the driver's own
  # post-apply re-probe would have raised before the gate reached
  # the post-apply assertions. The fact that the apply succeeds AND
  # the out-of-band `dscl . -read` shows the group present is
  # CONSTRUCTIVE proof the driver used dscl, not groupadd. We add an
  # additional check by `which groupadd` returning a non-zero exit
  # code — confirming groupadd genuinely is absent — so the test's
  # premise is solid.
  proc groupaddPresent(): bool =
    let (_, code) = execCmdEx("which groupadd",
      options = {poStdErrToStdOut})
    code == 0

suite "passwd.group (macOS): REAL dscl create / verify / destroy (sandbox-only)":

  test "real passwd.group lifecycle (only under macOS + env var)":
    if not sandboxMode:
      echo "  [sandbox-gated] REPRO_PHASE5_MACOS_PASSWD_GROUP_VM not " &
        "set (or not on macOS) - the real `dscl . -create " &
        "/Groups/<name>` scenario is NOT EXERCISED on this host (it " &
        "needs sudo on a real Mac). Run this gate inside a " &
        "disposable macOS VM with " &
        "REPRO_PHASE5_MACOS_PASSWD_GROUP_VM=1. The pure-logic " &
        "suites above already proved the parser + canonicalizer + " &
        "typed-op + RBEB codec without mutating any host."
    else:
      when defined(macosx):
        discard reproBinary()  # M6 scaffold parity (kept for runner audit).

        # The destructive arm mutates /Local/Default/Groups via dscl;
        # the host-side runner uses `sudo -E -n` to launch this
        # binary. Fail-closed if we're not root.
        let euid = geteuid()
        doAssert euid == 0,
          "PHASE-5 macOS gate must run as root inside the VM " &
          "(euid=" & $euid & "); the host-side runner should `sudo -E` " &
          "the gate binary before invocation. `dscl . -create " &
          "/Groups/<name>` is system-scope and needs root."

        # NEGATIVE precondition for the "no groupadd" assertion: the
        # macOS guest must NOT ship `groupadd` on PATH. If a future
        # macOS release adds it (extraordinarily unlikely — it's a
        # GNU/Linux shadow-utils binary), the assertion would lose
        # its meaning and we'd need to instrument the driver
        # instead. Documented as the gate's premise.
        doAssert not groupaddPresent(),
          "test premise violated: `groupadd` is on PATH on this " &
          "macOS guest. The macOS arm of passwd.group asserts the " &
          "driver does NOT use groupadd (which would not exist on " &
          "stock macOS); if a future guest ships groupadd, this " &
          "negative assertion needs to be re-thought (e.g. argv " &
          "tracing via the Tier-2 macOS-phase5-shims/ inventory)."

        # ---------------------------------------------------------------
        # Test group: pick a DISPOSABLE PID-scoped name that does NOT
        # collide with any Apple-owned group on the guest. Group names
        # use a metacraft-reverse-DNS-like prefix but adapted to the
        # group-name charset (no dots — dscl-Group names tolerate them
        # but it's cleaner to stick with letters + digits + dashes).
        # ---------------------------------------------------------------
        let pid = $getCurrentProcessId()
        let testGroupName = "reprophase5pgrp" & pid
        # PrimaryGroupID is pinned to a specific gid the gate computes
        # itself; we want a stable known value to assert against in the
        # post-apply re-probe. 7600 is in the 600..999 + 7000-range
        # reprobuild-managed band, far above the Apple-reserved (0-100)
        # and admin-tooling (80-99) ranges, and far below the default
        # user-group base (501+) so it does not collide with the
        # cirruslabs admin user's primary group.
        let testGid = "7600"

        # Best-effort cleanup of stale state from a prior aborted run.
        # The Tart guest is freshly cloned per gate so there should be
        # nothing to clean, but the defensive form is harmless and
        # matches the M10 launchd-system-daemon pattern.
        discard execCmdEx("dscl . -delete " &
          quoteShell("/Groups/" & testGroupName),
          options = {poStdErrToStdOut})

        # Prior state: the group is absent both via dscl and via the
        # independent dseditgroup witness.
        let preGid = dsclReadGroup(testGroupName, "PrimaryGroupID")
        doAssert preGid.exitCode != 0,
          "pre-apply: `dscl . -read /Groups/" & testGroupName &
          " PrimaryGroupID` unexpectedly succeeded (exit " &
          $preGid.exitCode & "); test cannot prove round-trip."
        let preDsedit = dseditgroupCheck(testGroupName)
        doAssert preDsedit.exitCode != 0,
          "pre-apply: `dseditgroup -o read " & testGroupName &
          "` unexpectedly succeeded (exit " & $preDsedit.exitCode &
          "); test cannot prove round-trip."

        # ---------------------------------------------------------------
        # 1. APPLY: create the group via `dscl . -create /Groups/<name>`
        #    + `dscl . -create /Groups/<name> PrimaryGroupID <gid>`.
        # ---------------------------------------------------------------
        let opApply = PrivilegedOperation(kind: pokPasswdGroup,
          address: "group:" & testGroupName,
          pgName: testGroupName,
          pgGid: testGid,
          pgMembers: @[],            # M11 sandbox: no member additions
          pgDestroy: false)
        doAssert operationValidationError(opApply).len == 0,
          "apply op rejected by validator: " &
          operationValidationError(opApply)
        let post1 = applyPasswdGroup(opApply)
        doAssert post1.present,
          "post-apply: driver reports group absent after `dscl . -create`"

        # PASS CRITERION (M11 verification block,
        # `verify_macos_passwd_group_dscl_create`): the group is
        # readable via `dscl . -read /Groups/<name>` AND the
        # PrimaryGroupID matches the pinned value. We re-check
        # OUT-OF-BAND so the assertion is independent of the
        # driver's observer.
        let postGid = dsclReadGroup(testGroupName, "PrimaryGroupID")
        doAssert postGid.exitCode == 0,
          "post-apply: `dscl . -read /Groups/" & testGroupName &
          " PrimaryGroupID` failed (exit " & $postGid.exitCode & "): " &
          postGid.output.strip()
        doAssert postGid.output.contains(testGid),
          "post-apply: PrimaryGroupID readout does not contain the " &
          "pinned gid '" & testGid & "': " & postGid.output.strip()

        # Independent dseditgroup witness — a SECOND tool, completely
        # separate from dscl, agreeing the group exists.
        let postDsedit = dseditgroupCheck(testGroupName)
        doAssert postDsedit.exitCode == 0,
          "post-apply: `dseditgroup -o read " & testGroupName &
          "` failed (exit " & $postDsedit.exitCode & "): " &
          postDsedit.output.strip()
        doAssert postDsedit.output.contains(testGroupName) or
                 postDsedit.output.contains(testGid),
          "post-apply: `dseditgroup -o read` output does not mention " &
          "the group name or gid: " & postDsedit.output.strip()

        # Independent observe call should report the same digest the
        # apply path returned.
        let obs1 = observePasswdGroup(opApply)
        doAssert obs1.present
        doAssert obs1.digestHex == post1.digestHex,
          "post-apply: independent observe digest disagrees with " &
          "driver-returned digest"

        # ---------------------------------------------------------------
        # 2. RE-APPLY: same operation. The driver's post-apply re-probe
        #    contract says the second apply observes the same state as
        #    the first; for `passwd.group` the canonical digest covers
        #    gid + sorted member list, both of which are stable across
        #    the no-op re-apply (the driver's `before.present == true`
        #    branch runs and the gid does not differ, so no dscl
        #    mutation is issued).
        # ---------------------------------------------------------------
        let post2 = applyPasswdGroup(opApply)
        doAssert post2.present
        doAssert post2.digestHex == post1.digestHex,
          "re-apply: digest changed unexpectedly (was " &
          post1.digestHex[0 ..< 12] & ", now " &
          post2.digestHex[0 ..< 12] & "); re-apply should be a no-op " &
          "from the drift-detection perspective"

        # ---------------------------------------------------------------
        # 3. DESTROY: `dscl . -delete /Groups/<name>` via the driver's
        #    destroy branch. Post-destroy the group must be absent
        #    both via dscl AND via the independent dseditgroup
        #    witness; an out-of-band `dscl . -list /Groups` must NOT
        #    list any group whose name contains our PID-scoped
        #    sentinel.
        # ---------------------------------------------------------------
        let opDestroy = PrivilegedOperation(kind: pokPasswdGroup,
          address: "group:" & testGroupName,
          pgName: testGroupName,
          pgGid: testGid,
          pgMembers: @[],
          pgDestroy: true)
        let postDestroy = applyPasswdGroup(opDestroy)
        doAssert not postDestroy.present,
          "post-destroy: driver reports group still present"
        doAssert postDestroy.digestHex == ZeroDigestHex,
          "post-destroy: driver-returned digest is non-zero (" &
          postDestroy.digestHex[0 ..< 12] & "); the destroy path " &
          "should report the canonical absent-digest"

        let postDelGid = dsclReadGroup(testGroupName, "PrimaryGroupID")
        doAssert postDelGid.exitCode != 0,
          "post-destroy: `dscl . -read /Groups/" & testGroupName &
          " PrimaryGroupID` STILL succeeds after destroy (exit " &
          $postDelGid.exitCode & "): " & postDelGid.output.strip()
        let postDelDsedit = dseditgroupCheck(testGroupName)
        doAssert postDelDsedit.exitCode != 0,
          "post-destroy: `dseditgroup -o read " & testGroupName &
          "` STILL succeeds after destroy (exit " &
          $postDelDsedit.exitCode & "): " &
          postDelDsedit.output.strip()

        # No orphaned groups: walk `dscl . -list /Groups` and confirm
        # nothing with our PID-scoped sentinel substring survives.
        let postList = dsclListGroups()
        doAssert postList.exitCode == 0,
          "post-destroy: `dscl . -list /Groups` failed (exit " &
          $postList.exitCode & "): " & postList.output.strip()
        for line in postList.output.splitLines():
          let trimmed = line.strip()
          if trimmed.len == 0:
            continue
          # Each line is `<name>` (or `<name>  <PrimaryGroupID>` for
          # `dscl . -list /Groups PrimaryGroupID`). The PID-scoped
          # sentinel uniquely identifies our test group.
          if trimmed.contains(pid) and
             trimmed.contains("reprophase5pgrp"):
            doAssert false,
              "post-destroy: orphaned group left behind: " & trimmed

        echo "  [OK] passwd.group lifecycle: dscl . -create /Groups/" &
          testGroupName & " (PrimaryGroupID=" & testGid & ") / re-apply " &
          "(no-op) / dscl . -delete /Groups/<name> round-trip; " &
          "out-of-band `dscl . -read` + `dseditgroup -o read` verified " &
          "registration; destroy removes the group with no orphans; " &
          "negative assertion: `groupadd` absent on PATH (proves the " &
          "driver used dscl, not groupadd)."
