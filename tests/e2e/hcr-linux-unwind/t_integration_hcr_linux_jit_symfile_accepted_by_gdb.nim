## HLX-M5 verification gate
## `integration_hcr_linux_jit_symfile_accepted_by_gdb`.
##
## Design: `reprobuild-specs/HCR/Debugger-Integration.md` §1.2, §1.3, §8.3 and
## `HCR/Linux-ELF-Provider.md` §8.3.
## Milestone: `HCR-Linux-ELF-Provider.milestones.org`, HLX-M5.
##
## WHY GDB IS THE INSTRUMENT. §8.3 records that GDB is stricter than LLDB about
## a malformed JIT symfile, "so the ELF must be well-formed rather than merely
## plausible". LLDB will happily attribute a frame to a module it could not
## fully parse; GDB will not. So the acceptance question is asked of GDB.
##
## WHAT IS ASSERTED, and why each piece is separate:
##
##   1. The symfile was REBASED — `.text` `sh_addr` is the live patch address,
##      and the symbol value follows it. Asked of the provider's own evidence.
##   2. Relocations were APPLIED to `.debug_*` and then RETIRED, so nothing
##      applies them twice. A count, not a boolean: "at least one relocation"
##      is satisfied by one of twenty-six.
##   3. GDB ACCEPTS it — `info line`/`info symbol` at the live patch address
##      resolve to the patch source file and function. This is the step a
##      malformed ELF fails.
##   4. GDB RESOLVES SOURCE LINE NUMBERS INSIDE the patched body. Naming the
##      function only needs `.symtab`; naming a LINE needs `.debug_line` to have
##      survived relocation, which is the part that goes silently wrong.
##   5. Rollback UNREGISTERS the symfile and the `.eh_frame` section — the leak
##      the pre-existing code left open by defining `REPRO_HCR_JIT_UNREGISTER_FN`
##      and never using it. HLX-M3 wired the rollback half and could not reach
##      it; this is the first gate that does.
##
## `allowed_mocks: none`. Real GDB, a real ELF `ET_REL` symfile with really
## relocated `.debug_*` sections, registered by the production code into a real
## patched process.
##
## ------------------------------------------------------------------------
## DISCRIMINATION, measured by this file (2026-09-17, GDB 17.1, GCC 15.2.0):
##
##   * the line-number claim is discriminated by the `no-jit` arm: the same
##     process, the same patch, the same `.eh_frame` registration, and NO
##     symfile. GDB must then resolve NO line inside the patch page. A gate
##     that only ever registered would not be able to tell a resolved line
##     from a line GDB invented from a neighbouring object;
##   * the rebase claim is discriminated by the addresses themselves: the
##     symfile's `.text` address must equal the LIVE dispatch address the
##     provider reported, which is chosen at run time by `mmap` and cannot be
##     matched by a symfile that was not rebased;
##   * the unregistration claim is discriminated by the `registered` arm, in
##     which nothing is rolled back and the unregister count must therefore
##     stay 0. An unregister that fired unconditionally would pass a
##     "rollback unregisters" check trivially.

import std/[json, os, strutils, times, unittest]

when defined(linux) and defined(amd64):
  import m5_fixture

  template expectCount(actual, expected: int) =
    if actual != expected:
      checkpoint("assertion count is " & $actual & ", expected " & $expected)
    check actual == expected

  suite "integration_hcr_linux_jit_symfile_accepted_by_gdb":
    test "GDB accepts the ELF ET_REL symfile and resolves lines inside the patch":
      var asserted = 0
      template ck(message: string; condition: untyped) =
        inc asserted
        if not (condition):
          checkpoint(message)
        check condition

      let started = epochTime()
      let repoRoot = getCurrentDir()
      let gate = "integration_hcr_linux_jit_symfile_accepted_by_gdb"
      let gdbPath = requireDebugger("gdb", gate)
      let gdbVersion = debuggerVersion(gdbPath)
      ck "gdb reported a version", gdbVersion.len > 0

      let payloads = buildPayloads(repoRoot)
      let binary = buildFixture(repoRoot, "m5_symfile")
      let registered = runArm(binary, "registered", payloads)

      # ---- 1. the rebase --------------------------------------------------
      let dispatch = registered["dispatch"].getStr()
      ck "the patch was published somewhere", dispatch != "0x0"
      ck "the symfile registration succeeded by name",
        registered["jitRefusal"].getStr() == "ok"
      ck "the symfile's text section was rebased onto the LIVE patch address",
        registered["symfileTextAddress"].getStr() == dispatch
      ck "the patched symbol's value follows the rebased section",
        registered["symfileSymbolValue"].getStr() == dispatch
      ck "the rebased section is not section 0",
        registered["symfileTextSection"].getInt() > 0
      ck "more than one allocatable section was given an address",
        registered["symfileAllocatedSections"].getInt() >= 2

      # ---- 2. the relocations --------------------------------------------
      # A COUNT, because "at least one" is satisfied by one of twenty-six and
      # a symfile with one relocated `.debug_info` field and an unrelocated
      # `.debug_line` is exactly the shape that names a function and then
      # points at the wrong line.
      ck "every relocation the compiler emitted into the debug sections was applied",
        registered["symfileRelocations"].getInt() >= 20
      ck "the relocation sections were retired so nothing applies them twice",
        registered["symfileRetiredRelocSections"].getInt() >= 4

      # ---- 3 and 4. GDB accepts it, and resolves a LINE -------------------
      #
      # `frame 2` is the patched frame — `#0 reached`, `#1 reached_and_trace`,
      # `#2` the patch body. `info line *$pc` asks GDB for the source line of
      # the address INSIDE the patch page, which is the whole question.
      let accepted = gdbSession(gdbPath, binary, "registered", payloads,
        ["frame 2", "info line *$pc", "info symbol $pc"])
      let control = gdbSession(gdbPath, binary, "no-jit", payloads,
        ["frame 2", "info line *$pc", "info symbol $pc"])

      if not accepted.contains("hcr_lx_m5_patch.c"):
        checkpoint("GDB transcript (registered):\n" & accepted)
      ck "GDB attributes the patched PC to the patch source file",
        accepted.contains("hcr_lx_m5_patch.c")
      ck "GDB names the patched function at that PC",
        accepted.contains(PatchSymbol)
      ck "GDB resolved a LINE NUMBER inside the patched body",
        accepted.contains("Line ") and accepted.contains("hcr_lx_m5_patch.c")
      ck "GDB did not reject the symfile as malformed",
        not accepted.contains("not in executable format") and
        not accepted.contains("file format not recognized")

      # THE CONTROL. Same patch, same `.eh_frame`, no symfile.
      if control.contains("hcr_lx_m5_patch.c"):
        checkpoint("GDB transcript (no-jit control):\n" & control)
      ck "without the symfile GDB resolves no source file in the patch page",
        not control.contains("hcr_lx_m5_patch.c")
      ck "without the symfile GDB names no function in the patch page",
        not control.contains(PatchSymbol)
      ck "the control's patch was still applied, so only the symfile differs",
        runArm(binary, "no-jit", payloads)["result"].getInt() == PatchedResult

      # ---- 5. rollback unregisters ---------------------------------------
      ck "the registered arm records the symfile entry on its site",
        registered["recordedJitOnSite"].getInt() == 1
      ck "the registered arm records the .eh_frame payload on its site",
        registered["recordedEhFrameOnSite"].getInt() == 1
      ck "nothing was unregistered when nothing was rolled back",
        registered["jitUnregisterCalls"].getInt() == 0

      let rolled = runArm(binary, "rollback", payloads)
      ck "the rollback arm registered both things first",
        rolled["jitRefusal"].getStr() == "ok" and
        rolled["ehFrameRefusal"].getStr() == "ok"
      ck "the FDE was findable before the rollback",
        rolled["fdeFoundAfterRegistration"].getBool()
      ck "rollback attempted exactly two unregistrations (symfile + .eh_frame)",
        rolled["unregisterAttempts"].getInt() == 2
      ck "the JIT descriptor hook fired for the unregistration",
        rolled["jitUnregisterCalls"].getInt() == 1
      ck "the descriptor list is empty again",
        rolled["jitFirstEntry"].getStr() == "0x0"
      ck "the unwinder can no longer find the FDE for the rolled-back body",
        rolled["fdeFoundAfterRollback"].getInt() == 0
      ck "the rollback itself reported success",
        rolled["rollbackRc"].getInt() == 0

      # ---- 6. one owner of the descriptor, measured by linking ------------
      #
      # Design §8.3's last paragraph: both agents emit `__jit_debug_descriptor`
      # and `__jit_debug_register_code`, "so linking the C and Nim agents into
      # one binary produces duplicate symbols. The Linux port must pick one
      # owner". The probe is that binary; whether it LINKS is the measurement.
      let owner = buildJitOwnerProbe(repoRoot, "single")
      if not owner.ok:
        checkpoint("jit_owner_probe build output:\n" & owner.output)
      ck "the C agent and debug_unwind.nim link into one binary", owner.ok
      ck "exactly one __jit_debug_descriptor is DEFINED in it",
        owner.ok and
          definedSymbolCount(repoRoot, owner.binary, "__jit_debug_descriptor") == 1
      ck "exactly one __jit_debug_register_code is DEFINED in it",
        owner.ok and
          definedSymbolCount(repoRoot, owner.binary,
                             "__jit_debug_register_code") == 1

      # THE FALSIFIER: put the second definition back and the link must refuse
      # by name. Without this the two counts above could be measuring a binary
      # in which `debug_unwind.nim` simply never participated.
      let duplicated = buildJitOwnerProbe(repoRoot, "duplicate",
        ["reproHcrFalsifyDuplicateJitOwner"])
      ck "with two owners the link FAILS", not duplicated.ok
      ck "…and it fails by naming the duplicated descriptor",
        duplicated.output.contains("multiple definition of") and
          duplicated.output.contains("__jit_debug_descriptor")

      let elapsed = epochTime() - started
      ck "the gate did real work (build + two GDB sessions + three runs)",
        elapsed > 1.0

      writeEvidence(repoRoot, gate, %*{
        "host": %*{"gdb": gdbVersion, "gdbPath": gdbPath},
        "elapsedSeconds": elapsed,
        "registered": registered,
        "rolledBack": rolled,
        "jitOwner": %*{
          "singleOwnerLinks": owner.ok,
          "duplicateOwnerLinks": duplicated.ok,
          "duplicateLinkerOutputTail":
            duplicated.output[max(0, duplicated.output.len - 2000) .. ^1]
        },
        "gdbAcceptedTranscript": accepted,
        "gdbControlTranscript": control
      })

      expectCount(asserted, 32)

else:
  suite "integration_hcr_linux_jit_symfile_accepted_by_gdb":
    test "[platform N/A] the HLX-M5 JIT symfile gate is linux-x86_64-only":
      check hostOS != "linux" or hostCPU != "amd64"
