## Test support (not a test): the NPC-M14 fixture, a package whose `.nimble`
## carries status-im's `when NimMajor >= 2` idiom (`chronicles` v0.11.0,
## NPC-M0), read by the production reader and turned into its version record
## by the production joiner -- no hand-built condition.
##
## The fixture's `nim` floor is `>= 1.6.0`, not v0.11.0's `>= 2.0.16`: the
## real floor would make every solve at Nim 1.6.20 fail on the range alone,
## and the point is the condition, which is the file's own text.

import std/options

import repro_nimble_index
import repro_nimble_reader

import ./index_fixtures

const ChroniclesIdiomNimble* = """
mode = ScriptMode.Verbose

packageName   = "chronicles"
version       = "0.11.0"
skipDirs      = @["tests"]

requires "nim >= 1.6.0"
requires "json_serialization"

# Allow old nimble versions to parse this nimble file
when NimMajor >= 2:
  taskRequires "test", "testutils"
else:
  requires "testutils"
"""

proc recordFromNimble*(package, tag, text: string): VersionRecord =
  ## The record the generator emits for ``text`` read at ``tag``: the
  ## static reader's reading joined with fixture digests.
  let f = readNimbleSource(text, package & ".nimble")
  doAssert f.isStaticallyReadable, $f.readerClass
  let base = record(package, tag)
  result = recordFromNimbleFile(f, VersionFacts(tag: tag, commit: base.commit,
    tree: base.tree, archiveSha256: base.archiveSha256, size: base.size,
    firstSeen: base.firstSeen, nimbleFile: base.nimbleFile))

proc chroniclesIdiomPackages*(): seq[PackageEnvelope] =
  ## `chronicles` 0.11.0 (the idiom), `json_serialization` and `testutils`.
  @[package("chronicles", @[recordFromNimble("chronicles", "v0.11.0",
      ChroniclesIdiomNimble)]),
    package("json_serialization", @[record("json_serialization", "v0.2.9")]),
    package("testutils", @[record("testutils", "0.5.0")])]
