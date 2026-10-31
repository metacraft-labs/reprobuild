## The ``reproos.image-layout.v1`` record: the disk layout an image was
## actually BUILT with.
##
## ## The hole this closes
##
## Whether a launch measurement is worth quoting depends on the shape of
## the disk the machine boots: a root filesystem that is integrity-checked
## and read-only for the life of the boot is a thing a measurement can
## speak for, and an ordinary writable volume is not.
##
## A profile says which of those it believes it is installing into, and
## until this record existed that belief was all anybody had. The rule
## that refuses a non-mock tier on a writable-root layout read a string
## the profile itself had written — so it compared a declaration against a
## declaration, and the one failure it could not see was the two
## disagreeing. A profile that says ``uefi-attested`` while its image was
## built ``uefi-ext4`` plans, applies, boots, and quotes a measurement of
## a root filesystem that is writable the whole time. Nothing fails. The
## quote is honest about a machine that is not.
##
## ## What the record is, and what makes it a second source
##
## It is written by the IMAGE BUILD, from the layout that build resolved,
## and it carries the digest of the partition table that layout rendered —
## the bytes the image's disk was actually created from. The build refuses
## to publish a record whose digest is not the digest of the table it
## applied, so the name in this document is tied to a partition table
## rather than to somebody's intent.
##
## The profile then reads the record. If it also names a layout of its
## own, the two must agree, and a disagreement is refused at plan time
## naming both. That is the whole of what this adds: the layout stops
## being something the configuration asserts and becomes something the
## image reports.
##
## ## Why the schema lives here rather than beside the recipe
##
## Same reason ``reproos.attested-image.v1`` does. The document is written
## at one end of a repository boundary and read at the other, so a second
## implementation of it would be a second opinion about what an image is —
## and the only two parties who could disagree are precisely the two this
## document exists to keep in step.
##
## ## Mocking
##
## None. Typed record, canonical renderer, strict parser; no I/O.

import std/[json, strutils]

type
  ImageLayoutRecordError* = object of CatchableError
    ## Raised for any document this module will not honour. Like the
    ## measurement manifest's error, the message names the offending key:
    ## its reader is whoever has to fix the document.

  ImageLayoutRecord* = object
    ## What the image build says about the disk it built.
    layout*: string
      ## The resolved preset name — the one the recipe's registry
      ## returned, not the one the configuration asked for. They differ
      ## whenever a default applies.
    id*: string
      ## The hardware-spec id the layout was rendered for.
    device*: string
      ## The block device the layout was applied to.
    espSizeMib*: int
    diskSizeGb*: int
    partitionTableSha256*: string
      ## SHA-256, lower-case hex, of the partition-table document the
      ## named layout renders for these parameters. This is the field
      ## that makes the record a report rather than a restatement: the
      ## build compares it against the digest of the document it actually
      ## handed the partitioner, and refuses to publish a record that
      ## does not match.

const
  ImageLayoutRecordSchema* = "reproos.image-layout.v1"

  ImageLayoutRecordFileName* = "reproos.image-layout.json"
    ## What the document is called when it rides an image build. Declared
    ## beside the schema so the build that writes it and the profile that
    ## reads it cannot disagree about the name.

  ImageLayoutRecordKeys*: array[7, string] = [
    "schema", "layout", "id", "device", "espSizeMib", "diskSizeGb",
    "partitionTableSha256"]
    ## The complete key set. A document with any other key was written by
    ## a tool that means something this one cannot honour, and is refused
    ## rather than partly understood.

  LayoutNameMaxLen* = 128

proc isLowerHex64(s: string): bool =
  if s.len != 64: return false
  for c in s:
    if c notin {'0' .. '9', 'a' .. 'f'}: return false
  true

proc isSafeToken(s: string; maxLen: int): bool =
  ## The character set every scalar here is confined to, checked on the
  ## way IN so the hand-written renderer below cannot be asked to emit a
  ## value it would have to escape.
  if s.len == 0 or s.len > maxLen: return false
  for c in s:
    if c notin {'0' .. '9', 'a' .. 'z', 'A' .. 'Z', '.', '_', '-', ':',
                '+', '/', '='}:
      return false
  true

proc validateImageLayoutRecord*(r: ImageLayoutRecord) =
  ## Raises ``ImageLayoutRecordError`` on anything this schema will not
  ## carry. Called by both the renderer and the parser, so a value that
  ## cannot be read back cannot be written either.
  if not isSafeToken(r.layout, LayoutNameMaxLen):
    raise newException(ImageLayoutRecordError,
      "layout must be a non-empty token of at most " & $LayoutNameMaxLen &
      " characters from [0-9A-Za-z._:+/=-], got " & r.layout.escapeJson())
  if not isSafeToken(r.id, LayoutNameMaxLen):
    raise newException(ImageLayoutRecordError,
      "id must be a non-empty token, got " & r.id.escapeJson())
  if not isSafeToken(r.device, LayoutNameMaxLen):
    raise newException(ImageLayoutRecordError,
      "device must be a non-empty token, got " & r.device.escapeJson())
  if r.espSizeMib <= 0:
    raise newException(ImageLayoutRecordError,
      "espSizeMib must be a positive integer, got " & $r.espSizeMib)
  if r.diskSizeGb <= 0:
    raise newException(ImageLayoutRecordError,
      "diskSizeGb must be a positive integer, got " & $r.diskSizeGb)
  if not isLowerHex64(r.partitionTableSha256):
    raise newException(ImageLayoutRecordError,
      "partitionTableSha256 must be 64 lower-case hex characters, got " &
      r.partitionTableSha256.escapeJson())

proc renderImageLayoutRecord*(r: ImageLayoutRecord): string =
  ## The canonical bytes. Written by hand, in the key order
  ## ``ImageLayoutRecordKeys`` declares, so two builds of the same image
  ## produce the same document under any JSON library.
  validateImageLayoutRecord(r)
  result = "{\n"
  result.add("  \"schema\": \"" & ImageLayoutRecordSchema & "\",\n")
  result.add("  \"layout\": \"" & r.layout & "\",\n")
  result.add("  \"id\": \"" & r.id & "\",\n")
  result.add("  \"device\": \"" & r.device & "\",\n")
  result.add("  \"espSizeMib\": " & $r.espSizeMib & ",\n")
  result.add("  \"diskSizeGb\": " & $r.diskSizeGb & ",\n")
  result.add("  \"partitionTableSha256\": \"" & r.partitionTableSha256 &
    "\"\n")
  result.add("}\n")

proc requireKeys(node: JsonNode; known: openArray[string]) =
  for key, _ in node:
    if key notin known:
      raise newException(ImageLayoutRecordError,
        "unknown key " & key.escapeJson() & "; this document was written " &
        "by a newer tool and cannot be partly understood")
  for key in known:
    if key notin node:
      raise newException(ImageLayoutRecordError,
        "missing key " & key.escapeJson())

proc getStrField(node: JsonNode; key: string): string =
  if node[key].kind != JString:
    raise newException(ImageLayoutRecordError,
      key.escapeJson() & " must be a string")
  node[key].getStr

proc getIntField(node: JsonNode; key: string): int =
  if node[key].kind != JInt:
    raise newException(ImageLayoutRecordError,
      key.escapeJson() & " must be an integer")
  node[key].getInt

proc parseImageLayoutRecord*(text: string): ImageLayoutRecord =
  ## Strict. Everything a lenient parser would let through here is a way
  ## to believe something the image build did not say.
  var doc: JsonNode
  try:
    doc = parseJson(text)
  except CatchableError as err:
    raise newException(ImageLayoutRecordError,
      "the image layout record is not JSON: " & err.msg)
  if doc.kind != JObject:
    raise newException(ImageLayoutRecordError,
      "the image layout record must be a JSON object")
  requireKeys(doc, ImageLayoutRecordKeys)
  let schema = getStrField(doc, "schema")
  if schema != ImageLayoutRecordSchema:
    raise newException(ImageLayoutRecordError,
      "unsupported schema " & schema.escapeJson() & "; this build reads " &
      ImageLayoutRecordSchema.escapeJson())
  result = ImageLayoutRecord(
    layout: getStrField(doc, "layout"),
    id: getStrField(doc, "id"),
    device: getStrField(doc, "device"),
    espSizeMib: getIntField(doc, "espSizeMib"),
    diskSizeGb: getIntField(doc, "diskSizeGb"),
    partitionTableSha256: getStrField(doc, "partitionTableSha256"))
  validateImageLayoutRecord(result)
