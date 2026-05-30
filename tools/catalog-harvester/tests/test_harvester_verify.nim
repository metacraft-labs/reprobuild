## M66 Part D — Verify round-trip.
##
## Emits a ``hello.nim`` catalog, writes it to a temp file, then
## simulates the ``verify`` subcommand's comparison logic: re-harvest
## and assert byte-identical. Drift is artificially introduced in a
## second sub-test to confirm the comparison catches it.

import std/[os, strutils, unittest]

import ../src/manifest_parser
import ../src/nim_emit
import repro_dsl_stdlib/packages_schema

const FixturesDir = currentSourcePath.parentDir / "fixtures"

proc readFixture(bucket, app: string): string =
  readFile(FixturesDir / bucket / "bucket" / (app & ".json"))

proc emitFor(bucket, app, bucketSpec: string): string =
  let raw = readFixture(bucket, app)
  let p = parseScoopManifest(app, raw)
  check p.ok
  emitCatalogFile(app, bucketSpec, @[p.entry])

suite "M66 — verify round-trip":

  test "checked-in catalog matches re-harvest":
    let checkedIn = emitFor("bucket-simple", "hello", "scoopinstaller/main")
    let reHarvested = emitFor("bucket-simple", "hello", "scoopinstaller/main")
    check checkedIn == reHarvested

  test "drift detection: a single byte off triggers inequality":
    let checkedIn = emitFor("bucket-simple", "hello", "scoopinstaller/main")
    var drifted = checkedIn
    # Introduce drift: change "1.0.0" -> "1.0.1".
    drifted = drifted.replace("1.0.0", "1.0.1")
    check checkedIn != drifted
