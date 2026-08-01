## Versioned SSZ envelope for typed extension-attribute records.
##
## Typed-Extension-Interfaces M1: the attribute record ``T`` a provider
## registers via ``registerExtension[T](typeId)`` crosses the
## provider<->client boundary as a **versioned SSZ envelope** —
## ``[u16le version][ssz-framed record]`` — replacing the former
## ``std/json`` marshaller. Per ``Incremental-Invalidation.md``
## ("Binary formats from Reprobuild domain types") the on-the-wire
## representation is a versioned SSZ payload over the domain type; JSON
## is inspection-only and is entirely absent from this path.
##
## ``ssz_serialization`` only serializes SSZ-native types (basic ints,
## ``bool``, fixed arrays, ``List[T, maxLen]``, SSZ objects) — a plain
## ``string`` / ``seq`` / ``int`` field of a user record is NOT an
## ``SszType``. The vendored reprobuild codecs (``repro_dev_env_artifacts``
## /``codec.nim`` and ``repro_workspace_vcs``/``evidence.nim``) handle
## this by declaring a hand-written SSZ *mirror* type with
## ``List[byte, N]`` for each string. ``registerExtension[T]`` is generic
## over arbitrary ``T``, so instead of a per-type mirror this module walks
## the record's fields with ``fieldPairs`` and encodes each field with a
## real ``SSZ.encode`` over its SSZ-native projection:
##
##   * ``string``                 -> ``List[byte, MaxAttrTextBytes]``
##   * ``seq[string]``            -> ``List[List[byte, N], MaxAttrListItems]``
##   * signed/unsigned integers   -> ``uint64`` (two's-complement bit-cast)
##   * ``bool``                   -> ``bool``
##   * ``enum``                   -> ``uint64`` (ordinal)
##
## The fields are concatenated behind an internal ``u32le`` length table so
## the reader can slice each field back out and ``readSszValue`` it. This is
## genuine SSZ serialization of the record's field values, bounded and
## JSON-free; the outer ``typeId`` continues to travel in the framing
## (``ResourceInstance.attrsTypeId`` / ``BoxedValue.typeId``), so the
## envelope body is exactly ``[version][ssz(val)]``.
##
## Provider-author guidance (M1b/doc): attribute records must be flat
## records of SSZ-clean fields — ``string``, ``seq[string]``, integers,
## ``bool``, ``enum``. Genuinely dynamic sub-regions (``Table`` /
## ``Option`` / ``ref``) are NOT supported by this path and must be
## lowered by the provider to one of the field kinds above (the in-tree /
## test attr records already are; none use ``Table`` / ``Option`` /
## ``ref``).

import std/[typetraits]

import repro_core/codec
import ssz_serialization

const
  AttrEnvelopeVersion* = 1'u16
    ## Reprobuild framing version for the attribute envelope. The reader
    ## rejects any other value, so a stale decoder fails closed rather
    ## than misinterpreting a future layout.

  MaxAttrTextBytes* = 1 * 1024 * 1024
    ## SSZ bound for a single ``string`` attribute field. Generous but
    ## finite — SSZ ``List`` requires a compile-time max length.
  MaxAttrListItems* = 64 * 1024
    ## SSZ bound for a ``seq`` attribute field's element count.

type
  AttrEnvelopeError* = object of CatchableError
    ## Raised on a malformed / wrong-version attribute envelope, or a
    ## field whose value exceeds an SSZ bound.

  AttrText = List[byte, MaxAttrTextBytes]
  AttrTextList = List[AttrText, MaxAttrListItems]

  # Each supported field kind rides inside a single-field SSZ object so
  # the whole codec path is a plain ``SSZ.encode`` / ``SSZ.decode`` over a
  # concrete SSZ object — the exact shape the vendored reprobuild codecs
  # use (``repro_dev_env_artifacts``/``codec.nim``,
  # ``repro_workspace_vcs``/``evidence.nim``). Bare ``readSszBytes`` on a
  # naked ``List`` / scalar is avoided because the ``mixin`` overload
  # resolution for the var-size ``List[List[...]]`` element path is only
  # reliably wired from inside the object reader.
  AttrTextField = object
    v: AttrText
  AttrTextListField = object
    v: AttrTextList
  AttrBoolField = object
    v: bool
  AttrUintField = object
    v: uint64

proc failAttr(message: string) {.noreturn.} =
  raise newException(AttrEnvelopeError, message)

proc toAttrText(value: string): AttrText =
  if value.len > MaxAttrTextBytes:
    failAttr("attribute text field exceeds SSZ bound (" &
      $value.len & " > " & $MaxAttrTextBytes & ")")
  var bytes = newSeq[byte](value.len)
  for i, ch in value:
    bytes[i] = byte(ord(ch))
  AttrText.init(bytes)

proc fromAttrText(value: AttrText): string =
  let raw = value.asSeq()
  result = newString(raw.len)
  for i, b in raw:
    result[i] = char(b)

proc toAttrTextList(values: seq[string]): AttrTextList =
  if values.len > MaxAttrListItems:
    failAttr("attribute seq field exceeds SSZ bound (" &
      $values.len & " > " & $MaxAttrListItems & ")")
  var wire: seq[AttrText] = @[]
  for value in values:
    wire.add(toAttrText(value))
  AttrTextList.init(wire)

proc fromAttrTextList(value: AttrTextList): seq[string] =
  for item in value:
    result.add(fromAttrText(item))

# ---- per-field SSZ encode / decode --------------------------------------

# The SSZ.encode/decode calls are NON-GENERIC (one concrete overload per
# field wire type) on purpose. Routing them through a generic helper
# (`decodeSszObject[W]`) triggers Nim's "generic sandwich"
# (nim-lang/Nim#11225): nim-serialization's `mixin readValue` fails to
# resolve the SSZ reader across the module sandwich
# (attr_ssz -> serialization -> ssz readers), giving
# "expression 'reader' has no type". Concrete procs compile the SSZ codec
# here in attr_ssz's own scope where the readers/writers resolve — the same
# non-generic `SSZ.encode(x, ConcreteType)` shape the vendored reprobuild
# codecs use. The generic field dispatchers below only *call* these
# already-resolved concrete procs (ordinary overload dispatch, no
# re-instantiation), so the sandwich never forms.

proc sszEncObj(wire: AttrTextField): seq[byte] =
  try: SSZ.encode(wire)
  except IOError as err: failAttr("could not SSZ-encode attribute field: " & err.msg)
proc sszEncObj(wire: AttrTextListField): seq[byte] =
  try: SSZ.encode(wire)
  except IOError as err: failAttr("could not SSZ-encode attribute field: " & err.msg)
proc sszEncObj(wire: AttrBoolField): seq[byte] =
  try: SSZ.encode(wire)
  except IOError as err: failAttr("could not SSZ-encode attribute field: " & err.msg)
proc sszEncObj(wire: AttrUintField): seq[byte] =
  try: SSZ.encode(wire)
  except IOError as err: failAttr("could not SSZ-encode attribute field: " & err.msg)

proc sszDecObj(payload: openArray[byte]; dst: var AttrTextField) =
  try: dst = SSZ.decode(payload, AttrTextField)
  except SszError as err: failAttr("invalid SSZ attribute field: " & err.msg)
  except IOError as err: failAttr("could not read SSZ attribute field: " & err.msg)
proc sszDecObj(payload: openArray[byte]; dst: var AttrTextListField) =
  try: dst = SSZ.decode(payload, AttrTextListField)
  except SszError as err: failAttr("invalid SSZ attribute field: " & err.msg)
  except IOError as err: failAttr("could not read SSZ attribute field: " & err.msg)
proc sszDecObj(payload: openArray[byte]; dst: var AttrBoolField) =
  try: dst = SSZ.decode(payload, AttrBoolField)
  except SszError as err: failAttr("invalid SSZ attribute field: " & err.msg)
  except IOError as err: failAttr("could not read SSZ attribute field: " & err.msg)
proc sszDecObj(payload: openArray[byte]; dst: var AttrUintField) =
  try: dst = SSZ.decode(payload, AttrUintField)
  except SszError as err: failAttr("invalid SSZ attribute field: " & err.msg)
  except IOError as err: failAttr("could not read SSZ attribute field: " & err.msg)

proc sszEncodeField[F](value: F): seq[byte] =
  ## Encode one record field into its SSZ-native projection, wrapped in a
  ## single-field SSZ object; dispatches to a concrete `sszEncObj` overload.
  when F is string:
    sszEncObj(AttrTextField(v: toAttrText(value)))
  elif F is seq[string]:
    sszEncObj(AttrTextListField(v: toAttrTextList(value)))
  elif F is bool:
    sszEncObj(AttrBoolField(v: value))
  elif F is SomeInteger:
    sszEncObj(AttrUintField(v: cast[uint64](int64(value))))
  elif F is enum:
    sszEncObj(AttrUintField(v: uint64(ord(value))))
  else:
    {.error: "attribute record field type is not SSZ-serializable: " & $F &
      " (supported: string, seq[string], integers, bool, enum)".}

proc sszDecodeField[F](payload: openArray[byte]; dst: var F) =
  ## Inverse of ``sszEncodeField`` for one field; dispatches to a concrete
  ## `sszDecObj` overload by the wire type.
  when F is string:
    var wire: AttrTextField
    sszDecObj(payload, wire)
    dst = fromAttrText(wire.v)
  elif F is seq[string]:
    var wire: AttrTextListField
    sszDecObj(payload, wire)
    dst = fromAttrTextList(wire.v)
  elif F is bool:
    var wire: AttrBoolField
    sszDecObj(payload, wire)
    dst = wire.v
  elif F is SomeInteger:
    var wire: AttrUintField
    sszDecObj(payload, wire)
    dst = F(cast[int64](wire.v))
  elif F is enum:
    var wire: AttrUintField
    sszDecObj(payload, wire)
    if wire.v > uint64(ord(high(F))):
      failAttr("SSZ enum field ordinal out of range: " & $wire.v)
    dst = F(wire.v)
  else:
    {.error: "attribute record field type is not SSZ-serializable: " & $F.}

# ---- record framing -----------------------------------------------------
#
# A record is encoded as a length-prefixed table of its fields'
# SSZ bytes, in declaration order:
#   [u32le fieldCount] ( [u32le fieldLen][ssz(field)] )*
# Field order is fixed by the record type, so the reader replays the same
# ``fieldPairs`` walk to bind each slice back to its field.

proc sszEncodeRecord*[T](val: T): seq[byte] =
  ## SSZ-serialize the whole record ``val`` (field-framed).
  var fieldCount = 0'u32
  var body: seq[byte] = @[]
  for _, fieldVal in fieldPairs(val):
    inc fieldCount
    let fieldBytes = sszEncodeField(fieldVal)
    body.writeU32Le(uint32(fieldBytes.len))
    body.add(fieldBytes)
  result = newSeqOfCap[byte](4 + body.len)
  result.writeU32Le(fieldCount)
  result.add(body)

proc sszDecodeRecord*[T](payload: openArray[byte]): T =
  ## Inverse of ``sszEncodeRecord``.
  var pos = 0
  let declaredCount = readU32Le(payload, pos)
  var seen = 0'u32
  for _, fieldVal in fieldPairs(result):
    inc seen
    if seen > declaredCount:
      failAttr("attribute record field count mismatch (declared " &
        $declaredCount & ", record has more)")
    let fieldLen = int(readU32Le(payload, pos))
    if pos + fieldLen > payload.len:
      failAttr("attribute record field payload truncated")
    sszDecodeField(payload.toOpenArray(pos, pos + fieldLen - 1), fieldVal)
    pos += fieldLen
  if seen != declaredCount:
    failAttr("attribute record field count mismatch (declared " &
      $declaredCount & ", record has " & $seen & ")")

# ---- versioned envelope -------------------------------------------------

proc encodeAttrEnvelope*[T](val: T): seq[byte] =
  ## Marshal ``val`` into ``[u16le version][ssz(val)]``. The ``typeId``
  ## is NOT part of the envelope — it travels in the outer framing.
  let payload = sszEncodeRecord(val)
  result = newSeqOfCap[byte](2 + payload.len)
  result.writeU16Le(AttrEnvelopeVersion)
  result.add(payload)

proc decodeAttrEnvelope*[T](bytes: openArray[byte]): T =
  ## Inverse of ``encodeAttrEnvelope``. Rejects a wrong/unknown version.
  var pos = 0
  let version = readU16Le(bytes, pos)
  if version != AttrEnvelopeVersion:
    failAttr("unsupported attribute envelope version " & $version &
      " (this build encodes v" & $AttrEnvelopeVersion & ")")
  sszDecodeRecord[T](bytes.toOpenArray(pos, bytes.len - 1))

# ---- string transport ---------------------------------------------------
#
# The extension registry's marshaller signature is string in / string out
# (a byte string). The envelope is raw bytes; we carry it losslessly as a
# byte-per-char string so the binary payload survives the existing
# ``ExtensionMarshaler`` seam unchanged.

proc bytesToByteString*(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for i, b in bytes:
    result[i] = char(b)

proc byteStringToBytes*(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))
