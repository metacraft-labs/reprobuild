## HLX-M5 verification gate
## `integration_hcr_linux_register_frame_abi_detection`.
##
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §8.2 and open question
## `HLX-OQ-4`; `HCR/Debugger-Integration.md` §5.1.
## Milestone: `HCR-Linux-ELF-Provider.milestones.org`, HLX-M5.
##
## WHAT `HLX-OQ-4` ASKS. `__register_frame` exists in libgcc and in LLVM
## libunwind and the two disagree about its argument. The design's own words:
## "guessing wrong corrupts every backtrace, silently". Nothing in the corpus
## specified a detection; `dladdr` was the cheapest candidate and cannot see a
## statically linked unwinder.
##
## HOW IT IS RESOLVED HERE. Not by identifying the library — by REGISTERING and
## then asking `_Unwind_Find_FDE` whether the body became findable. The
## per-FDE convention is tried first because it is the one measured to work
## under both; if the unwinder does not then answer, the registration is undone
## and the whole-section convention is tried and verified the same way.
##
## THE MEASUREMENT THIS GATE EXISTS TO TAKE (2026-09-17; GCC 15.2.0 /
## libgcc_s, LLVM libunwind 21.1.8, glibc 2.42, Linux 6.12.85, x86_64):
##
##   `__register_frame(<section start>)`  libgcc: FOUND   libunwind: NOT found
##   `__register_frame(<first FDE>)`      libgcc: FOUND   libunwind: FOUND
##
## LLVM libunwind prints "bad fde: FDE is really a CIE" for the first row.
##
## `allowed_mocks: none`. Two real binaries, linked against two real unwinders,
## registering a real compiler-generated `.eh_frame` for a real patched body,
## with the real `_Unwind_Find_FDE` of each unwinder asked whether it worked.
##
## ------------------------------------------------------------------------
## DISCRIMINATION, measured by this file.
##
## The hard part of this gate is that THE LIBGCC ARM IS GREEN NO MATTER WHAT
## YOU GUESS. That is the trap `HLX-OQ-4` names, and a gate that ran on one
## toolchain would pass while shipping a silent corruption. So each unwinder is
## run against three builds of the SAME fixture:
##
##   healthy              — the shipped provider.
##   whole-section-first  — `REPRO_HCR_HLX_M5_FALSIFY_WHOLE_SECTION_FIRST`,
##                          which tries the convention `Debugger-Integration.md`
##                          §5.1 attributes to libgcc. Under libgcc: identical.
##                          Under libunwind: the probe must FALL BACK.
##   no-verify            — the two falsifiers together, i.e. whole-section AND
##                          `REPRO_HCR_HLX_M5_FALSIFY_SKIP_VERIFICATION`, which
##                          removes the `_Unwind_Find_FDE` check and BELIEVES
##                          the guess. Under libgcc: still green. Under
##                          libunwind: registration reports `ok` while the FDE
##                          is NOT found and the runtime backtrace collapses —
##                          success on status, red on bytes.
##
## The measured `fallbackAttempts` column is the whole answer:
##
##   build \ link           libgcc              LLVM libunwind
##   healthy                fallback 0, FDE ok  fallback 0, FDE ok
##   whole-section-first    fallback 0, FDE ok  fallback 1, FDE ok
##   no-verify              fallback 0, FDE ok  fallback 0, FDE NOT FOUND

import std/[json, os, strutils, times, unittest]

when defined(linux) and defined(amd64):
  import m5_fixture

  template expectCount(actual, expected: int) =
    if actual != expected:
      checkpoint("assertion count is " & $actual & ", expected " & $expected)
    check actual == expected

  suite "integration_hcr_linux_register_frame_abi_detection":
    test "the __register_frame convention is measured, not guessed, under both unwinders":
      var asserted = 0
      template ck(message: string; condition: untyped) =
        inc asserted
        if not (condition):
          checkpoint(message)
        check condition

      let started = epochTime()
      let repoRoot = getCurrentDir()
      let gate = "integration_hcr_linux_register_frame_abi_detection"
      let payloads = buildPayloads(repoRoot)

      let libgccHealthy = buildFixture(repoRoot, "m5_abi_libgcc", uwLibgcc)
      let libunwindHealthy =
        buildFixture(repoRoot, "m5_abi_libunwind", uwLlvmLibunwind)
      let libgccWholeFirst = buildFixture(repoRoot, "m5_abi_libgcc_whole",
        uwLibgcc, ["REPRO_HCR_HLX_M5_FALSIFY_WHOLE_SECTION_FIRST"])
      let libunwindWholeFirst = buildFixture(repoRoot, "m5_abi_libunwind_whole",
        uwLlvmLibunwind, ["REPRO_HCR_HLX_M5_FALSIFY_WHOLE_SECTION_FIRST"])
      let libgccNoVerify = buildFixture(repoRoot, "m5_abi_libgcc_noverify",
        uwLibgcc, ["REPRO_HCR_HLX_M5_FALSIFY_WHOLE_SECTION_FIRST",
                   "REPRO_HCR_HLX_M5_FALSIFY_SKIP_VERIFICATION"])
      let libunwindNoVerify = buildFixture(repoRoot, "m5_abi_libunwind_noverify",
        uwLlvmLibunwind, ["REPRO_HCR_HLX_M5_FALSIFY_WHOLE_SECTION_FIRST",
                          "REPRO_HCR_HLX_M5_FALSIFY_SKIP_VERIFICATION"])

      # THE LINK IS A CLAIM; `ldd` IS THE MEASUREMENT. Two arms that both ended
      # up on libgcc would agree with each other forever, and the gate would
      # report a toolchain comparison it never made.
      let libgccSonames = linkedUnwinderSonames(repoRoot, libgccHealthy)
      let libunwindSonames = linkedUnwinderSonames(repoRoot, libunwindHealthy)
      ck "the libgcc arm really is linked against libgcc_s",
        libgccSonames.contains("libgcc_s")
      ck "the libgcc arm carries no LLVM libunwind",
        not libgccSonames.contains("libunwind")
      ck "the libunwind arm really is linked against LLVM libunwind",
        libunwindSonames.contains("libunwind")
      ck "the libunwind arm carries no libgcc_s at all",
        not libunwindSonames.contains("libgcc_s")

      let libgccRun = runArm(libgccHealthy, "registered", payloads)
      let libunwindRun = runArm(libunwindHealthy, "registered", payloads)

      # ---- the healthy arms ----------------------------------------------
      for (name, run) in [("libgcc", libgccRun), ("libunwind", libunwindRun)]:
        ck name & ": the registration succeeded by name",
          run["ehFrameRefusal"].getStr() == "ok"
        ck name & ": exactly one FDE was relocated and registered",
          run["fdeCount"].getInt() == 1
        ck name & ": the detection picked the per-FDE convention",
          run["registerFrameConvention"].getStr() == "single-fde"
        ck name & ": the probe ran once",
          run["probeAttempts"].getInt() == 1
        ck name & ": no fallback was needed",
          run["fallbackAttempts"].getInt() == 0
        ck name & ": no FDE covered the body BEFORE registration",
          not run["fdeFoundBeforeRegistration"].getBool()
        ck name & ": the unwinder FINDS the FDE after registration",
          run["fdeFoundAfterRegistration"].getBool()
        ck name & ": the runtime walk crossed the patch body",
          run["unwindCrossesPatch"].getBool()
        ck name & ": the patched body actually ran",
          run["result"].getInt() == PatchedResult

      # ---- falsifier: the convention the design attributes to libgcc ------
      let libgccWholeRun = runArm(libgccWholeFirst, "registered", payloads)
      let libunwindWholeRun = runArm(libunwindWholeFirst, "registered", payloads)

      ck "libgcc accepts a whole-section registration, so the arm stays green",
        libgccWholeRun["ehFrameRefusal"].getStr() == "ok"
      ck "libgcc needed no fallback for the whole-section convention",
        libgccWholeRun["fallbackAttempts"].getInt() == 0
      ck "libgcc's whole-section registration IS found by the unwinder",
        libgccWholeRun["fdeFoundAfterRegistration"].getBool()
      ck "libgcc recorded the whole-section convention it was forced into",
        libgccWholeRun["registerFrameConvention"].getStr() == "whole-section"

      ck "LLVM libunwind REFUSES the whole-section registration, so the probe falls back",
        libunwindWholeRun["fallbackAttempts"].getInt() == 1
      ck "the fallback rescued it: the convention ends up per-FDE",
        libunwindWholeRun["registerFrameConvention"].getStr() == "single-fde"
      ck "and the FDE is found after the fallback",
        libunwindWholeRun["fdeFoundAfterRegistration"].getBool()
      ck "and the runtime walk still crosses the patch body",
        libunwindWholeRun["unwindCrossesPatch"].getBool()

      # This pair IS the toolchain difference, asserted rather than described.
      ck "the two unwinders genuinely disagree about the whole-section argument",
        libgccWholeRun["fallbackAttempts"].getInt() !=
          libunwindWholeRun["fallbackAttempts"].getInt()

      # ---- falsifier: believing the guess instead of measuring it ---------
      let libgccBlindRun = runArm(libgccNoVerify, "registered", payloads)
      let libunwindBlindRun = runArm(libunwindNoVerify, "registered", payloads)

      ck "without verification libgcc is STILL green — which is the trap",
        libgccBlindRun["fdeFoundAfterRegistration"].getBool()
      ck "without verification libgcc's runtime walk still crosses the patch",
        libgccBlindRun["unwindCrossesPatch"].getBool()

      ck "without verification the registration still REPORTS success",
        libunwindBlindRun["ehFrameRefusal"].getStr() == "ok"
      ck "…while the unwinder cannot find the FDE at all",
        not libunwindBlindRun["fdeFoundAfterRegistration"].getBool()
      ck "…and the runtime backtrace does not cross the patch body",
        not libunwindBlindRun["unwindCrossesPatch"].getBool()
      ck "…which is the silent corruption HLX-OQ-4 names, demonstrated",
        libunwindBlindRun["unwindTraceFrames"].getInt() <
          libunwindRun["unwindTraceFrames"].getInt()
      ck "the patched body still ran, so the corruption is unwinding-only",
        libunwindBlindRun["result"].getInt() == PatchedResult

      let elapsed = epochTime() - started
      ck "the gate did real work (six links, six runs)", elapsed > 1.0

      writeEvidence(repoRoot, gate, %*{
        "elapsedSeconds": elapsed,
        "sonames": %*{"libgcc": %libgccSonames, "libunwind": %libunwindSonames},
        "healthy": %*{"libgcc": libgccRun, "libunwind": libunwindRun},
        "wholeSectionFirst": %*{
          "libgcc": libgccWholeRun, "libunwind": libunwindWholeRun},
        "noVerify": %*{
          "libgcc": libgccBlindRun, "libunwind": libunwindBlindRun}
      })

      expectCount(asserted, 39)

else:
  suite "integration_hcr_linux_register_frame_abi_detection":
    test "[platform N/A] the HLX-M5 __register_frame ABI gate is linux-x86_64-only":
      check hostOS != "linux" or hostCPU != "amd64"
