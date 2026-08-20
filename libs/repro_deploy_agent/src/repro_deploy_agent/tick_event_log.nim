## Windows-Runner-Binary-Cache-Deploy — the deploy agent's WINDOWS EVENT
## LOG sink.
##
## The JSONL history in `tick_history.nim` is the primary sink and the
## portable one; this is the sink a Windows administrator actually LOOKS at.
## Three things it gives that a file under the state dir cannot:
##
##   * it is where an admin already looks. `Event Viewer` → Windows Logs →
##     Application, next to the Task Scheduler entries for the very task
##     that runs this loop.
##   * it SURVIVES the state dir. `repro deploy-agent --state-dir` points at
##     a directory that gets wiped, re-imaged or moved; the reason the box
##     stopped converging should not go with it.
##   * it is queryable REMOTELY, without a session on the box:
##       Get-WinEvent -FilterHashtable @{
##         LogName = 'Application'; ProviderName = 'ReprobuildDeployAgent' }
##
## EVENT ID ASSIGNMENT. The IDs encode the exit-code CLASS in the tens
## digit, so an admin can filter and alert without a lookup table:
##
##     100  aoApplied           Information   exit 0
##     101  aoConverged         Information   exit 0
##     102  aoWaiting           Information   exit 0
##     110  aoApplyFailed       Error         exit 1  (retryable)
##     111  aoSourceError       Error         exit 1  (retryable)
##     120  aoRejected          Error         exit 2  (operator must act)
##     121  aoAmbiguous         Error         exit 2  (operator must act)
##     122  aoSecretsFailed     Error         exit 2  (operator must act)
##     190  tickRaised          Error         exit 1  (tick fell over)
##     199  <unrecognised>      Warning
##
## So `Id -ge 110` is "anything wrong", `Id -ge 120 -and Id -le 129` is
## "page someone", and 199 means this binary emitted an outcome name it does
## not know — a forward-compatibility escape hatch, deliberately a Warning
## rather than a silent drop.
##
## The IDs are constrained to 1..1000 ON PURPOSE. The source is registered
## with `EventMessageFile = %SystemRoot%\System32\EventCreate.exe`, the
## stock message resource every `eventcreate.exe`-made source uses; its
## message table covers exactly 1..1000, which is also why `eventcreate`
## itself refuses an `/ID` outside that range. An ID above 1000 would render
## as "The description for Event ID ... cannot be found" and bury the
## diagnosis this sink exists to surface.
##
## EVERYTHING HERE IS BEST EFFORT, and degrades in steps rather than
## failing:
##
##   * registration is idempotent and its failure is not fatal — a
##     deployment where the agent is NOT SYSTEM cannot write under HKLM, so
##     it reports against an unregistered source instead. Event Viewer then
##     prefixes the entry with a "description cannot be found" note but
##     still shows the inserted message, so the diagnosis survives.
##   * a failure to report at all degrades to the JSONL history, which was
##     already written.
##   * nothing in here may raise, and nothing in here may change the tick's
##     exit code.
##
## `REPRO_DEPLOY_AGENT_EVENT_LOG=0` disables the sink. The suite sets it:
## a test that ticks a hundred times must not deposit a hundred entries in
## the developer's real Application log.
##
## PORTABILITY. Only `reportTickEvent` is platform-conditional. The parts
## that carry the decisions — the ID assignment, the entry-type mapping and
## the message construction — are plain code compiled everywhere and pinned
## by `t_repro_deploy_agent_records_tick_history` on every host.

import std/[os, strutils]

import ./tick_status

const
  TickEventSourceName* = "ReprobuildDeployAgent"
    ## The `ProviderName` a `Get-WinEvent -FilterHashtable` filters on.
  TickEventLogName* = "Application"
    ## Not a custom log: a custom log is invisible to an admin who does not
    ## already know it exists, which is the failure mode this sink exists to
    ## avoid.

  EventIdTickApplied* = 100
  EventIdTickConverged* = 101
  EventIdTickWaiting* = 102
  EventIdTickApplyFailed* = 110
  EventIdTickSourceError* = 111
  EventIdTickRejected* = 120
  EventIdTickAmbiguous* = 121
  EventIdTickSecretsFailed* = 122
  EventIdTickRaised* = 190
  EventIdTickUnknownOutcome* = 199

  TickEventMaxMessageChars* = 16_000
    ## Well inside the ~31,839-character limit on a single ReportEvent
    ## insertion string. In practice `tick_history` has already capped the
    ## two free-text fields far below this; the cap is here so that this
    ## module's contract does not depend on that one's.

  TickEventLogEnvVar* = "REPRO_DEPLOY_AGENT_EVENT_LOG"

type
  TickEventEntryType* = enum
    ## The `EntryType` column in Event Viewer.
    teInformation, teWarning, teError

  TickEvent* = object
    ## Everything the Windows sink would report, decided portably so it can
    ## be asserted on any host.
    eventId*: int
    entryType*: TickEventEntryType
    message*: string

proc tickEventId*(outcome: string): int =
  ## Outcome NAME to event id. Keyed on the string rather than
  ## `AgentOutcomeKind` so the same mapping serves a record read back out of
  ## the JSONL history, where the kind is only ever a name.
  case outcome
  of "aoApplied": EventIdTickApplied
  of "aoConverged": EventIdTickConverged
  of "aoWaiting": EventIdTickWaiting
  of "aoApplyFailed": EventIdTickApplyFailed
  of "aoSourceError": EventIdTickSourceError
  of "aoRejected": EventIdTickRejected
  of "aoAmbiguous": EventIdTickAmbiguous
  of "aoSecretsFailed": EventIdTickSecretsFailed
  of TickRaisedOutcome: EventIdTickRaised
  else: EventIdTickUnknownOutcome

proc tickEventEntryType*(rec: TickStatusRecord): TickEventEntryType =
  ## Derived from the EXIT CODE, not from a second list of "bad" outcome
  ## names — `deployAgentExitCode` already decides which outcomes are
  ## failures, and two copies of that judgement would drift. An outcome this
  ## build does not recognise is a Warning regardless: it is not a failure
  ## we can name, but it is not nothing either.
  if tickEventId(rec.outcome) == EventIdTickUnknownOutcome:
    teWarning
  elif rec.exitCode == 0:
    teInformation
  else:
    teError

proc tickEventMessage*(rec: TickStatusRecord; historyPath = ""): string =
  ## The message body. The ERROR TEXT is included deliberately and is the
  ## whole point: the diagnosis has to be readable in Event Viewer, on a box
  ## whose state dir may be gone, without correlating anything.
  var lines = @[
    "repro deploy-agent tick: " & rec.outcome,
    "  target       : " & rec.target,
    "  outcome      : " & rec.outcome,
    "  exit code    : " & $rec.exitCode,
    "  timestamp    : " & rec.timestamp]
  if rec.sequence > 0'u64:
    lines.add("  sequence     : " & $rec.sequence)
  if rec.deploymentId.len > 0:
    lines.add("  deployment   : " & rec.deploymentId)
  if rec.errorCode.len > 0:
    lines.add("  error code   : " & rec.errorCode)
  if rec.message.len > 0:
    lines.add("  message      : " & rec.message)
  if rec.error.len > 0:
    lines.add("  error        : " & rec.error)
  if historyPath.len > 0:
    lines.add("  history      : " & historyPath)
  result = lines.join("\n") & "\n"
  if result.len > TickEventMaxMessageChars:
    result = result[0 ..< TickEventMaxMessageChars] & "\n...[truncated]\n"

proc tickEventFor*(rec: TickStatusRecord; historyPath = ""): TickEvent =
  ## The whole decision, in one value. `reportTickEvent` renders exactly
  ## this, so asserting on it here asserts on what Windows receives.
  TickEvent(
    eventId: tickEventId(rec.outcome),
    entryType: tickEventEntryType(rec),
    message: tickEventMessage(rec, historyPath))

proc tickEventLogEnabled*(): bool =
  ## Enabled unless explicitly switched off. The negative values are spelt
  ## the way the rest of the repo's env switches spell them.
  let raw = getEnv(TickEventLogEnvVar, "").strip().toLowerAscii()
  raw notin ["0", "off", "false", "no"]

when defined(windows):
  import std/winlean

  type
    WinHkey = pointer
    WinHandle = pointer
    WinDword = uint32
    WinBool = int32
    WinLStatus = int32

  const
    # HKEY_LOCAL_MACHINE. The source registration lives here because the
    # Event Log service reads it from here; there is no per-user equivalent.
    WinHkeyLocalMachineInt = cast[int](0x80000002'u32)
    WinKeyRead: WinDword = 0x20019
    WinKeyWrite: WinDword = 0x20006
    WinRegOptionNonVolatile: WinDword = 0
    WinRegExpandSz: WinDword = 2
    WinRegDword: WinDword = 4
    WinErrorSuccess: WinLStatus = 0

    WinEventLogErrorType: uint16 = 0x0001
    WinEventLogWarningType: uint16 = 0x0002
    WinEventLogInformationType: uint16 = 0x0004
    # ERROR | WARNING | INFORMATION — the three this sink emits.
    WinEventTypesSupported: WinDword = 0x0007

    # The stock message resource. See the EVENT ID ASSIGNMENT note above for
    # why this choice pins the ids to 1..1000.
    WinEventMessageFile = "%SystemRoot%\\System32\\EventCreate.exe"

    EventLogSourceKeyPrefix =
      "SYSTEM\\CurrentControlSet\\Services\\EventLog\\Application\\"

  proc winRegOpenKeyEx(key: WinHkey; subKey: ptr uint16; options: WinDword;
      desired: WinDword; outKey: ptr WinHkey): WinLStatus
      {.importc: "RegOpenKeyExW", stdcall, dynlib: "advapi32".}
  proc winRegCreateKeyEx(key: WinHkey; subKey: ptr uint16; reserved: WinDword;
      class: ptr uint16; options: WinDword; desired: WinDword;
      security: pointer; outKey: ptr WinHkey;
      disposition: ptr WinDword): WinLStatus
      {.importc: "RegCreateKeyExW", stdcall, dynlib: "advapi32".}
  proc winRegQueryValueEx(key: WinHkey; name: ptr uint16; reserved: ptr WinDword;
      valueType: ptr WinDword; data: pointer;
      dataSize: ptr WinDword): WinLStatus
      {.importc: "RegQueryValueExW", stdcall, dynlib: "advapi32".}
  proc winRegSetValueEx(key: WinHkey; name: ptr uint16; reserved: WinDword;
      valueType: WinDword; data: pointer; dataSize: WinDword): WinLStatus
      {.importc: "RegSetValueExW", stdcall, dynlib: "advapi32".}
  proc winRegCloseKey(key: WinHkey): WinLStatus
      {.importc: "RegCloseKey", stdcall, dynlib: "advapi32".}
  proc winRegisterEventSource(server: ptr uint16;
      source: ptr uint16): WinHandle
      {.importc: "RegisterEventSourceW", stdcall, dynlib: "advapi32".}
  proc winDeregisterEventSource(handle: WinHandle): WinBool
      {.importc: "DeregisterEventSource", stdcall, dynlib: "advapi32".}
  proc winReportEvent(handle: WinHandle; eventType, category: uint16;
      eventId: WinDword; userSid: pointer; numStrings: uint16;
      dataSize: WinDword; strings: ptr ptr uint16;
      rawData: pointer): WinBool
      {.importc: "ReportEventW", stdcall, dynlib: "advapi32".}

  proc toUtf16Z(s: string): seq[uint16] =
    ## UTF-8 to NUL-terminated UTF-16LE. Hand-rolled for the same reason
    ## `windows.registryValue`'s driver hand-rolls its copy: a tiny stable
    ## surface, and no lifetime question about a `WideCStringObj` temporary
    ## whose data must outlive the call it is passed into.
    result = newSeqOfCap[uint16](s.len + 1)
    var i = 0
    while i < s.len:
      let b0 = uint32(byte(s[i]))
      var cp: uint32
      var advance: int
      if b0 < 0x80:
        cp = b0; advance = 1
      elif (b0 and 0xE0) == 0xC0 and i + 1 < s.len:
        cp = ((b0 and 0x1F) shl 6) or (uint32(byte(s[i+1])) and 0x3F)
        advance = 2
      elif (b0 and 0xF0) == 0xE0 and i + 2 < s.len:
        cp = ((b0 and 0x0F) shl 12) or
             ((uint32(byte(s[i+1])) and 0x3F) shl 6) or
             (uint32(byte(s[i+2])) and 0x3F)
        advance = 3
      elif (b0 and 0xF8) == 0xF0 and i + 3 < s.len:
        cp = ((b0 and 0x07) shl 18) or
             ((uint32(byte(s[i+1])) and 0x3F) shl 12) or
             ((uint32(byte(s[i+2])) and 0x3F) shl 6) or
             (uint32(byte(s[i+3])) and 0x3F)
        advance = 4
      else:
        cp = b0; advance = 1
      if cp <= 0xFFFF:
        result.add(uint16(cp))
      else:
        let c = cp - 0x10000
        result.add(uint16(0xD800 + (c shr 10)))
        result.add(uint16(0xDC00 + (c and 0x3FF)))
      i += advance
    result.add(0'u16)

  proc hkeyLocalMachine(): WinHkey =
    cast[WinHkey](cast[pointer](WinHkeyLocalMachineInt))

  proc windowsEventType(entryType: TickEventEntryType): uint16 =
    case entryType
    of teInformation: WinEventLogInformationType
    of teWarning: WinEventLogWarningType
    of teError: WinEventLogErrorType

  proc sourceAlreadyRegistered(subKey: var seq[uint16]): bool =
    ## Registered means the key exists AND carries an `EventMessageFile`.
    ## A key without one renders every entry as "description cannot be
    ## found", so a half-registration must be repaired, not accepted.
    var key: WinHkey = nil
    if winRegOpenKeyEx(hkeyLocalMachine(), addr subKey[0], 0, WinKeyRead,
        addr key) != WinErrorSuccess:
      return false
    defer: discard winRegCloseKey(key)
    var name = toUtf16Z("EventMessageFile")
    var size: WinDword = 0
    winRegQueryValueEx(key, addr name[0], nil, nil, nil, addr size) ==
      WinErrorSuccess

  proc ensureEventSourceRegistered(): bool =
    ## Idempotent. Returns false when the source could not be registered —
    ## the caller reports anyway, because an unregistered source still
    ## delivers the message text.
    var subKey = toUtf16Z(EventLogSourceKeyPrefix & TickEventSourceName)
    if sourceAlreadyRegistered(subKey):
      return true
    var key: WinHkey = nil
    var disposition: WinDword = 0
    if winRegCreateKeyEx(hkeyLocalMachine(), addr subKey[0], 0, nil,
        WinRegOptionNonVolatile, WinKeyRead or WinKeyWrite, nil, addr key,
        addr disposition) != WinErrorSuccess:
      # Almost always "not elevated". Not an error worth a word on a stderr
      # nobody reads: the JSONL history already has the record.
      return false
    defer: discard winRegCloseKey(key)
    var messageFileName = toUtf16Z("EventMessageFile")
    var messageFile = toUtf16Z(WinEventMessageFile)
    if winRegSetValueEx(key, addr messageFileName[0], 0, WinRegExpandSz,
        addr messageFile[0],
        WinDword(messageFile.len * 2)) != WinErrorSuccess:
      return false
    var typesName = toUtf16Z("TypesSupported")
    var types = WinEventTypesSupported
    if winRegSetValueEx(key, addr typesName[0], 0, WinRegDword, addr types,
        WinDword(sizeof(types))) != WinErrorSuccess:
      return false
    true

  proc reportTickEvent*(rec: TickStatusRecord; historyPath = "") =
    ## BEST EFFORT. Never raises, never changes the caller's exit code.
    if not tickEventLogEnabled():
      return
    try:
      let event = tickEventFor(rec, historyPath)
      # Deliberately not gated on the result: an unregistered source still
      # carries the insertion string into the log, and a degraded entry
      # beats no entry on the box where the state dir is gone.
      discard ensureEventSourceRegistered()
      var source = toUtf16Z(TickEventSourceName)
      let handle = winRegisterEventSource(nil, addr source[0])
      if handle == nil:
        return
      defer: discard winDeregisterEventSource(handle)
      # `message` must outlive the call, hence the named binding.
      var message = toUtf16Z(event.message)
      var strings: array[1, ptr uint16] = [addr message[0]]
      discard winReportEvent(handle, windowsEventType(event.entryType), 0,
        WinDword(event.eventId), nil, 1, 0, addr strings[0], nil)
    except CatchableError:
      discard
else:
  proc reportTickEvent*(rec: TickStatusRecord; historyPath = "") =
    ## No Event Log off Windows. The systemd hosts get the JSONL history,
    ## which is why that one is the primary sink and this one is not.
    discard
