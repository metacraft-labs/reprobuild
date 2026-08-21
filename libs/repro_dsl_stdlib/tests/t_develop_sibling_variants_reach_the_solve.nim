## A develop-mode sibling's VARIANTS are solved. The other half of NLF-M2.
##
## `Named-Lock-Files.md` §10.3 records the implementation with its two halves
## inverted: a develop sibling's version was fabricated and then searched for,
## while "the develop sibling's own variants reach nothing at all, because
## `buildVariantDecls` walks only the current process's ambient
## `ConfigContext` and a sibling named in `uses:` is built with
## `newPackage(depName, versions)` — empty variants". The version half landed
## with `t_develop_dependency_source_is_read_not_solved.nim`; this is the
## variant half, and the milestone's third verification test.
##
## SOLVED, NOT RECORDED — owner decision Q-4 (2026-08-18), and the distinction
## is the whole design of this file. What the checkout contributes is the
## sibling's variant DECLARATIONS: the name, the universe, and the declared
## default. What it must NOT contribute is an assignment. Q-4's third reason
## says why: "if a checkout carried its own variant values, those values would
## have to feed back into the solve that configures its dependents — the same
## circularity §5.6 refuses for metadata fetching". A declaration is the shape
## of the question; an assignment is the answer, and the answer is the solve's
## to give. `a recorded default is a contribution, not a pin` asserts exactly
## that difference on the surface where the two are distinguishable.
##
## WHY THIS DOES NOT CREATE THE LAYERING LOOP THE MODULE HEADER WARNS ABOUT.
## `develop_sources.nim` says the solve path "deliberately does not import
## `repro_project_dsl` — its own comment says doing so would create a layering
## loop", and that `developOverridePath` is therefore unreachable from the
## solver's side. The version half resolved this by sharing the CONTRACT
## rather than the code: the same `REPRO_DEVELOP_OVERRIDES_FILE` naming the
## same JSON document the engine writes. The variant half takes the same road
## and adds no import in either direction — a `variants` array on the same
## override entry that already carries `path` and `version`. Nothing in the
## solve path learns about `repro_project_dsl`, and nothing in
## `repro_project_dsl` learns about the solver.
##
## NAMESPACED BY THE SIBLING, and this is a correctness property rather than a
## style choice. Variant identity is a flat string all the way into the ASP
## atom (`variant_assigned("name", X)`). A sibling's `enableTls` injected under
## its bare name would silently MERGE with a consumer that happens to declare
## `enableTls` too: one universe, one assignment, one `--variant` flag
## controlling both — or, when the two universes differ, an unexplained UNSAT.
## `libfoo.enableTls` is the key, and `a sibling's variant cannot collide with
## the consumer's` holds the line.
##
## PRECEDENCE. A checkout's declared default is a DEFAULT: it must lose to an
## explicit `--variant`, and it must not suppress a governing lock's pin the
## way an explicit `--variant` does. That is not a new rule invented here — it
## is NLF-M3's `lockedValueFor` (§2.5: "the lock is mode-agnostic and CLI/mode
## overrides sit above it"), applied to a variant whose declaration happens to
## have come from a sibling rather than from this process. The three
## precedence cases below pin all three edges of that lattice.
##
## Test-double policy: NO mocks, doubles, or fakes. The checkout is a real
## directory tree on the real filesystem carrying a real `VERSION` file; the
## override metadata is a real file in the real format the engine writes and
## `REPRO_DEVELOP_OVERRIDES_FILE` names; registration goes through the real
## public `registerSolverDependency` / `addVariantCliOverride` surfaces; the
## lock pins arrive through the real `REPRO_LOCK_PINS` grammar
## `repro_solver/lock_pins` defines; and the end-to-end case runs a real clingo
## solve through the real `finalizeVariants()`. Running the real solver is
## necessary for exactly one claim — that the assignment is READABLE from the
## solved graph — because nothing short of the solver produces a solved graph.
## The remaining claims are about what is HANDED to the solver and are asserted
## on the rendered input, which is also what `inputsDigest` is taken over.

import std/[algorithm, json, os, strutils, tables, tempfiles, unittest]

import repro_dsl_stdlib/configurables/variants
import repro_dsl_stdlib/configurables/api
import repro_dsl_stdlib/configurables/types
import repro_solver

const DevelopedPackage = "libfoo"
const CheckoutVersion = "2.3.1"
const TlsVariant = "libfoo.enableTls"
const ProfileVariant = "libfoo.profile"

proc makeCheckout(root: string): string =
  ## A real develop checkout carrying the `VERSION` file the source half
  ## reads. No git repository is created here: the version half already
  ## establishes that the VCS revision is deliberately NOT consulted (reading
  ## it would mean running ambient `git` from the solve path, which
  ## `Package-Model.md` forbids), so a git repository in this fixture would
  ## suggest a source of truth that does not exist.
  let path = root / DevelopedPackage
  createDir(path)
  writeFile(path / "repro.nim", "## develop-mode sibling under test\n")
  writeFile(path / "VERSION", CheckoutVersion & "\n")
  path

proc declareOverride(root, checkout: string; variants: JsonNode) =
  ## Write the override metadata in the shape the engine publishes and point
  ## `REPRO_DEVELOP_OVERRIDES_FILE` at it — the same contract the version half
  ## shares with `repro_project_dsl.developOverridePath`.
  var entry = %*{"node": DevelopedPackage, "path": checkout,
                 "state": "editable"}
  if variants != nil:
    entry["variants"] = variants
  let metadataPath = root / "develop-overrides.json"
  writeFile(metadataPath, $(%*{"overrides": [entry]}))
  putEnv("REPRO_DEVELOP_OVERRIDES_FILE", metadataPath)

proc twoVariants(): JsonNode =
  ## One bool and one enum, so both universe-emission strategies are covered
  ## and so the enum arm's `values:` list is exercised — a bool universe is
  ## hard-coded by the encoder and would hide a lost value list.
  %*[
    {"name": "enableTls", "kind": "bool", "default": "true"},
    {"name": "profile", "kind": "enum",
     "values": ["debug", "release"], "default": "release"}
  ]

proc variantBlock(fixture, name: string): string =
  ## The rendered block for `variant <name>`, up to the next blank line.
  ## Returns "" when the variant is absent.
  var collecting = false
  for line in fixture.splitLines():
    if line.startsWith("variant "):
      collecting = line.strip() == "variant " & name
      if collecting:
        result.add(line & "\n")
      continue
    if collecting:
      if line.len == 0 or line.startsWith("package "):
        return
      result.add(line & "\n")

template withScenario(variantsJson: JsonNode; body: untyped) =
  ## One temp workspace, one develop checkout, one override entry, one
  ## registered dependency. Torn down completely so no case can observe
  ## another's registry, environment or checkout.
  let scratch {.inject.} = createTempDir("repro-nlf-devvar-", "")
  let checkout {.inject.} = makeCheckout(scratch)
  declareOverride(scratch, checkout, variantsJson)
  resetVariantState()
  try:
    registerSolverDependency("appAlpha", DevelopedPackage,
                             DevelopedPackage & " >=0")
    body
  finally:
    resetVariantState()
    delEnv("REPRO_DEVELOP_OVERRIDES_FILE")
    delEnv(LockPinsEnvVar)
    delEnv(LockPathEnvVar)
    removeDir(scratch)

suite "a develop sibling's variants reach the solve":
  ## NLF-M2's third deliverable. Ref: Named-Lock-Files.md §10.3, §10.4, Q-4.

  test "the sibling's declared variants are rendered as solver input":
    withScenario(twoVariants()):
      let fixture = currentSolverInputsFixture()
      # Before this change `buildVariantDecls` walked only the ambient
      # context, and a sibling named in `uses:` contributed no variant at all.
      check ("variant " & TlsVariant) in fixture
      check ("variant " & ProfileVariant) in fixture

  test "the universes survive, bool and enum alike":
    withScenario(twoVariants()):
      let fixture = currentSolverInputsFixture()
      check "kind: bool" in variantBlock(fixture, TlsVariant)
      let profile = variantBlock(fixture, ProfileVariant)
      check "kind: enum" in profile
      # The enum universe is the declaration's, not one re-derived from the
      # contributions: a universe rebuilt from contributions alone would
      # contain only `release` and would silently make `debug` unreachable.
      check "values: debug, release" in profile

  test "a recorded default is a contribution, not a pin":
    withScenario(twoVariants()):
      let tls = variantBlock(currentSolverInputsFixture(), TlsVariant)
      # Q-4, reason 3. A pin would make the checkout's value an ASSERTED fact
      # the solve cannot revise, which is "recorded" — the half of the
      # decision that went the other way. The two are distinguishable exactly
      # here: `pinned:` versus a priority-band contribution.
      check "default: true" in tls
      check "pinned:" notin tls

  test "the encoder gives the sibling's variant a real choice rule":
    withScenario(twoVariants()):
      var decl: VariantDecl
      var found = false
      for v in currentSolverVariantDecls():
        if v.name == TlsVariant:
          decl = v
          found = true
      check found
      # The rendered text cannot tell a pinned variant from a contributed one
      # in every case, and the corpus calls that substitution out by name for
      # the package half. Assert on the real encoder instead: a solved variant
      # emits a cardinality choice, a recorded one asserts a fact.
      check ("{ variant_assigned(\"" & TlsVariant & "\"") in
        encodeCardinality(decl)

  test "a sibling's variant cannot collide with the consumer's":
    withScenario(twoVariants()):
      # The consumer declares its OWN `enableTls`, which is a different
      # variant of a different package that happens to share a spelling.
      discard variantImpl[bool](false, "enableTls", captureSite(ckDefault))
      let fixture = currentSolverInputsFixture()
      check "variant enableTls\n" in fixture
      check ("variant " & TlsVariant) in fixture
      # And they keep their own defaults: a merge would have to pick one.
      check "default: false" in variantBlock(fixture, "enableTls")
      check "default: true" in variantBlock(fixture, TlsVariant)

  test "the sibling's variants are canonically ordered with the rest":
    withScenario(twoVariants()):
      discard variantImpl[bool](false, "zzzLast", captureSite(ckDefault))
      discard variantImpl[bool](false, "aaaFirst", captureSite(ckDefault))
      var names: seq[string] = @[]
      for line in currentSolverInputsFixture().splitLines():
        if line.startsWith("variant "):
          names.add(line["variant ".len .. ^1].strip())
      # NLF-M1's rule, which this must not break: the rendering is what
      # `inputsDigest` is taken over, so a develop sibling's variants arriving
      # in override-file order would reopen exactly the defect NLF-M1 closed.
      check names == @["aaaFirst", TlsVariant, ProfileVariant,
                       "zzzLast"].sorted()

  test "a non-develop dependency contributes no variants":
    withScenario(twoVariants()):
      # The negative control. Injecting variants must apply to develop entries
      # ONLY: a registry package's configuration is not on any local disk, and
      # inventing one would be a much worse defect than the one under repair.
      registerSolverDependency("appAlpha", "zlib", "zlib >=1.2.0")
      let fixture = currentSolverInputsFixture()
      check "variant zlib." notin fixture

  test "an override recording no variants renders exactly as before":
    # The compatibility guard, and the reason NLF-STAT-4's fingerprints do not
    # move. Every override the engine writes today carries `node` and `path`
    # and nothing else, so this is the shape of every real develop build.
    let scratch = createTempDir("repro-nlf-devvar-none-", "")
    let checkout = makeCheckout(scratch)
    declareOverride(scratch, checkout, nil)
    resetVariantState()
    try:
      registerSolverDependency("appAlpha", DevelopedPackage,
                               DevelopedPackage & " >=0")
      let withOverride = currentSolverInputsFixture()
      check "variant " notin withOverride
      # And the version half still holds: no variants does not mean no pin.
      check "pinned: true" in withOverride
    finally:
      resetVariantState()
      delEnv("REPRO_DEVELOP_OVERRIDES_FILE")
      removeDir(scratch)

suite "the checkout's default sits below every explicit override":
  ## The precedence lattice, one case per edge. Consistent with NLF-M3's
  ## `lockedValueFor` by construction rather than by coincidence: the develop
  ## sibling's variants go through the same pin lookup the ambient ones do.

  test "an explicit --variant outranks the checkout's declared default":
    withScenario(twoVariants()):
      addVariantCliOverride(TlsVariant, "false")
      let tls = variantBlock(currentSolverInputsFixture(), TlsVariant)
      # Both bands present, and the CLI's is the higher one. Dropping the
      # default instead would lose the record of what the checkout declared.
      check "default: true" in tls
      check "set: false" in tls

  test "a governing lock pins the sibling's variant":
    withScenario(twoVariants()):
      putEnv(LockPinsEnvVar, "var:" & TlsVariant & "=false")
      putEnv(LockPathEnvVar, "/nonexistent/repro.lock")
      let tls = variantBlock(currentSolverInputsFixture(), TlsVariant)
      # NLF-M3's rule reaches a develop sibling's variant unchanged: a locked
      # assignment is a constraint, not a preference.
      check "pinned: false" in tls

  test "an explicit --variant still suppresses the lock's pin":
    withScenario(twoVariants()):
      putEnv(LockPinsEnvVar, "var:" & TlsVariant & "=false")
      putEnv(LockPathEnvVar, "/nonexistent/repro.lock")
      addVariantCliOverride(TlsVariant, "true")
      let tls = variantBlock(currentSolverInputsFixture(), TlsVariant)
      # §2.5: the lock is mode-agnostic and CLI overrides layer above it. A
      # develop sibling's variant must not acquire a different rule.
      check "pinned:" notin tls
      check "set: true" in tls

suite "the assignment is readable from the solved graph":
  ## The half of the milestone's verification clause that only a real solve can
  ## settle. A consumer linking a develop-mode `libfoo` has to know whether TLS
  ## was enabled in it (Q-4, reason 2), and that answer lives in the solution.

  test "the solver assigns the sibling's variant":
    withScenario(twoVariants()):
      finalizeVariants()
      check hasSolverSolution()
      let solved = lastSolverSolution()
      check TlsVariant in solved.variants
      check solved.variants[TlsVariant] == "true"
      check solved.variants[ProfileVariant] == "release"

  test "an explicit --variant changes the solved answer":
    withScenario(twoVariants()):
      addVariantCliOverride(TlsVariant, "false")
      finalizeVariants()
      let solved = lastSolverSolution()
      # The precedence assertions above are about what is handed to the
      # solver; this is the one that shows the handoff has consequences.
      check solved.variants[TlsVariant] == "false"

suite "an unreadable variant declaration is refused, not skipped":
  ## The same rule `lock_pins` states for an unknown pin entry: "an unknown
  ## entry dropped in silence is a constraint that was supposed to hold and
  ## didn't, with nothing in the output to say so". A silently skipped variant
  ## declaration is a package configured by a universe nobody declared.

  test "a variant with no name is an error":
    withScenario(%*[{"kind": "bool", "default": "true"}]):
      expect EDevelopVariantsMalformed:
        discard currentSolverInputsFixture()

  test "an unknown kind is an error":
    withScenario(%*[{"name": "enableTls", "kind": "tristate"}]):
      expect EDevelopVariantsMalformed:
        discard currentSolverInputsFixture()

  test "an enum with no values is an error":
    withScenario(%*[{"name": "profile", "kind": "enum"}]):
      expect EDevelopVariantsMalformed:
        discard currentSolverInputsFixture()

  test "the same variant declared twice is an error":
    withScenario(%*[{"name": "enableTls", "kind": "bool", "default": "true"},
                    {"name": "enableTls", "kind": "enum",
                     "values": ["a", "b"]}]):
      # Last-wins would silently pick one of two universes and there would be
      # nothing in the rendering to say the other existed.
      expect EDevelopVariantsMalformed:
        discard currentSolverInputsFixture()

  test "a default outside the declared universe is an error":
    withScenario(%*[{"name": "profile", "kind": "enum",
                     "values": ["debug"], "default": "release"}]):
      expect EDevelopVariantsMalformed:
        discard currentSolverInputsFixture()

  test "the diagnostic names the sibling and the variant":
    withScenario(%*[{"name": "profile", "kind": "tristate"}]):
      var message = ""
      try:
        discard currentSolverInputsFixture()
      except EDevelopVariantsMalformed as err:
        message = err.msg
      # A refusal that does not say WHICH sibling's declaration is unreadable
      # sends the reader through every override entry by hand.
      check DevelopedPackage in message
      check "profile" in message
      check "tristate" in message
