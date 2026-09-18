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
##
## THE STATIC ARMS, added 2026-09-18. HLX-M5 landed with HLX-OQ-4's static case
## explicitly unmeasured. Two more link shapes now cover it — `-static-libgcc`
## and LLVM `libunwind.a`, both with `-Wl,-u,__register_frame` and
## `-Wl,-u,_Unwind_Backtrace` because a WEAK UNDEFINED reference does not pull
## an archive member — and neither binary has any unwinder in its `DT_NEEDED`
## list:
##
##   build \ link           libgcc.a            libunwind.a
##   healthy                fallback 0, FDE ok  fallback 0, FDE ok
##   whole-section-first    fallback 0, FDE ok  fallback 1, FDE ok
##
## i.e. the SAME disagreement, with nothing dynamic to identify. And the
## rejected candidate is measured failing: `dladdr(__register_frame)` names
## `libgcc_s.so.1` / `libunwind.so.1` in the dynamic arms and THE MAIN
## EXECUTABLE in both static ones, so a library-identifying detection has
## nothing to decide on exactly where the two conventions still differ.

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

      # ====================================================================
      # THE STATICALLY LINKED ARMS — ADDED 2026-09-18.
      #
      # HLX-M5 landed with HLX-OQ-4's static case explicitly NOT MEASURED, and
      # said so in this gate's own evidence: "Both arms link their unwinder
      # dynamically. `dladdr` was rejected partly because it cannot see a
      # static unwinder, so that advantage of probe-and-verify is argued rather
      # than measured." These four builds are the measurement.
      #
      # They matter because the static case is the one the rejected candidate
      # cannot answer AT ALL, not merely the one it answers badly.
      # ====================================================================
      let libgccStatic = buildFixture(repoRoot, "m5_abi_static_gcc",
        uwLibgccStatic)
      let libunwindStatic = buildFixture(repoRoot, "m5_abi_static_llvm",
        uwLlvmLibunwindStatic)
      let libgccStaticWhole = buildFixture(repoRoot,
        "m5_abi_static_gcc_whole", uwLibgccStatic,
        ["REPRO_HCR_HLX_M5_FALSIFY_WHOLE_SECTION_FIRST"])
      let libunwindStaticWhole = buildFixture(repoRoot,
        "m5_abi_static_llvm_whole", uwLlvmLibunwindStatic,
        ["REPRO_HCR_HLX_M5_FALSIFY_WHOLE_SECTION_FIRST"])

      # There is NO unwinder in either binary's DT_NEEDED list. That is the
      # premise of everything below; without it these would just be two more
      # dynamic arms under different names.
      ck "the static libgcc arm links no unwinder shared object at all",
        linkedUnwinderSonames(repoRoot, libgccStatic).len == 0
      ck "the static libunwind arm links no unwinder shared object at all",
        linkedUnwinderSonames(repoRoot, libunwindStatic).len == 0

      let libgccStaticRun = runArm(libgccStatic, "registered", payloads)
      let libunwindStaticRun = runArm(libunwindStatic, "registered", payloads)

      for (name, run) in [("libgcc-static", libgccStaticRun),
                          ("libunwind-static", libunwindStaticRun)]:
        # A NULL `__register_frame` is refused by name, and that refusal would
        # look like a green arm to every assertion below if it were not checked
        # first: a weak undefined reference does not pull an archive member, so
        # this is the exact way a static arm silently measures nothing.
        ck name & ": __register_frame really is present in the process",
          run["registerFrameAvailable"].getBool()
        ck name & ": the registration succeeded by name",
          run["ehFrameRefusal"].getStr() == "ok"
        ck name & ": the detection still picks the per-FDE convention",
          run["registerFrameConvention"].getStr() == "single-fde"
        ck name & ": the probe ran once and needed no fallback",
          run["probeAttempts"].getInt() == 1 and
            run["fallbackAttempts"].getInt() == 0
        ck name & ": no FDE covered the body BEFORE registration",
          not run["fdeFoundBeforeRegistration"].getBool()
        ck name & ": the statically linked unwinder FINDS the FDE",
          run["fdeFoundAfterRegistration"].getBool()
        ck name & ": the runtime walk crossed the patch body",
          run["unwindCrossesPatch"].getBool()
        ck name & ": the patched body actually ran",
          run["result"].getInt() == PatchedResult

      # ---- the falsifier, run against the static arms ---------------------
      # This is the load-bearing pair. With no shared object to identify, the
      # two toolchains must STILL disagree about the whole-section argument,
      # and the probe must still rescue the one that refuses it.
      let libgccStaticWholeRun =
        runArm(libgccStaticWhole, "registered", payloads)
      let libunwindStaticWholeRun =
        runArm(libunwindStaticWhole, "registered", payloads)

      ck "static libgcc accepts a whole-section registration (no fallback)",
        libgccStaticWholeRun["fallbackAttempts"].getInt() == 0
      ck "static libgcc's whole-section registration IS found",
        libgccStaticWholeRun["fdeFoundAfterRegistration"].getBool()
      ck "static LLVM libunwind REFUSES it, so the probe falls back",
        libunwindStaticWholeRun["fallbackAttempts"].getInt() == 1
      ck "the fallback rescues the static libunwind arm too",
        libunwindStaticWholeRun["registerFrameConvention"].getStr() ==
          "single-fde"
      ck "and its FDE is found after the fallback",
        libunwindStaticWholeRun["fdeFoundAfterRegistration"].getBool()
      ck "the two STATIC arms disagree exactly as the dynamic pair does",
        libgccStaticWholeRun["fallbackAttempts"].getInt() !=
          libunwindStaticWholeRun["fallbackAttempts"].getInt()

      # ---- WHY `dladdr` WAS REJECTED, measured rather than argued ---------
      # Each arm asks `dladdr` which object defines `__register_frame`. With a
      # dynamically linked unwinder the answers are different shared objects,
      # so a library-identifying detection would work. With the unwinder linked
      # statically both answers are THE ARM'S OWN EXECUTABLE — different file
      # names, but the same fact, "it is in the main program" — so there is
      # nothing left to tell libgcc from LLVM libunwind. That is the case
      # probe-and-verify exists for, and it is now a measurement.
      ck "dladdr names libgcc_s for the dynamic libgcc arm",
        libgccRun["dladdrRegisterFrameObject"].getStr().contains("libgcc_s")
      ck "dladdr names LLVM libunwind for the dynamic libunwind arm",
        libunwindRun["dladdrRegisterFrameObject"].getStr().contains("libunwind.so")
      ck "the two DYNAMIC answers differ, which is what made dladdr plausible",
        libgccRun["dladdrRegisterFrameObject"].getStr() !=
          libunwindRun["dladdrRegisterFrameObject"].getStr()
      ck "dladdr names the MAIN EXECUTABLE for the static libgcc arm",
        libgccStaticRun["dladdrRegisterFrameObject"].getStr() ==
          extractFilename(libgccStatic)
      ck "dladdr names the MAIN EXECUTABLE for the static libunwind arm",
        libunwindStaticRun["dladdrRegisterFrameObject"].getStr() ==
          extractFilename(libunwindStatic)
      # The binaries are named `m5_abi_static_gcc` / `m5_abi_static_llvm` and
      # NOT `..._libgcc_static`: the first spelling contains the literal
      # `libgcc_s` as a substring, so this very assertion failed against its own
      # fixture's file name the first time it was run. Left as a comment because
      # the assertion is worth keeping and the trap is worth naming.
      ck "so neither static answer names an unwinder at all",
        (not libgccStaticRun["dladdrRegisterFrameObject"].getStr()
             .contains("libgcc_s")) and
        (not libunwindStaticRun["dladdrRegisterFrameObject"].getStr()
             .contains("libunwind.so"))

      let elapsed = epochTime() - started
      ck "the gate did real work (ten links, ten runs)", elapsed > 1.0

      writeEvidence(repoRoot, gate, %*{
        "elapsedSeconds": elapsed,
        "sonames": %*{
          "libgcc": %libgccSonames,
          "libunwind": %libunwindSonames,
          "libgccStatic": %linkedUnwinderSonames(repoRoot, libgccStatic),
          "libunwindStatic": %linkedUnwinderSonames(repoRoot, libunwindStatic)},
        "healthy": %*{"libgcc": libgccRun, "libunwind": libunwindRun},
        "wholeSectionFirst": %*{
          "libgcc": libgccWholeRun, "libunwind": libunwindWholeRun},
        "noVerify": %*{
          "libgcc": libgccBlindRun, "libunwind": libunwindBlindRun},
        "staticHealthy": %*{
          "libgcc": libgccStaticRun, "libunwind": libunwindStaticRun},
        "staticWholeSectionFirst": %*{
          "libgcc": libgccStaticWholeRun,
          "libunwind": libunwindStaticWholeRun}
      })

      expectCount(asserted, 69)

else:
  suite "integration_hcr_linux_register_frame_abi_detection":
    test "[platform N/A] the HLX-M5 __register_frame ABI gate is linux-x86_64-only":
      check hostOS != "linux" or hostCPU != "amd64"
