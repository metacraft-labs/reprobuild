## The TCG event log: the record a platform keeps of what it measured,
## and the replay that recomputes the registers from it.
##
## ## Why a log exists at all
##
## A quote carries a PCR value and a PCR value is a fold — a chain of
## `PCR ← H(PCR ‖ digest)` with no memory of what went into it. Two
## machines that booted entirely different software can be told apart
## only because one of them *also* kept a list of the digests it
## extended and in what order. That list is the TCG event log, and it is
## the only thing standing between "this register holds some bytes" and
## "this register holds these bytes *because* that firmware, that
## bootloader and that kernel were measured, in that order".
##
## The log is not trusted. It is a plain memory image the platform
## writes, and nothing signs it. What makes it worth reading is that
## replaying it must *reproduce* the registers a TPM signed: a log
## edited to describe a different boot no longer folds to the quoted
## value, and a log describing the real boot folds to it exactly. The
## register is the authenticated part; the log is the explanation that
## has to survive being checked against it.
##
## ## Two shapes on the wire, and both are here
##
## The log is a bare sequence of entries with no count and no terminator
## — it ends where the buffer ends. There are two entry shapes:
##
##   * **`TCG_PCR_EVENT`** (TCG 1.2, "legacy"): `PCRIndex` `UINT32`,
##     `EventType` `UINT32`, a bare **20-byte SHA-1** digest,
##     `EventSize` `UINT32`, then that many bytes.
##   * **`TCG_PCR_EVENT2`** ("crypto-agile"): `PCRIndex`, `EventType`,
##     then a `TPML_DIGEST_VALUES` — a `UINT32` count followed by that
##     many `(TPM_ALG_ID, digest)` pairs — then `EventSize` and the data.
##
## A log says which it is by its **first** entry. A crypto-agile log
## opens with a `TCG_PCR_EVENT` — deliberately, so that a TCG 1.2 parser
## can walk past it — carrying `EV_NO_ACTION` and a `Spec ID Event03`
## structure that declares every digest algorithm the rest of the log
## uses and how long each one is. Anything else, and the log is legacy
## and SHA-1 all the way down.
##
## That declaration is load-bearing rather than informational: an entry
## in the agile shape has no length field before its digest list, so the
## *only* way to find where a digest ends is the size the header
## declared for its algorithm. A parser that meets an algorithm the
## header did not declare cannot find the end of the entry, and this one
## refuses rather than guessing. Implementing only the agile shape would
## also be a silent trap, because a legacy log's first four bytes parse
## as a plausible `PCRIndex` and the walk would run off into the middle
## of a digest; both shapes are implemented and the choice is made by
## what is on the wire.
##
## ## Byte order, which is the opposite of everything next door
##
## `tpm2.nim` reads structures a TPM *signed*, and those are big-endian.
## The event log is a memory image *firmware* wrote, and every integer in
## it — `PCRIndex`, `EventType`, `EventSize`, the digest count, the
## algorithm identifier, the digest size — is **little-endian**. The two
## even share a type: a `TPM_ALG_ID` is `0x000B` in a quote and `0B 00`
## in a log. The cursor is shared with `tpm2.nim` (see `readU16Le`
## there) precisely so that the bounds checks are not reimplemented here
## with slightly different corners, while the byte order stays a
## property of the read.
##
## ## Replay, and the three ways it quietly goes wrong
##
## Replay is the fold: start each register at its reset value and, for
## every event, `PCR[i] ← H(PCR[i] ‖ digest)` under the bank's own hash.
## Three details decide whether the answer is right, and each of them
## has a way of being *almost* right:
##
##   1. **`EV_NO_ACTION` is not extended.** It is the log's own
##      metadata — the `Spec ID Event03` header is one, and so is a
##      `StartupLocality` record. A replay that folds them in produces a
##      register that is wrong in a way no test of the *shape* of the
##      log will show: the parse succeeds, the count is right, and only
##      the digest differs. This is the classic near-miss and it is why
##      the gates carry a control that inserts an `EV_NO_ACTION` event
##      into a real log and requires the answer not to move.
##   2. **The reset value is not zero for every register.** PCRs 0–16
##      and 23 reset to all-zero; **17–22 reset to all-ones**, because
##      they are the DRTM registers a platform may only reset from
##      locality 4. A replay that starts everything at zero agrees with
##      the TPM about every register a normal boot touches and disagrees
##      about six it does not, so the error hides until the day one of
##      them matters.
##   3. **A register the log never mentions still has a value**, and it
##      is that reset value — not "unknown" and not "zero" as a
##      convenience. `ReplayedPcr` therefore carries both the value and
##      whether any event reached it, because "the log explains this
##      register" and "the log is silent and the register is at its
##      reset value" are different claims and a verifier needs to tell
##      them apart.
##
## ## Failing closed, which is this module's whole posture
##
## Every refusal is a raised `TcgEventLogError`. Nothing here returns an
## empty log, an empty bank or a `false` that a caller might read as a
## verdict, because the failure mode this is built against is precisely
## the one where a log that could not be parsed becomes "no events", a
## replay over no events becomes "the initial values", and a comparison
## against nothing reports agreement. A log with zero events is refused
## at the door; a replay is never handed a log that was not parsed; and
## `explainsQuote` refuses a selection whose every register the log left
## untouched, because a digest over nothing but reset values is the same
## on every machine in the world and proves nothing about this one.
##
## ## What this module does not do
##
## It does not verify a signature, does not decide whether a measurement
## is *acceptable*, and does not interpret an event's payload: a
## `EV_EFI_VARIABLE_DRIVER_CONFIG`'s contents are bytes here, not a
## UEFI variable. It also does not implement the locality-3 startup
## rule, under which a `StartupLocality` record changes PCR 0's reset
## value; such a log is **refused by name** rather than replayed with
## the wrong initial value, and the refusal says so.
##
## ## Mocking
##
## None. The fixtures the gates replay are event logs real firmware
## wrote; nothing here stands in for a platform.

import std/strutils

import nimcrypto/[hash, sha, sha2]

import ./tpm2

type
  TcgEventLogError* = object of CatchableError
    ## Raised for any byte string this module will not accept as an
    ## event log, and for any replay it will not perform. The message
    ## names the entry, the field and the offset in the log.

  TcgEventType* = distinct uint32
    ## A TCG event type. A `distinct uint32` for the same reason
    ## `TpmAlgId` is a `distinct uint16`: the registry is open, firmware
    ## emits vendor-defined types in the `0x8000_0000` range, and an
    ## `enum` with holes would let an unchecked conversion fabricate a
    ## member. Only `EV_NO_ACTION` changes what replay *does*; the rest
    ## are carried through and named for diagnostics.

proc `==`*(a, b: TcgEventType): bool {.borrow.}

const
  NumPcrs* = 24
    ## The PC Client Platform TPM Profile's register count. An event
    ## naming an index outside `0 ..< NumPcrs` describes a register the
    ## platform does not have.

  FirstDrtmPcr* = 17
  LastDrtmPcr* = 22
    ## PCRs 17–22 are the DRTM registers. They reset to all-ONES rather
    ## than all-zero, which is the reset rule `initialPcrValue` encodes
    ## and the gates anchor against a real TPM's own report of all 24
    ## registers.

  # --- event types, TCG PC Client Platform Firmware Profile ----------
  EvPrebootCert* = TcgEventType(0x00000000'u32)
  EvPostCode* = TcgEventType(0x00000001'u32)
  EvUnused* = TcgEventType(0x00000002'u32)
  EvNoAction* = TcgEventType(0x00000003'u32)
    ## The one type replay treats specially: it is NOT extended. See the
    ## module header.
  EvSeparator* = TcgEventType(0x00000004'u32)
  EvAction* = TcgEventType(0x00000005'u32)
  EvEventTag* = TcgEventType(0x00000006'u32)
  EvSCrtmContents* = TcgEventType(0x00000007'u32)
  EvSCrtmVersion* = TcgEventType(0x00000008'u32)
  EvCpuMicrocode* = TcgEventType(0x00000009'u32)
  EvPlatformConfigFlags* = TcgEventType(0x0000000A'u32)
  EvTableOfDevices* = TcgEventType(0x0000000B'u32)
  EvCompactHash* = TcgEventType(0x0000000C'u32)
  EvIpl* = TcgEventType(0x0000000D'u32)
  EvIplPartitionData* = TcgEventType(0x0000000E'u32)
  EvNonhostCode* = TcgEventType(0x0000000F'u32)
  EvNonhostConfig* = TcgEventType(0x00000010'u32)
  EvNonhostInfo* = TcgEventType(0x00000011'u32)
  EvOmitBootDeviceEvents* = TcgEventType(0x00000012'u32)
  EvEfiVariableDriverConfig* = TcgEventType(0x80000001'u32)
  EvEfiVariableBoot* = TcgEventType(0x80000002'u32)
  EvEfiBootServicesApplication* = TcgEventType(0x80000003'u32)
  EvEfiBootServicesDriver* = TcgEventType(0x80000004'u32)
  EvEfiRuntimeServicesDriver* = TcgEventType(0x80000005'u32)
  EvEfiGptEvent* = TcgEventType(0x80000006'u32)
  EvEfiAction* = TcgEventType(0x80000007'u32)
  EvEfiPlatformFirmwareBlob* = TcgEventType(0x80000008'u32)
  EvEfiHandoffTables* = TcgEventType(0x80000009'u32)
  EvEfiPlatformFirmwareBlob2* = TcgEventType(0x8000000A'u32)
  EvEfiHandoffTables2* = TcgEventType(0x8000000B'u32)
  EvEfiVariableBoot2* = TcgEventType(0x8000000C'u32)
  EvEfiHcrtmEvent* = TcgEventType(0x80000010'u32)
  EvEfiVariableAuthority* = TcgEventType(0x800000E0'u32)
  EvEfiSpdmFirmwareBlob* = TcgEventType(0x800000E1'u32)
  EvEfiSpdmFirmwareConfig* = TcgEventType(0x800000E2'u32)

  SpecIdSignature* = "Spec ID Event03\0"
    ## The 16 bytes that make the first entry of a crypto-agile log a
    ## header rather than a measurement. The trailing NUL is part of it.
  StartupLocalitySignature* = "StartupLocality\0"
    ## An `EV_NO_ACTION` record that changes PCR 0's RESET VALUE. Not
    ## implemented, and therefore refused by name rather than ignored —
    ## see the module header.

  LegacyDigestBytes* = 20
    ## A `TCG_PCR_EVENT` carries a bare SHA-1 digest and no algorithm
    ## identifier, so its length is fixed by the structure.

  SpecIdSignatureBytes* = 16
  MaxEventDataBytes* = 16 * 1024 * 1024
    ## A single event's payload. Generous — a `dbx` variable event is
    ## six figures on real firmware — but finite: without a ceiling a
    ## corrupt `EventSize` inside a large buffer is indistinguishable
    ## from a large event, and the entries after it are read from the
    ## wrong offset while the parse reports success.

type
  TcgLogFormat* = enum
    lfLegacy
      ## TCG 1.2 `TCG_PCR_EVENT` entries, SHA-1 only, no header.
    lfCryptoAgile
      ## `TCG_PCR_EVENT2` entries after a `Spec ID Event03` header.

  TcgAlgorithmSize* = object
    ## One row of the `Spec ID Event03` algorithm table: what a bank is
    ## called and how many bytes its digests occupy. The size is what
    ## lets the parser walk an entry whose algorithm it does not
    ## otherwise understand.
    alg*: TpmAlgId
    digestSize*: int

  TcgSpecIdEvent* = object
    platformClass*: uint32
    specVersionMinor*: uint8
    specVersionMajor*: uint8
    specErrata*: uint8
    uintnSize*: uint8
      ## 1 for a 32-bit `UINTN`, 2 for 64-bit. Any other value is a
      ## header nothing produces.
    algorithms*: seq[TcgAlgorithmSize]
    vendorInfo*: string

  TcgDigest* = object
    alg*: TpmAlgId
    digest*: string
      ## RAW digest bytes, `digestSize(alg)` of them.

  TcgEvent* = object
    ## One entry, in either shape. A legacy entry's single digest is
    ## presented as a one-element `digests` under `sha1`, so a caller
    ## walking events does not branch on the format.
    wireOffset*: int
      ## Where this entry began in the log. Reported in refusals and in
      ## anything that has to point an operator at a byte.
    pcrIndex*: int
    eventType*: TcgEventType
    digests*: seq[TcgDigest]
    data*: string

  TcgEventLog* = object
    format*: TcgLogFormat
    specId*: TcgSpecIdEvent
      ## Meaningful only when `format == lfCryptoAgile`.
    events*: seq[TcgEvent]
      ## Every entry INCLUDING the `Spec ID Event03` header, which is a
      ## real `EV_NO_ACTION` entry on the wire and is kept as one. A
      ## representation that dropped it would make the log this module
      ## reports shorter than the log the firmware wrote, and would hide
      ## the very entry whose mis-replay this module exists to prevent.

  PcrReplayState* = enum
    prNeverExtended
      ## No event in the log reached this register. Its value is the
      ## reset value, which is a fact about the platform rather than
      ## about this boot.
    prExtended
      ## At least one event folded into this register.

  ReplayedPcr* = object
    state*: PcrReplayState
    value*: string
      ## RAW digest bytes. Populated in BOTH states — a never-extended
      ## register holds its reset value, and a caller comparing against
      ## a TPM needs that value, not a sentinel.

  ReplayedBank* = object
    ## One bank's registers after the whole log has been folded in.
    alg*: TpmAlgId
    digestSize*: int
    pcrs*: array[NumPcrs, ReplayedPcr]
    extendsApplied*: int
      ## How many events were folded in. Zero is impossible: a log with
      ## no extendable event is refused, so this can never be the
      ## "nothing happened, so everything matches" shape.

proc `$`*(t: TcgEventType): string =
  ## Diagnostics only. Named types get their profile spelling;
  ## everything else gets its number, because an operator reading a
  ## refusal about a vendor event needs the value to look it up.
  case uint32(t)
  of 0x00000000'u32: "EV_PREBOOT_CERT"
  of 0x00000001'u32: "EV_POST_CODE"
  of 0x00000002'u32: "EV_UNUSED"
  of 0x00000003'u32: "EV_NO_ACTION"
  of 0x00000004'u32: "EV_SEPARATOR"
  of 0x00000005'u32: "EV_ACTION"
  of 0x00000006'u32: "EV_EVENT_TAG"
  of 0x00000007'u32: "EV_S_CRTM_CONTENTS"
  of 0x00000008'u32: "EV_S_CRTM_VERSION"
  of 0x00000009'u32: "EV_CPU_MICROCODE"
  of 0x0000000A'u32: "EV_PLATFORM_CONFIG_FLAGS"
  of 0x0000000B'u32: "EV_TABLE_OF_DEVICES"
  of 0x0000000C'u32: "EV_COMPACT_HASH"
  of 0x0000000D'u32: "EV_IPL"
  of 0x0000000E'u32: "EV_IPL_PARTITION_DATA"
  of 0x0000000F'u32: "EV_NONHOST_CODE"
  of 0x00000010'u32: "EV_NONHOST_CONFIG"
  of 0x00000011'u32: "EV_NONHOST_INFO"
  of 0x00000012'u32: "EV_OMIT_BOOT_DEVICE_EVENTS"
  of 0x80000001'u32: "EV_EFI_VARIABLE_DRIVER_CONFIG"
  of 0x80000002'u32: "EV_EFI_VARIABLE_BOOT"
  of 0x80000003'u32: "EV_EFI_BOOT_SERVICES_APPLICATION"
  of 0x80000004'u32: "EV_EFI_BOOT_SERVICES_DRIVER"
  of 0x80000005'u32: "EV_EFI_RUNTIME_SERVICES_DRIVER"
  of 0x80000006'u32: "EV_EFI_GPT_EVENT"
  of 0x80000007'u32: "EV_EFI_ACTION"
  of 0x80000008'u32: "EV_EFI_PLATFORM_FIRMWARE_BLOB"
  of 0x80000009'u32: "EV_EFI_HANDOFF_TABLES"
  of 0x8000000A'u32: "EV_EFI_PLATFORM_FIRMWARE_BLOB2"
  of 0x8000000B'u32: "EV_EFI_HANDOFF_TABLES2"
  of 0x8000000C'u32: "EV_EFI_VARIABLE_BOOT2"
  of 0x80000010'u32: "EV_EFI_HCRTM_EVENT"
  of 0x800000E0'u32: "EV_EFI_VARIABLE_AUTHORITY"
  of 0x800000E1'u32: "EV_EFI_SPDM_FIRMWARE_BLOB"
  of 0x800000E2'u32: "EV_EFI_SPDM_FIRMWARE_CONFIG"
  else: "0x" & toHex(uint32(t), 8).toLowerAscii

proc fail(msg: string) {.noreturn.} =
  raise newException(TcgEventLogError, msg)

# ---------------------------------------------------------------------
# The extend, and the reset value
# ---------------------------------------------------------------------

proc extendPcr*(alg: TpmAlgId; current, digest: string): string =
  ## One link of the chain: `H(current ‖ digest)` under `alg`.
  ##
  ## The hash lives here rather than being borrowed from `tpm2.nim`
  ## because the extend is the event log's own operation, and that
  ## module deliberately keeps its digest helper private so it does not
  ## grow a general-purpose crypto front door. The two lengths are
  ## checked before anything is hashed: a `current` or a `digest` of the
  ## wrong length still hashes to *something*, and that something would
  ## be a register value indistinguishable from a correct one.
  let n = digestSize(alg)
  if n == 0:
    fail("PCR extend: " & $alg & " is not a digest this codec computes")
  if current.len != n:
    fail("PCR extend: the register holds " & $current.len & " bytes, but a " &
         $alg & " register is " & $n)
  if digest.len != n:
    fail("PCR extend: the event's digest is " & $digest.len &
         " bytes, but a " & $alg & " digest is " & $n)
  let data = current & digest
  case uint16(alg)
  of 0x0004'u16:
    let d = sha1.digest(data)
    result = newString(20)
    for i in 0 ..< 20: result[i] = char(d.data[i])
  of 0x000B'u16:
    let d = sha256.digest(data)
    result = newString(32)
    for i in 0 ..< 32: result[i] = char(d.data[i])
  of 0x000C'u16:
    let d = sha384.digest(data)
    result = newString(48)
    for i in 0 ..< 48: result[i] = char(d.data[i])
  of 0x000D'u16:
    let d = sha512.digest(data)
    result = newString(64)
    for i in 0 ..< 64: result[i] = char(d.data[i])
  else:
    fail("PCR extend: " & $alg & " is not a digest this codec computes")

proc initialPcrValue*(index, digestSize: int): string =
  ## What a register holds before anything is extended into it.
  ##
  ## All-zero, EXCEPT PCRs 17–22, which are all-ONES. Those six are the
  ## DRTM registers: a platform may only reset them from locality 4, and
  ## a TPM that has never been asked to holds them at `0xFF…FF` rather
  ## than at zero. Getting this wrong is invisible on an ordinary boot —
  ## no firmware extends 17–22 — and wrong the moment one of them is
  ## quoted, which is why it is a value here and is anchored in the
  ## gates against a real TPM's report of all 24 of its registers rather
  ## than against this comment.
  if index < 0 or index >= NumPcrs:
    fail("PCR " & $index & " is outside the " & $NumPcrs &
         " registers a PC Client platform has")
  if digestSize <= 0:
    fail("PCR " & $index & ": a register cannot be " & $digestSize &
         " bytes long")
  if index >= FirstDrtmPcr and index <= LastDrtmPcr:
    result = repeat('\xFF', digestSize)
  else:
    result = repeat('\0', digestSize)

# ---------------------------------------------------------------------
# The Spec ID Event
# ---------------------------------------------------------------------

proc isSpecIdEvent(eventType: TcgEventType; data: string): bool =
  eventType == EvNoAction and data.len >= SpecIdSignatureBytes and
    data[0 ..< SpecIdSignatureBytes] == SpecIdSignature

proc isStartupLocalityEvent(eventType: TcgEventType; data: string): bool =
  eventType == EvNoAction and data.len >= SpecIdSignatureBytes and
    data[0 ..< SpecIdSignatureBytes] == StartupLocalitySignature

proc parseSpecId(data: string): TcgSpecIdEvent =
  ## Read the `TCG_EfiSpecIdEvent` out of the first entry's payload.
  ##
  ## Everything here is little-endian, and the payload is consumed
  ## EXACTLY: `finish` refuses a header with bytes left over, because
  ## the algorithm table is what every later entry's length is computed
  ## from and a header this parser only half understood is a header it
  ## must not proceed on.
  var r = initTpm2Reader(data, "TCG_EfiSpecIdEvent")
  let signature = r.readBytes("signature", SpecIdSignatureBytes)
  if signature != SpecIdSignature:
    fail("TCG_EfiSpecIdEvent: signature is not " & SpecIdSignature.strip(
      leading = false, trailing = true, chars = {'\0'}))
  result.platformClass = r.readU32Le("platformClass")
  result.specVersionMinor = r.readU8("specVersionMinor")
  result.specVersionMajor = r.readU8("specVersionMajor")
  result.specErrata = r.readU8("specErrata")
  result.uintnSize = r.readU8("uintnSize")
  if result.specVersionMajor != 2'u8:
    fail("TCG_EfiSpecIdEvent: specVersionMajor is " &
         $result.specVersionMajor & "; a Spec ID Event03 header declares 2, " &
         "and a header claiming another major version describes entries of " &
         "a shape this parser does not know")
  if result.uintnSize != 1'u8 and result.uintnSize != 2'u8:
    fail("TCG_EfiSpecIdEvent: uintnSize is " & $result.uintnSize &
         "; it is 1 for a 32-bit UINTN or 2 for a 64-bit one")
  let count = r.readU32Le("numberOfAlgorithms")
  if count == 0'u32:
    fail("TCG_EfiSpecIdEvent: declares no algorithms; every later entry's " &
         "digest length comes from this table, so an empty one makes the " &
         "rest of the log unwalkable")
  if count > uint32(MaxPcrBanks):
    fail("TCG_EfiSpecIdEvent: declares " & $count & " algorithms, but a TPM " &
         "carries at most " & $MaxPcrBanks & " banks")
  result.algorithms = @[]
  for i in 0 ..< int(count):
    let alg = r.readAlgLe("digestSizes[" & $i & "].algorithmId")
    let size = int(r.readU16Le("digestSizes[" & $i & "].digestSize"))
    for prior in result.algorithms:
      if prior.alg == alg:
        fail("TCG_EfiSpecIdEvent: algorithm " & $alg & " is declared twice, " &
             "at entry " & $i & "; two rows for one bank make an entry's " &
             "digest length ambiguous")
    let known = digestSize(alg)
    if known != 0 and size != known:
      fail("TCG_EfiSpecIdEvent: declares a " & $size & "-byte digest for " &
           $alg & ", which is " & $known & " bytes; the header and the " &
           "algorithm disagree and one of them is wrong")
    if size <= 0 or size > MaxDigestBytes:
      fail("TCG_EfiSpecIdEvent: declares a " & $size & "-byte digest for " &
           $alg & "; a TPM digest is between 1 and " & $MaxDigestBytes &
           " bytes")
    result.algorithms.add TcgAlgorithmSize(alg: alg, digestSize: size)
  let vendorSize = int(r.readU8("vendorInfoSize"))
  result.vendorInfo = r.readBytes("vendorInfo", vendorSize)
  r.finish()

proc digestSizeFor(spec: TcgSpecIdEvent; alg: TpmAlgId; eventIndex: int): int =
  ## How long a digest under `alg` is, according to the header.
  ##
  ## An algorithm the header did not declare is a REFUSAL and not a
  ## guess. There is no length field in front of a `TPML_DIGEST_VALUES`
  ## element, so an undeclared algorithm leaves the parser with no way
  ## to find where the digest ends — and "assume 32 because most things
  ## are SHA-256" would walk the remainder of the log from an offset
  ## that is off by however much it guessed wrong, silently.
  for row in spec.algorithms:
    if row.alg == alg: return row.digestSize
  fail("TCG_PCR_EVENT2[" & $eventIndex & "]: digest algorithm " & $alg &
       " is not one the Spec ID Event declared, so its length is unknown " &
       "and the entries after it cannot be located")

# ---------------------------------------------------------------------
# The log
# ---------------------------------------------------------------------

proc checkPcrIndex(index: uint32; eventIndex, offset: int) =
  if index >= uint32(NumPcrs):
    fail("event " & $eventIndex & " at offset " & $offset & ": PCRIndex is " &
         $index & ", outside the " & $NumPcrs &
         " registers a PC Client platform has")

proc readEventData(r: var Tpm2Reader; eventIndex: int): string =
  let size = r.readU32Le("event[" & $eventIndex & "].eventSize")
  if size > uint32(MaxEventDataBytes):
    fail("event " & $eventIndex & ": declares a " & $size &
         "-byte payload at offset " & $(r.offset - 4) & ", above the " &
         $MaxEventDataBytes & "-byte ceiling this parser accepts")
  result = r.readBytes("event[" & $eventIndex & "].event", int(size))

proc parseEventLogImpl(data: string): TcgEventLog =
  ## Read a whole TCG event log.
  ##
  ## The format is decided by the first entry and then never
  ## reconsidered: a `Spec ID Event03` appearing later in the log is a
  ## refusal, because a second header would redefine the digest lengths
  ## everything after it is read with, and a parser that took the last
  ## one would disagree with a parser that took the first about the same
  ## bytes.
  ##
  ## The walk is bounded at both ends. There is no entry count on the
  ## wire, so the log ends when the buffer does — and `finish` then
  ## requires that it ended EXACTLY there. A trailing fragment means the
  ## last entry's length field was wrong, which means some earlier
  ## entry's was too, which means the events this returns are not the
  ## events the firmware wrote.
  if data.len == 0:
    fail("TCG event log: the log is empty; an empty log is not a log of a " &
         "boot in which nothing was measured, it is the absence of evidence")
  var r = initTpm2Reader(data, "TCG event log")

  # The first entry is a TCG_PCR_EVENT in BOTH shapes. That is
  # deliberate on the TCG's part: it is what lets a 1.2-era parser walk
  # past a crypto-agile log's header instead of choking on it.
  let firstOffset = r.offset
  let firstPcr = r.readU32Le("event[0].pcrIndex")
  checkPcrIndex(firstPcr, 0, firstOffset)
  let firstType = TcgEventType(r.readU32Le("event[0].eventType"))
  let firstDigest = r.readBytes("event[0].digest", LegacyDigestBytes)
  let firstData = readEventData(r, 0)

  result.events = @[TcgEvent(
    wireOffset: firstOffset,
    pcrIndex: int(firstPcr),
    eventType: firstType,
    digests: @[TcgDigest(alg: TpmAlgSha1, digest: firstDigest)],
    data: firstData)]

  if isSpecIdEvent(firstType, firstData):
    result.format = lfCryptoAgile
    result.specId = parseSpecId(firstData)
    var index = 1
    while r.remaining > 0:
      let offset = r.offset
      let pcr = r.readU32Le("event[" & $index & "].pcrIndex")
      checkPcrIndex(pcr, index, offset)
      let eventType = TcgEventType(r.readU32Le("event[" & $index &
                                               "].eventType"))
      let count = r.readU32Le("event[" & $index & "].digests.count")
      if count == 0'u32:
        fail("TCG_PCR_EVENT2[" & $index & "] at offset " & $offset &
             ": declares no digests; an entry that measured nothing is not " &
             "an entry")
      if count > uint32(MaxPcrBanks):
        fail("TCG_PCR_EVENT2[" & $index & "] at offset " & $offset &
             ": declares " & $count & " digests, but a TPM carries at most " &
             $MaxPcrBanks & " banks")
      var digests: seq[TcgDigest] = @[]
      for d in 0 ..< int(count):
        let alg = r.readAlgLe("event[" & $index & "].digests[" & $d & "].alg")
        for prior in digests:
          if prior.alg == alg:
            fail("TCG_PCR_EVENT2[" & $index & "] at offset " & $offset &
                 ": bank " & $alg & " appears twice in one digest list; a " &
                 "replay would have to choose between them")
        let size = digestSizeFor(result.specId, alg, index)
        digests.add TcgDigest(
          alg: alg,
          digest: r.readBytes("event[" & $index & "].digests[" & $d &
                              "].digest", size))
      let eventData = readEventData(r, index)
      if isSpecIdEvent(eventType, eventData):
        fail("TCG_PCR_EVENT2[" & $index & "] at offset " & $offset &
             ": a second Spec ID Event03 header. The first one fixes the " &
             "digest lengths every later entry is read with, so a second " &
             "one makes the same bytes mean two different things")
      result.events.add TcgEvent(
        wireOffset: offset,
        pcrIndex: int(pcr),
        eventType: eventType,
        digests: digests,
        data: eventData)
      inc index
  else:
    result.format = lfLegacy
    var index = 1
    while r.remaining > 0:
      let offset = r.offset
      let pcr = r.readU32Le("event[" & $index & "].pcrIndex")
      checkPcrIndex(pcr, index, offset)
      let eventType = TcgEventType(r.readU32Le("event[" & $index &
                                               "].eventType"))
      let digest = r.readBytes("event[" & $index & "].digest",
                               LegacyDigestBytes)
      let eventData = readEventData(r, index)
      if isSpecIdEvent(eventType, eventData):
        fail("TCG_PCR_EVENT[" & $index & "] at offset " & $offset &
             ": a Spec ID Event03 header appears after the log has already " &
             "been read as TCG 1.2. The format is decided by the FIRST " &
             "entry; a header here would redefine entries already parsed")
      result.events.add TcgEvent(
        wireOffset: offset,
        pcrIndex: int(pcr),
        eventType: eventType,
        digests: @[TcgDigest(alg: TpmAlgSha1, digest: digest)],
        data: eventData)
      inc index

  # There is deliberately no `finish` call here. `finish` exists for a
  # structure that declares its own length and might have bytes left
  # over; a log declares nothing, so the loop condition IS the
  # exhaustiveness check — it runs until `remaining` is zero and the
  # only way out is a refusal. Bytes appended to a log are therefore
  # refused as a TRUNCATED FINAL ENTRY, which is what they are, and
  # bytes appended that happen to form a well-formed entry are a longer
  # log whose replay no longer reaches the quoted registers.

  if result.events.len == 0:
    fail("TCG event log: no entries were read")

proc parseEventLog*(data: string): TcgEventLog =
  ## Read a whole TCG event log. See `parseEventLogImpl`.
  ##
  ## The bounds checks live in `tpm2.nim`'s cursor and raise that
  ## module's `Tpm2CodecError`, so they are translated here. One
  ## contract, one exception type: a caller that catches
  ## `TcgEventLogError` catches every way this module refuses, and a
  ## truncated log cannot escape as a different exception that a
  ## `try` written against the documented type would not catch.
  try:
    result = parseEventLogImpl(data)
  except Tpm2CodecError as e:
    fail(e.msg)

proc banks*(log: TcgEventLog): seq[TpmAlgId] =
  ## The banks this log carries digests for: the `Spec ID Event03`
  ## table's algorithms in the order it declares them, or SHA-1 alone
  ## for a legacy log.
  case log.format
  of lfLegacy:
    result = @[TpmAlgSha1]
  of lfCryptoAgile:
    result = @[]
    for row in log.specId.algorithms:
      result.add row.alg

proc digestFor(event: TcgEvent; alg: TpmAlgId; index: int): string =
  for d in event.digests:
    if d.alg == alg: return d.digest
  fail("event " & $index & " at offset " & $event.wireOffset & " (" &
       $event.eventType & ", PCR " & $event.pcrIndex & ") carries no " &
       $alg & " digest, so this bank cannot be replayed past it; a replay " &
       "that skipped the event would produce a register the TPM never held")

# ---------------------------------------------------------------------
# Replay
# ---------------------------------------------------------------------

proc replayBank*(log: TcgEventLog; alg: TpmAlgId): ReplayedBank =
  ## Fold the whole log into one bank's registers.
  ##
  ## `EV_NO_ACTION` entries are SKIPPED rather than extended — see the
  ## module header — and every other entry is folded in, in log order,
  ## including entries whose digest is all zero. A bank the log does not
  ## carry, and an algorithm this codec cannot hash, are both refusals:
  ## the answer to "what does PCR 4 hold in a bank nothing wrote to" is
  ## not the reset value, it is that the question is wrong.
  let size = digestSize(alg)
  if size == 0:
    fail("event log replay: " & $alg & " is not a digest this codec " &
         "computes, so the log cannot be folded under it")
  block bankIsPresent:
    for present in banks(log):
      if present == alg: break bankIsPresent
    fail("event log replay: this log carries no " & $alg &
         " bank; it carries " &
         (block:
            var names: seq[string] = @[]
            for b in banks(log): names.add $b
            names.join(", ")))

  if log.events.len == 0:
    fail("event log replay: the log has no entries")

  result.alg = alg
  result.digestSize = size
  result.extendsApplied = 0
  for i in 0 ..< NumPcrs:
    result.pcrs[i] = ReplayedPcr(state: prNeverExtended,
                                 value: initialPcrValue(i, size))

  for i, event in log.events:
    if event.eventType == EvNoAction:
      # The log's own metadata, not a measurement. Refuse the one kind
      # that changes an ANSWER rather than merely being skipped.
      if isStartupLocalityEvent(event.eventType, event.data):
        fail("event log replay: event " & $i & " at offset " &
             $event.wireOffset & " is a StartupLocality record, which " &
             "changes PCR 0's reset value to the startup locality. This " &
             "replay does not implement that rule, and a register replayed " &
             "from the wrong initial value is wrong in a way that looks " &
             "like a tampered log; the log is refused rather than replayed")
      continue
    let digest = digestFor(event, alg, i)
    result.pcrs[event.pcrIndex].value =
      extendPcr(alg, result.pcrs[event.pcrIndex].value, digest)
    result.pcrs[event.pcrIndex].state = prExtended
    inc result.extendsApplied

  if result.extendsApplied == 0:
    fail("event log replay: the log's " & $log.events.len & " entries are " &
         "all EV_NO_ACTION, so nothing was extended and every register " &
         "would be reported at its reset value. That is a machine-" &
         "independent answer, and returning it as a successful replay is " &
         "how a log that explains nothing comes to agree with everything")

proc replayAllBanks*(log: TcgEventLog): seq[ReplayedBank] =
  ## Every bank the log carries that this codec can hash, in the order
  ## the log declares them. A bank whose algorithm is unknown is
  ## SKIPPED here rather than refused — the log is still perfectly
  ## readable, and a caller asking for that bank by name still gets the
  ## refusal from `replayBank`.
  result = @[]
  for alg in banks(log):
    if digestSize(alg) == 0: continue
    result.add replayBank(log, alg)
  if result.len == 0:
    fail("event log replay: none of this log's banks (" &
         (block:
            var names: seq[string] = @[]
            for b in banks(log): names.add $b
            names.join(", ")) &
         ") is a digest this codec computes")

proc pcrValue*(bank: ReplayedBank; index: int): string =
  ## One register, whether or not the log reached it. Use `state` to
  ## tell the two apart.
  if index < 0 or index >= NumPcrs:
    fail("PCR " & $index & " is outside the " & $NumPcrs & " a bank has")
  bank.pcrs[index].value

# ---------------------------------------------------------------------
# The join with a quote
# ---------------------------------------------------------------------

type
  BankCache = object
    ## A replay is a fold over the whole log, so a selection naming
    ## eight registers of one bank must not perform it eight times. The
    ## cache is per call and deliberately not global: a memo keyed on a
    ## log would have to decide when two logs are the same log, and
    ## getting that wrong would answer a question about one machine with
    ## another machine's registers.
    banks: seq[ReplayedBank]

proc replayedBankFor(cache: var BankCache; log: TcgEventLog;
                     alg: TpmAlgId): ReplayedBank =
  for b in cache.banks:
    if b.alg == alg: return b
  result = replayBank(log, alg)
  cache.banks.add result

proc selectedFromReplay*(log: TcgEventLog;
                         sel: TpmlPcrSelection): seq[SelectedPcr] =
  ## The register values a quote's selection names, taken from a replay
  ## of this log — in exactly the shape `tpm2.pcrComposite` wants.
  ##
  ## The ORDER is irrelevant here and deliberately so: `pcrComposite`
  ## refuses to take one from its caller and emits in the selection's
  ## own order. This proc's job is to supply the SET, and to fail if the
  ## log cannot answer for one of the registers the quote covers.
  var cache = BankCache(banks: @[])
  result = @[]
  for wanted in selectedPcrs(sel):
    let bank = replayedBankFor(cache, log, wanted.bank)
    result.add selectedPcr(wanted.bank, wanted.index,
                           pcrValue(bank, wanted.index))

proc explainsQuote*(log: TcgEventLog; q: Tpm2Quote): bool =
  ## Whether replaying this log reproduces the PCR composite the quote
  ## carries.
  ##
  ## This is the whole point of the module: the quote's `pcrDigest` is
  ## signed and the log is not, so agreement means the log describes the
  ## boot the TPM attested to, and disagreement means it does not.
  ##
  ## It is NOT a verification. It says nothing about whether the
  ## signature is genuine (`tpm2.nim` does not check one either) and
  ## nothing about whether the measurements are ACCEPTABLE — a verifier's
  ## policy owns that. A caller that has only this has learned that two
  ## artifacts from the same machine agree with each other.
  ##
  ## A selection whose registers the log NEVER TOUCHED is refused rather
  ## than answered. Those registers hold their reset values, which are
  ## the same on every machine, so the composite over them is a constant
  ## — and a constant compared against a stored copy of itself agrees
  ## forever while saying nothing about any boot.
  let sel = q.attest.quote.pcrSelect
  let values = selectedFromReplay(log, sel)
  var cache = BankCache(banks: @[])
  var anyExtended = false
  for wanted in selectedPcrs(sel):
    let bank = replayedBankFor(cache, log, wanted.bank)
    if bank.pcrs[wanted.index].state == prExtended:
      anyExtended = true
      break
  if not anyExtended:
    fail("event log replay: the quote selects " & $values.len & " register" &
         (if values.len == 1: "" else: "s") & " and this log extends none " &
         "of them. Their composite is the digest of their reset values, " &
         "identical on every machine, so agreement would say nothing about " &
         "this one")
  result = pcrCompositeMatches(q, values)
