## M6 Phase-5 Gate: e2e_macos_phase5_fs_user_file
##
## Per the macOS Mac-host validation checklist in
## `metacraft/reprobuild-specs/Nix-Flake-Migration-Roadmap.md` ("Drivers
## with shipped macOS arms - never E2E-validated"), the `fs.userFile`
## driver (home-scope, in
## `libs/repro_home_resources/src/repro_home_resources/drivers/user_file.nim`)
## has had only a Linux WSL gate
## (`tests/e2e/m69/t_e2e_repro_home_fs_user_file_vm.nim`,
## `defined(linux)` only). This gate is the M6 macOS scaffolding; M7
## (`macOS Driver Validation - POSIX File Primitives`) populates the
## concrete `~/Library/Preferences/test.conf` + `~/.zprofile` apply +
## verify + destroy scenario.
##
## M6 deliverable: the non-destructive half asserts the pure mode
## parser (`parseModeOctal`, `filePermissionsFromMode`), the
## resource-typed digest stability, and the resource-typed
## validation. The destructive half is sandbox-gated to macOS + a
## new Phase-5 env var.
##
## ===========================================================================
## DESTRUCTIVE GATE - REQUIRES A macOS SANDBOX / VM. DO NOT RUN ON A
## REAL HOST.
## ===========================================================================
##
## The destructive half writes a real file under `$HOME` and verifies
## Apple-flavored `~`-expansion + POSIX mode application. Even though
## home-scope writes don't need root, they mutate the user's live
## `$HOME` tree; guarded by BOTH `defined(macosx)` AND
## `REPRO_PHASE5_MACOS_FS_USERFILE_VM=1`. M7 lands the concrete
## sandbox scenario; until then the destructive half emits a
## `[sandbox-gated]` notice.

import std/[os, unittest]

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
# M7 lands the concrete scenario; M6 only scaffolds.
# ===========================================================================

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
      echo "  [sandbox-scaffold] REPRO_PHASE5_MACOS_FS_USERFILE_VM " &
        "set; M6 scaffold present, M7 will populate the concrete " &
        "~/Library/Preferences/test.conf + ~/.zprofile lifecycle " &
        "steps."
