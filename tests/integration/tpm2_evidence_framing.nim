## A second implementation of the tpm2 evidence framing, written from
## the format's description rather than from the code that produces it.
##
## ## Why this exists
##
## Two jobs, and they are the same job:
##
##   1. **A positive control that is not a self-check.** A round trip
##      through one encoder and its own decoder proves the pair agrees
##      with itself, which it would do just as happily if the framing
##      were wrong. Requiring the library's bytes to equal bytes written
##      here, from the written format, makes the agreement a statement
##      about the format.
##   2. **A way to spell malformed documents.** Every refusal the parser
##      owes has to be reachable, and most of them are unreachable
##      through the composer — it will not emit a duplicated member, a
##      count that disagrees with the members, or a tag nothing defines.
##      So the negative cases are built here instead, where each field is
##      independently writable.
##
## ``declaredCount`` is deliberately separate from ``members.len``: a
## helper that could only produce documents whose count matched its
## members could not build the disagreement, and the disagreement is one
## of the things the parser must refuse.
##
## ## Mocking
##
## None. This is an encoder, not a stand-in for one — it writes the bytes
## the format describes and nothing consults it at run time.

import std/strutils

proc hexOf*(s: string): string =
  result = ""
  for c in s: result.add toHex(uint8(c), 2).toLowerAscii

proc be32*(v: uint32): string =
  ## Four-byte big-endian, written here rather than borrowed from the
  ## writer under test.
  result = newString(4)
  for i in 0 ..< 4:
    result[i] = char(uint8((v shr (8 * (3 - i))) and 0xFF'u32))

proc frame*(schema: string; declaredCount: int;
            members: openArray[(uint32, string)]): string =
  ## ``be32(len(schema)) ‖ schema ‖ be32(count) ‖ [be32(tag) be32(len) bytes]*``
  result = be32(uint32(schema.len))
  result.add schema
  result.add be32(uint32(declaredCount))
  for (tag, payload) in members:
    result.add be32(tag)
    result.add be32(uint32(payload.len))
    result.add payload

proc frameWithRawCount*(schema: string; rawCount: uint32;
                        members: openArray[(uint32, string)]): string =
  ## The same, with a count that does not fit an ``int`` comfortably —
  ## needed to test the member-count bound at a value a hostile document
  ## would actually carry.
  result = be32(uint32(schema.len))
  result.add schema
  result.add be32(rawCount)
  for (tag, payload) in members:
    result.add be32(tag)
    result.add be32(uint32(payload.len))
    result.add payload
