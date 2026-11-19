## test_cs_m6b_derivation_once_per_description: compiling a recipe that writes
## many configuration blocks for one described tool derives the tool's
## configuration table once, and checking each block adds a bounded amount
## of compile time.
##
## The table (`cargoConfigDescription`) is derived where cargo's description
## is declared, by the `package` macro's `const`; every checked
## `tomlContent(ctx, cargoConfigDescription):` block reads that constant. The
## count comes from the instrumented compile: clispec counts every table it
## derives at compile time (`cliConfigTableDerivationCount`), and the fixture
## prints the count when it has been compiled. With N blocks it must be 1, at
## two values of N.
##
## Falsifying mutation: emitting the description
## as a `template` instead of a `const` in `cliConfigDescriptionCode`
## (`repro_project_dsl/cli_extension.nim`) re-derives the table at every use,
## so the count equals N and this test fails.
##
## Compile time: each fixture is compiled with `nim check` (the checks run at
## semantic-check time; no C compiler is involved) with the blocks checked
## and with the same blocks unchecked, at N = `smallN` and `largeN`, each
## `timedRuns` times in alternation; the fastest run of each counts, since a
## busy host only ever adds time. The time the checks add per block,
## (checked - unchecked) / N, must stay below `boundPerBlockMs` at both
## values; the measured values are printed. A wall-clock bound is loose on
## purpose (a shared host), and it bounds the cost per block, which is what
## grows with a recipe.

import std/[monotimes, os, osproc, strutils, times, unittest]

proc repoRoot(): string =
  currentSourcePath().parentDir().parentDir().parentDir().parentDir()

const
  smallN = 50
  largeN = 300
  timedRuns = 3
  boundPerBlockMs = 25.0
    ## The bound on the compile time a checked block adds, per block. When it
    ## was set (2026-11-19) the checks measured 2 to 4 ms per block and a
    ## shared host's noise between two ~10 s compiles was up to 0.3 s, which
    ## is 6 ms per block at the small N; deriving the table per block costs
    ## about 130 to 650 ms per block and fails it.

proc fixture(n: int; checked: bool): string =
  result = "import repro_dsl_stdlib/configurables\n" &
    "import repro_dsl_stdlib/generated_config\n" &
    "import repro_dsl_stdlib/packages/cargo as cargo_module\n\n" &
    "let ctx = evalConfig:\n  discard\n\n"
  let head = if checked: "tomlContent(ctx, cargo_module.cargoConfigDescription):"
             else: "tomlContent(ctx):"
  for i in 0 ..< n:
    result.add("let rendered" & $i & " = " & head & "\n" &
      "  build:\n" &
      "    `target-dir` = \"out/target-" & $i & "\"\n" &
      "    target = \"x86_64-unknown-linux-gnu\"\n" &
      "  net:\n" &
      "    offline = " & (if i mod 2 == 0: "true" else: "false") & "\n" &
      "  term:\n" &
      "    color = \"never\"\n" &
      "echo renderToString(rendered" & $i & ")\n")
  result.add("\nstatic:\n  echo \"cs-m6b derivations: \", " &
    "cliConfigTableDerivationCount()\n")

type Compiled = object
  ok: bool
  output: string
  seconds: float

proc compile(n: int; checked: bool): Compiled =
  let scratch = repoRoot() / "build" / ("cs-m6b-derive-" & $n & "-" &
    (if checked: "checked" else: "plain") & "-" & $getCurrentProcessId())
  createDir(scratch)
  defer:
    try: removeDir(scratch)
    except CatchableError: discard
  let source = scratch / "fixture.nim"
  writeFile(source, fixture(n, checked))
  let started = getMonoTime()
  let (output, code) = execCmdEx("nim check --hints:off --colors:off " &
    quoteShell(source), workingDir = repoRoot())
  Compiled(ok: code == 0, output: output,
    seconds: (getMonoTime() - started).inNanoseconds.float / 1e9)

proc derivations(c: Compiled): int =
  for line in c.output.splitLines:
    if line.startsWith("cs-m6b derivations: "):
      return parseInt(line["cs-m6b derivations: ".len .. ^1].strip)
  -1

suite "test_cs_m6b_derivation_once_per_description":

  for n in [smallN, largeN]:
    test "N = " & $n & " checked blocks derive the table once":
      var checkedSeconds, plainSeconds = Inf
      for run in 1 .. timedRuns:
        let checked = compile(n, checked = true)
        if not checked.ok:
          echo checked.output
        check checked.ok
        check derivations(checked) == 1
        let plain = compile(n, checked = false)
        check plain.ok
        # The unchecked fixture reads no description, but cargo's is still
        # derived once where it is declared.
        check derivations(plain) == 1
        checkedSeconds = min(checkedSeconds, checked.seconds)
        plainSeconds = min(plainSeconds, plain.seconds)
      let added = (checkedSeconds - plainSeconds) * 1000.0 / n.float
      echo "  N = ", n, ": checked ", checkedSeconds.formatFloat(ffDecimal, 2),
        " s, unchecked ", plainSeconds.formatFloat(ffDecimal, 2),
        " s (fastest of ", timedRuns, "), added per block ",
        added.formatFloat(ffDecimal, 2), " ms"
      check added < boundPerBlockMs
