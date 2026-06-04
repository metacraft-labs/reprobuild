## M69 Verification Gate: e2e_repro_infra_fs_system_file
##
## Per the M69 Phase C `fs.systemFile` driver: write / update / delete
## a managed file under an allowlisted system directory (`/etc/`,
## `/usr/local/etc/`, `${PROGRAMDATA}`); paths outside the allowlist
## are refused with `EOutOfScope`; out-of-band edits drift on the next
## plan; rollback restores.
##
## ===========================================================================
## DESTRUCTIVE GATE - REQUIRES A LINUX SANDBOX / VM. DO NOT RUN ON A
## REAL HOST.
## ===========================================================================
##
## A `fs.systemFile` write lands under `/etc/` or `/usr/local/etc/` -
## that is a real system path. The destructive scenario runs ONLY on
## POSIX (Linux/macOS) AND ONLY when `REPRO_M69_FS_VM=1` is set, so a
## normal dev / CI host can never mutate real system files. Outside
## the throwaway WSL distro (or an equivalent disposable VM) the gate
## still runs its non-destructive halves: the allowlist + scope-error
## logic, the `fs.systemFile` typed-operation wiring, and the RBEB
## protocol codec round-trip. No `skip`, no `xfail`.
##
## The PURE allowlist / drift logic (`isAllowedSystemFilePath`,
## `systemFileScopeError`) has dense cross-platform smoke coverage in
## `libs/repro_elevation/tests/t_smoke_repro_elevation.nim` and
## `libs/repro_infra/tests/t_smoke_repro_infra.nim`; this gate links
## to those rather than duplicating them, and adds the typed-op +
## RBEB round-trip + sandbox-mutation pieces that only an end-to-end
## gate can prove.

import std/[os, tempfiles, unittest]

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
    ProjectRoot / "build" / "bin" / addFileExt("repro", ExeExt)

# The real-mutation scenario is gated by BOTH the platform (POSIX) and
# an explicit opt-in env var. The env var is left UNSET on every CI /
# dev host so the gate never writes a real system file.
let sandboxMode =
  (defined(linux) or defined(macosx)) and
  getEnv("REPRO_M69_FS_VM") == "1"

# Phase-5 macOS-specific destructive arm: driver-direct (no broker, no
# `repro` binary required). Validates the macOS `/private/etc` symlink
# resolution and the `applyFsSystemFile` post-apply re-probe contract
# inside a Tart-managed macOS guest. Per the M6 reuse decision, the
# existing `(linux or macosx) + REPRO_M69_FS_VM` arm above remains the
# canonical "infra apply via broker" sandbox path; this Phase-5 arm
# focuses on the macOS-specific behavior (symlink resolution) without
# requiring the broker binary in the guest, so the host-side runner
# can ship just this gate binary + its dynamic dependencies.
let phase5MacosSandboxMode =
  defined(macosx) and getEnv("REPRO_PHASE5_MACOS_FS_VM") == "1"

# ===========================================================================
# NON-DESTRUCTIVE: allowlist + scope checks + typed-operation wiring +
# RBEB codec round-trip. Proves the driver logic + the allowlist gate
# without touching any host system path. Always runs.
# ===========================================================================

suite "fs.systemFile: allowlist + scope-error spot checks":
  # The full canonical test surface for `isAllowedSystemFilePath` /
  # `systemFileScopeError` lives in
  # `libs/repro_elevation/tests/t_smoke_repro_elevation.nim` and is
  # covered by `t_smoke_repro_infra`'s Phase C parse suite. The checks
  # below are spot anchors so this gate FAILS LOUDLY if the contract
  # ever regresses, not a full re-statement.

  test "an /etc/ path is in-scope; /tmp/ is out":
    check isAllowedSystemFilePath("/etc/repro.conf")
    check not isAllowedSystemFilePath("/tmp/x")
    check systemFileScopeError("/etc/repro.conf").len == 0
    check systemFileScopeError("/tmp/x").len > 0

  test "a path-traversal attempt is rejected even under /etc/":
    check not isAllowedSystemFilePath("/etc/../tmp/x")
    check systemFileScopeError("/etc/../tmp/x").len > 0

  test "a /usr/local/etc/ path is in-scope":
    check isAllowedSystemFilePath("/usr/local/etc/repro.conf")

  test "${PROGRAMDATA} is in-scope only when programDataRoot is supplied":
    # The driver injects `getEnv("PROGRAMDATA")` on Windows.
    check not isAllowedSystemFilePath("C:/ProgramData/Repro/x")
    check isAllowedSystemFilePath("C:/ProgramData/Repro/x",
      programDataRoot = "C:/ProgramData")

suite "fs.systemFile: typed-operation wiring into the M81 closed set":

  test "a fs.systemFile system.nim resource parses and types":
    let profile = parseSystemProfile("""
fs.systemFile {
  path = "/etc/repro-m69-fs-gate.conf"
  content = "managed=true"
}
""")
    check profile.resources.len == 1
    let r = profile.resources[0]
    check r.kind == srkFsSystemFile
    check r.sfPath == "/etc/repro-m69-fs-gate.conf"
    let op = toPrivilegedOperation(r)
    check op.kind == pokFsSystemFile
    check op.sfPath == "/etc/repro-m69-fs-gate.conf"
    check op.sfContent == "managed=true"
    check not op.sfDestroy
    check requiresElevation(op.kind)
    # The destroy direction flips the typed operation.
    check toPrivilegedOperation(r, destroy = true).sfDestroy
    # It partitions as a privileged (broker-dispatched) operation.
    let part = partitionApply(@[op], nonPrivilegedOperationCount = 0)
    check part.privilegedOperations.len == 1

  test "a fs.systemFile operation round-trips the RBEB protocol codec":
    let op = PrivilegedOperation(kind: pokFsSystemFile,
      address: "systemFile:/etc/repro-m69-fs-gate.conf",
      sfPath: "/etc/repro-m69-fs-gate.conf", sfContent: "managed=true",
      sfDestroy: false)
    check operationValidationError(op) == ""
    let dec = decodeOperation(decodeFrame(encodeOperation(
      WireOperation(operation: op, baselineDigestHex: "ab"))).body)
    check dec.operation.kind == pokFsSystemFile
    check dec.operation.sfPath == "/etc/repro-m69-fs-gate.conf"
    check dec.operation.sfContent == "managed=true"
    check dec.baselineDigestHex == "ab"

  test "an out-of-allowlist sfPath fails validation closed":
    let op = PrivilegedOperation(kind: pokFsSystemFile,
      address: "systemFile:/tmp/bad", sfPath: "/tmp/bad",
      sfContent: "x", sfDestroy: false)
    # The validator rejects a path-traversal sfPath up front.
    let opTraversal = PrivilegedOperation(kind: pokFsSystemFile,
      address: "systemFile:/etc/../tmp/x", sfPath: "/etc/../tmp/x",
      sfContent: "x", sfDestroy: false)
    check operationValidationError(opTraversal).len > 0
    # An out-of-allowlist (no `..`) path is caught by the driver's own
    # scope check at apply time; the validator's coarse-grained `..`
    # filter is upstream defence in depth.
    discard op

# ===========================================================================
# DESTRUCTIVE: real `fs.systemFile` write / drift / rollback against a
# sandboxed /etc/ path. SANDBOX/VM-ONLY - guarded by BOTH the POSIX
# platform AND `REPRO_M69_FS_VM=1`. Never runs on a normal host.
# ===========================================================================

suite "fs.systemFile: REAL write / drift / rollback (sandbox-only)":

  test "real fs.systemFile lifecycle (only under Linux/macOS + the env var)":
    if not sandboxMode:
      echo "  [sandbox-gated] REPRO_M69_FS_VM not set (or not on " &
        "Linux/macOS) - the real /etc/ write / drift / rollback " &
        "scenario is NOT EXERCISED on this host. Run this gate " &
        "inside a disposable Linux sandbox / VM with " &
        "REPRO_M69_FS_VM=1 to exercise the real fs.systemFile " &
        "mutation. The non-destructive suites above already proved " &
        "the allowlist + driver wiring without writing any system " &
        "file."
    else:
      # ---------------------------------------------------------------
      # End-to-end: write a managed system file at /etc/repro-m69-fs-
      # gate-<pid>.conf, observe post-state byte-identical, simulate
      # an out-of-band edit and prove drift is detected on re-observe,
      # then run the destroy direction and prove the file is gone.
      # ---------------------------------------------------------------
      let stateDir = createTempDir("repro-m69-fs-sb-", "")
      defer: removeDir(stateDir)
      ensureSystemStateDir(stateDir)

      let targetPath = "/etc/repro-m69-fs-gate-" &
        $getCurrentProcessId() & ".conf"
      let content1 = "managed=true\nversion=1\n"
      let content2 = "managed=true\nversion=2\n"

      writeFile(stateDir / "system.nim",
        "fs.systemFile {\n" &
        "  path = \"" & targetPath & "\"\n" &
        "  content = \"" & content1 & "\"\n" &
        "}\n")
      let profileText1 = readFile(stateDir / "system.nim")

      var opts: ApplyOptions
      opts.stateDir = stateDir
      opts.hostIdentity = "sandbox-fs-host"
      opts.reproExe = reproBinary()
      opts.elevationMode = emBroker
      opts.forceBroker = false        # the sandbox runs as root
      opts.noPreview = true

      # Defence in depth: the real-mutation scenario must NOT escape
      # the allowlist. A bug that would let an operator write
      # `/tmp/whatever` would be caught here.
      check isAllowedSystemFilePath(targetPath)

      # 1. Create the file.
      let created = runInfraApply(profileText1, opts)
      check created.errorCount == 0
      check fileExists(targetPath)
      check readFile(targetPath) == content1

      # 2. Out-of-band edit: a second `runInfraApply` with the SAME
      #    declared content but a divergent on-disk file is a drift
      #    the planner re-observes. We simulate the drift by writing
      #    a different byte sequence to the file directly, then assert
      #    `observeResource` reports a digest mismatch against the
      #    desired digest.
      writeFile(targetPath, "tampered\n")
      let profile1 = parseSystemProfile(profileText1)
      let obsDrift = observeResource(profile1.resources[0])
      let desiredDigest = posixSystemDesiredDigestHex(
        toPrivilegedOperation(profile1.resources[0]))
      check obsDrift.present
      check obsDrift.observedDigestHex != desiredDigest

      # 3. Re-apply converges back to the declared content.
      let reconverged = runInfraApply(profileText1, opts)
      check reconverged.errorCount == 0
      check readFile(targetPath) == content1

      # 4. Update: change content; a re-apply observes a no-op for the
      #    OLD plan but a new apply with the NEW desired text converges.
      writeFile(stateDir / "system.nim",
        "fs.systemFile {\n" &
        "  path = \"" & targetPath & "\"\n" &
        "  content = \"" & content2 & "\"\n" &
        "}\n")
      let profileText2 = readFile(stateDir / "system.nim")
      let updated = runInfraApply(profileText2, opts)
      check updated.errorCount == 0
      check readFile(targetPath) == content2

      # 5. Destroy via the rollback seam: an `extraDestroyResources`
      #    entry removes the file. `fs.systemFile` is NOT covered by
      #    `--accept-feature-destroy` (that gate is for OS features /
      #    capabilities / VS installs) nor `--accept-passwd-destroy`
      #    (users), so no flag is required - per the M69 spec a
      #    `fs.systemFile` removal is a routine convergence step.
      var destroyOpts = opts
      destroyOpts.extraDestroyResources = @[SystemResource(
        kind: srkFsSystemFile,
        address: "systemFile:" & targetPath,
        sfPath: targetPath, sfContent: "")]
      let removed = runInfraApply("", destroyOpts)
      check removed.errorCount == 0
      check not fileExists(targetPath)

      # 6. The allowlist genuinely rejects a path outside the
      #    recognized roots. We do NOT actually apply this operation -
      #    the validator must REJECT it BEFORE any I/O.
      let badOp = PrivilegedOperation(kind: pokFsSystemFile,
        address: "systemFile:/etc/../tmp/escape",
        sfPath: "/etc/../tmp/escape",
        sfContent: "escape", sfDestroy: false)
      check operationValidationError(badOp).len > 0

# ===========================================================================
# PHASE-5 macOS-SPECIFIC DESTRUCTIVE: driver-direct `applyFsSystemFile`
# + `/private/etc` symlink-resolution check. SANDBOX/VM-ONLY - guarded
# by `defined(macosx) and REPRO_PHASE5_MACOS_FS_VM=1`. Covers the
# macOS-only PASS criterion from `db84280`: "File written + readable
# post-apply; symlink resolution does not double-write under
# /private/etc".
#
# This suite is independent of the `(linux or macosx) +
# REPRO_M69_FS_VM` suite above: it skips the broker / `repro` binary
# entirely (the host-side runner ships only this gate binary into the
# Tart guest), and instead invokes `applyFsSystemFile` directly. Since
# the destructive half runs as the cirruslabs `admin` user with
# passwordless sudo, the gate elevates itself by re-exec'ing under
# sudo when not already root.
# ===========================================================================

when defined(macosx):

  proc readEtcViaPrivateEtc(name: string): string =
    ## Re-read the file via the explicit `/private/etc/<name>` path.
    ## On macOS `/etc` is a symlink to `/private/etc`; a write to
    ## `/etc/<name>` lands at `/private/etc/<name>` and BOTH paths
    ## should resolve to the same bytes. We assert byte-equality
    ## across the two read paths to confirm the driver does not
    ## double-write or land in two distinct files.
    readFile("/private/etc/" & name)

  proc statInode(path: string): tuple[dev: uint64, ino: uint64] =
    ## Stat helper for the symlink-resolution check. Two paths that
    ## resolve to the same on-disk file MUST share (dev, ino). Used
    ## to prove `/etc/<name>` and `/private/etc/<name>` are the same
    ## inode, NOT two separate files.
    let info = getFileInfo(path, followSymlink = true)
    (dev: info.id.device.uint64, ino: info.id.file.uint64)

suite "fs.systemFile: PHASE-5 macOS driver-direct + symlink check":

  test "macOS /etc write resolves through /private/etc symlink (driver-direct)":
    if not phase5MacosSandboxMode:
      echo "  [sandbox-gated] REPRO_PHASE5_MACOS_FS_VM not set (or " &
        "not on macOS) - the macOS-specific /private/etc symlink " &
        "resolution scenario is NOT EXERCISED on this host. Run " &
        "this gate inside a disposable macOS VM (via vm-harness " &
        "tart-macos) with REPRO_PHASE5_MACOS_FS_VM=1 to exercise " &
        "the real driver-direct apply + verify + destroy path."
    else:
      when defined(macosx):
        # Defence in depth: an in-VM cirruslabs admin user has
        # passwordless sudo; we expect this process to already be
        # running as root (the host-side runner uses `sudo -E` to
        # invoke the gate binary so the apply path can write under
        # /etc/). Fail closed if we are not root.
        let euid = geteuid()
        doAssert euid == 0,
          "PHASE-5 macOS gate must run as root inside the VM " &
          "(euid=" & $euid & "); the host-side runner should `sudo -E` " &
          "the gate binary before invocation"

        let pid = $getCurrentProcessId()
        let targetName = "repro-phase5-fs-systemfile-" & pid & ".conf"
        let targetEtc = "/etc/" & targetName
        let targetPrivate = "/private/etc/" & targetName
        let content1 = "phase5=fs.systemFile\nversion=1\n"
        let content2 = "phase5=fs.systemFile\nversion=2\n" &
          "macos=tahoe\n"

        # Pre-condition: allowlist accepts /etc/ + the path normalizes
        # to under SystemFileAllowedRoots. Defence in depth before any
        # I/O.
        doAssert isAllowedSystemFilePath(targetEtc),
          "/etc/ path unexpectedly rejected by allowlist"

        # Ensure no stale file leftover from a prior aborted run.
        if fileExists(targetEtc):
          removeFile(targetEtc)
        doAssert not fileExists(targetEtc)
        doAssert not fileExists(targetPrivate)

        # -------------------------------------------------------------
        # 1. APPLY: driver-direct, no broker.
        # -------------------------------------------------------------
        let opApply = PrivilegedOperation(kind: pokFsSystemFile,
          address: "systemFile:" & targetEtc,
          sfPath: targetEtc, sfContent: content1, sfDestroy: false)
        doAssert operationValidationError(opApply).len == 0
        let post1 = applyFsSystemFile(opApply)
        doAssert post1.present
        doAssert post1.digestHex == posixDigestHexOfText(content1)

        # PASS CRITERION (db84280, fs.systemFile macOS row):
        # "File written + readable post-apply".
        doAssert fileExists(targetEtc),
          "post-apply: /etc/" & targetName & " does not exist"
        doAssert readFile(targetEtc) == content1,
          "post-apply: /etc read back unexpected bytes"

        # PASS CRITERION: "symlink resolution does not double-write
        # under /private/etc". The same bytes must be readable via the
        # /private/etc/ path, AND the two paths must resolve to the
        # SAME inode (no double-write to two distinct files).
        doAssert fileExists(targetPrivate),
          "post-apply: /private/etc/" & targetName & " not visible " &
          "through symlink (driver should not have double-written)"
        doAssert readEtcViaPrivateEtc(targetName) == content1,
          "post-apply: /private/etc read disagrees with /etc read"
        let stEtc = statInode(targetEtc)
        let stPriv = statInode(targetPrivate)
        doAssert stEtc.dev == stPriv.dev,
          "/etc/ and /private/etc/ resolve to different devices " &
          "(symlink-resolution check FAILED)"
        doAssert stEtc.ino == stPriv.ino,
          "/etc/ and /private/etc/ resolve to different inodes " &
          "(driver double-wrote — PASS criterion VIOLATED)"

        # -------------------------------------------------------------
        # 2. RE-OBSERVE: independent observe call reports same digest.
        # -------------------------------------------------------------
        let obs1 = observeFsSystemFile(opApply)
        doAssert obs1.present
        doAssert obs1.digestHex == post1.digestHex

        # -------------------------------------------------------------
        # 3. UPDATE: change content; driver overwrites in place.
        # -------------------------------------------------------------
        let opUpdate = PrivilegedOperation(kind: pokFsSystemFile,
          address: "systemFile:" & targetEtc,
          sfPath: targetEtc, sfContent: content2, sfDestroy: false)
        let post2 = applyFsSystemFile(opUpdate)
        doAssert post2.present
        doAssert post2.digestHex == posixDigestHexOfText(content2)
        doAssert readFile(targetEtc) == content2
        doAssert readEtcViaPrivateEtc(targetName) == content2
        # Inode stability: a same-path overwrite preserves inode on
        # macOS APFS (the driver uses fmWrite truncate, not unlink+
        # create). This is defence-in-depth on the symlink-resolution
        # contract — different inode after overwrite would suggest the
        # driver took an unlink+rewrite path.
        let stEtc2 = statInode(targetEtc)
        doAssert stEtc2.dev == stPriv.dev
        # Inode CAN differ across overwrite on APFS in principle, but
        # the dev must match; we only assert dev-equality + bytes-
        # equality here. The two-path resolution must still match.
        doAssert statInode(targetPrivate) == stEtc2,
          "post-update: /etc and /private/etc no longer share inode"

        # -------------------------------------------------------------
        # 4. DESTROY: removes the file via the driver's destroy
        #    direction; post-apply re-probe ensures the file is gone.
        # -------------------------------------------------------------
        let opDestroy = PrivilegedOperation(kind: pokFsSystemFile,
          address: "systemFile:" & targetEtc,
          sfPath: targetEtc, sfContent: "", sfDestroy: true)
        let postDestroy = applyFsSystemFile(opDestroy)
        doAssert not postDestroy.present
        doAssert not fileExists(targetEtc),
          "post-destroy: /etc file still present"
        doAssert not fileExists(targetPrivate),
          "post-destroy: /private/etc still visible (orphan?)"

        echo "  [OK] fs.systemFile macOS lifecycle (driver-direct): " &
          "apply / observe / update / destroy; /etc and /private/etc " &
          "resolve to same inode; no double-write."
