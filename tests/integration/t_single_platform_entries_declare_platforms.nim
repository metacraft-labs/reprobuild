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
## Declaring gcc `platforms [windows]` would make it unavailable on Linux
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
## durability the milestone wanted: every single-OS entry is decided — either
## its package declares ``platforms:``, or it is recorded in
## ``PartialCatalogCoverage`` with a reason. A NEW single-OS entry is neither
## and fails here until a human decides which. That is the drift protection,
## without a guess that breaks builds.
##
## GM4b: the harvested catalogs are gone; their records are ``tarball``
## realizations of the packages, and the four genuinely Windows-only entries
## (wix3, innounp, lessmsi, sevenzip) declare ``platforms [windows]`` on the
## package itself. The survey now covers the ``tarball`` realizations of EVERY
## package the engine links (``package_registry``) — the set a home profile
## resolves against — not just the former catalog registry, so a single-OS
## package that never had a catalog is held to the same rule.
##
## Falsifiable: delete the ``platforms [windows]`` line of ``wix3.nim`` and the
## Windows-only block and the lint both fail; delete a ``PartialCatalogCoverage``
## row and the lint fails naming that package.

import std/[options, sets, strutils, unittest]

import repro_dsl_stdlib/packages_schema
import repro_dsl_stdlib/package_registry
import repro_home_apply/package_catalog

proc singleOsTools(): seq[tuple[name: string; os: PlatformOs]] =
  ## Every linked package whose ``tarball`` realizations name exactly one
  ## concrete OS (an ``any``-OS realization covers every OS and excludes the
  ## package from the survey).
  for name in linkedPackageNames():
    let records = profileToolUse(name).useDef.tarballProvisioning
    if records.len == 0:
      continue
    var oses = initHashSet[PlatformOs]()
    for r in records:
      let os = parsePlatformOsToken(r.os)
      check os.ok
      oses.incl(os.os)
    if oses.len != 1 or poAny in oses:
      continue
    for o in oses:
      result.add((name: name, os: o))

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
    # The failure path is the product here. Somebody hits this having just
    # added a package and knowing nothing about this campaign, so the message
    # has to be actionable on its own: which file, both snippets ready to
    # paste, the test that decides between them, and what each wrong choice
    # costs. `platformDeclarationGuidance` lives next to the tables so it stays
    # correct when they move, and so any other surface asking the same question
    # gets identical wording rather than a drifting second copy.
    var unaccounted: seq[tuple[name: string; os: string]] = @[]
    for entry in singleOsTools():
      if packageAvailability(entry.name).declared or
          isPartiallyCovered(entry.name):
        continue
      unaccounted.add((name: entry.name, os: $entry.os))
    for entry in unaccounted:
      checkpoint platformDeclarationGuidance(entry.name, entry.os)
    if unaccounted.len > 0:
      var names: seq[string] = @[]
      for e in unaccounted: names.add(e.name & " (" & e.os & ")")
      checkpoint "undecided single-OS entries: " & names.join(", ")
    check unaccounted.len == 0

  test "the guidance names the file, both lists, and the safe default":
    # Pin the remediation itself. A diagnostic nobody asserts on is a
    # diagnostic that rots -- and this one is the entire value of the lint,
    # since the lint's job is to stop a human and tell them what to do.
    let g = platformDeclarationGuidance("demo-tool", "windows")
    check "demo-tool" in g
    check PlatformDeclarationSourceFile in g
    # Option (a) is now a `platforms` line on the package itself.
    check "platforms [windows]" in g
    check "PartialCatalogCoverage" in g
    # The asymmetry is the part a reader most needs and is most likely to skip.
    check "IF YOU ARE UNSURE, CHOOSE (b)" in g
    check "HOW TO DECIDE" in g
    # It must say what the WRONG choice costs, not just what to type.
    check "UNAVAILABLE" in g

  test "no entry is both declared and excused":
    # The two decisions mean opposite things. A package both declared
    # platform-bound and recorded as existing elsewhere is self-contradictory,
    # and whichever one a reader trusted would be wrong.
    var checked = 0
    for pair in PartialCatalogCoverage:
      inc checked
      checkpoint "package: " & pair[0]
      check not packageAvailability(pair[0]).declared
    check checked > 0

  test "the genuinely Windows-only entries resolve as declared":
    # GM4b: 7-Zip's canonical definition is ``package sevenzip`` (the package
    # macro cannot declare a name starting with a digit).
    for name in ["wix3", "innounp", "lessmsi", "sevenzip"]:
      let avail = packageAvailability(name)
      checkpoint "package: " & name
      check avail.declared
      check avail.platforms.len == 1
      check avail.platforms[0].os == poWindows
      # A declaration without a reason is a declaration nobody can audit.
      check avail.message.len > 0

  test "chocolatey keeps its DSL declaration":
    # chocolatey declares `platforms:` in a real `package` block, with its
    # own author message.
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
