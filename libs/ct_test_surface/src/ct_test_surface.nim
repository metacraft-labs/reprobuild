## ``ct_test_surface`` — locate and read CodeTracer's canonical ``ct test``
## catalog/provider surface.
##
## What this is for
## ----------------
## Reprobuild has one long-standing way of asking "what cases does this
## repository contain, and what is each one called": it runs a compiled test
## binary with ``--list-json`` and reads the catalog the binary itself emits.
## That is a *Reprobuild-side* consumption of a *compiler-side* protocol, and
## it works, but it is not the surface CodeTracer publishes.
##
## The published surface is ``ct test`` — ``ct-test test discover`` /
## ``ct-test test run`` — driven by CodeTracer's provider registry. This module
## is how Reprobuild reads that surface. It deliberately does **not** wrap the
## Reprobuild runner: everything here goes through the ``ct test`` binary and
## parses the ``DiscoverResponse`` document that binary prints, so a caller
## that succeeds against this module has demonstrably reached the canonical
## boundary and not a local substitute for it.
##
## Two lookups, and why they are separate
## --------------------------------------
## There is already a runner lookup in this repository — ``CT_TEST_RUNNER``,
## then ``ct-test-runner`` on ``PATH``, then ``build/bin/repro_test_runner``
## (``scripts/run_tests.sh`` and ``locateCtTestRunner`` in
## ``libs/repro_cli_support``). ``locateCtTestSurface`` below is NOT that
## lookup and must not be merged into it, because the two resolve different
## contracts:
##
## * the runner lookup wants a program handed a directory of *already
##   compiled* test binaries, which it executes: ``--bin-dir=…
##   --summary-json=… --results-dir=…``. Do not read more precision into that
##   than is there — the two branches of the lookup disagree about the verb.
##   ``scripts/run_tests.sh`` passes ``run`` to a resolved ``ct-test-runner``
##   and passes *no verb* to the ``repro_test_runner`` fallback, which is the
##   branch actually taken here and which rejects ``run`` outright
##   ("unexpected positional: run");
## * this lookup wants ``<bin> test discover --workspace <root> [--file <f>]
##   --json``, i.e. a program that is handed a *source tree* and enumerates it
##   through providers.
##
## The load-bearing difference is the **input model**, not the spelling: one is
## given a directory of compiled binaries and the other a source tree, so there
## is no argv translation between them. (CodeTracer's Nim provider also
## declares it cannot run a project, a file or a single case, so a ``ct-test``
## put in the runner's place would execute nothing even if the arguments were
## made to fit.) Keeping the two lookups apart is what stops "Reprobuild
## consumes the canonical surface" from being asserted by a rename.
##
## The identity mapping
## --------------------
## A case has two names in this workspace and they have to be reconciled:
##
## * the *binary's* name — ``suite`` and ``name`` from the codetracer-nim
##   ``--list-json`` catalog, joined by the runner into a ``run_name``;
## * the *catalog's* name — ``TestItem.id`` from ``ct test discover``, built by
##   CodeTracer's ``makeTestItemId`` as
##   ``<provider>/<language>/<framework>/<file>::<selector>``.
##
## ``ctTestItemIdFor`` below constructs the second from the first. It is
## written here, once, rather than in each caller, because it *is* the claim
## being made: "the case the binary calls ``Suite::Case`` in file ``F`` is
## addressable through the canonical surface under exactly this identity". A
## caller compares sets of these strings; nothing infers a match by position,
## by count, or by fuzzy name.
##
## Ambient execution: this module is a *PATH-only bootstrap* consumer, in the
## sense Package-Model.md §"Executables, Libraries, And Package Collections"
## gives that term (class 2). It resolves a binary from ``PATH`` with
## provisioning deliberately disabled — that is the whole job; the surface is
## a tool the developer's shell provides — and it therefore records what class
## 2 requires: the **search path** it resolved against, the **resolved
## executable path**, and **which lookup step** produced it, all on
## ``CtTestSurface`` and all carried into the evidence artifact. It is on
## ``scripts/ambient-execution-baseline.txt`` for that reason and no other. It
## runs no build action, spawns nothing from the store, and has no second
## caller: if this file ever grows one, the class-2 record has to grow with it.
##
## No mocks. Every proc here shells out to a real ``ct test`` binary and parses
## its real output; there is no in-process stand-in for the surface, because a
## stand-in would be the thing under test.

import std/[json, options, os, osproc, sequtils, streams, strutils]

const
  CtTestSurfaceEnvVar* = "CT_TEST"
    ## Explicit override: an absolute or relative path to a binary that
    ## implements ``test discover`` / ``test run``. Checked first so a
    ## reviewer can point this module at a specific build (for example one
    ## built from the pinned ``codetracer-src`` revision rather than from a
    ## sibling checkout) without touching ``PATH``.

  CtTestSurfaceCandidates* = ["ct-test", "ct"]
    ## ``PATH`` names, in order. ``ct-test`` is the standalone driver the dev
    ## shell installs (``ctTestTools`` in ``flake.nix``); ``ct`` is
    ## CodeTracer's main binary, which routes ``ct test …`` to the same entry
    ## point. ``ct`` is second and not first for a reason worth knowing: it is
    ## built ``--mm:refc`` for the rest of CodeTracer's sake, and its own
    ## ``test run`` branch refuses on that build, so it is a discovery-capable
    ## surface and not a run-capable one.

  CtTestNimUnittestProviderId* = "nim-unittest"
  CtTestNimLanguage* = "nim"
  CtTestNimUnittestFramework* = "std/unittest"

type
  CtTestSurfaceOrigin* = enum
    ## Which lookup step produced the binary. Recorded rather than discarded
    ## so evidence can say *where the surface came from* — a measurement
    ## against a ``ct-test`` picked up from an ambient ``PATH`` is a different
    ## fact from one against a binary named explicitly.
    ctsoEnvironment      ## resolved from ``$CT_TEST``
    ctsoPathCtTest       ## found on ``PATH`` as ``ct-test``
    ctsoPathCt           ## found on ``PATH`` as ``ct``

  CtTestSurface* = object
    binary*: string             ## the resolved executable path
    origin*: CtTestSurfaceOrigin
    searchPath*: string
      ## The ``PATH`` this resolution ran against, captured at resolution time.
      ##
      ## Kept because a class-2 (PATH-only) resolution that records only its
      ## answer cannot be re-checked: "``ct-test`` was found" is not a fact
      ## anyone can reproduce without knowing where it was looked for. Empty
      ## when ``$CT_TEST`` decided the answer, because then no search happened
      ## and recording a path would imply one did.

  CtTestDiscoverOutcome* = object
    ## One ``test discover`` invocation, kept whole.
    ##
    ## ``exitCode``, ``stdout`` and the parsed document are all retained
    ## because they are three separate channels and a consumer that keeps only
    ## one of them cannot detect the case where they disagree — which is the
    ## failure this repository has already paid for twice on the binary-side
    ## protocol (a catalog parsed out of a stream that also carried the
    ## child's log lines).
    command*: seq[string]
    exitCode*: int
    rawStdout*: string
    rawStderr*: string
    document*: JsonNode        ## ``nil`` when stdout carried no JSON document
    parseError*: string

  CtTestCatalogItem* = object
    id*: string
    providerId*: string
    language*: string
    framework*: string
    name*: string
    kind*: string
    file*: string
    selector*: string
    startLine*: int
    startColumn*: int

  CtTestCatalogCounts* = object
    ## Machine-readable counts over one discover response.
    ##
    ## ``caseItems`` + ``suiteItems`` + ``otherItems`` == ``items`` by
    ## construction. ``otherItems`` exists so a ``kind`` this code does not
    ## recognise is COUNTED rather than folded into one of the other two: a
    ## new item kind arriving from the provider must show up as an unexplained
    ## number, not silently inflate the case total.
    catalogs*: int
    items*: int
    caseItems*: int          ## items whose ``kind`` is ``case``
    suiteItems*: int         ## items whose ``kind`` is ``suite``
    otherItems*: int         ## every other ``kind``, counted and not merged
    errorDiagnostics*: int
    warningDiagnostics*: int
    otherDiagnostics*: int

proc lookupOrderDescription*(): string =
  ## The lookup order, as one line, for a diagnostic that has to tell an
  ## operator what was tried. Derived from the constants rather than
  ## hand-written, so it cannot drift away from the code below.
  "$" & CtTestSurfaceEnvVar & ", then " &
    CtTestSurfaceCandidates.mapIt("`" & it & "` on PATH").join(", then ")

proc locateCtTestSurface*(): Option[CtTestSurface] =
  ## Resolve the canonical ``ct test`` surface, or ``none``.
  ##
  ## Returns ``none`` rather than raising: the caller is the one that knows
  ## whether an absent surface is a hard failure (inside the suite, where the
  ## dev shell is contractually present) or a reportable condition (a
  ## standalone invocation on a bare host). Every caller in this repository is
  ## required to say which, out loud — a silent skip here would reproduce
  ## exactly the "healthy-looking summary over a surface nobody reached"
  ## failure this module exists to make impossible.
  let fromEnv = getEnv(CtTestSurfaceEnvVar)
  if fromEnv.len > 0 and fileExists(fromEnv):
    return some(CtTestSurface(binary: absolutePath(fromEnv),
                              origin: ctsoEnvironment))
  let searchPath = getEnv("PATH")
  for idx, candidate in CtTestSurfaceCandidates:
    let found = findExe(candidate)
    if found.len > 0:
      return some(CtTestSurface(
        binary: found,
        origin: if idx == 0: ctsoPathCtTest else: ctsoPathCt,
        searchPath: searchPath))
  none(CtTestSurface)

proc extractJsonDocument(stream: string): (JsonNode, string) =
  ## Pull the ``DiscoverResponse`` object out of a stream that may also carry
  ## unrelated lines.
  ##
  ## The document is pretty-printed and starts at column 0, so the first line
  ## that is exactly ``{`` opens it and the first later line that is exactly
  ## ``}`` closes it. Anything outside that range is left alone. This is the
  ## same defensive shape the binary-side probe in
  ## ``scripts/reprobuild_suite_inventory.py`` uses, and for the same reason:
  ## a parser that assumes it owns the whole stream turns one stray log line
  ## into "this surface reported nothing", which is indistinguishable from an
  ## empty catalog.
  var
    startIdx = -1
    endIdx = -1
  let lines = stream.splitLines
  for i, line in lines:
    if startIdx < 0:
      if line == "{":
        startIdx = i
    elif line == "}":
      endIdx = i
      break
  if startIdx < 0 or endIdx < 0:
    return (nil, "no pretty-printed JSON object found on stdout")
  let body = lines[startIdx .. endIdx].join("\n")
  try:
    (parseJson(body), "")
  except CatchableError as err:
    (nil, "could not decode the JSON object on stdout: " & err.msg)

proc runDiscover(surface: CtTestSurface;
                 args: seq[string]): CtTestDiscoverOutcome =
  ## Spawn ``<binary> test discover <args…>`` and keep all three channels.
  let argv = @["test", "discover"] & args
  result.command = @[surface.binary] & argv
  let process = startProcess(surface.binary, args = argv,
                             options = {poStdErrToStdOut})
  defer: process.close()
  var
    collected = ""
    line = newStringOfCap(200)
  let outp = process.outputStream
  while true:
    if outp.readLine(line):
      collected.add(line)
      collected.add("\n")
    else:
      let code = process.peekExitCode()
      if code != -1:
        result.exitCode = code
        break
  result.rawStdout = collected
  # ``poStdErrToStdOut`` merges the channels deliberately: CodeTracer's
  # discover prints its diagnostics INTO the response document, so the only
  # thing that reaches stderr is a crash, and losing that would turn a crashed
  # surface into an empty catalog.
  result.rawStderr = ""
  let (document, parseError) = extractJsonDocument(collected)
  result.document = document
  result.parseError = parseError

proc discoverFile*(surface: CtTestSurface;
                   workspaceRoot, file: string): CtTestDiscoverOutcome =
  ## ``ct-test test discover --workspace <root> --file <f> --json``.
  runDiscover(surface, @["--workspace", workspaceRoot, "--file", file,
                         "--json"])

proc discoverWorkspace*(surface: CtTestSurface;
                        workspaceRoot: string;
                        scope = ""): CtTestDiscoverOutcome =
  ## ``ct-test test discover --workspace <root> --json [--scope <s>]``.
  ##
  ## ``scope`` is passed through rather than defaulted here. The surface's own
  ## default is ``auto``, which restricts discovery to the workspace's VCS
  ## inventory; ``unscoped`` includes vendored trees. Choosing on the caller's
  ## behalf would silently decide whether ``references/`` counts as part of
  ## this repository's suite, which is a question about the measurement and
  ## not about the plumbing.
  var args = @["--workspace", workspaceRoot, "--json"]
  if scope.len > 0:
    args.add(@["--scope", scope])
  runDiscover(surface, args)

proc catalogItems*(outcome: CtTestDiscoverOutcome): seq[CtTestCatalogItem] =
  ## Every item from every catalog in the response, flattened.
  result = @[]
  if outcome.document == nil or outcome.document.kind != JObject:
    return
  for catalog in outcome.document{"catalogs"}:
    let provider = catalog{"provider"}
    for item in catalog{"items"}:
      result.add(CtTestCatalogItem(
        id: item{"id"}.getStr(),
        providerId:
          if item{"providerId"}.isNil: provider{"id"}.getStr()
          else: item{"providerId"}.getStr(),
        language: item{"language"}.getStr(),
        framework: item{"framework"}.getStr(),
        name: item{"name"}.getStr(),
        kind: item{"kind"}.getStr(),
        file: item{"file"}.getStr(),
        selector: item{"selector"}.getStr(),
        startLine: item{"range"}{"startLine"}.getInt(),
        startColumn: item{"range"}{"startColumn"}.getInt()))

proc counts*(outcome: CtTestDiscoverOutcome): CtTestCatalogCounts =
  ## Machine-readable counts over one discover response.
  ##
  ## Diagnostics are counted by severity and NOT folded into the item totals.
  ## A response carrying 40 items and one error is not the same fact as one
  ## carrying 40 items and none, and a count that cannot tell them apart is
  ## exactly the kind of report that has to be un-believed later.
  if outcome.document == nil or outcome.document.kind != JObject:
    return

  proc countDiagnostic(counts: var CtTestCatalogCounts; node: JsonNode) =
    case node{"severity"}.getStr()
    of "error": inc counts.errorDiagnostics
    of "warning": inc counts.warningDiagnostics
    else: inc counts.otherDiagnostics

  for catalog in outcome.document{"catalogs"}:
    inc result.catalogs
    for item in catalog{"items"}:
      inc result.items
      case item{"kind"}.getStr()
      of "case": inc result.caseItems
      of "suite": inc result.suiteItems
      else: inc result.otherItems
    for diagnostic in catalog{"diagnostics"}:
      countDiagnostic(result, diagnostic)
  for diagnostic in outcome.document{"diagnostics"}:
    countDiagnostic(result, diagnostic)

proc normalizeIdComponent*(raw: string): string =
  ## Mirror of CodeTracer's ``contracts.normalizeIdComponent``.
  ##
  ## Reproduced here rather than imported because this repository does not
  ## link CodeTracer's sources; the tests that use it compare the result
  ## against ids from a real ``ct test`` document, so a drift between the two
  ## shows up as a failing assertion rather than as a silent mismatch.
  ##
  ## **This is a slug, and a slug is not injective.** Case is folded, runs of
  ## whitespace become single hyphens, and ``--`` collapses. Two cases whose
  ## titles differ only in those respects therefore receive the *same*
  ## identity. That is a property of the canonical surface, not of this
  ## reproduction of it, and a consumer that treats the id as a primary key
  ## has to say what it does about collisions rather than assume there are
  ## none.
  result = raw.strip().toLowerAscii()
  result = result.replace("\\", "/")
  result = result.replace(" ", "-")
  result = result.replace("\t", "-")
  while "--" in result:
    result = result.replace("--", "-")

proc ctTestSelectorFor*(suite, name: string): string =
  ## The ``selector`` CodeTracer's Nim provider gives a case.
  ##
  ## A case declared outside any ``suite`` gets ``::name`` — the leading empty
  ## component is not an accident of joining, it is how the provider spells
  ## "no enclosing suite", and reproducing it exactly is the difference
  ## between matching and not matching.
  if suite.len == 0: "::" & name
  else: suite & "::" & name

proc ctTestItemIdFor*(relativeFile, suite, name: string): string =
  ## The canonical ``TestItem.id`` for a case the binary catalog calls
  ## ``suite`` / ``name`` in ``relativeFile`` (repo-relative, ``/``-separated).
  [normalizeIdComponent(CtTestNimUnittestProviderId),
   normalizeIdComponent(CtTestNimLanguage),
   normalizeIdComponent(CtTestNimUnittestFramework),
   normalizeIdComponent(relativeFile)].join("/") & "::" &
    normalizeIdComponent(ctTestSelectorFor(suite, name))
