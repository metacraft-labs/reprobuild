## The normal build graph orders a C consumer of generated parser sources
## after the typed `tree_sitter.generate` edge that produces them.
##
## # Why this needs the engine
##
## `tree_sitter.generate` declares its generated directory (`generated`) as
## its output. A consumer reads `generated/parser.c`, a path *inside* that
## directory. Output-to-input path inference matches exact paths only, so it
## connects nothing here: the recipe's `after = @[gen]` is the only edge, and
## the scheduler counts readiness from `deps`. `t_tree_sitter_generate.nim`
## checks that `after` lands in `consumer.deps` and then runs both commands by
## hand; that says nothing about what the engine schedules. This file builds
## the recipe through `build/bin/repro` and reads the order from the build
## report's scheduler trace.
##
## # The control
##
## Both fixtures are built through one selector, `<project>#compile-parser`,
## the compile edge alone. `repro build <project>` with no selector schedules
## every declared edge, generator included, and the negative outcome would
## then depend on which process the scheduler happened to finish first.
## Through the selector the generator is built only when an edge from the
## compile reaches it. (An `aggregate` of the one compile is not used as the
## selector: a single-member aggregate is reported under the aggregate's
## name instead of `compile-parser`, which would only obscure the report.)
##
## * WITH `after`: the generator is pulled into the build, succeeds, and its
##   `asSucceeded` trace event precedes the compile's `ready` event. The
##   object file exists.
## * WITHOUT `after`: the same generator is declared but nothing reaches it.
##   The scheduler sees one action, the compile fails on the missing
##   `generated/parser.c`, the generator never appears in the report or on
##   disk, and no object file is produced.
##
## The negative fixture is deterministic: it does not depend on whether a
## parallel scheduler happens to run the generator first. If path inference
## ever learned to connect a directory output to an input beneath it, the
## negative control would start to pass the build and this file would say so.
##
## # Mocks
##
## NONE. The real `tree-sitter` CLI evaluates a JavaScript grammar with the
## real `node`, and the real `gcc` compiles the generated parser. The tools
## come from `PATH` (`--tool-provisioning=path`, as the other local-build
## engine e2e tests use); the test shell supplies all three. The grammar and
## its `tree-sitter.json` metadata are private inputs written by this test.
## A private `runquotad` serves the build so it does not couple to a host
## daemon, as in `t_e2e_m51_dsl_stdlib_file_ops.nim`.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support

proc pathExists(path: string): bool =
  try:
    discard getFileInfo(path, followSymlink = false)
    true
  except OSError:
    false

proc ensureRunQuotaDaemon(repoRoot: string): tuple[process: owned(Process);
    socket: string] =
  let daemonBin = requireRunQuotaDaemonBin(repoRoot)
  let socketPath = runquotaSocketEndpoint(
    "repro-ts-order-rq-" & $getCurrentProcessId())
  if fileExists(socketPath):
    removeFile(socketPath)
  let daemon = startProcess(daemonBin, args = [
    "--socket", socketPath,
    "--cpu-milli", "16000",
    "--memory-bytes", "17179869184",
    # Test daemon: keep it out of the host-wide observation store.
    "--no-write-stats"
  ], options = {poUsePath})
  putEnv("RUNQUOTA_SOCKET", socketPath)
  for _ in 0 ..< 200:
    if pathExists(socketPath):
      return (process: daemon, socket: socketPath)
    sleep(25)
  daemon.terminate()
  raise newException(OSError, "runquotad socket did not appear")

proc reproBinary(repoRoot: string): string =
  requireBinary(repoRoot / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

const TargetName = "compile-parser"

proc buildProject(reproBin, projectRoot, repoRoot: string): CmdResult =
  # `--daemon=off` and `--log=actions` for the reasons
  # `t_e2e_m51_dsl_stdlib_file_ops.nim` gives; `--write-report` so the
  # scheduler trace can be read back. The project is cold: it lives in a
  # fresh temporary directory and no previous build has run in it.
  result = runShell(shellCommand([reproBin, "build",
    projectRoot & "#" & TargetName,
    "--daemon=off", "--tool-provisioning=path", "--log=actions",
    "--write-report"]), repoRoot)
  checkpoint(result.output)

proc valueAfter(output, prefix: string): string =
  for line in output.splitLines:
    if line.startsWith(prefix):
      return line[prefix.len .. ^1].strip()
  ""

proc reportAction(report: JsonNode; id: string): JsonNode =
  for item in report{"actions"}.getElems():
    if item{"id"}.getStr() == id:
      return item
  newJNull()

proc traceSeq(report: JsonNode; id, event: string): int =
  ## The scheduler sequence number of `event` for action `id`, or -1. The
  ## engine stamps every trace event from one monotonic counter, so two
  ## numbers compare as "happened before".
  result = -1
  for item in report{"trace"}.getElems():
    if item{"actionId"}.getStr() == id and item{"event"}.getStr() == event:
      return item{"seq"}.getInt()

proc writeGrammar(projectRoot: string) =
  # ABI 15 embeds grammar metadata. Without it the generator warns and falls
  # back to ABI 14. Schema: https://tree-sitter.github.io/tree-sitter/cli/init.html
  writeFile(projectRoot / "tree-sitter.json", """{
    "grammars": [{"name":"repro_order", "scope":"source.repro_order",
      "path":".", "file-types":["repro"]}],
    "metadata": {"version":"0.1.0", "license":"MIT",
      "description":"Private graph-order test grammar",
      "authors":[{"name":"Reprobuild"}],
      "links":{"repository":"https://github.com/metacraft-labs/reprobuild"}},
    "bindings":{"c":true}
  }""")
  writeFile(projectRoot / "grammar.js", "module.exports = grammar({" &
    "name: 'repro_order', rules: {source_file: $ => repeat('x')}});\n")

proc writeProject(projectRoot: string; ordered: bool) =
  ## The two fixtures differ in one line: the compile's `after`.
  createDir(projectRoot)
  writeGrammar(projectRoot)
  let afterLine =
    if ordered: "      after = @[gen],\n"
    else: ""
  writeFile(projectRoot / "repro.nim",
    "{.experimental: \"callOperator\".}\n" &
    "import repro_dsl_stdlib\n" &
    "import repro_dsl_stdlib/packages/tree_sitter as tree_sitter_module\n" &
    "import repro_dsl_stdlib/packages/node as node_module\n" &
    "import repro_dsl_stdlib/packages/gcc as gcc_module\n\n" &
    "package tsOrder:\n" &
    "  defaultToolProvisioning \"path\"\n" &
    "  uses:\n" &
    "    \"tree-sitter\"\n" &
    "    \"node\"\n" &
    "    \"gcc\"\n" &
    "  build:\n" &
    "    let gen = tree_sitter.generate(\n" &
    "      actionId = \"generate-parser\",\n" &
    "      grammar = \"grammar.js\",\n" &
    "      outputDir = \"generated\",\n" &
    "      abi = 15)\n" &
    "    discard gcc(\n" &
    "      actionId = \"compile-parser\",\n" &
    "      source = \"generated/parser.c\",\n" &
    "      output = \"build/parser.o\",\n" &
    "      includeDirs = @[\"generated\"],\n" &
    afterLine &
    "      compileOnly = true)\n")

proc buildFixture(ordered: bool; tempRoot: string): tuple[res: CmdResult;
    projectRoot: string] =
  ## Builds one fixture under `tempRoot` and returns the build's result. The
  ## private `runquotad` is stopped here, before the caller asserts, so a
  ## failing `require` in the caller cannot leave it running (`require` quits
  ## the process and skips pending `defer`s). The caller owns `tempRoot`, so
  ## the report and products stay readable until it removes it.
  let repoRoot = getCurrentDir()
  let reproBin = reproBinary(repoRoot)
  result.projectRoot = tempRoot / "project"
  writeProject(result.projectRoot, ordered)
  doAssert not dirExists(result.projectRoot / "generated")

  var daemon = ensureRunQuotaDaemon(repoRoot)
  defer:
    daemon.process.terminate()
    discard daemon.process.waitForExit()
    daemon.process.close()
    if pathExists(daemon.socket):
      removeFile(daemon.socket)
  result.res = buildProject(reproBin, result.projectRoot, repoRoot)

suite "tree-sitter generation orders its C consumer in the engine":
  # The tools come from the Nix test shell, as in the m51 file ops tests.
  when isNixSupported:
    setup:
      for tool in ["tree-sitter", "node", "gcc"]:
        if findExe(tool).len == 0:
          checkpoint(tool & " is not on PATH; run inside the test dev shell")
        require findExe(tool).len > 0

    test "after = @[gen] builds the generator first and the compile second":
      let tempRoot = createTempDir("repro-ts-order", "")
      try:
        let (res, projectRoot) = buildFixture(ordered = true, tempRoot)
        check res.code == 0
        check res.output.contains("selectedTarget: " & TargetName)
        check res.output.contains("scheduler: actions=2")
        let reportPath = valueAfter(res.output, "buildReport:")
        require reportPath.len > 0
        let report = parseFile(reportPath)

        let gen = reportAction(report, "generate-parser")
        let compile = reportAction(report, "compile-parser")
        require gen.kind != JNull
        require compile.kind != JNull
        check gen{"status"}.getStr() == "asSucceeded"
        check gen{"launched"}.getBool()
        check compile{"status"}.getStr() == "asSucceeded"
        check compile{"launched"}.getBool()

        let genDone = traceSeq(report, "generate-parser", "asSucceeded")
        let compileReady = traceSeq(report, "compile-parser", "ready")
        let compileLaunched = traceSeq(report, "compile-parser", "launched")
        checkpoint("generate-parser asSucceeded seq=" & $genDone &
          ", compile-parser ready seq=" & $compileReady &
          ", launched seq=" & $compileLaunched)
        check genDone >= 0
        check compileReady >= 0
        check compileLaunched >= 0
        # The ordering itself: the compile became ready only after the
        # generator had finished, and launched after it became ready.
        check genDone < compileReady
        check compileReady < compileLaunched

        let parserC = projectRoot / "generated" / "parser.c"
        require fileExists(parserC)
        check "#define LANGUAGE_VERSION 15" in readFile(parserC)
        check fileExists(projectRoot / "generated" / "tree_sitter" / "parser.h")
        check fileExists(projectRoot / "build" / "parser.o")
      finally:
        removeDir(tempRoot)

    test "without after the generator is not reached and the compile fails":
      let tempRoot = createTempDir("repro-ts-order", "")
      try:
        let (res, projectRoot) = buildFixture(ordered = false, tempRoot)
        check res.code != 0
        check res.output.contains("selectedTarget: " & TargetName)
        check res.output.contains("scheduler: actions=1")
        check res.output.contains("generated/parser.c")
        check "generate-parser" notin res.output
        check not dirExists(projectRoot / "generated")
        check not fileExists(projectRoot / "build" / "parser.o")
        # A failed build still writes the full report beside the failure
        # report; the compile is in it and the generator is not.
        let reportPath = valueAfter(res.output, "buildReport:")
        require reportPath.len > 0
        let report = parseFile(reportPath)
        let compile = reportAction(report, "compile-parser")
        require compile.kind != JNull
        check compile{"status"}.getStr() == "asFailed"
        check compile{"launched"}.getBool()
        check reportAction(report, "generate-parser").kind == JNull
        check traceSeq(report, "generate-parser", "ready") == -1
      finally:
        removeDir(tempRoot)
