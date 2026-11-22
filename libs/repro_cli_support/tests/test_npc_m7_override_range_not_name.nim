## NPC-M7 verification `test_npc_m7_override_range_not_name` (NPC-AREQ24).
##
## A native override is keyed by a package AND a version range. The
## override for `jester >= 0.5` -- read from an index repository's source
## set (`[[native]]`), as a build reads it at the pinned revision --
## adds its native dependency to `jester` 0.5.x and not to `jester` 0.4.x,
## and `repro nimble check`'s report says so per version: the override is
## shown as applied to 0.5.x, and 0.4.x's `foreignDep` is reported as an
## unmapped native dependency (reported, not a failure).
##
## The source set refuses a `[[native]]` that has no `versions`, or whose
## `versions` is not a range (`any version` would key it by the name).
##
## Falsifying mutation (recorded in the plan): keying the override by name
## alone (``nativeOverridesFor`` skipping the range check) adds it to 0.4.x
## and fails the test.

import std/[sequtils, strutils, unittest]

import repro_cli_support
import repro_nimble_generator/source_set
import repro_nimble_index

const SourceSet = """
schema = "reprobuild.nimble-source-set.v1"

[[extra]]
name = "jester"
origin = "https://example.invalid/jester"

[[native]]
package = "jester"
versions = ">= 0.5"
runtime_deps = ["openssl"]
defines = ["ssl"]
"""

proc locked(name, version: string; foreign: seq[string]): LockedNimblePackage =
  result.row.name = name
  result.version = version
  for f in foreign:
    result.record.foreign.add ForeignDependency(name: f)

proc refusal(text: string): string =
  try:
    discard parseSourceSet(text, "nimble-sources.toml")
  except SourceSetError as e:
    return e.msg
  ""

suite "NPC-M7: native overrides are keyed by package and version range":
  let natives = parseSourceSet(SourceSet, "nimble-sources.toml").natives

  test "the override reaches 0.5.x and not 0.4.x":
    check natives.len == 1
    check natives[0].versions == ">= 0.5"
    for v in ["0.5.0", "0.5.7", "1.2.0"]:
      let applied = nativeOverridesFor("jester", v, natives)
      check applied.len == 1
      check applied[0].runtimeDeps == @["openssl"]
    for v in ["0.4.9", "0.4.0", "0.1.0"]:
      check nativeOverridesFor("jester", v, natives).len == 0
    # Another package of the same index is not reached, and a
    # pseudo-version is in no range.
    check nativeOverridesFor("httpbeast", "0.5.0", natives).len == 0
    check nativeOverridesFor("jester", "#head", natives).len == 0
    # Nimble names compare as Nimble compares them.
    check nativeOverridesFor("Jester", "0.5.1", natives).len == 1

  test "repro nimble check reports it per version":
    var report = NimbleSourcesReport(active: true, platform: "amd64-linux",
      natives: natives)
    report.packages = @[locked("jester", "0.5.2", @["openssl"])]
    let newer = nimbleCheck(report)
    checkpoint newer.lines.join("\n")
    check newer.lines.anyIt("override applied (jester >= 0.5)" in it and
      "runtime deps openssl" in it)
    check not newer.lines.anyIt("unmapped native dependency" in it)
    report.packages = @[locked("jester", "0.4.9", @["openssl"])]
    let older = nimbleCheck(report)
    checkpoint older.lines.join("\n")
    check not older.lines.anyIt("override applied" in it)
    check older.lines.anyIt("unmapped native dependency: openssl" in it)
    check older.refused == 0

  test "a native override without a range is refused":
    let noRange = refusal(SourceSet.replace("versions = \">= 0.5\"\n", ""))
    checkpoint noRange
    check "is missing `versions`" in noRange
    check "never by the name alone" in noRange
    let anyVersion = refusal(SourceSet.replace("\">= 0.5\"", "\"\""))
    check "is missing `versions`" in anyVersion
    let notRange = refusal(SourceSet.replace("\">= 0.5\"", "\"#head\""))
    checkpoint notRange
    check "is not a Nimble version range" in notRange
    let nothing = refusal(SourceSet.replace(
      "runtime_deps = [\"openssl\"]\ndefines = [\"ssl\"]\n", ""))
    check "supplies nothing" in nothing

  test "a native override is part of what the index says":
    let plain = parseSourceSet(SourceSet.split("[[native]]")[0],
      "nimble-sources.toml")
    let withNative = parseSourceSet(SourceSet, "nimble-sources.toml")
    check sourceSetIdentity(plain) != sourceSetIdentity(withNative)
    check "native \"jester\" versions=\">= 0.5\"" in canonicalText(withNative)
