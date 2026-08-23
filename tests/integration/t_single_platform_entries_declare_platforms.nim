## PMC-5 — every single-OS catalog entry is a DELIBERATE decision.
##
## ## The lint the milestone asked for, and why it is not the lint it named
##
## PMC-5's acceptance text reads: "a catalog-WIDE assertion that any entry
## whose arms are all one OS declares that OS in `platforms:`. This is PMC-1's
## lint made durable — without it the stdlib drifts back one undeclared entry
## at a time, which is precisely how this gap arose."
##
## The durability goal is right. The rule as literally stated is not, and
## implementing it verbatim would have caused an outage. Measured across the
## registry, **22** entries have arms for exactly one OS — and most are not
## platform-bound at all. `gcc`, `git`, `python3`, `ruby`, `php`, `erlang`,
## `elixir`, `meson`, `autoconf`, `automake`, `libtool`, `ocaml`, `swift`,
## `dotnet-sdk` and `fpc` are single-OS in the CATALOG because only the
## Windows slices were harvested. `packages/gcc.nim` says so in its own header:
## the DSL block "remains the source of truth ... on Nix-capable hosts; the
## `gccCatalog` slice is consumed by the M64 `cakBuiltin` adapter on Windows."
##
## Declaring gcc `platforms: [windows]` would make it unavailable on Linux
## through PMC-1's gate — a far worse failure than the hole being closed.
##
## This is the same trap PMC-1 hit from the other side. It shipped
## `inferredPackagePlatforms`, which derived availability by walking a
## package's arms, then deleted it because the inference could not see
## harvested entries and so answered "available everywhere" for exactly the
## class the lint exists to catch. The lesson is not "infer from the other
## direction" — it is that **the distinction between "cannot exist there" and
## "we only harvested that platform" is not recoverable from the data.**
##
## So the lint asserts the property that IS checkable and does carry the
## durability the milestone wanted: every single-OS entry appears in exactly
## one of two hand-maintained lists — declared available, or explicitly
## recorded as partially covered with a reason. A NEW single-OS entry belongs
## to neither and fails here until a human decides which. That is the drift
## protection, without a guess that breaks builds.

import std/[options, sets, strutils, unittest]

import repro_dsl_stdlib/packages_schema
import repro_dsl_stdlib/catalog_registry

proc singleOsTools(): seq[tuple[name: string; os: PlatformOs]] =
  ## Every registered tool whose catalog arms name exactly one concrete OS.
  ## `poAny` means "everywhere" and is not single-OS.
  for tool in registeredToolSet():
    let cat = getCatalog(tool)
    if cat.isNone or cat.get.len == 0:
      continue
    var oses = initHashSet[PlatformOs]()
    var arms = 0
    for vp in cat.get:
      for pb in vp.platforms:
        inc arms
        oses.incl(pb.os)
    if arms == 0 or oses.len != 1 or poAny in oses:
      continue
    for o in oses:
      result.add((name: tool, os: o))

proc isPartiallyCovered(name: string): bool =
  for pair in PartialCatalogCoverage:
    if pair[0] == name:
      return true
  false

suite "PMC-5 — single-OS entries are declared or explicitly excused":

  test "the survey finds something (the lint is not vacuous)":
    # Without this, every assertion below passes trivially the day the
    # registry lookup breaks -- which is the classic way a catalog-wide lint
    # stops protecting anything without failing.
    check singleOsTools().len > 0

  test "every single-OS entry is declared OR recorded as partially covered":
    var unaccounted: seq[string] = @[]
    for entry in singleOsTools():
      let declared = packageAvailability(entry.name).declared
      if declared or isPartiallyCovered(entry.name):
        continue
      unaccounted.add(entry.name & " (" & $entry.os & ")")
    if unaccounted.len > 0:
      checkpoint "single-OS entries in neither list: " & unaccounted.join(", ")
      checkpoint "Decide which: add a HarvestedPlatformDeclarations entry if " &
        "the package genuinely cannot exist elsewhere, or a " &
        "PartialCatalogCoverage entry if only one platform was harvested."
    check unaccounted.len == 0

  test "no entry is in BOTH lists":
    # The two lists mean opposite things. An entry in both would be a package
    # simultaneously declared Windows-only and recorded as existing elsewhere,
    # and whichever one the resolver happened to read first would win.
    for pair in HarvestedPlatformDeclarations:
      check not isPartiallyCovered(pair[0])

  test "the genuinely Windows-only entries resolve as declared":
    for name in ["wix3", "innounp", "lessmsi", "7zip"]:
      let avail = packageAvailability(name)
      checkpoint "package: " & name
      check avail.declared
      check avail.platforms.len == 1
      check avail.platforms[0].os == poWindows
      # A declaration without a reason is a declaration nobody can audit.
      check avail.message.len > 0

  test "chocolatey keeps its DSL declaration, not the harvested fallback":
    # chocolatey declares `platforms:` in a real `package` block. If the
    # fallback ever shadowed a DSL declaration, the generated-file table would
    # start overriding hand-written source.
    let avail = packageAvailability("chocolatey")
    check avail.declared
    check avail.platforms[0].os == poWindows
    check "Windows package manager" in avail.message

  test "a partially covered entry is NOT declared available":
    # The load-bearing negative. If gcc ever became "declared windows", it
    # would stop resolving on Linux through PMC-1's gate.
    for name in ["gcc", "git", "python3"]:
      checkpoint "must remain undeclared: " & name
      check not packageAvailability(name).declared

  test "an unknown package is unaffected":
    # Everything not in either list keeps its exact pre-PMC-5 behaviour.
    check not packageAvailability("no-such-package-anywhere").declared
