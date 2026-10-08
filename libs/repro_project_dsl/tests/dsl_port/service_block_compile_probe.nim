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
