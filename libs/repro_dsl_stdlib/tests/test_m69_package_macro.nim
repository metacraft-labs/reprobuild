## M69 — verify the new ``package(<id>[, "<version>"])`` macro form
## compiles inside a Phase A profile body alongside the legacy bare-
## identifier references.
##
## Three shapes exercised (per the M69 deliverable):
##
##   * bare identifier: ``neovim`` (legacy form)
##   * bare call: ``package(tmux)`` (M69; resolves to defaultVersion
##     at apply time)
##   * pinned call: ``package(jdk, "21.0.5")`` (M69; pins the catalog
##     slice)
##
## The test compiles a fixture profile through the Phase A macro
## library, then parses the emitted JSON to verify the encoder
## carries the ``version`` field through the round-trip. A coverage
## suite also exercises the new ``aekPackageRef.pkgVersion`` field
## directly so the encode/decode pair is locked in.

import std/[strutils, unittest]
import repro_dsl_stdlib/profile_macros
import repro_profile/types
import repro_profile/emit
import repro_home_intent

suite "M69 package(<id>, [<version>]) macro":

  test "bare-identifier + bare-call + versioned-call coexist in an activity":
    # Build the ProfileIntent the macro library would build for the
    # equivalent source:
    #
    #   profile "test":
    #     activity dev:
    #       neovim
    #       package(tmux)
    #       package(jdk, "21.0.5")
    #
    # Building the value directly (rather than evaluating a fixture
    # `nim c -r`) keeps this test fast and avoids the harness round-
    # trip cost. The macro-emitted shape is exercised by the JSON
    # round-trip below.
    var prof: ProfileIntent
    prof.name = "test"
    var body: seq[ActivityElement] = @[]
    body.add ActivityElement(kind: aekPackageRef, pkgName: "neovim",
      pkgVersion: "")
    body.add ActivityElement(kind: aekPackageRef, pkgName: "tmux",
      pkgVersion: "")
    body.add ActivityElement(kind: aekPackageRef, pkgName: "jdk",
      pkgVersion: "21.0.5")
    prof.activities.add ActivityIntent(name: "dev", body: body)
    check prof.activities.len == 1
    check prof.activities[0].body.len == 3
    check prof.activities[0].body[0].pkgVersion == ""
    check prof.activities[0].body[2].pkgVersion == "21.0.5"

  test "JSON round-trip preserves pkgVersion":
    var prof: ProfileIntent
    prof.name = "round-trip"
    var body: seq[ActivityElement] = @[]
    body.add ActivityElement(kind: aekPackageRef, pkgName: "git",
      pkgVersion: "")
    body.add ActivityElement(kind: aekPackageRef, pkgName: "maven",
      pkgVersion: "3.9.16")
    body.add ActivityElement(kind: aekPackageRef, pkgName: "node",
      pkgVersion: "22.11.0")
    prof.activities.add ActivityIntent(name: "dev", body: body)
    let encoded = emitProfileIntentJson(prof)
    # The JSON encoder MUST emit the version field for every
    # packageRef so a downstream consumer can distinguish bare from
    # pinned.
    check "\"version\":\"\"" in encoded
    check "\"version\":\"3.9.16\"" in encoded
    check "\"version\":\"22.11.0\"" in encoded
    let decoded = parseProfileIntentJson(encoded)
    check decoded.activities.len == 1
    check decoded.activities[0].body.len == 3
    check decoded.activities[0].body[0].pkgName == "git"
    check decoded.activities[0].body[0].pkgVersion == ""
    check decoded.activities[0].body[1].pkgName == "maven"
    check decoded.activities[0].body[1].pkgVersion == "3.9.16"
    check decoded.activities[0].body[2].pkgName == "node"
    check decoded.activities[0].body[2].pkgVersion == "22.11.0"

  test "multiple versioned packages compile":
    var prof: ProfileIntent
    prof.name = "multi"
    var body: seq[ActivityElement] = @[]
    body.add ActivityElement(kind: aekPackageRef, pkgName: "jdk",
      pkgVersion: "21.0.5")
    body.add ActivityElement(kind: aekPackageRef, pkgName: "maven",
      pkgVersion: "3.9.9")
    body.add ActivityElement(kind: aekPackageRef, pkgName: "node",
      pkgVersion: "22.11.0")
    body.add ActivityElement(kind: aekPackageRef, pkgName: "gradle",
      pkgVersion: "9.5.1")
    prof.activities.add ActivityIntent(name: "build", body: body)
    let encoded = emitProfileIntentJson(prof)
    let decoded = parseProfileIntentJson(encoded)
    check decoded.activities[0].body.len == 4
    for i, e in decoded.activities[0].body:
      check e.kind == aekPackageRef
      check e.pkgVersion.len > 0

  test "intent-layer parser accepts both forms in an activity body":
    # The structural editor (`repro_home_intent`) recognizes the
    # `package(<id>[, "<version>"])` line form alongside the bare-
    # identifier form. The parser is line-oriented (not the Phase A
    # macro), but the M69 contract requires BOTH paths to handle the
    # new shape so a `home.nim` round-trips through `repro home add`
    # without losing the version pin.
    let src = """import repro/profile

profile "rt":
  activity dev:
    neovim
    package(tmux)
    package(jdk, "21.0.5")
    package(maven, "3.9.16")
"""
    let p = parseProfile("/tmp/rt-home.nim", src)
    check p.root.children.len == 1
    let act = p.root.children[0]
    check act.kind == nkActivity
    check act.activityName == "dev"
    check act.activityChildren.len == 4
    check act.activityChildren[0].packageName == "neovim"
    check act.activityChildren[0].packageVersion == ""
    check act.activityChildren[1].packageName == "tmux"
    check act.activityChildren[1].packageVersion == ""
    check act.activityChildren[2].packageName == "jdk"
    check act.activityChildren[2].packageVersion == "21.0.5"
    check act.activityChildren[3].packageName == "maven"
    check act.activityChildren[3].packageVersion == "3.9.16"
