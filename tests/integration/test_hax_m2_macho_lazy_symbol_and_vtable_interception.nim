# test_hax_m2_macho_lazy_symbol_and_vtable_interception.nim
#
# Integration verification test for Milestone HAX-M2:
# "Dispatch Table and Stub Interception"
#
# References:
# - reprobuild-specs/HCR/Dispatch-Table-Patching.md §1–§5
# - reprobuild-specs/HCR/Trampoline-Mechanics.md §7
# - reprobuild-specs/HCR-Advanced-Lifecycle-And-Tooling.milestones.org (HAX-M2)
#
# Asserts:
# 1. Anti-vacuity arm: Initial calls invoke original virtual and non-virtual implementations;
#    verify polymorphic calls dispatch through vtable.
# 2. Vtable Interception arm: Virtual method slot rewritten to point to replacement function;
#    calling shape->area() on existing and new instances executes replacement method
#    without modifying __TEXT.
# 3. Control arm: Non-virtual calls (shape->identity()) and unmodified virtual slots
#    (shape->perimeter(), rectangle->area()) continue executing original code.
# 4. Mach-O Lazy Symbol Pointer Interception arm: __la_symbol_ptr rewritten for external_metric_calc;
#    invocation from library executes replacement function.
# 5. Transactional Rollback arm: Rollback reverses all redirections; subsequent calls
#    return baseline results.
# 6. Falsifier arm (--falsify-wrong-slot): Deliberately overwrites wrong vtable slot index,
#    causing unexpected dispatch or trapping, caught by FALSIFIER-CAUGHT.

import std/[os, strutils, sequtils, dynlib]
import repro_hcr_agent/dispatch_table

# C++ Replacement functions
proc replacementCircleArea(self: pointer): cint {.cdecl.} =
  9999

proc replacementMetricCalc(x: cint): cint {.cdecl.} =
  x * 1000

type
  CreateCircleFn = proc(r: cint): pointer {.cdecl.}
  CreateRectangleFn = proc(w, h: cint): pointer {.cdecl.}
  DestroyShapeFn = proc(s: pointer) {.cdecl.}
  CallShapeAreaFn = proc(s: pointer): cint {.cdecl.}
  CallShapePerimeterFn = proc(s: pointer): cint {.cdecl.}
  CallShapeDescribeFn = proc(s: pointer): cstring {.cdecl.}
  CallShapeIdentityFn = proc(s: pointer): cint {.cdecl.}
  CallShapeMetricFn = proc(s: pointer): cint {.cdecl.}
  ReadTextBytesFn = proc(funcPtr: pointer, outBuf: ptr uint8, count: csize_t) {.cdecl.}

proc runGate(metricDylibPath: string, shapeDylibPath: string, falsifyWrongSlot: bool) =
  echo "[HAX-M2] Loading shared libraries..."
  echo "  Metric dylib: ", metricDylibPath
  echo "  Shape dylib:  ", shapeDylibPath

  # Pre-load metric library so dynamic symbols are available
  let metricLib = loadLib(metricDylibPath)
  if metricLib == nil:
    quit("ERROR: Failed to load metric library: " & metricDylibPath, 1)

  let shapeLib = loadLib(shapeDylibPath)
  if shapeLib == nil:
    quit("ERROR: Failed to load shape library: " & shapeDylibPath, 1)

  let createCircle = cast[CreateCircleFn](shapeLib.symAddr("create_circle"))
  let createRectangle = cast[CreateRectangleFn](shapeLib.symAddr("create_rectangle"))
  let destroyShape = cast[DestroyShapeFn](shapeLib.symAddr("destroy_shape"))
  let callShapeArea = cast[CallShapeAreaFn](shapeLib.symAddr("call_shape_area"))
  let callShapePerimeter = cast[CallShapePerimeterFn](shapeLib.symAddr("call_shape_perimeter"))
  let callShapeDescribe = cast[CallShapeDescribeFn](shapeLib.symAddr("call_shape_describe"))
  let callShapeIdentity = cast[CallShapeIdentityFn](shapeLib.symAddr("call_shape_identity"))
  let callShapeMetric = cast[CallShapeMetricFn](shapeLib.symAddr("call_shape_metric"))
  let readTextBytes = cast[ReadTextBytesFn](shapeLib.symAddr("read_text_bytes"))

  if createCircle == nil or createRectangle == nil or callShapeArea == nil:
    quit("ERROR: Failed to locate required C bridge symbols in shape library", 1)

  echo "  [OK] Shared libraries loaded and bridge functions bound."

  # Instantiate polymorphic objects
  let circle = createCircle(10) # radius = 10 -> area = 314, perimeter = 62
  let rectangle = createRectangle(20, 10) # 20x10 -> area = 200, perimeter = 60
  let circleVptrInstance = discoverVtableFromInstance(circle)

  # Record baseline function text bytes from __TEXT of Circle::area
  var baselineTextBytes = newSeq[uint8](16)
  if readTextBytes != nil and circleVptrInstance != nil:
    let origAreaPtr = circleVptrInstance[0]
    readTextBytes(origAreaPtr, addr baselineTextBytes[0], 16)
    echo "  [OK] Baseline __TEXT bytes captured for Circle::area at ", repr(origAreaPtr), ": ",
         baselineTextBytes.mapIt(toHex(int(it), 2)).join(" ")

  # ---------------------------------------------------------------------------
  # 1. Anti-vacuity Arm
  # ---------------------------------------------------------------------------
  echo "[1/6] Anti-vacuity Arm: Verifying baseline execution and vtable resolution..."
  let baseCircleArea = callShapeArea(circle)
  let baseCirclePerimeter = callShapePerimeter(circle)
  let baseCircleDesc = $callShapeDescribe(circle)
  let baseCircleIdent = callShapeIdentity(circle)

  let baseRectArea = callShapeArea(rectangle)
  let baseRectPerimeter = callShapePerimeter(rectangle)
  let baseRectDesc = $callShapeDescribe(rectangle)

  echo "  Baseline Circle: area=", baseCircleArea, " perim=", baseCirclePerimeter,
       " desc=", baseCircleDesc, " ident=", baseCircleIdent
  echo "  Baseline Rect:   area=", baseRectArea, " perim=", baseRectPerimeter,
       " desc=", baseRectDesc

  doAssert baseCircleArea == 314, "Expected base circle area 314, got: " & $baseCircleArea
  doAssert baseCirclePerimeter == 62, "Expected base circle perim 62, got: " & $baseCirclePerimeter
  doAssert baseCircleDesc == "Circle", "Expected 'Circle', got: " & baseCircleDesc
  doAssert baseCircleIdent == 42, "Expected non-virtual identity 42, got: " & $baseCircleIdent
  doAssert baseRectArea == 200, "Expected base rect area 200, got: " & $baseRectArea
  doAssert baseRectPerimeter == 60, "Expected base rect perim 60, got: " & $baseRectPerimeter

  # Discover vtable pointers via instance and symbol resolution
  let circleVptrSymbol = findVtableBySymbol("_ZTV6Circle")

  echo "  circleVptrInstance: ", repr(circleVptrInstance)
  echo "  circleVptrSymbol:   ", repr(circleVptrSymbol)
  doAssert circleVptrInstance != nil, "Failed to discover vtable from instance"
  if circleVptrSymbol != nil:
    doAssert circleVptrInstance == circleVptrSymbol,
      "Instance vptr and symbol-derived vptr must match under Itanium C++ ABI"

  echo "  [OK] Anti-vacuity arm verified: polymorphic calls dispatch through vtable."

  # ---------------------------------------------------------------------------
  # Falsifier Arm Check
  # ---------------------------------------------------------------------------
  if falsifyWrongSlot:
    echo "[FALSIFIER] Deliberately overwriting WRONG vtable slot index (slot 1 instead of slot 0)..."
    var origSlot1: pointer = nil
    let ok = patchVtableSlot(circleVptrInstance, 1, cast[pointer](replacementCircleArea), origSlot1)
    doAssert ok, "Patching slot 1 failed"
    let falsifiedArea = callShapeArea(circle)
    let falsifiedPerim = callShapePerimeter(circle)
    echo "  Observed after wrong slot patch: area=", falsifiedArea, " perimeter=", falsifiedPerim
    if falsifiedArea != 9999:
      echo "[FALSIFIER-CAUGHT] Wrong vtable slot index 1 rewritten: area() remained " &
           $falsifiedArea & " (expected 9999), and perimeter() was corrupted to " & $falsifiedPerim
      quit(2)
    else:
      quit("ERROR: Falsifier unexpectedly succeeded: area() was 9999 despite wrong slot!", 1)

  # ---------------------------------------------------------------------------
  # 2. Vtable Interception Arm
  # ---------------------------------------------------------------------------
  echo "[2/6] Vtable Interception Arm: Rewriting Circle::area slot (slot 0)..."
  let txId = beginTransaction()
  echo "  Started transaction ID: ", txId

  var origAreaMethod: pointer = nil
  let patchOk = patchVtableSlotTx(txId, circleVptrInstance, 0,
                                  cast[pointer](replacementCircleArea),
                                  origAreaMethod)
  doAssert patchOk, "patchVtableSlotTx failed for slot 0"
  doAssert origAreaMethod != nil, "Expected original area method pointer to be non-nil"
  echo "  Original Circle::area pointer: ", repr(origAreaMethod)
  echo "  Replacement method pointer:    ", repr(cast[pointer](replacementCircleArea))

  # Verify existing instance executes replacement code
  let patchedExistingArea = callShapeArea(circle)
  echo "  Existing circle->area(): ", patchedExistingArea
  doAssert patchedExistingArea == 9999,
    "Expected replacement area 9999 on existing instance, got: " & $patchedExistingArea

  # Verify newly constructed instance ALSO executes replacement code (shared vtable)
  let newCircle = createCircle(10)
  let patchedNewArea = callShapeArea(newCircle)
  echo "  New circle->area():      ", patchedNewArea
  doAssert patchedNewArea == 9999,
    "Expected replacement area 9999 on new instance, got: " & $patchedNewArea
  destroyShape(newCircle)

  # Verify __TEXT of original function was NOT modified
  if readTextBytes != nil and origAreaMethod != nil:
    var currentTextBytes = newSeq[uint8](16)
    readTextBytes(origAreaMethod, addr currentTextBytes[0], 16)
    echo "  Current __TEXT bytes:  ", currentTextBytes.mapIt(toHex(int(it), 2)).join(" ")
    doAssert baselineTextBytes == currentTextBytes,
      "CRITICAL: __TEXT bytes were modified! Dispatch interception must NOT write to __TEXT."

  echo "  [OK] Vtable interception verified: existing and new instances dispatch without __TEXT modification."

  # ---------------------------------------------------------------------------
  # 3. Control Arm
  # ---------------------------------------------------------------------------
  echo "[3/6] Control Arm: Verifying non-virtual calls and unmodified virtual slots..."
  let controlIdent = callShapeIdentity(circle)
  let controlPerimeter = callShapePerimeter(circle)
  let controlDesc = $callShapeDescribe(circle)
  let controlRectArea = callShapeArea(rectangle)

  echo "  Circle identity() (non-virtual): ", controlIdent
  echo "  Circle perimeter() (slot 1):     ", controlPerimeter
  echo "  Circle describe() (slot 2):      ", controlDesc
  echo "  Rectangle area() (other vtable): ", controlRectArea

  doAssert controlIdent == 42, "Non-virtual identity() must remain 42, got: " & $controlIdent
  doAssert controlPerimeter == 62, "Unmodified slot 1 perimeter() must remain 62, got: " & $controlPerimeter
  doAssert controlDesc == "Circle", "Unmodified slot 2 describe() must remain 'Circle', got: " & controlDesc
  doAssert controlRectArea == 200, "Rectangle vtable must be completely untouched, got: " & $controlRectArea

  echo "  [OK] Control arm verified: direct non-virtual calls and separate vtables unaffected."

  # ---------------------------------------------------------------------------
  # 4. Mach-O Lazy Symbol Pointer Interception Arm
  # ---------------------------------------------------------------------------
  echo "[4/6] Mach-O Lazy Symbol Pointer Interception Arm: Rewriting external_metric_calc..."
  let preMetric = callShapeMetric(circle)
  # area() is currently 9999; external_metric_calc(9999) = 9999 * 10 = 99990
  echo "  Pre-patch callShapeMetric(circle): ", preMetric
  doAssert preMetric == 99990, "Expected pre-patch metric 99990, got: " & $preMetric

  var origMetricFunc: pointer = nil
  let machoPatchOk = patchMachoLazySymbolTx(
    txId,
    "libshape.dylib",
    "external_metric_calc",
    cast[pointer](replacementMetricCalc),
    origMetricFunc
  )
  doAssert machoPatchOk, "patchMachoLazySymbolTx failed for external_metric_calc"
  echo "  Original external_metric_calc slot target: ", repr(origMetricFunc)

  let postMetric = callShapeMetric(circle)
  # replacementMetricCalc(9999) = 9999 * 1000 = 9999000
  echo "  Post-patch callShapeMetric(circle): ", postMetric
  doAssert postMetric == 9999000,
    "Expected replacement metric 9999000, got: " & $postMetric

  echo "  [OK] Mach-O lazy symbol pointer interception verified."

  # ---------------------------------------------------------------------------
  # 5. Transactional Rollback Arm
  # ---------------------------------------------------------------------------
  echo "[5/6] Transactional Rollback Arm: Reversing all redirections in transaction..."
  let preRollbackCount = rollbackLogCount()
  echo "  Active rollback entries before rollback: ", preRollbackCount
  doAssert preRollbackCount >= 2, "Expected at least 2 rollback entries, got: " & $preRollbackCount

  let rolledBack = rollbackTransaction(txId)
  echo "  Rolled back entries: ", rolledBack
  doAssert rolledBack >= 2, "Expected at least 2 entries rolled back, got: " & $rolledBack

  let postRollbackCount = rollbackLogCount()
  echo "  Active rollback entries after rollback: ", postRollbackCount
  doAssert postRollbackCount == 0, "Expected 0 rollback entries after rollback, got: " & $postRollbackCount

  # Verify that all calls now return exact baseline results
  let rolledBackArea = callShapeArea(circle)
  let rolledBackMetric = callShapeMetric(circle)
  echo "  Rolled back circle->area():        ", rolledBackArea
  echo "  Rolled back callShapeMetric(circle): ", rolledBackMetric

  doAssert rolledBackArea == 314, "Expected restored area 314, got: " & $rolledBackArea
  doAssert rolledBackMetric == 3140, "Expected restored metric 3140 (314 * 10), got: " & $rolledBackMetric

  echo "  [OK] Transactional rollback verified: exact baseline state restored."

  destroyShape(circle)
  destroyShape(rectangle)
  echo ""
  echo "=== [SUCCESS] HAX-M2: Dispatch Table and Stub Interception Verified ==="

proc main() =
  var metricDylib = ""
  var shapeDylib = ""
  var falsifyWrongSlot = false

  for arg in commandLineParams():
    if arg == "--falsify-wrong-slot":
      falsifyWrongSlot = true
    elif metricDylib.len == 0 and arg.endsWith(".dylib"):
      metricDylib = arg
    elif shapeDylib.len == 0 and arg.endsWith(".dylib"):
      shapeDylib = arg

  if metricDylib.len == 0 or shapeDylib.len == 0:
    quit("Usage: test_hax_m2_driver [--falsify-wrong-slot] <libmetric.dylib> <libshape.dylib>", 1)

  runGate(metricDylib, shapeDylib, falsifyWrongSlot)

when isMainModule:
  main()
