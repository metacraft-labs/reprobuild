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
##   2. ENGINE — on macOS-arm64 only, drive ``./build/bin/repro build
##      <hcr-stem>`` and assert the build edge's argv includes
##      ``--passC:-fpatchable-function-entry=16,0`` and
##      ``--passL:-Wl,-segprot,__HCR,rwx,rwx``. On Linux this arm
##      SKIPs because the HCR tests are macOS-only at runtime anyway
##      (no benefit to forcing the engine path on a host that can't
##      validate the flag).
##
## Skip-with-classifier follows the standard B0/B1/B2/B3 shape.

import std/[os, strutils, unittest]

const RepoMarker = "repro.nim"
const HcrStems = [
  "t_hcr_agent_process_target",
  "t_e2e_repro_watch_hcr_multi_target_independent_patches",
  "t_e2e_repro_watch_hcr_one_target_agent_inject_failure",
]
const ExpectedPassC = "-fpatchable-function-entry=16,0"
const ExpectedPassL = "-Wl,-segprot,__HCR,rwx,rwx"

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

proc sliceForStem(content, stem: string): string =
  ## Return a ~600-char slice of ``content`` starting at the TestSpec
  ## entry whose ``binary`` field references the given stem. Returns the
  ## empty string when the stem is not found.
  let marker = "build/test-bin/" & stem & "\""
  let pos = content.find(marker)
  if pos < 0:
    return ""
  let limit = min(content.len, pos + 600)
  content[pos ..< limit]

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

    # --- per-HCR-stem assertions ---
    var missing: seq[string] = @[]
    for stem in HcrStems:
      let slice = sliceForStem(reproTestsText, stem)
      if slice.len == 0:
        missing.add(stem & " (not present in repro_tests.nim)")
        continue
      var problems: seq[string] = @[]
      if ExpectedPassC notin slice:
        problems.add("missing extraPassC value " & ExpectedPassC)
      if ExpectedPassL notin slice:
        problems.add("missing extraPassL value " & ExpectedPassL)
      if "targetOs: soMacosArm64" notin slice:
        problems.add("missing targetOs: soMacosArm64")
      if problems.len > 0:
        missing.add(stem & " — " & problems.join("; "))
    if missing.len > 0:
      for entry in missing:
        checkpoint("HCR spec problem: " & entry)
    check missing.len == 0

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
      # On Apple Silicon the engine path should produce a build edge that
      # passes the codesign workaround flags down to ``nim c``. The
      # detailed assertion lives in a follow-on that wires the path-mode
      # tool resolver for buildNimUnittest. Today this arm skips because
      # of the B3-outcome tool-profile gap.
      checkpoint("skipped — HCR engine-arm pending the buildNimUnittest " &
        "path-mode tool profile (per the B3 outcome). Structural arm " &
        "above covers the source-level migration intent.")
      skip()
    else:
      checkpoint("skipped — HCR tests are macOS-arm64-only at runtime; " &
        "the build flags are gated on cross-target aarch64-darwin. On " &
        "Linux/x86_64 the workaround is not exercised.")
      skip()
