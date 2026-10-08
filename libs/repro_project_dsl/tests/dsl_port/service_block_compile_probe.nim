## Compile a recipe fixture carrying a ``service <ident>:`` block and
## capture the compiler's diagnostic.
##
## Not named ``t_*`` / ``test_*``, so ``scripts/generate_test_edges.nim``
## does not register it as a test binary of its own.
##
## WHY THIS EXISTS RATHER THAN ``compiles``. The obvious spelling for a
## macro-refusal gate is ``check not compiles((block: package …))`` and
## there is an existing test in this repository written that way. It is
## vacuous, and measured so: ``compiles`` returns **false for every**
## ``package`` block placed inside a ``block:`` expression, including a
## minimal well-formed one, because the macro expands to module-level
## ``type`` / ``const`` declarations that cannot live in a block
## expression. So ``not compiles`` passes whether or not the refusal
## under test exists, and the matching positive control cannot be
## written at all.
##
## An out-of-process ``nim check`` has neither problem: the fixture is a
## real module, a well-formed one compiles, and the refusal's MESSAGE is
## readable — which matters, because the requirement is not that the
## build stops but that the author is told where configuration belongs.
##
## The shape is taken from ``libs/repro_dsl_stdlib/tests/
## lock_file_compile_probe.nim``, including the reason the fixture is
## written under the repository rather than in the system temp directory:
## Nim finds ``config.nims`` by walking up from the compiled file, and
## this repo's ``config.nims`` is what puts every ``libs/*/src`` on the
## module path.
##
## Test-double policy: NO mocks, doubles or fakes. The compiler is the
## real ``nim`` this repo is built with, invoked on a real file, and the
## text asserted on is its real output.

import std/[os, osproc, strutils]

type
  ServiceCompileProbeResult* = object
    ok*: bool
      ## True when the compile SUCCEEDED.
    output*: string
      ## stdout and stderr joined — Nim writes diagnostics to stderr and
      ## hints to stdout, and reading one would miss half of them.

proc repoRoot(): string =
  currentSourcePath().parentDir().parentDir().parentDir().parentDir()
    .parentDir()

proc nimExe(): string =
  let found = findExe("nim")
  if found.len > 0: found else: "nim"

proc checkRecipeSource*(source: string; tag: string):
    ServiceCompileProbeResult =
  ## Write ``source`` as a recipe under the repo's ``build/`` scratch and
  ## run ``nim check`` on it.
  ##
  ## ``nim check`` rather than ``nim c``: the properties under test are
  ## macro-expansion-time and overload-resolution-time errors, which
  ## ``check`` reaches, and skipping code generation keeps the probe fast
  ## enough to run several per test.
  let scratch = repoRoot() / "build" /
    ("service-block-probe-" & tag & "-" & $getCurrentProcessId())
  createDir(scratch)
  defer:
    try: removeDir(scratch)
    except CatchableError: discard
  let path = scratch / "recipe.nim"
  writeFile(path, source)
  let (output, exitCode) = execCmdEx(
    nimExe() & " check --hints:off --colors:off -d:reproProviderMode " &
      quoteShell(path),
    workingDir = repoRoot())
  ServiceCompileProbeResult(ok: exitCode == 0, output: output)

proc mentions*(probe: ServiceCompileProbeResult; text: string): bool =
  probe.output.contains(text)

proc checkConsumerWithProducer*(producerSelector, producerSource,
                                consumerSource, tag: string):
    ServiceCompileProbeResult =
  ## Shared-Development-Services L3: write a PRODUCER project and a
  ## CONSUMER recipe as workspace siblings and run ``nim check`` on the
  ## consumer.
  ##
  ## The layout is dictated by ``workspaceProducerLocation``
  ## (``macros_a.nim``), which the ``uses:`` import path walks up from the
  ## consumer's own source file looking for ``<ancestor>/<selector>/
  ## repro.nim``::
  ##
  ##   build/l3-consumer-probe-<tag>-<pid>/
  ##     <selector>/repro.nim      <- the producer
  ##     consumer/recipe.nim       <- the consumer `nim check` is run on
  ##
  ## The producer's PACKAGE NAME must equal ``producerSelector``: the
  ## consumer reaches the lifted symbols through the producer's
  ## ``const <packageValueIdent>*`` and ``uses:`` names the directory.
  ##
  ## Under the repository rather than in the system temp directory for
  ## the reason ``checkRecipeSource`` gives: Nim finds ``config.nims`` by
  ## walking up from the compiled file, and this repo's ``config.nims``
  ## is what puts every ``libs/*/src`` on the module path.
  ##
  ## ``nim c --compileOnly`` RATHER THAN ``nim check``, AND THE REASON IS
  ## A MEASURED DEFECT IN THE MACHINERY UNDER TEST. ``usesImportCode``'s
  ## workspace-producer branch materialises a per-sibling shim module by
  ## calling ``createDir`` / ``writeFile`` from the Nim VM at macro
  ## expansion, then emits an ``import`` of it. Measured on
  ## aarch64-unaffected x86_64-linux with nim 2.3.1: under ``nim check``
  ## those VM filesystem writes DO NOT HAPPEN — the directory and the
  ## shim file are never created — and the emitted import then fails with
  ## ``cannot open file: <shimdir>/repro_sib_<selector>``, so none of the
  ## producer's symbols are in scope. Under ``nim c`` the same expansion
  ## writes the shim and the consumer compiles. This is not specific to
  ## L3: the pre-existing SC-9 test
  ## ``tests/integration/
  ## t_sc_uses_import_resolves_workspace_project_schema.nim``
  ## reproduces it at the base commit, failing the same way for
  ## ``repro_sib_scprod9exe``. It is reported, not worked around in the
  ## macro, because fixing it is not L3's milestone.
  ##
  ## ``--compileOnly`` keeps the cost down: the properties under test are
  ## macro-expansion-time and overload-resolution-time errors, which the
  ## Nim half reaches, and skipping the C compiler and linker is most of
  ## the wall clock. ``--nimcache`` is SHARED across probes on purpose —
  ## only the consumer module differs between them, so the library half
  ## is compiled once.
  ##
  ## Test-double policy: NO mocks. Two real recipes on a real filesystem,
  ## compiled by the real ``nim``.
  let scratch = repoRoot() / "build" /
    ("l3-consumer-probe-" & tag & "-" & $getCurrentProcessId())
  createDir(scratch / producerSelector)
  createDir(scratch / "consumer")
  defer:
    try: removeDir(scratch)
    except CatchableError: discard
  writeFile(scratch / producerSelector / "repro.nim", producerSource)
  let consumerPath = scratch / "consumer" / "recipe.nim"
  writeFile(consumerPath, consumerSource)
  let nimcache = repoRoot() / "build" /
    ("l3-consumer-probe-nimcache-" & $getCurrentProcessId())
  let (output, exitCode) = execCmdEx(
    nimExe() & " c --compileOnly --hints:off --colors:off " &
      "-d:reproProviderMode --nimcache:" & quoteShell(nimcache) & " " &
      quoteShell(consumerPath),
    workingDir = repoRoot())
  ServiceCompileProbeResult(ok: exitCode == 0, output: output)
