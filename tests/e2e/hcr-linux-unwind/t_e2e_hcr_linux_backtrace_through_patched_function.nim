## HLX-M5 verification gate
## `e2e_hcr_linux_backtrace_through_patched_function`.
##
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §8.1, §8.2, §8.3 and
## `HCR/Debugger-Integration.md` §1, §2, §5.
## Milestone: `HCR-Linux-ELF-Provider.milestones.org`, HLX-M5.
##
## WHY THIS EXISTS. §8.1 states the defect in one sentence: inside the new body
## there is no FDE at all unless one is registered, the body lives in an
## anonymous `mmap` that belongs to no loaded object, and an unwind through it
## yields a corrupt or truncated backtrace. A patched process is then
## undebuggable exactly when debugging matters.
##
## THREE INSTRUMENTS, because three different pieces of software have to be
## able to walk the same stack:
##
##   1. REAL GDB, which parses the registered ELF `ET_REL` symfile itself;
##   2. REAL LLDB, which reaches the same registration through its
##      `JITLoaderGDB` plugin;
##   3. the process's OWN unwinder (`_Unwind_Backtrace`), which is answered by
##      `__register_frame` and not by the symfile at all.
##
## Instrument 3 is not decoration. GDB and LLDB never consult
## `__register_frame`, so a gate built only on debuggers would leave the
## `.eh_frame` half — the half that exceptions and `backtrace(3)` depend on —
## entirely unmeasured.
##
## `allowed_mocks: none`. Real GDB and real LLDB, driven at a real patched
## Linux process; real compiler-generated `.eh_frame` and a real `.o` symfile;
## real `_Unwind_Backtrace` inside the target. Nothing here fabricates a
## backtrace, and a missing debugger FAILS the gate rather than skipping it.
##
## ------------------------------------------------------------------------
## DISCRIMINATION, measured by this file (2026-09-17; GDB 17.1, LLDB 21.1.8,
## GCC 15.2.0, glibc 2.42, Linux 6.12.85, x86_64):
##
## Each debugger runs THREE arms against the SAME binary, differing only in
## which registration the fixture performed:
##
##   * `registered`   — patch + `.eh_frame` + JIT symfile. The subject.
##   * `unregistered` — patch, no registration. THE NEGATIVE CONTROL.
##   * `unpatched`    — no patch at all. THE POSITIVE CONTROL, which proves the
##                      driver can read a correct chain and that "corrupt" is
##                      not the only answer this instrument can give.
##
## Measured outcomes, which the assertions below encode:
##
##   GDB    registered   : #2 names `hcr_lx_m5_patch_body` at
##                         `hcr_lx_m5_patch.c:33`, chain complete to `main`,
##                         no `?? ()` anywhere.
##   GDB    unregistered : #2 is `?? ()`, a bogus stack address appears as a
##                         frame, and the walk stops — `main` is ABSENT.
##   LLDB   registered   : the patched frame is attributed to the JIT module
##                         and to `hcr_lx_m5_patch.c`.
##   LLDB   unregistered : the patched frame carries NO symbol at all. NOTE the
##                         honest difference from GDB: LLDB's frame-pointer
##                         fallback still recovers the CALLERS here, so its
##                         corruption is the unattributable frame rather than a
##                         truncated stack. Asserting truncation for LLDB would
##                         be asserting something that is not true.
##   in-process unwind   : 9 frames crossing the patch page and reaching `main`
##                         when registered; 1 frame, stopping at the patch
##                         page, when not.

import std/[json, os, strutils, times, unittest]

when defined(linux) and defined(amd64):
  import m5_fixture

  template expectCount(actual, expected: int) =
    if actual != expected:
      checkpoint("assertion count is " & $actual & ", expected " & $expected)
    check actual == expected

  suite "e2e_hcr_linux_backtrace_through_patched_function":
    test "GDB, LLDB and the in-process unwinder all cross the patched frame":
      var asserted = 0
      template ck(message: string; condition: untyped) =
        inc asserted
        if not (condition):
          checkpoint(message)
        check condition

      let started = epochTime()
      let repoRoot = getCurrentDir()
      let gate = "e2e_hcr_linux_backtrace_through_patched_function"

      # Prerequisites, loud. `requireDebugger` raises with the remedy in the
      # message when the binary is absent; it never returns a stand-in.
      let gdbPath = requireDebugger("gdb", gate)
      let lldbPath = requireDebugger("lldb", gate)
      let gdbVersion = debuggerVersion(gdbPath)
      let lldbVersion = debuggerVersion(lldbPath)
      ck "gdb reported a version", gdbVersion.len > 0
      ck "lldb reported a version", lldbVersion.len > 0

      let payloads = buildPayloads(repoRoot)
      ck "the patch body was extracted from a real object",
        payloads.bodyLen > 0
      ck "a compiler-generated .eh_frame was extracted",
        getFileSize(payloads.ehFramePath) > 0

      let binary = buildFixture(repoRoot, "m5_backtrace")
      ck "the fixture was built", fileExists(binary)

      # ---- the in-process unwinder -------------------------------------
      # Run first and without any debugger attached, so `_Unwind_Backtrace`'s
      # answer is not something a `ptrace` attach could have influenced.
      let registered = runArm(binary, "registered", payloads)
      let unregistered = runArm(binary, "unregistered", payloads)
      let unpatched = runArm(binary, "unpatched", payloads)

      ck "the patch took effect (the chain returns the patched value)",
        registered["result"].getInt() == PatchedResult
      ck "the control arm is the SAME patch, only unregistered",
        unregistered["result"].getInt() == PatchedResult
      ck "the positive control ran the ORIGINAL body",
        unpatched["result"].getInt() == UnpatchedResult

      ck "the registration succeeded by name",
        registered["ehFrameRefusal"].getStr() == "ok"
      ck "the JIT symfile registration succeeded by name",
        registered["jitRefusal"].getStr() == "ok"

      # The FDE is not findable before registration and is findable after. The
      # BEFORE reading is what stops "found" from being true for free: a patch
      # page is in no object's PT_LOAD, so a `_Unwind_Find_FDE` that answered
      # here would mean the instrument is measuring something else.
      ck "no FDE covered the patch body before registration",
        not registered["fdeFoundBeforeRegistration"].getBool()
      ck "the unwinder finds the FDE after registration",
        registered["fdeFoundAfterRegistration"].getBool()
      ck "the control never registers, so no FDE is ever found",
        not unregistered["fdeFoundAfterRegistration"].getBool()

      let registeredTrace = registered["unwindTrace"]
      let unregisteredTrace = unregistered["unwindTrace"]
      var registeredNames: seq[string] = @[]
      for frame in registeredTrace:
        registeredNames.add(frame["symbol"].getStr())
      ck "the in-process walk crossed the patch body",
        registered["unwindCrossesPatch"].getBool()
      ck "the in-process walk names level1 below the patch body",
        registeredNames.contains("hcr_lx_m5_level1")
      ck "the in-process walk names level2", registeredNames.contains("hcr_lx_m5_level2")
      ck "the in-process walk names level3", registeredNames.contains("hcr_lx_m5_level3")
      ck "the in-process walk reached main", registeredNames.contains("main")
      # The control's walk stops AT the patch body. Asserting the frame count
      # rather than "fewer frames" because the number is the observation: one
      # frame, the patch page itself, and nothing below it.
      ck "the unregistered walk is truncated at the patch page",
        unregisteredTrace.len < registeredTrace.len
      ck "the unregistered walk never reaches any caller",
        unregisteredTrace.len == 1
      ck "the unpatched positive control walks the original chain",
        unpatched["unwindTraceFrames"].getInt() ==
          registered["unwindTraceFrames"].getInt()

      # ---- GDB -----------------------------------------------------------
      let gdbRegistered = gdbBacktrace(gdbPath, binary, "registered", payloads)
      let gdbUnregistered = gdbBacktrace(gdbPath, binary, "unregistered", payloads)
      let gdbUnpatched = gdbBacktrace(gdbPath, binary, "unpatched", payloads)
      let gdbRegFrames = gdbFrames(gdbRegistered)
      let gdbUnregFrames = gdbFrames(gdbUnregistered)
      let gdbUnpatchedFrames = gdbFrames(gdbUnpatched)

      if gdbRegFrames.len == 0:
        checkpoint("GDB transcript (registered):\n" & gdbRegistered)
      ck "GDB produced frames at all", gdbRegFrames.len > 0
      let gdbPatchFrame = frameNaming(gdbRegFrames, PatchSymbol)
      if gdbPatchFrame < 0:
        checkpoint("GDB transcript (registered):\n" & gdbRegistered)
      ck "GDB resolved the patched frame to the patch body", gdbPatchFrame >= 0
      ck "GDB resolved a source file inside the patched body",
        gdbPatchFrame >= 0 and
          gdbRegFrames[gdbPatchFrame].contains("hcr_lx_m5_patch.c:")
      ck "GDB has a frame ABOVE the patched one",
        frameNaming(gdbRegFrames, "hcr_lx_m5_reached") >= 0
      ck "GDB has the whole caller chain BELOW the patched one, in order",
        chainInOrder(gdbRegFrames, CallerChain)
      ck "GDB's patched frame sits between them",
        gdbPatchFrame > frameNaming(gdbRegFrames, "hcr_lx_m5_reached") and
          gdbPatchFrame < frameNaming(gdbRegFrames, "hcr_lx_m5_level1")
      ck "no frame in GDB's registered backtrace is unresolved",
        frameNaming(gdbRegFrames, "?? ()") < 0

      # THE NEGATIVE CONTROL. Same binary, same breakpoint, same commands.
      if frameNaming(gdbUnregFrames, "?? ()") < 0:
        checkpoint("GDB transcript (unregistered):\n" & gdbUnregistered)
      ck "GDB cannot resolve the patched frame without registration",
        frameNaming(gdbUnregFrames, "?? ()") >= 0
      ck "GDB does not name the patch body without registration",
        frameNaming(gdbUnregFrames, PatchSymbol) < 0
      # The direct negation of the registered claim, rather than "main is
      # absent": whether GDB truncates at `level1` or wanders on depends on
      # whether the compiler happened to keep a frame pointer in the patch
      # body, and the property under test is the CHAIN, not the stopping point.
      ck "GDB's unregistered backtrace does not carry the whole caller chain",
        not chainInOrder(gdbUnregFrames, CallerChain)
      ck "GDB's unregistered backtrace is shorter than the registered one",
        gdbUnregFrames.len < gdbRegFrames.len

      # THE POSITIVE CONTROL for the driver itself.
      ck "GDB reads a correct chain through the ORIGINAL body",
        chainInOrder(gdbUnpatchedFrames, CallerChain)
      ck "the unpatched chain goes through the victim, not the patch body",
        frameNaming(gdbUnpatchedFrames, VictimSymbol) >= 0 and
          frameNaming(gdbUnpatchedFrames, PatchSymbol) < 0

      # ---- LLDB ----------------------------------------------------------
      let lldbRegistered = lldbBacktrace(lldbPath, binary, "registered", payloads)
      let lldbUnregistered = lldbBacktrace(lldbPath, binary, "unregistered", payloads)
      let lldbUnpatched = lldbBacktrace(lldbPath, binary, "unpatched", payloads)
      let lldbRegFrames = lldbFrames(lldbRegistered)
      let lldbUnregFrames = lldbFrames(lldbUnregistered)
      let lldbUnpatchedFrames = lldbFrames(lldbUnpatched)

      if lldbRegFrames.len == 0:
        checkpoint("LLDB transcript (registered):\n" & lldbRegistered)
      ck "LLDB produced frames at all", lldbRegFrames.len > 0
      let lldbPatchFrame = frameNaming(lldbRegFrames, PatchSymbol)
      if lldbPatchFrame < 0:
        checkpoint("LLDB transcript (registered):\n" & lldbRegistered)
      ck "LLDB resolved the patched frame to the patch body", lldbPatchFrame >= 0
      ck "LLDB resolved a source file inside the patched body",
        lldbPatchFrame >= 0 and
          lldbRegFrames[lldbPatchFrame].contains("hcr_lx_m5_patch.c:")
      ck "LLDB has a frame ABOVE the patched one",
        frameNaming(lldbRegFrames, "hcr_lx_m5_reached") >= 0
      ck "LLDB has the whole caller chain BELOW the patched one, in order",
        chainInOrder(lldbRegFrames, CallerChain)
      ck "LLDB's patched frame sits between them",
        lldbPatchFrame > frameNaming(lldbRegFrames, "hcr_lx_m5_reached") and
          lldbPatchFrame < frameNaming(lldbRegFrames, "hcr_lx_m5_level1")

      # THE NEGATIVE CONTROL for LLDB. Its corruption is the UNATTRIBUTABLE
      # frame, not a truncated stack — LLDB's frame-pointer fallback still
      # walks the callers. Asserted as measured rather than as hoped.
      if frameNaming(lldbUnregFrames, PatchSymbol) >= 0:
        checkpoint("LLDB transcript (unregistered):\n" & lldbUnregistered)
      ck "LLDB does not name the patch body without registration",
        frameNaming(lldbUnregFrames, PatchSymbol) < 0
      ck "LLDB does not resolve a source line without registration",
        frameNaming(lldbUnregFrames, "hcr_lx_m5_patch.c:") < 0
      ck "LLDB's unregistered patched frame carries no module either",
        frameNaming(lldbUnregFrames, "JIT(") < 0

      ck "LLDB reads a correct chain through the ORIGINAL body",
        chainInOrder(lldbUnpatchedFrames, CallerChain)
      ck "LLDB's unpatched chain goes through the victim",
        frameNaming(lldbUnpatchedFrames, VictimSymbol) >= 0

      let elapsed = epochTime() - started
      # A real build plus six debugger sessions cannot be instant. This is a
      # generous one-sided floor against vacuity, not a performance bound:
      # "N passed in ~0 s" is the tell that a suite did nothing.
      ck "the gate did real work (build + six debugger sessions)",
        elapsed > 1.0

      writeEvidence(repoRoot, gate, %*{
        "host": %*{
          "gdb": gdbVersion, "gdbPath": gdbPath,
          "lldb": lldbVersion, "lldbPath": lldbPath
        },
        "elapsedSeconds": elapsed,
        "inProcess": %*{
          "registered": registered,
          "unregistered": unregistered,
          "unpatched": unpatched
        },
        "gdb": %*{
          "registeredFrames": %gdbRegFrames,
          "unregisteredFrames": %gdbUnregFrames,
          "unpatchedFrames": %gdbUnpatchedFrames
        },
        "lldb": %*{
          "registeredFrames": %lldbRegFrames,
          "unregisteredFrames": %lldbUnregFrames,
          "unpatchedFrames": %lldbUnpatchedFrames
        }
      })

      expectCount(asserted, 46)

else:
  suite "e2e_hcr_linux_backtrace_through_patched_function":
    test "[platform N/A] the HLX-M5 backtrace gate is linux-x86_64-only":
      # Not a skip: the case asserts the HOST, so a linux/amd64 machine that
      # somehow compiled this branch fails here instead of reporting green.
      check hostOS != "linux" or hostCPU != "amd64"
