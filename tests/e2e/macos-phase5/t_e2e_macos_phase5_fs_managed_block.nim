## M7 Phase-5 Gate: e2e_macos_phase5_fs_managed_block
##
## Per the macOS Mac-host validation checklist in
## `metacraft/reprobuild-specs/Nix-Flake-Migration-Roadmap.md` ("Drivers
## with shipped macOS arms - never E2E-validated"), the
## `fs.managedBlock` driver (home-scope, in
## `libs/repro_home_resources/src/repro_home_resources/drivers/managed_block.nim`)
## has had only a Linux WSL gate
## (`tests/e2e/m69/t_e2e_repro_home_fs_managed_block_vm.nim`,
## `defined(linux)` only). M6 scaffolded the gate; M7 populates the
## concrete `~/.zprofile-repro-phase5-test` managed-block apply +
## re-apply (no-op) + update + destroy scenario inside a Tart-managed
## macOS VM.
##
## Non-destructive half asserts the pure sentinel splice
## (`spliceManagedBlock`), the resource-typed digest, and the
## resource validation. The destructive half is sandbox-gated to
## macOS + the Phase-5 env var.
##
## ===========================================================================
## DESTRUCTIVE GATE - REQUIRES A macOS SANDBOX / VM. DO NOT RUN ON A
## REAL HOST.
## ===========================================================================
##
## The destructive half writes a managed block into a real shell
## profile in `$HOME`. Guarded by BOTH `defined(macosx)` AND
## `REPRO_PHASE5_MACOS_FS_MANAGEDBLOCK_VM=1`. The host-side runner
## (`run_phase5_in_tart.nim`) cross-builds this binary, copies it
## into a freshly-cloned Tart macOS guest, and runs it with the env
## var set.

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
# The host-side runner cross-builds this binary, copies it into a Tart
# macOS guest, and runs it with the env var set.
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
      when defined(macosx):
        # -----------------------------------------------------------------
        # Target file: a `.zprofile`-shaped sibling under `$HOME` we
        # fully own for the test lifetime — avoids clobbering the
        # admin user's real `.zprofile`. The block id is
        # `phase5-fs-managedblock` so the sentinel comments are
        # recognizable in the on-disk file.
        # -----------------------------------------------------------------
        let pid = $getCurrentProcessId()
        let target = expandTilde(
          "~/.zprofile-repro-phase5-mb-" & pid)
        doAssert target.startsWith("/Users/"),
          "managedBlock target '" & target &
          "' not under Apple-flavored /Users/ (HOME expansion misbehaved)"
        let blockId = "phase5-fs-managedblock"

        if fileExists(target):
          removeFile(target)

        # Pre-existing surrounding content the splice must preserve.
        # We intentionally place text BOTH before and AFTER (the splice
        # contract: edits outside the sentinels are not drift; the
        # destroy direction removes only the block + sentinel lines).
        let preamble = "# user-owned preamble line 1\n" &
          "# user-owned preamble line 2\n"
        let trailing = "# user-owned trailing line 1\n" &
          "# user-owned trailing line 2\n"
        writeFile(target, preamble & trailing)

        # -----------------------------------------------------------------
        # 1. Apply: inserts the managed block at end of file.
        # -----------------------------------------------------------------
        let content1 = "export REPRO_PHASE5_MB_V=1\n" &
          "alias repro-phase5-mb='echo v1'\n"
        let recorded1 = applyManagedBlockResource(target, blockId, content1)
        doAssert fileExists(target)
        let after1 = readFile(target)
        # Sentinel comments are present.
        let openS = "# >>> repro-managed:" & blockId & " >>>"
        let closeS = "# <<< repro-managed:" & blockId & " <<<"
        doAssert after1.contains(openS),
          "open sentinel missing after apply"
        doAssert after1.contains(closeS),
          "close sentinel missing after apply"
        # Body is between sentinels.
        doAssert after1.contains("REPRO_PHASE5_MB_V=1"),
          "managed body missing after apply"
        # Surrounding user content is preserved verbatim.
        doAssert after1.contains("# user-owned preamble line 1"),
          "preamble lost after apply"
        doAssert after1.contains("# user-owned trailing line 1"),
          "trailing lost after apply"
        doAssert recorded1.len > 0

        # Observation digest matches the recorded payload.
        let obs1 = observeManagedBlock(target, blockId)
        doAssert obs1.present
        doAssert obs1.rawBytes == recorded1

        # -----------------------------------------------------------------
        # 2. Re-apply with the SAME content — idempotent.
        #    The on-disk bytes between the sentinels must be byte-equal
        #    after the second apply, and the observation digest must
        #    not change. The driver may rewrite the file (the splice is
        #    not currently a digest-skip cache hit at the driver level),
        #    but the observed bytes are stable.
        # -----------------------------------------------------------------
        let preReapply = readFile(target)
        let recorded2 = applyManagedBlockResource(target, blockId, content1)
        let obs2 = observeManagedBlock(target, blockId)
        doAssert obs2.present
        doAssert obs2.digest == obs1.digest,
          "managed-block digest changed across same-content re-apply"
        doAssert recorded2 == recorded1
        # The full file contents are byte-stable across the same-content
        # re-apply (the splice is content-deterministic; sentinel
        # positions, body bytes, and surrounding content all unchanged).
        doAssert readFile(target) == preReapply,
          "managed-block file bytes drifted across same-content re-apply"

        # -----------------------------------------------------------------
        # 3. Update: change body; the splice rewrites the inner section
        #    in place, leaving the sentinels + surrounding content
        #    intact.
        # -----------------------------------------------------------------
        let content2 = "export REPRO_PHASE5_MB_V=2\n" &
          "alias repro-phase5-mb='echo v2'\n" &
          "# added line in v2\n"
        let recorded3 = applyManagedBlockResource(target, blockId, content2)
        let after3 = readFile(target)
        doAssert after3.contains("REPRO_PHASE5_MB_V=2"),
          "updated body missing"
        doAssert not after3.contains("REPRO_PHASE5_MB_V=1"),
          "old body still present after update"
        doAssert after3.contains("# added line in v2")
        doAssert after3.contains(openS) and after3.contains(closeS),
          "sentinels lost after update"
        # Surrounding preamble + trailing still intact.
        doAssert after3.contains("# user-owned preamble line 1")
        doAssert after3.contains("# user-owned trailing line 1")
        # Observation reports new digest.
        let obs3 = observeManagedBlock(target, blockId)
        doAssert obs3.present
        doAssert obs3.digest != obs1.digest,
          "observation digest unchanged after update"
        doAssert obs3.rawBytes == recorded3

        # -----------------------------------------------------------------
        # 4. Destroy: removes the block + both sentinels; surrounding
        #    content remains.
        # -----------------------------------------------------------------
        destroyManagedBlockResource(target, blockId)
        let after4 = readFile(target)
        doAssert not after4.contains(openS),
          "open sentinel still present after destroy"
        doAssert not after4.contains(closeS),
          "close sentinel still present after destroy"
        doAssert not after4.contains("REPRO_PHASE5_MB_V"),
          "managed body still present after destroy"
        # Surrounding user content survives the destroy direction.
        doAssert after4.contains("# user-owned preamble line 1"),
          "preamble lost in destroy"
        doAssert after4.contains("# user-owned preamble line 2"),
          "preamble line 2 lost in destroy"
        doAssert after4.contains("# user-owned trailing line 1"),
          "trailing lost in destroy"
        doAssert after4.contains("# user-owned trailing line 2"),
          "trailing line 2 lost in destroy"
        # Observation reports absent (no sentinels => block absent).
        let obs4 = observeManagedBlock(target, blockId)
        doAssert not obs4.present

        # -----------------------------------------------------------------
        # 5. Cleanup: leave the host the way we found it.
        # -----------------------------------------------------------------
        removeFile(target)
        doAssert not fileExists(target)

        echo "  [OK] fs.managedBlock macOS lifecycle: apply / " &
          "re-apply (no-op) / update / destroy; sentinel comments " &
          "preserved across all stages; surrounding content " &
          "byte-stable; destroy removes block + sentinels only."
