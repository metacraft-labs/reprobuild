## ``t_version_encoder_existing_programs_unchanged`` — NPC-M6 changed the
## shared encoder (per-version dependencies, on-demand activation, exact
## ``#...`` ranges, a newest-first search heuristic). A declaration set that
## uses none of them must reach clingo as exactly the program it reached
## before, or every existing solve -- and the lock identity derived from it
## -- could move (NLF-STAT-4).
##
## The corpus below covers the shapes the existing solver tests use:
## package-level ranges and chains, a range that does not parse, a
## dependency on an undeclared package, variant-gated dependencies, pinned
## packages and variants, instances of one base, cross-package variant
## propagation, and every ``VersionPreference``. For each it hashes the
## solving program (``encodeUnified``) and the unsat-core program
## (``encodeWithAssumptions``) and compares the hashes with those recorded
## from the encoder BEFORE NPC-M6 (reprobuild ``8c92d3530e``), by running
## this file there with ``-d:printProgramHashes``.
##
## Falsifying mutation: emitting the newest-first heuristic for every package
## under no strategy (or a ``package_active`` rule instead of the fact) moves
## the hash of every ``vpNone`` case.

import std/[strutils, tables, unittest]

import nimcrypto/[hash, sha2]

import repro_solver/version_encoder
import repro_solver/variant_encoder
import repro_solver/explainer

proc digest(text: string): string =
  toLowerAscii($sha256.digest(text))

proc chain(n, v: int): seq[PackageDecl] =
  for i in 0 ..< n:
    var vs: seq[string]
    for j in 0 ..< v: vs.add($(1 + j div 3) & "." & $(j mod 3) & ".0")
    var deps: seq[DependencyDecl]
    if i + 1 < n:
      deps.add newDependency("p" & $(i + 1), ">=1.0.0, <" & $(2 + i mod 2) &
        ".0.0")
    if i + 2 < n: deps.add newDependency("p" & $(i + 2), ">=1.1.0")
    result.add newPackage("p" & $i, vs, deps)

proc corpus(): seq[(string, seq[VariantDecl], seq[PackageDecl])] =
  let none: seq[VariantDecl] = @[]
  result.add ("chain", none, chain(8, 5))
  result.add ("unparseable-and-undeclared", none, @[
    newPackage("app", ["0.1.0"], [newDependency("lib", ">=banana"),
      newDependency("ghost", ">=1.0.0"), newDependency("ok", "^1.2")]),
    newPackage("lib", ["1.0.0", "2.0.0"]),
    newPackage("ok", ["1.1.0", "1.2.5", "1.9.0", "2.0.0"])])
  let ssl = newBoolVariant("ssl", [contribution(vpDefault, "false"),
    contribution(vpSet, "true")], [requiresExpr("true", "backend", "epoll")])
  let backend = newEnumVariant("backend", ["epoll", "kqueue", "poll"],
    [contribution(vpDefault, "epoll")])
  result.add ("variant-gated", @[ssl, backend], @[
    newPackage("app", ["1.0.0"], [
      newConditionalDependency("openssl", ">=3.0.0", "ssl", "true"),
      newConditionalDependency("libev", ">=4.0.0", "backend", "epoll"),
      newDependency("zlib", ">=1.2.0")], [ssl, backend]),
    newPackage("openssl", ["1.1.1", "3.0.2", "3.3.1"]),
    newPackage("libev", ["4.31.0", "4.33.0"]),
    newPackage("zlib", ["1.2.11", "1.3.1"])])
  let pinnedVariant = newBoolVariant("lto", pinnedValue = "true")
  result.add ("pinned", @[pinnedVariant], @[
    newPackage("app", ["1.0.0"], [newDependency("core", ">=2.0.0"),
      newDependency("util", ">=0.1.0")], [pinnedVariant]),
    newPinnedPackage("core", "2.4.0", [newDependency("util", "<1.0.0")]),
    newPackage("util", ["0.1.0", "0.5.0", "1.0.0"])])
  result.add ("instances", none, @[
    newPackage("host-tool", ["1.0.0"], [newDependency("zlib-host",
      ">=1.2.0")]),
    newPackage("target-lib", ["1.0.0"], [newDependency("zlib-target",
      ">=1.3.0")]),
    newInstance("zlib-host", "zlib", ["1.2.11", "1.3.1"]),
    newInstance("zlib-target", "zlib", ["1.2.11", "1.3.1"])])

proc programs(variants: seq[VariantDecl];
              packages: seq[PackageDecl]): seq[(string, string)] =
  for pref in VersionPreference:
    result.add ($pref, encodeUnified(variants, packages, pref))
  result.add ("assumptions", encodeWithAssumptions(variants, packages)[0])

const Recorded = {
  # Recorded with -d:printProgramHashes at reprobuild 8c92d3530e, the
  # encoder before NPC-M6.
  "chain/none": "eccfac8d046133725c4d4252702c3dbadb758f6f1a71cadea9255b22258e40aa",
  "chain/lowest": "a632a1ce74a9a4f3e1abb3d6f7f82e726dba64226e9a1141406a575941c695eb",
  "chain/highest": "89c6408e9bc622b0cb962e572854018b5ddf74d0612646228882db536361e837",
  "chain/lowest-direct": "13e2610f60d6377673601bf155500c74c948d5afb5408833ebfc9873543a9008",
  "chain/assumptions": "b477f6f9ba76a4a91923dc316e466d6ddcb0368c2c73a6d370df719454311ed8",
  "unparseable-and-undeclared/none": "3e3635d798fdc138c48dcb991201351b88f157df37cf83f3e7afa415e5223e6f",
  "unparseable-and-undeclared/lowest": "22ca24fa2c3f865966b4ec2aa39fc9fd22773b8e117803019f0ad64d78a2a5d4",
  "unparseable-and-undeclared/highest": "8837b484f28644df7ee3e1a1bdee59c500bee37a4c1426b01312b2ed3d5e148a",
  "unparseable-and-undeclared/lowest-direct": "44207aad5928f778f31375097df6c08892ec1d82c0d49becbacc77fd5a38c1ff",
  "unparseable-and-undeclared/assumptions": "c8d69981d92ee2ea921a0c1b6566cc1ba05c114278b7d15f9f3c36f1dba8facd",
  "variant-gated/none": "93875d0bc63f2e8bc664a8114d034271e213a544ce4896319c45598564ac84a0",
  "variant-gated/lowest": "445e5125a56355c2a59aae19a529826a7cf103aab5e3728800ba01761ff4cc3c",
  "variant-gated/highest": "11e175c1c95e6c4d32562ec4ca096e7649f4a74818b0fbec06a4ca21ed1b5171",
  "variant-gated/lowest-direct": "1733108a990772bfff61c377b954a9af0e0e16f198ace3552b1c3298bc675d56",
  "variant-gated/assumptions": "a102d25a15e8902d9bc2abf4d7155bce7a4b14e0b6f85feee25216008877dd57",
  "pinned/none": "28dd7dd86fca29be13ec92b6befc1e5ae128c329e9872eb6eb52b12de907b458",
  "pinned/lowest": "efe8b514eb90dedee2257b7b5792eea0e2f1a4485642b735d4dab9ec039d6c97",
  "pinned/highest": "0cbb107ec1c8549e64552f147ca13e859d374788eed70196224dd680091f4734",
  "pinned/lowest-direct": "3395ca065892dd83fa2f2aa57cd65cf8f4052cde7f91c38d3442b4b843c83f7a",
  "pinned/assumptions": "7bafd9f3cda1aad9be79b36c95ddad846f282e6971c1b490f278c6792c4fb6e2",
  "instances/none": "65df692a61c482fd1624766c58fccbacc75cf42dabdf49240c3f7defa55f3a25",
  "instances/lowest": "ccdb2d892e5cb72a875d78f01a0d538fa013a5bf100d8b85a4f1f50ae4c8aae4",
  "instances/highest": "cdde4229888244ca00a407eb11611b1cadfd387115c46883d94363c5d71b94d2",
  "instances/lowest-direct": "2a4735af3b3bf9a1235606c8ab7fce03aff22468a770bfd431ef622ae92a4b21",
  "instances/assumptions": "9a26cecc4ec670ad57f8954d61de261d5947701e44552f3cefd0b73983943dee"}.toTable

when defined(printProgramHashes):
  for (name, variants, packages) in corpus():
    for (kind, text) in programs(variants, packages):
      echo "  \"", name, "/", kind, "\": \"", digest(text), "\","
else:
  suite "version_encoder: existing declaration sets encode as before (NPC-M6)":
    test "every corpus program hashes as recorded before NPC-M6":
      var compared = 0
      for (name, variants, packages) in corpus():
        for (kind, text) in programs(variants, packages):
          let key = name & "/" & kind
          checkpoint key
          check key in Recorded
          check digest(text) == Recorded.getOrDefault(key)
          inc compared
      check compared == Recorded.len

    test "the corpus does not use the NPC-M6 fields":
      # Otherwise the comparison above would not be about the old shape.
      for (name, variants, packages) in corpus():
        for p in packages:
          checkpoint name & ": " & p.name
          check p.versionDepends.len == 0
          check not p.onDemand
          check not p.preferNewest
