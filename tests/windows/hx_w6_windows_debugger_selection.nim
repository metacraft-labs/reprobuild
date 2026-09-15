## HX-W-6 production delivery-selection probe.
##
## `allowed_mocks: none`. Matrix rows call the real production selector, and
## the detection row calls the operating system's IsDebuggerPresent API. The
## Python E2E gate runs that row both normally and under the real debugger.

import std/[json, os]

import repro_hcr_agent/windows_debugger

proc selectionJson(debugger: HcrWindowsDebuggerKind;
                   selection: HcrWindowsDebuggerSelection): JsonNode =
  %*{
    "debugger": debugger.debuggerName,
    "accepted": selection.accepted,
    "delivery": selection.delivery.patchDeliveryName,
    "refusal_reason": selection.refusalReason,
    "detail": selection.detail
  }

proc main() =
  let arguments = commandLineParams()
  if arguments == @["--detect"]:
    let debugger = currentWindowsDebuggerKind()
    echo $selectionJson(
      debugger,
      selectWindowsPatchDelivery(hwpmAutomatic, debugger))
    return

  if arguments.len != 0:
    raise newException(ValueError, "usage: [--detect]")

  var matrix = newJArray()
  for debugger in HcrWindowsDebuggerKind:
    matrix.add selectionJson(
      debugger,
      selectWindowsPatchDelivery(hwpmAutomatic, debugger))
  for debugger in [hwdWinDbg, hwdVisualStudio, hwdUnknownNative]:
    matrix.add selectionJson(
      debugger,
      selectWindowsPatchDelivery(hwpmDirect, debugger))
  echo $(%*{
    "refusal": HcrWindowsDirectDebuggerRefusal,
    "matrix": matrix
  })

when isMainModule:
  main()
