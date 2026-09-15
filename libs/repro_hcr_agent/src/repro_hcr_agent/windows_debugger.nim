## Windows HCR debugger-aware patch-delivery selection.
##
## HX-W-6 deliberately has one debugger-supported path in Windows v1: a real
## patch DLL with its matching PDB. `RtlAddFunctionTable` remains the runtime
## correctness mechanism for direct patches when no debugger is attached; it
## is not treated as an out-of-process debugger registration API.

const
  HcrWindowsDirectDebuggerRefusal* =
    "windows-direct-debugger-unsupported"

type
  HcrWindowsDebuggerKind* = enum
    hwdNone
    hwdWinDbg
    hwdVisualStudio
    hwdUnknownNative

  HcrWindowsPatchModeRequest* = enum
    hwpmAutomatic
    hwpmDirect
    hwpmSharedLibrary

  HcrWindowsPatchDelivery* = enum
    hwpdDirect
    hwpdSharedLibrary

  HcrWindowsDebuggerSelection* = object
    accepted*: bool
    delivery*: HcrWindowsPatchDelivery
    refusalReason*: string
    detail*: string

proc debuggerName*(debugger: HcrWindowsDebuggerKind): string =
  case debugger
  of hwdNone: "none"
  of hwdWinDbg: "windbg"
  of hwdVisualStudio: "visual-studio"
  of hwdUnknownNative: "unknown-native"

proc patchDeliveryName*(delivery: HcrWindowsPatchDelivery): string =
  case delivery
  of hwpdDirect: "direct"
  of hwpdSharedLibrary: "shared-library"

proc selectWindowsPatchDelivery*(
    request: HcrWindowsPatchModeRequest;
    debugger: HcrWindowsDebuggerKind
): HcrWindowsDebuggerSelection =
  let attached = debugger != hwdNone
  case request
  of hwpmSharedLibrary:
    HcrWindowsDebuggerSelection(
      accepted: true,
      delivery: hwpdSharedLibrary,
      detail: "real patch DLL plus matching PDB")
  of hwpmAutomatic:
    if attached:
      HcrWindowsDebuggerSelection(
        accepted: true,
        delivery: hwpdSharedLibrary,
        detail: debugger.debuggerName &
          " attached; selected real patch DLL plus matching PDB")
    else:
      HcrWindowsDebuggerSelection(
        accepted: true,
        delivery: hwpdDirect,
        detail: "no native debugger attached")
  of hwpmDirect:
    if attached:
      HcrWindowsDebuggerSelection(
        accepted: false,
        delivery: hwpdDirect,
        refusalReason: HcrWindowsDirectDebuggerRefusal,
        detail: debugger.debuggerName &
          " attached; use shared-library mode for debugger-visible PE/PDB " &
          "and unwind metadata")
    else:
      HcrWindowsDebuggerSelection(
        accepted: true,
        delivery: hwpdDirect,
        detail: "no native debugger attached")

when defined(windows):
  proc isDebuggerPresent(): int32
      {.stdcall, importc: "IsDebuggerPresent", dynlib: "kernel32.dll".}

proc currentWindowsDebuggerKind*(): HcrWindowsDebuggerKind =
  ## The operating-system API reports attachment, not debugger identity. A
  ## front end that knows it launched WinDbg or Visual Studio may refine the
  ## kind before selection; the delivery decision is identical for all three.
  when defined(windows):
    if isDebuggerPresent() != 0:
      hwdUnknownNative
    else:
      hwdNone
  else:
    hwdNone

proc selectCurrentWindowsPatchDelivery*(
    request: HcrWindowsPatchModeRequest
): HcrWindowsDebuggerSelection =
  selectWindowsPatchDelivery(request, currentWindowsDebuggerKind())
