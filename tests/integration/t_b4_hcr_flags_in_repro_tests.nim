## Bootstrap-And-Self-Build B4: the three macOS-arm64 HCR tests have
## their special compile flags expressed via the typed-tool DSL's
## ``extraPassC`` / ``extraPassL`` slots and carry a ``targetOs:
## soMacosArm64`` cross-target guard.
##
## Two halves
## ----------
##
##   1. STRUCTURAL — read ``repro_tests.nim`` directly and assert that
##      each of the three known HCR stems has a ``TestSpec`` entry with
##      the expected ``extraPassC`` value
##      (``-fpatchable-function-entry=16,0``), the expected
##      ``extraPassL`` value (``-Wl,-segprot,__HCR,rwx,rwx``), and
##      ``targetOs: soMacosArm64``. Also assert ``repro.nim``'s test-
##      spec loop passes the lists through to
##      ``buildNimUnittest.build`` and ct-test's adapter has the slot
##      surface in place. This is the strong PASS arm — no engine
##      cooperation required.
##
##   2. ENGINE — on macOS-arm64 only, drive ``./build/bin/repro graph``
##      for one HCR build member and assert the lowered action's argv includes
##      ``--passC:-fpatchable-function-entry=16,0`` and
##      ``--passL:-Wl,-segprot,__HCR,rwx,rwx``. On Linux this arm
##      SKIPs because the HCR tests are macOS-only at runtime anyway
##      (no benefit to forcing the engine path on a host that can't
##      validate the flag).
##
## The old engine arm skipped unconditionally on Apple Silicon with a stale
## claim that buildNimUnittest lacked a path-mode profile. The graph now lowers
## that profile, so this case checks the real engine payload rather than
## preserving a historical limitation as a permanent skip.

import std/[json, os, strutils, unittest]

import repro_test_support

const RepoMarker = "repro.nim"
const ExpectedPassC = "-fpatchable-function-entry=16,0"
const ExpectedPassL = "-Wl,-segprot,__HCR,rwx,rwx"

## HX-S-10, 2026-09-19 — the stem list is DERIVED, not written down.
##
## This gate used to carry a three-name `const HcrStems` array. On 2026-09-18
## two of those three -- `t_e2e_repro_watch_hcr_multi_target_independent_patches`
## and `t_e2e_repro_watch_hcr_one_target_agent_inject_failure` -- were
## deliberately made portable: `targetOs: soAny`, no codesign flags, and they
## now build and PASS on Linux x86_64 (1 case each, measured 2026-09-19). The
## hardcoded list did not move with them, so this gate went RED on `dev` and
## stayed red, asserting that two portable tests must still be declared
## macOS-only.
##
## That is Verification-Harness-Traps.md Sec. 35 with the arrow reversed: a
## frozen subject list could not see the population change, and the CLAIM --
## "the three macOS-arm64 HCR tests" -- stopped being true the moment the
## population became one. The repair is the one that section prescribes:
## enumerate the subject from the thing being described, and assert the
## enumeration's own size against a floor so an empty derivation cannot satisfy
## every check below it.
##
## The rule is now stated in BOTH directions, which the frozen list could not
## do at all:
##
##   * every spec declaring `targetOs: soMacosArm64` must carry both flags, and
##   * every spec carrying either flag must declare `targetOs: soMacosArm64`,
##
## so the flags cannot be attached without the cross-target guard, and the guard
## cannot be declared without the flags. Adding a fourth macOS-arm64 HCR test
## is then covered with no edit here; removing one is too.
const MinMacosArmSpecs = 1

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoMarker) and
        fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc testSpecSlices(content: string): seq[(string, string)] =
  ## Every ``TestSpec(...)`` entry in ``repro_tests.nim``, as
  ## ``(binary-stem, entry-text)``. The entry ends at the next ``TestSpec(``
  ## or at end of text, so a field can never be read out of a neighbour's
  ## record -- which a fixed-width slice could do.
  result = @[]
  const Marker = "TestSpec("
  const BinaryMarker = "binary: \"build/test-bin/"
  var pos = content.find(Marker)
  while pos >= 0:
    let nextPos = content.find(Marker, pos + Marker.len)
    let stop = if nextPos < 0: content.len else: nextPos
    let entry = content[pos ..< stop]
    let bpos = entry.find(BinaryMarker)
    if bpos >= 0:
      let start = bpos + BinaryMarker.len
      let close = entry.find('"', start)
      if close > start:
        result.add((entry[start ..< close], entry))
    pos = nextPos

proc parseGraphOutput(output: string): JsonNode =
  let start = output.find('{')
  if start < 0:
    raise newException(ValueError, "repro graph emitted no JSON object")
  parseJson(output[start .. ^1])

suite "Bootstrap-And-Self-Build B4: HCR flags carry through the typed-tool DSL":

  test "structural: repro_tests.nim + repro.nim + ct-test wire HCR flags via extraPassC/extraPassL":
    let repoRoot = findRepoRoot()
    let reproTestsPath = repoRoot / "repro_tests.nim"
    let reproNimPath = repoRoot / "repro.nim"

    check fileExists(reproTestsPath)
    check fileExists(reproNimPath)

    let reproTestsText = readFile(reproTestsPath)
    let reproNimText = readFile(reproNimPath)

    # --- TestSpec shape ---
    check "extraPassC*: seq[string]" in reproTestsText
    check "extraPassL*: seq[string]" in reproTestsText
    check "targetOs*: TargetOs" in reproTestsText
    check "soAny, soMacosArm64" in reproTestsText

    # --- per-HCR-stem assertions, over a DERIVED subject set ---
    let specs = testSpecSlices(reproTestsText)
    # The instrument first. A parse that found nothing would satisfy every
    # assertion below by leaving nothing to disagree with it.
    checkpoint("repro_tests.nim declares " & $specs.len & " TestSpec entries")
    check specs.len >= 100

    var macosArmStems: seq[string] = @[]
    var flaggedStems: seq[string] = @[]
    var missing: seq[string] = @[]
    for (stem, entry) in specs:
      let declaresMacosArm = "targetOs: soMacosArm64" in entry
      let hasPassC = ExpectedPassC in entry
      let hasPassL = ExpectedPassL in entry
      if declaresMacosArm:
        macosArmStems.add(stem)
        var problems: seq[string] = @[]
        if not hasPassC:
          problems.add("missing extraPassC value " & ExpectedPassC)
        if not hasPassL:
          problems.add("missing extraPassL value " & ExpectedPassL)
        if problems.len > 0:
          missing.add(stem & " — " & problems.join("; "))
      if hasPassC or hasPassL:
        flaggedStems.add(stem)
        if not declaresMacosArm:
          missing.add(stem & " — carries the macOS codesign workaround flags " &
            "without declaring targetOs: soMacosArm64, so binutils-ld on a " &
            "Linux cross-target would be handed -segprot")
    checkpoint("specs declaring targetOs: soMacosArm64 — " &
      (if macosArmStems.len == 0: "(none)" else: macosArmStems.join(", ")))
    if missing.len > 0:
      for entry in missing:
        checkpoint("HCR spec problem: " & entry)
    check missing.len == 0
    # The population floor. Zero macOS-arm64 specs would make the loop above
    # vacuous, and "no spec is wrong" is not the claim this case makes.
    check macosArmStems.len >= MinMacosArmSpecs
    check flaggedStems.len >= MinMacosArmSpecs

    # --- repro.nim test-spec loop forwards the lists ---
    # The loop must call buildNimUnittest.build with extraPassC and
    # extraPassL parameters fed from spec.extraPassC / spec.extraPassL.
    # The CI-break fix gated the forwarding on ``when hostIsMacos``
    # (so binutils-ld on Linux doesn't reject the macOS-only
    # ``-Wl,-segprot`` flag), so the assertion now checks for the
    # substring fragments rather than the literal ``extraPassC =
    # spec.extraPassC`` form. The structural intent — the spec's
    # extraPassC/L values are routed through to buildNimUnittest's
    # cli surface — is unchanged.
    check "spec.extraPassC" in reproNimText
    check "spec.extraPassL" in reproNimText
    check "extraPassC =" in reproNimText
    check "extraPassL =" in reproNimText

    # --- in-tree ct-test adapter exposes the slots ---
    let adapter = repoRoot / "libs" / "ct_test_nim_unittest" /
      "src" / "ct_test_nim_unittest.nim"
    if fileExists(adapter):
      let adapterText = readFile(adapter)
      check "extraPassC: seq[string]" in adapterText
      check "extraPassL: seq[string]" in adapterText
      check "--passC:" in adapterText
      check "--passL:" in adapterText
    else:
      checkpoint("in-tree ct-test adapter not found at " & adapter &
        "; skipping that arm")

    checkpoint("B4 HCR-flag structural assertion: OK")

  test "engine: HCR flags reach nim c argv on macOS-arm64":
    when defined(macosx) and (defined(arm64) or defined(aarch64)):
      let repoRoot = findRepoRoot()
      let reproBin = requireBinary(repoRoot / "build" / "bin" /
        addFileExt("repro", ExeExt), "reprobuild.apps.repro")
      let runquotad = requireRunQuotaDaemonBin(repoRoot)
      let macosArmSpecs = testSpecSlices(readFile(repoRoot / "repro_tests.nim"))
      var targetStem = ""
      for (stem, entry) in macosArmSpecs:
        if "targetOs: soMacosArm64" in entry:
          targetStem = stem
          break
      require targetStem.len > 0
      let target = ".#test-builds#" & targetStem
      let res = runShell(shellCommand(@[
        reproBin,
        "graph",
        target,
        "--tool-provisioning=path",
        "--format=json",
      ], @[("PATH", runquotad.parentDir & $PathSep & getEnv("PATH"))]),
        repoRoot)
      if res.code != 0:
        checkpoint(res.output)
      check res.code == 0
      if res.code == 0:
        let graph = parseGraphOutput(res.output)
        var matchedAction = false
        for action in graph{"actions"}:
          var hasInput = false
          for input in action{"inputs"}:
            if input.getStr("").endsWith("/" & targetStem & ".nim"):
              hasInput = true
          if not hasInput:
            continue

          var hasPassC = false
          var hasPassL = false
          for arg in action{"argv"}:
            let value = arg.getStr("")
            if value == "--passC:" & ExpectedPassC:
              hasPassC = true
            if value == "--passL:" & ExpectedPassL:
              hasPassL = true
          checkpoint("HCR lowered action id=" & action{"id"}.getStr("") &
            " passC=" & $hasPassC & " passL=" & $hasPassL)
          check hasPassC
          check hasPassL
          matchedAction = true
        check matchedAction
    else:
      # HX-S-10: this arm is genuinely macOS-arm64-only -- the codesign
      # workaround it measures is gated on the aarch64-darwin cross-target --
      # but it used to say so only in a `checkpoint`, which nothing greps. The
      # lane manifest declares this gate `run:1+skip:1` on Linux and Windows,
      # and a declared skip is accepted ONLY if it carries this diagnostic, so
      # a bare skip() here would redden the lane rather than sit inside the
      # allowance.
      announceHcrUnsupportedHost(
        "t_b4_hcr_flags_in_repro_tests engine arm", "macOS arm64",
        "macOS arm64 CI on eph-macos-arm64")
      skip()
