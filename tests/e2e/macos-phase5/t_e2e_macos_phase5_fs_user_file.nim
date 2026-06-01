## M7 Phase-5 Gate: e2e_macos_phase5_fs_user_file
##
## Per the macOS Mac-host validation checklist in
## `metacraft/reprobuild-specs/Nix-Flake-Migration-Roadmap.md` ("Drivers
## with shipped macOS arms - never E2E-validated"), the `fs.userFile`
## driver (home-scope, in
## `libs/repro_home_resources/src/repro_home_resources/drivers/user_file.nim`)
## has had only a Linux WSL gate
## (`tests/e2e/m69/t_e2e_repro_home_fs_user_file_vm.nim`,
## `defined(linux)` only). M6 scaffolded the gate; M7 populates the
## concrete `~/Library/Preferences/test.conf` + `~/.zprofile-repro-test`
## apply + verify + destroy scenario inside a Tart-managed macOS VM.
##
## Non-destructive half asserts the pure mode parser
## (`parseModeOctal`, `filePermissionsFromMode`), the resource-typed
## digest stability, and the resource-typed validation. The
## destructive half is sandbox-gated to macOS + the Phase-5 env var.
##
## ===========================================================================
## DESTRUCTIVE GATE - REQUIRES A macOS SANDBOX / VM. DO NOT RUN ON A
## REAL HOST.
## ===========================================================================
##
## The destructive half writes real files under `$HOME` and verifies
## Apple-flavored `~`-expansion + POSIX mode application. Even though
## home-scope writes don't need root, they mutate the user's live
## `$HOME` tree; guarded by BOTH `defined(macosx)` AND
## `REPRO_PHASE5_MACOS_FS_USERFILE_VM=1`. The host-side driver
## (`run_phase5_in_tart.nim`) cross-builds this binary, copies it into
## a freshly-cloned Tart macOS guest, and runs it with the env var
## set.

import std/[os, strutils, unittest]

import repro_home_resources

let sandboxMode =
  defined(macosx) and
  getEnv("REPRO_PHASE5_MACOS_FS_USERFILE_VM") == "1"

# ===========================================================================
# NON-DESTRUCTIVE: mode parser + digest + validation. Always runs.
# ===========================================================================

suite "fs.userFile: POSIX mode parser":

  test "parseModeOctal accepts 4-digit and 3-digit forms":
    check parseModeOctal("0644") == 0o644
    check parseModeOctal("644") == 0o644
    check parseModeOctal("0755") == 0o755
    check parseModeOctal("0600") == 0o600

  test "parseModeOctal rejects empty / non-octal / oversized":
    expect ValueError:
      discard parseModeOctal("")
    expect ValueError:
      discard parseModeOctal("0999")          # 9 is not octal
    expect ValueError:
      discard parseModeOctal("12345")         # > 4 digits

  test "filePermissionsFromMode maps owner/group/other bits":
    let p644 = filePermissionsFromMode("0644")
    check fpUserRead in p644
    check fpUserWrite in p644
    check fpUserExec notin p644
    check fpGroupRead in p644
    check fpOthersRead in p644
    let p755 = filePermissionsFromMode("0755")
    check fpUserExec in p755
    check fpGroupExec in p755
    check fpOthersExec in p755

suite "fs.userFile: typed-resource wiring + digest":

  test "a fs.userFile Resource accepts the canonical fields":
    let r = Resource(kind: rkFsUserFile,
      address: "userFile:Library/Preferences/test.conf",
      lifecyclePolicy: lpDefault,
      userFileHostPath: "/Users/zahary/Library/Preferences/test.conf",
      userFileContent: "managed=true\nversion=1\n",
      userFileMode: "0644")
    check resourceValidationError(r) == ""
    check realWorldIdentity(r) ==
      "/Users/zahary/Library/Preferences/test.conf"

  test "digestOfResource changes when content changes":
    var r = Resource(kind: rkFsUserFile,
      address: "userFile:digest",
      lifecyclePolicy: lpDefault,
      userFileHostPath: "/tmp/repro-m6-digest.txt",
      userFileContent: "v=1\n",
      userFileMode: "0644")
    let d0 = digestOfResource(r)
    r.userFileContent = "v=2\n"
    let d1 = digestOfResource(r)
    check d0 != d1

  test "digestOfResource is INVARIANT in mode (mode is not drift)":
    # Per the driver header: a mode-only change is intentionally NOT
    # drift (mirrors fs.systemFile contract — the file body is the
    # unit of drift, not the mode bits).
    var r = Resource(kind: rkFsUserFile,
      address: "userFile:mode",
      lifecyclePolicy: lpDefault,
      userFileHostPath: "/tmp/repro-m6-mode.txt",
      userFileContent: "x\n",
      userFileMode: "0644")
    let d0 = digestOfResource(r)
    r.userFileMode = "0600"
    let d1 = digestOfResource(r)
    check d0 == d1

  test "resourceKindFromString recognizes fs.userFile":
    check resourceKindFromString("fs.userFile") == rkFsUserFile

# ===========================================================================
# DESTRUCTIVE: real file write under `$HOME` (Apple-flavored). SANDBOX/
# VM-ONLY - guarded by BOTH macOS + `REPRO_PHASE5_MACOS_FS_USERFILE_VM=1`.
# The host-side runner cross-builds this binary, copies it into a Tart
# macOS guest, and runs it with the env var set. The guest's `admin`
# user (cirruslabs golden) owns `$HOME`; `applyUserFileResource`
# writes through Apple's `/Users/admin` path (not `/var/admin`).
# ===========================================================================

when defined(macosx):

  proc verifyApplePathExpansion(hostPath: string) =
    ## Apple-flavored `$HOME` resolves under `/Users/<user>`. On other
    ## POSIX OSes the home is under `/home/<user>`; this gate runs only
    ## under macOS so the expected prefix is `/Users/`. Mirrors the
    ## `db84280` punch-list PASS criterion "~-expansion honors
    ## Apple-flavored $HOME".
    doAssert hostPath.startsWith("/Users/"),
      "fs.userFile host path '" & hostPath &
      "' does not begin with /Users/ (Apple-flavored $HOME)"

  proc verifyModeBits(hostPath: string; expectedMode: string) =
    ## Re-read the POSIX mode bits and assert they match the requested
    ## mode. The driver applies them via `setFilePermissions` after
    ## the atomic rename; we re-probe to prove the bits actually
    ## landed (the file body is the unit of drift, mode is not; so the
    ## driver's own re-probe doesn't cover mode).
    let perms = getFilePermissions(hostPath)
    let expected = filePermissionsFromMode(expectedMode)
    doAssert perms == expected,
      "fs.userFile " & hostPath & " mode mismatch: expected " &
      expectedMode & " (" & $expected & "), got " & $perms

suite "fs.userFile: REAL apply / verify / destroy (sandbox-only)":

  test "real fs.userFile lifecycle (only under macOS + env var)":
    if not sandboxMode:
      echo "  [sandbox-gated] REPRO_PHASE5_MACOS_FS_USERFILE_VM not " &
        "set (or not on macOS) - the real `$HOME` write + " &
        "verification + destroy scenario is NOT EXERCISED on this " &
        "host. Run this gate inside a disposable macOS VM with " &
        "REPRO_PHASE5_MACOS_FS_USERFILE_VM=1 to exercise the real " &
        "Apple-flavored ~-expansion + POSIX mode application. The " &
        "pure-logic suites above already proved the mode parser + " &
        "typed-field digest + validation without mutating any host."
    else:
      when defined(macosx):
        # -----------------------------------------------------------------
        # Scenario 1: ~/Library/Preferences/repro-phase5-test.conf
        # -----------------------------------------------------------------
        # Apple-flavored $HOME expansion + 0644 mode. The `~`-expansion
        # is done by the caller (`expandTilde`); the driver receives a
        # fully-resolved host path. We verify both the expansion shape
        # (host path starts with `/Users/`) and the mode bits after the
        # atomic rename.
        let pid = $getCurrentProcessId()
        let prefTarget = expandTilde(
          "~/Library/Preferences/repro-phase5-test-" & pid & ".conf")
        verifyApplePathExpansion(prefTarget)
        let prefContent = "managed=true\nphase5=fs.userFile\n" &
          "version=1\n"
        let prefMode = "0644"

        if fileExists(prefTarget):
          removeFile(prefTarget)

        # 1a. Apply.
        let recordedPref = applyUserFileResource(prefTarget,
          prefContent, prefMode)
        doAssert fileExists(prefTarget),
          "Preferences file " & prefTarget & " not created"
        doAssert readFile(prefTarget) == prefContent,
          "Preferences content mismatch"
        doAssert recordedPref.len == prefContent.len
        verifyModeBits(prefTarget, prefMode)

        # 1b. Observe present.
        let obs1 = observeUserFile(prefTarget)
        doAssert obs1.present
        doAssert obs1.rawBytes.len == prefContent.len

        # 1c. Re-apply with same content: idempotent no-op (driver
        # rewrites bytes; the digest stays stable; file still present
        # + readable post-write).
        discard applyUserFileResource(prefTarget, prefContent, prefMode)
        doAssert readFile(prefTarget) == prefContent

        # 1d. Destroy + verify clean.
        destroyUserFileResource(prefTarget)
        doAssert not fileExists(prefTarget),
          "Preferences file still exists after destroy"
        let obs1d = observeUserFile(prefTarget)
        doAssert not obs1d.present

        # -----------------------------------------------------------------
        # Scenario 2: ~/.zprofile-repro-phase5-test (a whole-file write
        # to a shell-profile sibling, avoiding clobbering the user's
        # real `.zprofile` — the managed-block gate handles in-place
        # `.zprofile` editing).
        # -----------------------------------------------------------------
        # Different mode (0600) to exercise restricted permissions.
        let zpTarget = expandTilde(
          "~/.zprofile-repro-phase5-test-" & pid)
        verifyApplePathExpansion(zpTarget)
        let zpContent = "# repro fs.userFile gate marker\n" &
          "export REPRO_PHASE5_FS_USERFILE_GATE=1\n"
        let zpMode = "0600"

        if fileExists(zpTarget):
          removeFile(zpTarget)

        # 2a. Apply.
        discard applyUserFileResource(zpTarget, zpContent, zpMode)
        doAssert fileExists(zpTarget),
          "Shell-profile sibling " & zpTarget & " not created"
        doAssert readFile(zpTarget) == zpContent,
          "Shell-profile sibling content mismatch"
        verifyModeBits(zpTarget, zpMode)

        # 2b. Update: change content; driver overwrites atomically.
        let zpContent2 = "# repro fs.userFile gate marker (v2)\n" &
          "export REPRO_PHASE5_FS_USERFILE_GATE=2\n"
        discard applyUserFileResource(zpTarget, zpContent2, zpMode)
        doAssert readFile(zpTarget) == zpContent2,
          "Update did not overwrite content"
        # Mode still honored after update.
        verifyModeBits(zpTarget, zpMode)

        # 2c. Destroy.
        destroyUserFileResource(zpTarget)
        doAssert not fileExists(zpTarget),
          "Shell-profile sibling still exists after destroy"

        # -----------------------------------------------------------------
        # Safety net: make sure no stray .repro.tmp orphans remain.
        # -----------------------------------------------------------------
        doAssert not fileExists(prefTarget & ".repro.tmp"),
          "stray .repro.tmp orphan beside Preferences target"
        doAssert not fileExists(zpTarget & ".repro.tmp"),
          "stray .repro.tmp orphan beside shell-profile sibling"

        echo "  [OK] fs.userFile macOS lifecycle: Preferences + " &
          "shell-profile sibling, mode 0644 + 0600, Apple " &
          "/Users/ expansion verified, destroy clean."
