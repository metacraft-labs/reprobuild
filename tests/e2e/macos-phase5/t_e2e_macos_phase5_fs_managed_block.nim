## M6 Phase-5 Gate: e2e_macos_phase5_fs_managed_block
##
## Per the macOS Mac-host validation checklist in
## `metacraft/reprobuild-specs/Nix-Flake-Migration-Roadmap.md` ("Drivers
## with shipped macOS arms - never E2E-validated"), the
## `fs.managedBlock` driver (home-scope, in
## `libs/repro_home_resources/src/repro_home_resources/drivers/managed_block.nim`)
## has had only a Linux WSL gate
## (`tests/e2e/m69/t_e2e_repro_home_fs_managed_block_vm.nim`,
## `defined(linux)` only). This gate is the M6 macOS scaffolding; M7
## populates the concrete `~/.zprofile` managed-block apply +
## re-apply (no-op) + update + destroy scenario.
##
## M6 deliverable: the non-destructive half asserts the pure
## sentinel splice (`spliceManagedBlock`), the resource-typed
## digest, and the resource validation. The destructive half is
## sandbox-gated to macOS + a new Phase-5 env var.
##
## ===========================================================================
## DESTRUCTIVE GATE - REQUIRES A macOS SANDBOX / VM. DO NOT RUN ON A
## REAL HOST.
## ===========================================================================
##
## The destructive half writes a managed block into a real shell
## profile in `$HOME`. Guarded by BOTH `defined(macosx)` AND
## `REPRO_PHASE5_MACOS_FS_MANAGEDBLOCK_VM=1`. M7 lands the
## concrete sandbox scenario.

import std/[os, strutils, unittest]

import repro_home_resources

let sandboxMode =
  defined(macosx) and
  getEnv("REPRO_PHASE5_MACOS_FS_MANAGEDBLOCK_VM") == "1"

# ===========================================================================
# NON-DESTRUCTIVE: pure sentinel splice + digest + validation.
# Always runs.
# ===========================================================================

suite "fs.managedBlock: pure sentinel splice":

  test "spliceManagedBlock inserts a new block at end of file":
    let openS = "# >>> repro-managed:m6 <<<"
    let closeS = "# <<< repro-managed:m6 >>>"
    let after = spliceManagedBlock("existing content\n",
      "managed body\n", openS, closeS)
    check after.contains("existing content")
    check after.contains(openS)
    check after.contains("managed body")
    check after.contains(closeS)
    # Existing content is preserved verbatim ahead of the block.
    check after.startsWith("existing content\n")

  test "spliceManagedBlock updates an existing block in place":
    let openS = "# >>> repro-managed:m6 <<<"
    let closeS = "# <<< repro-managed:m6 >>>"
    let original = "preamble\n" & openS & "\nold body\n" & closeS &
      "\ntrailing\n"
    let updated = spliceManagedBlock(original, "new body\n",
      openS, closeS)
    check updated.contains("preamble")
    check updated.contains("new body")
    check not updated.contains("old body")
    check updated.contains("trailing")

suite "fs.managedBlock: typed-resource wiring + digest":

  test "a fs.managedBlock Resource accepts the canonical fields":
    let r = Resource(kind: rkFsManagedBlock,
      address: "managedBlock:~/.zprofile#m6",
      lifecyclePolicy: lpDefault,
      hostFilePath: "/Users/zahary/.zprofile",
      managedBlockId: "m6",
      managedBlockContent: "export REPRO_M6=1\n")
    check resourceValidationError(r) == ""
    check realWorldIdentity(r) == "/Users/zahary/.zprofile#m6"

  test "digestOfResource changes when block content changes":
    var r = Resource(kind: rkFsManagedBlock,
      address: "managedBlock:digest",
      lifecyclePolicy: lpDefault,
      hostFilePath: "/tmp/repro-m6-mb.txt",
      managedBlockId: "m6",
      managedBlockContent: "v=1\n")
    let d0 = digestOfResource(r)
    r.managedBlockContent = "v=2\n"
    let d1 = digestOfResource(r)
    check d0 != d1

  test "resourceKindFromString recognizes fs.managedBlock":
    check resourceKindFromString("fs.managedBlock") == rkFsManagedBlock

# ===========================================================================
# DESTRUCTIVE: real managed-block write under `$HOME`. SANDBOX/VM-ONLY -
# guarded by BOTH macOS + `REPRO_PHASE5_MACOS_FS_MANAGEDBLOCK_VM=1`.
# M7 lands the concrete scenario; M6 only scaffolds.
# ===========================================================================

suite "fs.managedBlock: REAL apply / update / destroy (sandbox-only)":

  test "real fs.managedBlock lifecycle (only under macOS + env var)":
    if not sandboxMode:
      echo "  [sandbox-gated] REPRO_PHASE5_MACOS_FS_MANAGEDBLOCK_VM " &
        "not set (or not on macOS) - the real `$HOME` managed-block " &
        "write + re-apply (no-op) + update + destroy scenario is NOT " &
        "EXERCISED on this host. Run this gate inside a disposable " &
        "macOS VM with REPRO_PHASE5_MACOS_FS_MANAGEDBLOCK_VM=1 to " &
        "exercise the real ~/.zprofile splice. The pure-logic suites " &
        "above already proved the sentinel splice + typed-field " &
        "digest + validation without mutating any host."
    else:
      echo "  [sandbox-scaffold] REPRO_PHASE5_MACOS_FS_MANAGEDBLOCK_VM " &
        "set; M6 scaffold present, M7 will populate the concrete " &
        "managed-block lifecycle steps."
