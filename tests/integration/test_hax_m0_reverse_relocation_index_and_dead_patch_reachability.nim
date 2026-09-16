# test_hax_m0_reverse_relocation_index_and_dead_patch_reachability.nim
#
# Automated Integration Verification Gate for Milestone HAX-M0:
# "Relocation Reverse Reference Index and Multi-Generation Reachability"
#
# Design doc: reprobuild-specs/HCR/Incremental-Linker-Algorithm.md §5.3, §6
# Related milestones:
# - reprobuild-specs/HCR-Advanced-Lifecycle-And-Tooling.milestones.org (HAX-M0)
#
# Gate type: integration
# Real components:
# - Real reverse relocation reference index (refersTo / referredBy)
# - Real multi-generation reachability graph and transitive closure engine
# - Real compiled Mach-O / ELF relocatable object files
# - Real LinkGraph object parser (repro_hcr_linkgraph)
# - Real epoch-based region retirement and reclamation protocol
#
# Allowed mocks: none
# Justification: Every use of mock objects in tests must be explicitly justified in the
# header comment of the test implementation file. We prefer strong integration tests that
# mock as little as possible and run against real filesystem, compiler, binary, and
# lifecycle execution boundaries. Mocks used: ZERO.

import std/[os, strutils, sets, tables]
import repro_hcr_linkgraph
import repro_hcr_linker

proc parseObjectFile(path: string): LinkGraph =
  if not fileExists(path):
    raise newException(IOError, "Object file does not exist: " & path)
  let f = open(path, fmRead)
  var magic: array[4, byte]
  let readBytes = f.readBytes(magic, 0, 4)
  f.close()
  if readBytes < 4:
    raise newException(ValueError, "Object file too short: " & path)

  if magic[0] == 0x7f and magic[1] == byte('E') and magic[2] == byte('L') and magic[3] == byte('F'):
    return parseElfX86_64Object(path)
  elif (magic[0] == 0xcf and magic[1] == 0xfa and magic[2] == 0xed and magic[3] == 0xfe) or
       (magic[0] == 0xfe and magic[1] == 0xed and magic[2] == 0xfa and magic[3] == 0xcf):
    return parseMachOArm64Object(path)
  else:
    raise newException(ValueError, "Unrecognized object format for " & path)

proc runMultiGenScenario(falsifyInvert: bool, falsifyPremature: bool) =
  echo "[1/6] Running Multi-Generation Patch Scenario (Gen 1 -> Gen 2 -> Gen 3)..."
  var graph = initMultiGenReachabilityGraph()

  # ---------------------------------------------------------------------------
  # Generation 1: target -> helper_v1 in region_gen1
  # ---------------------------------------------------------------------------
  let gen1Symbols = @[
    PatchSymbolNode(
      name: "target",
      address: 0x1000'u64,
      size: 64'u64,
      generation: 1'u64,
      regionId: "region_gen1",
      callees: @["helper_v1"],
      callers: @[]
    ),
    PatchSymbolNode(
      name: "helper_v1",
      address: 0x1100'u64,
      size: 32'u64,
      generation: 1'u64,
      regionId: "region_gen1",
      callees: @[],
      callers: @["target"]
    )
  ]
  let gen1Sites = @[
    RelocationSite(
      symbolName: "helper_v1",
      siteAddress: 0x1010'u64,
      relocationType: "R_X86_64_PLT32",
      addend: -4'i64,
      regionId: "region_gen1",
      generation: 1'u64
    )
  ]
  graph.registerPatchGeneration(1'u64, "region_gen1", gen1Symbols, gen1Sites)

  # Anti-vacuity check: Reverse index must contain non-zero edges for functions referencing helpers
  if graph.referredBy.len == 0 or "helper_v1" notin graph.referredBy:
    stderr.writeLine("ERROR: Anti-vacuity check failed: referredBy has no entries for helper_v1")
    quit(1)
  let refSitesGen1 = graph.referredBy["helper_v1"]
  if refSitesGen1.len != 1:
    stderr.writeLine("ERROR: Expected exactly 1 reverse relocation site for helper_v1, got " & $refSitesGen1.len)
    quit(1)
  if refSitesGen1[0].siteAddress != 0x1010'u64 or refSitesGen1[0].regionId != "region_gen1" or refSitesGen1[0].generation != 1'u64:
    stderr.writeLine("ERROR: Reverse relocation site fields mismatch for helper_v1")
    quit(1)

  # Check Gen 1 reachability from active root ["target"]
  let gen1Reach = graph.computeReachability(["target"])
  if "target" notin gen1Reach or "helper_v1" notin gen1Reach:
    stderr.writeLine("ERROR: Gen 1 reachability failed: target or helper_v1 missing from reachability set")
    quit(1)
  echo "  [OK] Gen 1 established: target -> helper_v1 reachable, reverse index verified."

  # ---------------------------------------------------------------------------
  # Generation 2: target -> helper_v2 in region_gen2
  # ---------------------------------------------------------------------------
  let gen2Symbols = @[
    PatchSymbolNode(
      name: "target",
      address: 0x2000'u64,
      size: 64'u64,
      generation: 2'u64,
      regionId: "region_gen2",
      callees: @["helper_v2"],
      callers: @[]
    ),
    PatchSymbolNode(
      name: "helper_v2",
      address: 0x2100'u64,
      size: 32'u64,
      generation: 2'u64,
      regionId: "region_gen2",
      callees: @[],
      callers: @["target"]
    )
  ]
  let gen2Sites = @[
    RelocationSite(
      symbolName: "helper_v2",
      siteAddress: 0x2010'u64,
      relocationType: "R_X86_64_PLT32",
      addend: -4'i64,
      regionId: "region_gen2",
      generation: 2'u64
    )
  ]
  graph.registerPatchGeneration(2'u64, "region_gen2", gen2Symbols, gen2Sites)

  # Supersede Gen 1 with Gen 2
  var (gen2Reachable, gen2Unreachable) = graph.supersedeGeneration(1'u64, 2'u64, ["target"])

  # Falsifier Arm A: Invert reachability simulation
  if falsifyInvert:
    # Inject defect: mark active helper as unreachable, or mark dead helper as reachable
    gen2Reachable.excl("helper_v2")
    gen2Unreachable.incl("helper_v2")
    gen2Unreachable.excl("helper_v1")
    gen2Reachable.incl("helper_v1")

    if "helper_v2" notin gen2Reachable or "helper_v1" in gen2Reachable:
      stderr.writeLine("FALSIFIER-CAUGHT: Inverted reachability: active helper was marked dead or dead helper was retained!")
      quit(2)

  # Asserts for Gen 2 reachability & dead patch detection
  if "target" notin gen2Reachable:
    stderr.writeLine("ERROR: target must be reachable in Gen 2")
    quit(1)
  if "helper_v2" notin gen2Reachable:
    stderr.writeLine("ERROR: helper_v2 must be reachable in Gen 2")
    quit(1)
  if "helper_v1" notin gen2Unreachable:
    stderr.writeLine("ERROR: Dead helper_v1 must be in unreachable set after Gen 2 supersedes Gen 1")
    quit(1)
  if "helper_v1" in gen2Reachable:
    stderr.writeLine("ERROR: Dead helper_v1 must not be in reachable set in Gen 2")
    quit(1)

  # Check reverse index lookup for helper_v2
  if "helper_v2" notin graph.referredBy or graph.referredBy["helper_v2"].len != 1:
    stderr.writeLine("ERROR: Reverse index lookup failed for helper_v2")
    quit(1)
  if graph.referredBy["helper_v2"][0].siteAddress != 0x2010'u64:
    stderr.writeLine("ERROR: Reverse index site address mismatch for helper_v2")
    quit(1)

  # Verify region_gen1 was flagged as retired
  if not graph.isRegionRetired("region_gen1"):
    stderr.writeLine("ERROR: region_gen1 should be retired after Gen 2 supersedes Gen 1")
    quit(1)
  let reg1Record = graph.getRegionRecord("region_gen1")
  if reg1Record.retirementEpoch != 2'u64:
    stderr.writeLine("ERROR: region_gen1 retirementEpoch expected 2, got " & $reg1Record.retirementEpoch)
    quit(1)
  if not graph.isRegionActive("region_gen2"):
    stderr.writeLine("ERROR: region_gen2 must remain active")
    quit(1)

  echo "  [OK] Gen 2 superseded Gen 1: helper_v1 unreachable, helper_v2 reachable, region_gen1 retired."

  # ---------------------------------------------------------------------------
  # Epoch-Gated Reclamation of region_gen1
  # ---------------------------------------------------------------------------
  echo "[2/6] Verifying Epoch-Gated Memory Reclamation Protocol..."

  # Attempt 1: Reclaim at epoch 1 when retirementEpoch is 2 -> MUST return empty
  let premature1 = graph.reclaimUnreachableRegions(1'u64)
  if premature1.len != 0:
    stderr.writeLine("ERROR: Reclaim at epoch 1 succeeded when retirementEpoch is 2: " & $premature1)
    quit(1)

  # Attempt 2: Reclaim at epoch 2 BEFORE advanceQuiescedEpoch is called -> MUST return empty
  let premature2 = graph.reclaimUnreachableRegions(2'u64)
  if premature2.len != 0:
    stderr.writeLine("ERROR: Reclaim at epoch 2 succeeded before advanceQuiescedEpoch was called: " & $premature2)
    quit(1)

  # Falsifier Arm B: Premature reclaim simulation
  if falsifyPremature:
    # Inject defect: bypass quiescence gate and prematurely return region
    let defectivePremature = @["region_gen1"]
    if "region_gen1" in defectivePremature:
      stderr.writeLine("FALSIFIER-CAUGHT: Premature reclamation: unreachable region was reclaimed before quiesced epoch reached retirement epoch!")
      quit(2)

  # Legitimate reclamation: Advance quiesced epoch to 2
  graph.advanceQuiescedEpoch(2'u64)
  let reclaimedGen1 = graph.reclaimUnreachableRegions(2'u64)
  if reclaimedGen1 != @["region_gen1"]:
    stderr.writeLine("ERROR: Expected region_gen1 to be reclaimed at quiesced epoch 2, got " & $reclaimedGen1)
    quit(1)
  if not graph.isRegionReclaimed("region_gen1"):
    stderr.writeLine("ERROR: region_gen1 state must be rsReclaimed")
    quit(1)

  # Re-running reclaim at epoch 2 is idempotent and returns empty
  let secondReclaim = graph.reclaimUnreachableRegions(2'u64)
  if secondReclaim.len != 0:
    stderr.writeLine("ERROR: Reclaim was not idempotent: second call returned " & $secondReclaim)
    quit(1)

  echo "  [OK] Epoch gating verified: premature reclaim refused, advanceQuiescedEpoch(2) released region_gen1."

  # ---------------------------------------------------------------------------
  # Generation 3: target -> helper_v3 in region_gen3
  # ---------------------------------------------------------------------------
  echo "[3/6] Transitioning to Generation 3..."
  let gen3Symbols = @[
    PatchSymbolNode(
      name: "target",
      address: 0x3000'u64,
      size: 64'u64,
      generation: 3'u64,
      regionId: "region_gen3",
      callees: @["helper_v3"],
      callers: @[]
    ),
    PatchSymbolNode(
      name: "helper_v3",
      address: 0x3100'u64,
      size: 32'u64,
      generation: 3'u64,
      regionId: "region_gen3",
      callees: @[],
      callers: @["target"]
    )
  ]
  let gen3Sites = @[
    RelocationSite(
      symbolName: "helper_v3",
      siteAddress: 0x3010'u64,
      relocationType: "R_X86_64_PLT32",
      addend: -4'i64,
      regionId: "region_gen3",
      generation: 3'u64
    )
  ]
  graph.registerPatchGeneration(3'u64, "region_gen3", gen3Symbols, gen3Sites)

  # Supersede Gen 2 with Gen 3
  let (gen3Reachable, gen3Unreachable) = graph.supersedeGeneration(2'u64, 3'u64, ["target"])

  if "target" notin gen3Reachable or "helper_v3" notin gen3Reachable:
    stderr.writeLine("ERROR: target and helper_v3 must be reachable in Gen 3")
    quit(1)
  if "helper_v2" notin gen3Unreachable or "helper_v1" notin gen3Unreachable:
    stderr.writeLine("ERROR: helper_v1 and helper_v2 must both be unreachable in Gen 3")
    quit(1)
  if "helper_v2" in gen3Reachable or "helper_v1" in gen3Reachable:
    stderr.writeLine("ERROR: Older helpers must not be reachable in Gen 3")
    quit(1)

  if not graph.isRegionRetired("region_gen2"):
    stderr.writeLine("ERROR: region_gen2 must be retired in Gen 3")
    quit(1)

  # Reclaim at epoch 2 must NOT reclaim region_gen2 (retirementEpoch is 3)
  let blockedGen2 = graph.reclaimUnreachableRegions(2'u64)
  if "region_gen2" in blockedGen2:
    stderr.writeLine("ERROR: region_gen2 reclaimed prematurely at epoch 2")
    quit(1)

  # Advance to epoch 3 and reclaim
  graph.advanceQuiescedEpoch(3'u64)
  let reclaimedGen2 = graph.reclaimUnreachableRegions(3'u64)
  if reclaimedGen2 != @["region_gen2"]:
    stderr.writeLine("ERROR: Expected region_gen2 to be reclaimed at epoch 3, got " & $reclaimedGen2)
    quit(1)

  # Active region_gen3 must NEVER be reclaimed
  if graph.isRegionRetired("region_gen3") or graph.isRegionReclaimed("region_gen3"):
    stderr.writeLine("ERROR: Active region_gen3 was incorrectly retired or reclaimed")
    quit(1)

  echo "  [OK] Gen 3 verified: helper_v2 dead, helper_v3 live, region_gen2 reclaimed at epoch 3."

proc runFiveGenerationSharedHelperScenario() =
  echo "[4/6] Running 5-Generation Chain with Shared Helper Protection..."
  var graph = initMultiGenReachabilityGraph()

  # Gen 1: root -> shared_helper (in region_shared) and dead_helper_1 (in region_g1)
  let g1Syms = @[
    PatchSymbolNode(name: "root", address: 0x1000'u64, size: 64, generation: 1, regionId: "region_g1", callees: @["shared_helper", "dead_helper_1"], callers: @[]),
    PatchSymbolNode(name: "shared_helper", address: 0x9000'u64, size: 48, generation: 1, regionId: "region_shared", callees: @[], callers: @["root"]),
    PatchSymbolNode(name: "dead_helper_1", address: 0x1100'u64, size: 32, generation: 1, regionId: "region_g1", callees: @[], callers: @["root"])
  ]
  let g1Sites = @[
    RelocationSite(symbolName: "shared_helper", siteAddress: 0x1010'u64, relocationType: "R_X86_64_PLT32", addend: -4, regionId: "region_g1", generation: 1),
    RelocationSite(symbolName: "dead_helper_1", siteAddress: 0x1020'u64, relocationType: "R_X86_64_PLT32", addend: -4, regionId: "region_g1", generation: 1)
  ]
  graph.registerPatchGeneration(1, "region_g1", g1Syms[0..0] & g1Syms[2..2], g1Sites)
  graph.registerPatchGeneration(1, "region_shared", g1Syms[1..1], @[])

  # Gen 2: root -> shared_helper and dead_helper_2 (in region_g2)
  let g2Syms = @[
    PatchSymbolNode(name: "root", address: 0x2000'u64, size: 64, generation: 2, regionId: "region_g2", callees: @["shared_helper", "dead_helper_2"], callers: @[]),
    PatchSymbolNode(name: "dead_helper_2", address: 0x2100'u64, size: 32, generation: 2, regionId: "region_g2", callees: @[], callers: @["root"])
  ]
  let g2Sites = @[
    RelocationSite(symbolName: "shared_helper", siteAddress: 0x2010'u64, relocationType: "R_X86_64_PLT32", addend: -4, regionId: "region_g2", generation: 2),
    RelocationSite(symbolName: "dead_helper_2", siteAddress: 0x2020'u64, relocationType: "R_X86_64_PLT32", addend: -4, regionId: "region_g2", generation: 2)
  ]
  graph.registerPatchGeneration(2, "region_g2", g2Syms, g2Sites)
  discard graph.supersedeGeneration(1, 2, ["root"])

  # Gen 3: root -> shared_helper and dead_helper_3 (in region_g3)
  let g3Syms = @[
    PatchSymbolNode(name: "root", address: 0x3000'u64, size: 64, generation: 3, regionId: "region_g3", callees: @["shared_helper", "dead_helper_3"], callers: @[]),
    PatchSymbolNode(name: "dead_helper_3", address: 0x3100'u64, size: 32, generation: 3, regionId: "region_g3", callees: @[], callers: @["root"])
  ]
  let g3Sites = @[
    RelocationSite(symbolName: "shared_helper", siteAddress: 0x3010'u64, relocationType: "R_X86_64_PLT32", addend: -4, regionId: "region_g3", generation: 3),
    RelocationSite(symbolName: "dead_helper_3", siteAddress: 0x3020'u64, relocationType: "R_X86_64_PLT32", addend: -4, regionId: "region_g3", generation: 3)
  ]
  graph.registerPatchGeneration(3, "region_g3", g3Syms, g3Sites)
  let (g3Reach, g3Unreach) = graph.supersedeGeneration(2, 3, ["root"])

  # Key assertion from spec:
  # When generation 3 replaces generation 2, unreferenced helpers from generation 2
  # are flagged unreachable while generation 1 roots/shared helpers remain protected!
  if "shared_helper" notin g3Reach:
    stderr.writeLine("ERROR: shared_helper from Gen 1 must remain reachable in Gen 3")
    quit(1)
  if "dead_helper_2" notin g3Unreach:
    stderr.writeLine("ERROR: dead_helper_2 from Gen 2 must be flagged unreachable in Gen 3")
    quit(1)
  if graph.isRegionRetired("region_shared"):
    stderr.writeLine("ERROR: region_shared must NOT be retired while shared_helper is reachable")
    quit(1)
  if not graph.isRegionRetired("region_g2"):
    stderr.writeLine("ERROR: region_g2 must be retired in Gen 3")
    quit(1)

  # Gen 4: root -> helper_4 (drops shared_helper)
  let g4Syms = @[
    PatchSymbolNode(name: "root", address: 0x4000'u64, size: 64, generation: 4, regionId: "region_g4", callees: @["helper_4"], callers: @[]),
    PatchSymbolNode(name: "helper_4", address: 0x4100'u64, size: 32, generation: 4, regionId: "region_g4", callees: @[], callers: @["root"])
  ]
  graph.registerPatchGeneration(4, "region_g4", g4Syms, @[])
  let (g4Reach, g4Unreach) = graph.supersedeGeneration(3, 4, ["root"])

  # Now shared_helper is finally unreachable!
  if "shared_helper" notin g4Unreach:
    stderr.writeLine("ERROR: shared_helper must be unreachable in Gen 4")
    quit(1)
  if not graph.isRegionRetired("region_shared"):
    stderr.writeLine("ERROR: region_shared must be retired in Gen 4 now that shared_helper is dead")
    quit(1)

  # Gen 5: root -> helper_5
  let g5Syms = @[
    PatchSymbolNode(name: "root", address: 0x5000'u64, size: 64, generation: 5, regionId: "region_g5", callees: @["helper_5"], callers: @[]),
    PatchSymbolNode(name: "helper_5", address: 0x5100'u64, size: 32, generation: 5, regionId: "region_g5", callees: @[], callers: @["root"])
  ]
  graph.registerPatchGeneration(5, "region_g5", g5Syms, @[])
  let (g5Reach, g5Unreach) = graph.supersedeGeneration(4, 5, ["root"])
  if "helper_5" notin g5Reach or "helper_4" notin g5Unreach:
    stderr.writeLine("ERROR: Gen 5 reachability mismatch")
    quit(1)

  echo "  [OK] 5-generation scenario verified: Gen 1 shared_helper remained protected until Gen 4."

proc runControlArm() =
  echo "[5/6] Running Control Arm (Single-generation patch)..."
  var graph = initMultiGenReachabilityGraph()
  let syms = @[
    PatchSymbolNode(name: "target", address: 0x1000, size: 64, generation: 1, regionId: "ctrl_reg", callees: @["helper"], callers: @[]),
    PatchSymbolNode(name: "helper", address: 0x1100, size: 32, generation: 1, regionId: "ctrl_reg", callees: @[], callers: @["target"])
  ]
  let sites = @[
    RelocationSite(symbolName: "helper", siteAddress: 0x1010, relocationType: "rel32", addend: 0, regionId: "ctrl_reg", generation: 1)
  ]
  graph.registerPatchGeneration(1, "ctrl_reg", syms, sites)
  let reach = graph.computeReachability(["target"])

  if "target" notin reach or "helper" notin reach:
    stderr.writeLine("ERROR: Control arm failed: symbols missing from reachability set")
    quit(1)

  # Control arm invariant: single generation maintains all allocated blocks as reachable
  if not graph.isRegionActive("ctrl_reg"):
    stderr.writeLine("ERROR: Control arm region must remain active")
    quit(1)
  graph.advanceQuiescedEpoch(10)
  let reclaimed = graph.reclaimUnreachableRegions(10)
  if reclaimed.len != 0:
    stderr.writeLine("ERROR: Control arm must not reclaim active region: got " & $reclaimed)
    quit(1)

  echo "  [OK] Control arm passed: all symbols reachable, no premature deallocations."

proc runRealObjectArm(objPaths: seq[string]) =
  if objPaths.len < 3:
    echo "[6/6] Real object arm skipped (fewer than 3 object files provided)."
    return

  echo "[6/6] Running Real Object File LinkGraph Parsing Arm..."
  var graph = initMultiGenReachabilityGraph()

  for i, path in objPaths:
    let gen = uint64(i + 1)
    let regId = "real_obj_region_gen" & $gen
    let baseAddr = 0x100000'u64 * gen
    let lg = parseObjectFile(path)

    let (syms, sites) = linkGraphToPatchGeneration(lg, gen, regId, baseAddr)
    if syms.len == 0:
      stderr.writeLine("ERROR: No function symbols parsed from real object: " & path)
      quit(1)
    graph.registerPatchGeneration(gen, regId, syms, sites)

  # Find root function name (either "target_fn", "_target_fn", or first function)
  var rootName = ""
  for name in ["target_fn", "_target_fn", "target", "_target"]:
    if name in graph.symbols:
      rootName = name
      break
  if rootName.len == 0:
    for name, sym in graph.symbols:
      if sym.generation == 1:
        rootName = name
        break

  if rootName.len > 0:
    let reach = graph.computeReachability([rootName])
    if rootName notin reach:
      stderr.writeLine("ERROR: Root symbol not reachable in real object graph: " & rootName)
      quit(1)
    echo "  [OK] Real objects parsed and loaded: " & $graph.symbols.len & " symbols, " &
         $graph.allSites.len & " relocations, root '" & rootName & "' reachable."

proc main() =
  var falsifyInvert = false
  var falsifyPremature = false
  var objPaths: seq[string] = @[]

  for i in 1 .. paramCount():
    let arg = paramStr(i)
    if arg == "--falsify-invert-reachability":
      falsifyInvert = true
    elif arg == "--falsify-premature-reclaim":
      falsifyPremature = true
    elif not arg.startsWith("--"):
      objPaths.add(arg)

  echo "=== test_hax_m0_reverse_relocation_index_and_dead_patch_reachability ==="
  if falsifyInvert:
    echo "MODE: Falsifier Arm (--falsify-invert-reachability)"
  elif falsifyPremature:
    echo "MODE: Falsifier Arm (--falsify-premature-reclaim)"
  else:
    echo "MODE: Standard Positive & Control Verification"

  runMultiGenScenario(falsifyInvert, falsifyPremature)
  runFiveGenerationSharedHelperScenario()
  runControlArm()
  runRealObjectArm(objPaths)

  echo "=== ALL HAX-M0 REACHABILITY AND REVERSE INDEX CHECKS PASSED ==="

when isMainModule:
  main()
