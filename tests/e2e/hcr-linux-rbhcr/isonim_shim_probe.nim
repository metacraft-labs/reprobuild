## HLX-M8 — IsoNim's own FFI shim, driven against the REAL Reprobuild agent.
##
## This file is the application half of
## `e2e_hcr_linux_isonim_shim_against_real_agent`. It is deliberately written
## the way IsoNim writes its own call sites: it imports
## `isonim/native/hcr` from the sibling IsoNim checkout — the real module, not
## a copy — and reaches the agent only through that module's public wrappers
## (`rbHcrBeforeReload`, `rbHcrWantsReload`, `rbHcrApplyReload`, …). Nothing
## here declares an `rb_hcr_*` symbol itself.
##
## Built with BOTH gates on:
##
##   -d:reprobuildHcr — the FFI bindings are live: the wrappers `importc` the
##     real `rb_hcr_*` symbols out of `librepro_hcr_agent` with
##     `header: "repro_hcr_agent.h"`, and `{.passL: "-lrepro_hcr_agent".}`
##     puts the real shared library on the link line. Before HLX-M8 this path
##     had never been linked on any platform; the "green on Linux" result
##     NH-M0 recorded was the no-op fallback branch.
##   -d:isonimHmr — the NH-M2 agent-hook seam exists, and `hcrAgentHooks` is
##     left NIL. That is the configuration IsoNim's native HMR actually ships
##     in, and leaving the seam installed-but-empty proves the wrappers fall
##     THROUGH to the real agent rather than only working against the stub.
##
## The agent's own control surface (start, poll, synchronized mode, and the
## evidence readers) is not part of the ten-function application ABI, so it is
## declared here rather than in IsoNim — an embedding host does exactly this.
##
## The observation that matters: each callback CALLS the victim. Under the
## normative phase order the before-reload callback must see the old body and
## the after-reload callback the new one.

import std/[os, strutils]

import isonim/native/hcr

when not defined(reprobuildHcr):
  {.error: "isonim_shim_probe is meaningless without -d:reprobuildHcr: " &
      "without it isonim/native/hcr compiles its no-op fallback bodies and " &
      "the probe would link no rb_hcr_* symbol at all, then report that " &
      "nothing fired.".}

when not defined(isonimHmr):
  {.error: "isonim_shim_probe requires -d:isonimHmr: the seam IsoNim's " &
      "native HMR runs through only exists under that flag, and a probe " &
      "that bypassed it would not be testing the shipped call path.".}

type
  ReproHcrAgentSymbol {.importc: "repro_hcr_agent_symbol",
                        header: "repro_hcr_agent.h", bycopy.} = object
    name {.importc: "name".}: cstring
    address {.importc: "address".}: pointer

proc reproHcrAgentDefaultSupportProfile(): cstring
  {.importc: "repro_hcr_agent_default_support_profile",
    header: "repro_hcr_agent.h".}

proc reproHcrAgentStartPollingFromEnv(supportProfile: cstring;
                                      symbols: ptr ReproHcrAgentSymbol;
                                      symbolCount: csize_t): cint
  {.importc: "repro_hcr_agent_start_polling_from_env",
    header: "repro_hcr_agent.h".}

proc reproHcrAgentPollNonblocking(): cint
  {.importc: "repro_hcr_agent_poll_nonblocking",
    header: "repro_hcr_agent.h".}

proc reproHcrAgentSetSynchronizedMode(enabled: cint)
  {.importc: "repro_hcr_agent_set_synchronized_mode",
    header: "repro_hcr_agent.h".}

proc reproHcrRbLifecycleTrace(): cstring
  {.importc: "repro_hcr_rb_lifecycle_trace", header: "repro_hcr_agent.h".}

proc reproHcrRbLastCodeSwapped(): cint
  {.importc: "repro_hcr_rb_last_code_swapped", header: "repro_hcr_agent.h".}

proc reproHcrRbLastRejection(): cstring
  {.importc: "repro_hcr_rb_last_rejection", header: "repro_hcr_agent.h".}

const
  ProbeChangedFile = "hcr_lx_m8_views.nim"
  ProbeAbsentFile = "hcr_lx_m8_never_in_any_patch.nim"
  ProbeManagedType = "HcrM8State"
  PollBudget = 20000

proc isonimVictim(): cint {.exportc: "hcr_lx_m8_victim", noinline.} =
  ## The patch target. `{.exportc.}` so it is a real ELF symbol the agent can
  ## be handed, `{.noinline.}` so it has its own body and its own
  ## `__patchable_function_entries` sled entry.
  ##
  ## The calling convention is left at Nim's default rather than forced to
  ## `cdecl`: for a nullary function returning `cint` the two are the same
  ## x86_64 SysV signature, and the replacement body the coordinator ships is
  ## an ordinary C `int f(void)`. Spelling `cdecl` here is also rejected by the
  ## compiler alongside `exportc` in this position, which is how the point came
  ## up.
  11

var victimCall: proc(): cint {.nimcall, noinline, noSideEffect, gcsafe.} =
  isonimVictim
  ## Called through a variable so neither Nim nor the C compiler can fold two
  ## calls into one or constant-fold either. The effect pragmas are the ones
  ## Nim infers for `isonimVictim`; a proc TYPE has to spell them or the
  ## assignment is a type mismatch. Note which way a folding mistake would
  ## fail: the gate asserts the two calls return DIFFERENT values, so folding
  ## could only turn this red, never falsely green.

type
  Observation = object
    fired: int
    victim: int
    changedFiles: int
    changedTypes: int
    firstFile: string
    firstType: string
    firstOldSize: uint32
    firstNewSize: uint32
    fileChangedProbe: bool
    fileChangedAbsent: bool
    typeChangedProbe: bool

var beforeObserved: Observation
var afterObserved: Observation
var beforeUserData: pointer
var afterUserData: pointer

proc record(observed: var Observation; info: ptr RbHcrReloadInfo) =
  observed.fired.inc
  observed.victim = int(victimCall())
  if info != nil:
    observed.changedFiles = int(info.changedFilesCount)
    observed.changedTypes = int(info.changedTypesCount)
    if info.changedFilesCount > 0'u32 and info.changedFiles != nil:
      observed.firstFile = $info.changedFiles[0]
    if info.changedTypesCount > 0'u32 and info.changedTypes != nil:
      observed.firstType = $info.changedTypes[0].typeName
      observed.firstOldSize = info.changedTypes[0].oldSize
      observed.firstNewSize = info.changedTypes[0].newSize
  observed.fileChangedProbe = rbHcrFileChanged(ProbeChangedFile)
  observed.fileChangedAbsent = rbHcrFileChanged(ProbeAbsentFile)
  observed.typeChangedProbe = rbHcrTypeChanged(ProbeManagedType)

proc onBeforeReload(info: ptr RbHcrReloadInfo; userData: pointer) {.cdecl.} =
  ## A `{.cdecl.}` callback the C agent invokes directly. It catches
  ## everything: an exception escaping into a C frame is undefined behaviour,
  ## and the stub's OPEN-3 records that the spec says nothing about a faulting
  ## callback, so IsoNim's callbacks must be their own guard.
  try:
    beforeUserData = userData
    record(beforeObserved, info)
  except CatchableError:
    discard

proc onAfterReload(info: ptr RbHcrReloadInfo; userData: pointer) {.cdecl.} =
  try:
    afterUserData = userData
    record(afterObserved, info)
  except CatchableError:
    discard

proc jsonBool(value: bool): string = (if value: "true" else: "false")

proc emit(name: string; observed: Observation): string =
  "\"" & name & "\":{" &
    "\"fired\":" & $observed.fired &
    ",\"victim\":" & $observed.victim &
    ",\"changedFilesCount\":" & $observed.changedFiles &
    ",\"changedTypesCount\":" & $observed.changedTypes &
    ",\"firstFile\":\"" & observed.firstFile & "\"" &
    ",\"firstType\":\"" & observed.firstType & "\"" &
    ",\"firstTypeOldSize\":" & $observed.firstOldSize &
    ",\"firstTypeNewSize\":" & $observed.firstNewSize &
    ",\"fileChangedProbe\":" & jsonBool(observed.fileChangedProbe) &
    ",\"fileChangedAbsent\":" & jsonBool(observed.fileChangedAbsent) &
    ",\"typeChangedProbe\":" & jsonBool(observed.typeChangedProbe) & "}"

proc main() =
  var managed: seq[string] = @[]
  for i in 1 .. paramCount():
    let arg = paramStr(i)
    if arg.startsWith("--managed="):
      managed.add arg["--managed=".len .. ^1]

  # HCR-Overview §13.2 and the shipped registry: the agent stores the POINTER,
  # not a copy, so the strings must outlive every reload. `managed` is a
  # module-level-lifetime seq here, which is the same discipline an embedding
  # application needs.
  for name in managed:
    rbHcrRegisterManagedType(name.cstring)

  reproHcrAgentSetSynchronizedMode(1)

  rbHcrBeforeReload(onBeforeReload, cast[pointer](0x8100))
  rbHcrAfterReload(onAfterReload, cast[pointer](0x8200))
  # Idempotent on (callback, user_data) — these must not add a second entry.
  rbHcrBeforeReload(onBeforeReload, cast[pointer](0x8100))
  rbHcrAfterReload(onAfterReload, cast[pointer](0x8200))
  # Registered then removed: proves removal works rather than that nothing
  # ever fires.
  rbHcrBeforeReload(onBeforeReload, cast[pointer](0x8300))
  rbHcrRemoveBeforeReload(onBeforeReload, cast[pointer](0x8300))
  rbHcrAfterReload(onAfterReload, cast[pointer](0x8400))
  rbHcrRemoveAfterReload(onAfterReload, cast[pointer](0x8400))
  # Registered and immediately withdrawn, so all ten of the ABI's functions
  # are REFERENCED by this probe. That matters beyond tidiness: the gate greps
  # `nm -u` for all ten, and an `importc` proc Nim never calls emits no
  # undefined symbol at all — the check would then be measuring which
  # functions the probe happened to use rather than which the shim binds.
  rbHcrRegisterManagedType("HcrM8TransientType")
  rbHcrUnregisterManagedType("HcrM8TransientType")

  let beforeValue = int(victimCall())

  var symbols: array[1, ReproHcrAgentSymbol]
  symbols[0].name = "hcr_lx_m8_victim"
  symbols[0].address = cast[pointer](isonimVictim)
  let startRc = reproHcrAgentStartPollingFromEnv(
    reproHcrAgentDefaultSupportProfile(), addr symbols[0], 1.csize_t)

  var polls = 0
  var wantsBefore = false
  var wantsAfter = true
  var timedOut = true
  while polls < PollBudget:
    discard reproHcrAgentPollNonblocking()
    if rbHcrWantsReload():
      wantsBefore = true
      rbHcrApplyReload()
      wantsAfter = rbHcrWantsReload()
      timedOut = false
      break
    polls.inc
    sleep(1)

  if timedOut:
    # Loud. A probe that printed an empty result here would read as "the shim
    # linked and nothing happened", which is the silent self-pass this
    # campaign keeps finding.
    stderr.writeLine("isonim_shim_probe: no patch became pending within " &
      $PollBudget & " polls")
    quit(3)

  let afterValue = int(victimCall())

  var doc = "{\"schemaId\":" &
    "\"reprobuild.hcr.hlx-m8.isonim-shim-probe-result.v1\""
  doc.add ",\"before\":" & $beforeValue
  doc.add ",\"after\":" & $afterValue
  doc.add ",\"startRc\":" & $startRc
  doc.add ",\"polls\":" & $polls
  doc.add ",\"wantsReloadBeforeApply\":" & jsonBool(wantsBefore)
  doc.add ",\"wantsReloadAfterApply\":" & jsonBool(wantsAfter)
  doc.add ",\"lifecycleTrace\":\"" & $reproHcrRbLifecycleTrace() & "\""
  doc.add ",\"codeSwapped\":" & jsonBool(reproHcrRbLastCodeSwapped() != 0)
  doc.add ",\"rejection\":\"" &
    ($reproHcrRbLastRejection()).multiReplace(("\\", "\\\\"), ("\"", "\\\"")) &
    "\""
  doc.add ",\"beforeUserData\":\"0x" & toHex(cast[uint](beforeUserData), 4).
    toLowerAscii & "\""
  doc.add ",\"afterUserData\":\"0x" & toHex(cast[uint](afterUserData), 4).
    toLowerAscii & "\""
  doc.add ",\"fileChangedProbeAtEnd\":" &
    jsonBool(rbHcrFileChanged(ProbeChangedFile))
  doc.add ",\"fileChangedAbsentAtEnd\":" &
    jsonBool(rbHcrFileChanged(ProbeAbsentFile))
  doc.add ",\"typeChangedProbeAtEnd\":" &
    jsonBool(rbHcrTypeChanged(ProbeManagedType))
  doc.add ",\"hcrAgentHooksInstalled\":" & jsonBool(hcrAgentHooks != nil)
  doc.add "," & emit("observedInBefore", beforeObserved)
  doc.add "," & emit("observedInAfter", afterObserved)
  doc.add "}"
  echo doc

main()
