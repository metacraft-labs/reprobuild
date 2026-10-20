## The Boundary between the registry's Edge and Interior
## (`reprobuild-pm/spec/Remix-Registry.md` §"The Boundary vocabulary").
##
## Exactly five message types exist. A message is a framed record the Edge
## intake *creates* in the spool and the Interior registrar *claims*. The
## spool uses the Maildir delivery discipline — write under `tmp/`, then
## rename into `new/` — so a reader never sees a partial message, and the
## writer needs only create-and-rename rights, never read, list or delete:
##   https://cr.yp.to/proto/maildir.html
##
## Everything a message carries besides its type and payload is advisory
## Edge metadata. `rateKey` is used for rate limiting only and never for
## authorization (FLOW-4): author identity comes from signatures.

import std/[algorithm, os, strutils, times]

import ssz_serialization
import repro_remix

const
  MaxMessageBytes* = 512 * 1024 * 1024 + 64 * 1024
    ## The largest payload any type admits (a maximal blob) plus framing.
  MaxReportTextBytes* = 4096
  BoundaryFrameVersion = 1'u16

type
  MessageType* = enum
    mtSubmitRelease = 1
      ## A manifest or key-log envelope.
    mtSubmitBlob = 2
    mtRequestIndexUpdate = 3
    mtReportContent = 4
    mtModerationQuery = 5

  BoundaryMessage* = object
    msgType*: MessageType
    receivedAt*: int64
      ## Unix seconds at the intake; advisory.
    intake*: string
      ## Intake instance name; advisory.
    rateKey*: string
      ## Rate-limit identity the intake derived (e.g. client address);
      ## advisory, never an authorization input.
    payload*: seq[byte]

  BoundaryMessageW = object
    version: uint16
    msgType: uint8
    receivedAt: uint64
    intake: List[byte, 256]
    rateKey: List[byte, 256]
    payload: List[byte, MaxMessageBytes]

proc maxPayload*(t: MessageType): int =
  ## Per-type size bound, enforced by the intake and again, independently,
  ## by the Interior.
  case t
  of mtSubmitRelease: MaxBodyBytes + 64 * 1024
  of mtSubmitBlob: int(MaxBlobBytes)
  of mtRequestIndexUpdate: 0
  of mtReportContent: 32 + 1 + MaxReportTextBytes
  of mtModerationQuery: 32

proc parseMessageType*(name: string): (bool, MessageType) =
  case name
  of "release": (true, mtSubmitRelease)
  of "blob": (true, mtSubmitBlob)
  of "index-update": (true, mtRequestIndexUpdate)
  of "report": (true, mtReportContent)
  of "moderation-query": (true, mtModerationQuery)
  else: (false, mtSubmitRelease)

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(ord(c))

proc strOf(b: openArray[byte]): string =
  result = newString(b.len)
  for i, x in b: result[i] = char(x)

proc encodeMessage*(m: BoundaryMessage): seq[byte] =
  if m.payload.len > maxPayload(m.msgType):
    refuse(rrOversize, $m.msgType & " payload of " & $m.payload.len & " bytes")
  if m.intake.len > 256 or m.rateKey.len > 256:
    refuse(rrBound, "boundary metadata too long")
  SSZ.encode(BoundaryMessageW(version: BoundaryFrameVersion,
    msgType: uint8(ord(m.msgType)), receivedAt: uint64(max(m.receivedAt, 0)),
    intake: List[byte, 256].init(bytesOf(m.intake)),
    rateKey: List[byte, 256].init(bytesOf(m.rateKey)),
    payload: List[byte, MaxMessageBytes].init(m.payload)))

proc decodeMessage*(bytes: openArray[byte]): BoundaryMessage =
  ## The Interior-side schema check: everything is refused unless it is a
  ## v1 frame of one of the five declared types within that type's bound.
  if bytes.len > MaxMessageBytes + 1024:
    refuse(rrOversize, "boundary message too large")
  var w: BoundaryMessageW
  try:
    w = SSZ.decode(bytes, BoundaryMessageW)
  except SerializationError as e:
    refuse(rrMalformed, "boundary frame: " & e.msg)
  if w.version != BoundaryFrameVersion:
    refuse(rrUnknownEnvelopeVersion, "boundary frame version " & $w.version)
  if w.msgType < 1 or w.msgType > uint8(ord(MessageType.high)):
    refuse(rrUnknownVocabulary, "undeclared boundary message type " & $w.msgType)
  result = BoundaryMessage(msgType: MessageType(w.msgType),
    receivedAt: int64(min(w.receivedAt, uint64(high(int64)))), intake: strOf(asSeq(w.intake)),
    rateKey: strOf(asSeq(w.rateKey)), payload: asSeq(w.payload))
  if result.payload.len > maxPayload(result.msgType):
    refuse(rrOversize, $result.msgType & " payload of " & $result.payload.len & " bytes")

# ---------------------------------------------------------------------------
# Spool (Maildir discipline).
# ---------------------------------------------------------------------------

type
  Spool* = object
    root*: string

proc initSpool*(root: string): Spool =
  for sub in ["tmp", "new", "cur"]:
    createDir(root / sub)
  Spool(root: root)

var deliveryCounter {.threadvar.}: int

proc deliver*(s: Spool; intake: string; message: openArray[byte]): string =
  ## Edge side. Write under `tmp/`, fsync-free rename into `new/`. Returns
  ## the unique name. Never reads, lists or removes anything.
  inc deliveryCounter
  let name = $getTime().toUnix & "." & $getCurrentProcessId() & "." &
             $deliveryCounter & "." & intake
  let tmpPath = s.root / "tmp" / name
  var f: File
  if not open(f, tmpPath, fmWrite):
    refuse(rrMalformed, "cannot create spool file")
  try:
    if message.len > 0:
      discard f.writeBuffer(unsafeAddr message[0], message.len)
  finally:
    f.close()
  moveFile(tmpPath, s.root / "new" / name)
  name

proc pending*(s: Spool): seq[string] =
  ## Interior side: delivered, unclaimed messages, oldest first by name.
  for kind, path in walkDir(s.root / "new"):
    if kind == pcFile:
      result.add path.extractFilename
  result.sort(cmp)

proc claim*(s: Spool; name: string): seq[byte] =
  ## Interior side: move a message to `cur/` and read it. A message is
  ## claimed once; a crash after the move leaves it in `cur/` for replay.
  if '/' in name or name.startsWith("."):
    refuse(rrInvalidText, "spool name")
  let src = s.root / "new" / name
  let dst = s.root / "cur" / name
  moveFile(src, dst)
  let data = readFile(dst)
  result = bytesOf(data)

proc retire*(s: Spool; name: string) =
  ## Interior side: drop a fully processed message.
  removeFile(s.root / "cur" / name)
