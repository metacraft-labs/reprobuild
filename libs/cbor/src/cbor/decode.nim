## The `DynamicValue` decoder.
##
## `DynamicValue` is the small, string-keyed view this library started
## as, and it is still the shape `repro_profile_intent` reads. The
## PARSING is no longer done here: this module calls the RFC 8949 reader
## and then projects the resulting `CborItem` onto `DynamicValue`,
## refusing anything the smaller type cannot hold.
##
## Doing it this way rather than keeping a second parser is the point.
## The old decoder here accepted heads the RFC forbids, had no bound
## between a declared length and an allocation, and answered every bad
## input with one of six sentences that a caller could not tell apart.
## Its only consumer now reads through the checked reader, so the
## library has one answer to "is this well-formed CBOR" rather than two.
##
## The projection refuses rather than approximates: a negative integer,
## a tag, a float, a bignum or a map with a non-text key raises
## `CborError` with `cekBadDiagnostic` and a sentence naming what was
## found. It does not, for instance, turn a tag into its content.

import ./types
import ./item
import ./reader

proc project(node: CborItem): DynamicValue =
  if node.isNil:
    cborFail(cekBadDiagnostic, "nil item")
  case node.kind
  of ckUInt:
    cborUInt(node.arg)
  of ckBytes:
    cborBytes(node.bytes)
  of ckText:
    cborText(node.text)
  of ckArray:
    var values = newSeq[DynamicValue](node.elems.len)
    for i in 0 ..< node.elems.len:
      values[i] = project(node.elems[i])
    cborArray(values)
  of ckMap:
    var entries = newSeq[DynamicMapEntry](node.entries.len)
    for i in 0 ..< node.entries.len:
      let k = node.entries[i].key
      if k.isNil or k.kind != ckText:
        cborFail(cekBadDiagnostic,
          "this view requires text map keys, found " &
            (if k.isNil: "nil" else: $k.kind))
      entries[i] = entry(k.text, project(node.entries[i].val))
    cborMap(entries)
  of ckSimple:
    case node.simple
    of SimpleFalse: cborBool(false)
    of SimpleTrue: cborBool(true)
    of SimpleNull: cborNull()
    else:
      cborFail(cekBadDiagnostic,
        "this view holds no simple value " & $node.simple)
  of ckNegInt, ckTag, ckFloat:
    cborFail(cekBadDiagnostic, "this view holds no " & $node.kind)

proc decode*(bytes: openArray[byte]): DynamicValue =
  ## One complete item, projected onto `DynamicValue`.
  project(decodeItem(bytes))
