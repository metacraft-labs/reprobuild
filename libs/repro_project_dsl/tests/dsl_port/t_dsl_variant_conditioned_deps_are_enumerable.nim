## Every arm of a variant-conditioned dependency is statically enumerable.
##
## Configurable-System §"`uses:` Resolution Driven by Variants" promises that
## the arms of a variant-conditioned dependency block can be read from the
## recipe source, so one metadata-fetch wave covers every arm and the solver
## sees each entry with the ONE (variant, value) gate that selects it
## (Core-Invariants §"Static Metadata Is The Hot Path"). Inside a `uses:` /
## `buildDeps:` / `nativeBuildDeps:` / `runtimeDeps:` block a variant may
## therefore condition entries only through
##
##   * `if <boolVariant>.value:` (or bare `if <boolVariant>:`) with an
##     optional single `else:` -- gates `true` / `false`;
##   * `case <variant>.value:` (or bare `case <variant>:`) whose `of` arms
##     each carry exactly ONE literal label (string, integer, `true` /
##     `false`), with no `else:` arm;
##
## and a variant `if` / `case` may not be nested inside another variant arm,
## because an entry carries at most one gate. `when` stays a compile-time
## branch on compile-time facts, so a `when` over a variant's `.value`, and
## an entry computed from one, do not compile: the dependency block is
## evaluated by the compiler, where a variant is not a value at all.
##
## Issue: reprobuild-pm/issues/2026-11-12-every-arm-is-statically-enumerable-
## but-the-canonical-example-computes-its-uses.md
##
## WHAT THE PREDECESSOR DID. `lowerUsesBody` (macros_a.nim) recognised the two
## admissible shapes and lowered EVERY OTHER `if` / `case` shape with the outer
## gate -- usually none -- so the entries it held became UNCONDITIONAL
## dependencies, silently:
##
##   1. an `if` whose condition is not a bare selector (`sslBackend.value ==
##      "openssl"`, `not v.value`, an `elif` chain): both arms always active;
##   2. a `case` `else:` arm: active even when an `of` arm matches;
##   3. an `of` arm with several labels or a non-literal label: unconditional;
##   4. a `case` whose selector is not a variant selector: every arm
##      unconditional;
##   5. a variant `if` / `case` inside another variant arm: the inner arms
##      took the outer gate, so the inner condition vanished;
##   6. a membership gate on a multi-valued variant (`"gnome" in
##      desktopKind.value`): unconditional. The spec admits it in design, but
##      the solver does not implement multi-valued variants, so it is refused
##      with its own diagnostic until it does.
##
## Each refused shape is compiled by the real compiler on a real file and the
## diagnostic is asserted on. Should one compile (the predecessor's
## behaviour), the probe re-compiles it with a dump of the gates it lowered to
## and attaches that to the failure, so a red run shows not just "it
## compiled" but which entries came out ungated.
##
## WHY OUT-OF-PROCESS. `compiles((block: package ...))` is false for every
## `package` block, well-formed or not; see `service_block_compile_probe.nim`.
##
## Test-double policy: NO mocks, doubles or fakes. The compiler is the real
## `nim` this repo is built with; the admissible forms are checked in-process
## against the `PackageUseDef` rows the real macro registers.

import std/[os, osproc, strutils, unittest]

import repro_project_dsl

import ./service_block_compile_probe

# ---------------------------------------------------------------------------
# The refused shapes, compiled out of process.
# ---------------------------------------------------------------------------

const
  BodyNeedle = "    \"always-tool\"\n"
    ## The `uses:` line every probe replaces with its own block body.

  WellFormed = """import repro_project_dsl

package enumProbePkg:
  config:
    enableTLS: variant bool = true
    enableLTO: variant bool = false
    sslBackend: variant string = "openssl"
    compiler: variant string = "gcc"
    desktopKind: variant seq[string] = @["gnome"]
  uses:
    "always-tool"
  build:
    discard

when defined(enumProbeDump):
  for pkg in registeredPackages():
    for use in pkg.toolUses:
      echo "GATE ", use.rawConstraint, " [", use.gateVariant, "=",
        use.gateValue, "]"
"""

  Enumerable = "every arm of a variant-conditioned dependency must be " &
    "statically enumerable"
    ## The sentence every refusal carries.
  Remedy = @[
    "`case <variant>.value:` with exactly one literal label per `of` arm " &
      "and no `else:` arm",
    "`if <boolVariant>.value:` with an optional `else:`",
    "`when`"]
    ## The admissible forms the refusal must offer.

type
  Probe = object
    tag: string
    body: string
      ## Replaces `BodyNeedle`; indented for the `uses:` block.
    mentions: seq[string]
      ## Fragments the diagnostic must contain besides the shared ones.
    generic: bool
      ## Carries the shared `Enumerable` sentence and `Remedy`.

const Probes = @[
  # ---- shape 1: an `if` whose condition is not a bare selector ----
  Probe(tag: "if-comparison", generic: true,
    body: "    if sslBackend.value == \"openssl\":\n" &
          "      \"openssl >=3\"\n" &
          "    else:\n" &
          "      \"libressl >=4\"\n",
    mentions: @["`if sslBackend.value == \"openssl\"`",
                "not a bare `<variant>.value`"]),
  Probe(tag: "if-negation", generic: true,
    body: "    if not enableTLS.value:\n" &
          "      \"plaintext-shim\"\n",
    mentions: @["`if not enableTLS.value`"]),
  Probe(tag: "if-elif-chain", generic: true,
    body: "    if enableTLS.value:\n" &
          "      \"openssl >=3\"\n" &
          "    elif enableLTO.value:\n" &
          "      \"lld >=15\"\n",
    mentions: @["`elif enableLTO.value`"]),
  # ---- shape 2: a `case` with an `else:` arm ----
  Probe(tag: "case-else", generic: true,
    body: "    case compiler.value:\n" &
          "    of \"gcc\": \"gcc >=12\"\n" &
          "    else: \"clang >=16\"\n",
    mentions: @["`else:` arm of `case compiler.value`"]),
  # ---- shape 3: an `of` arm with several labels / a non-literal label ----
  Probe(tag: "case-multi-label", generic: true,
    body: "    case compiler.value:\n" &
          "    of \"gcc\", \"cc\": \"gcc >=12\"\n" &
          "    of \"clang\": \"clang >=16\"\n",
    mentions: @["`of \"gcc\", \"cc\"`", "case compiler.value",
                "2 labels"]),
  Probe(tag: "case-non-literal-label", generic: true,
    body: "    case compiler.value:\n" &
          "    of DefaultCompiler: \"gcc >=12\"\n",
    mentions: @["`of DefaultCompiler`", "not a literal"]),
  # ---- shape 4: a `case` whose selector is not a variant selector ----
  Probe(tag: "case-non-selector", generic: true,
    body: "    case compiler.value.toLowerAscii:\n" &
          "    of \"gcc\": \"gcc >=12\"\n",
    mentions: @["`case compiler.value.toLowerAscii`",
                "not a bare `<variant>.value`"]),
  # ---- shape 5: a variant gate nested inside another variant arm ----
  Probe(tag: "nested-if-in-case", generic: true,
    body: "    case compiler.value:\n" &
          "    of \"gcc\":\n" &
          "      \"gcc >=12\"\n" &
          "      if enableLTO.value:\n" &
          "        \"lld >=15\"\n",
    mentions: @["`if enableLTO.value`", "nested inside",
                "variant `compiler`", "at most one variant gate"]),
  Probe(tag: "nested-case-in-if-through-when", generic: true,
    # Through a `when`: the `when` is the compiler's, but the entries under
    # it still carry the outer gate, so the inner gate is still a second one.
    body: "    if enableTLS.value:\n" &
          "      when true:\n" &
          "        case sslBackend.value:\n" &
          "        of \"openssl\": \"openssl >=3\"\n",
    mentions: @["`case sslBackend.value`", "nested inside",
                "variant `enableTLS`"]),
  # ---- shape 6: a membership gate on a multi-valued variant ----
  Probe(tag: "multi-valued-membership", generic: false,
    body: "    if \"gnome\" in desktopKind.value:\n" &
          "      \"gnome-de >=1.0\"\n",
    mentions: @["`if \"gnome\" in desktopKind.value`",
                "membership gate on a multi-valued variant",
                "not implemented yet"]),
  ]

proc dumpGates(source, tag: string): string =
  ## Only reached when a refused probe COMPILED: run it with the gate dump on
  ## so the failure shows what the predecessor lowered it to.
  let scratch = currentSourcePath().parentDir().parentDir().parentDir()
    .parentDir().parentDir() / "build" /
    ("enum-probe-dump-" & tag & "-" & $getCurrentProcessId())
  createDir(scratch)
  defer:
    try: removeDir(scratch)
    except CatchableError: discard
  let path = scratch / "recipe.nim"
  writeFile(path, source)
  let nim = (let f = findExe("nim"); if f.len > 0: f else: "nim")
  let (output, _) = execCmdEx(nim & " c -r --hints:off --colors:off " &
    "--warnings:off -d:enumProbeDump --nimcache:" &
    quoteShell(scratch / "nimcache") & " " & quoteShell(path))
  for line in output.splitLines():
    if line.startsWith("GATE "): result.add(line & "\n")

const CompileTimeOnly = @[
  # Not DSL diagnostics: the dependency block is a compile-time expression
  # in which a variant is not even a name (the DSL reads `<v>.value` as a
  # gate selector from the source, it never binds `<v>` there), so the
  # compiler refuses the recipe with "undeclared identifier". Asserted so
  # that a change which bound variants into the block (and so let a `when` on
  # a variant, or a package name computed from one, through) fails here.
  Probe(tag: "when-on-variant",
    body: "    when compiler.value == \"gcc\":\n" &
          "      \"gcc >=12\"\n"),
  Probe(tag: "computed-entry",
    body: "    case compiler.value:\n" &
          "    of \"gcc\": \"cross-toolchain-\" & compiler.value\n"),
  ]

suite "variant-conditioned dependencies: the refused shapes":

  test "the well-formed recipe compiles":
    # Without this every refusal below could be passing for an unrelated
    # reason, such as the `config:` block itself not compiling.
    let probe = checkRecipeSource(WellFormed, "enum-control")
    checkpoint(probe.output)
    check probe.ok

  for p in Probes:
    test "refused at compile time: " & p.tag:
      let source = WellFormed.replace(BodyNeedle, p.body)
      # A drifted needle would silently make this a second control run.
      check source != WellFormed
      let probe = checkRecipeSource(source, "enum-" & p.tag)
      if probe.ok:
        checkpoint("probe compiled clean; it lowered to:\n" &
          dumpGates(source, p.tag))
      check not probe.ok
      var fragments = p.mentions
      if p.generic:
        fragments.add(Enumerable)
        fragments.add(Remedy)
      for fragment in fragments:
        checkpoint("diagnostic is missing `" & fragment & "`:\n" &
          probe.output)
        check probe.mentions(fragment)

  for p in CompileTimeOnly:
    test "not a compile-time value: " & p.tag:
      let source = WellFormed.replace(BodyNeedle, p.body)
      check source != WellFormed
      let probe = checkRecipeSource(source, "enum-" & p.tag)
      if probe.ok:
        checkpoint("probe compiled clean; it lowered to:\n" &
          dumpGates(source, p.tag))
      check not probe.ok
      checkpoint(probe.output)
      check probe.mentions("undeclared identifier: 'compiler'")

  test "the membership refusal is told apart from the generic one":
    # A multi-valued gate IS enumerable in design; telling its author to
    # rewrite it as a `case` would be wrong advice.
    let source = WellFormed.replace(BodyNeedle,
      "    if \"gnome\" in desktopKind.value:\n      \"gnome-de >=1.0\"\n")
    let probe = checkRecipeSource(source, "enum-membership-distinct")
    check not probe.ok
    checkpoint(probe.output)
    check not probe.mentions(Enumerable)

# ---------------------------------------------------------------------------
# The admissible forms, lowered in process.
# ---------------------------------------------------------------------------

const FixtureFlag = true

package enumIfElsePkg:
  config:
    enableTLS: variant bool = true
  uses:
    "always-tool"
    if enableTLS.value:
      "openssl >=3"
    else:
      "plaintext-shim"
  build:
    discard

package enumBareIfPkg:
  config:
    bareTLS: variant bool = true
  uses:
    if bareTLS: "openssl >=3"
  build:
    discard

package enumCasePkg:
  config:
    compiler: variant string = "gcc"
    jobs: variant int = 1
    strict: variant bool = false
  uses:
    case compiler.value:
    of "gcc": "gcc >=12 <16"
    of "clang":
      "clang >=16 <19"
      "lld >=15"
    case jobs.value:
    of 4: "parallel-make"
    case strict.value:
    of true: "strict-linter"
  build:
    discard

package enumBareCasePkg:
  config:
    bareCompiler: variant string = "gcc"
  uses:
    case bareCompiler:
    of "gcc": "gcc >=12 <16"
    of "clang": "clang >=16 <19"
  build:
    discard

package enumWhenAroundAndInsidePkg:
  ## `when` keeps meaning the compiler's question in both directions: around
  ## a variant gate, and inside one (where its entries keep the gate).
  config:
    nativeTLS: variant bool = true
  nativeBuildDeps:
    when FixtureFlag:
      if nativeTLS.value:
        "openssl-native >=3"
        when not FixtureFlag:
          "unreachable-tool"
        when FixtureFlag:
          "inside-when-tool"
  build:
    discard

proc usesOf(packageName: string): seq[PackageUseDef] =
  for pkg in registeredPackages():
    if pkg.packageName == packageName:
      return pkg.toolUses & pkg.nativeBuildDeps
  @[]

proc gates(packageName: string): seq[string] =
  for entry in usesOf(packageName):
    result.add(entry.rawConstraint & " [" & entry.gateVariant & "=" &
      entry.gateValue & "]")

suite "variant-conditioned dependencies: the admissible forms":

  test "if / else gates the arms true and false":
    check gates("enumIfElsePkg") == @[
      "always-tool [=]",
      "openssl >=3 [enableTLS=true]",
      "plaintext-shim [enableTLS=false]"]

  test "a bare `if <variant>:` is the same gate":
    check gates("enumBareIfPkg") == @["openssl >=3 [bareTLS=true]"]

  test "case arms gate on their one literal: string, int and bool":
    check gates("enumCasePkg") == @[
      "gcc >=12 <16 [compiler=gcc]",
      "clang >=16 <19 [compiler=clang]",
      "lld >=15 [compiler=clang]",
      "parallel-make [jobs=4]",
      "strict-linter [strict=true]"]

  test "a bare `case <variant>:` is the same gate":
    check gates("enumBareCasePkg") == @[
      "gcc >=12 <16 [bareCompiler=gcc]",
      "clang >=16 <19 [bareCompiler=clang]"]

  test "`when` around and inside a gate stays the compiler's":
    check gates("enumWhenAroundAndInsidePkg") == @[
      "openssl-native >=3 [nativeTLS=true]",
      "inside-when-tool [nativeTLS=true]"]
