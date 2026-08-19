import std/[os, strutils, tempfiles, unittest]

import repro_test_support

const NimCompiler =
  when defined(windows):
    staticExec("where nim").splitLines()[0].strip()
  else:
    staticExec("command -v nim").strip()

suite "ambient execution external import":
  test "convention attribution compiles outside the reprobuild checkout":
    let repoRoot = getCurrentDir()
    let scratch = createTempDir("repro-ambient-import-", "")
    defer: removeDir(scratch)

    let consumer = scratch / "consumer.nim"
    writeFile(consumer,
      "import repro_core/convention_attribution\n" &
      "discard attributeConvention(\".\")\n")

    let command = @[
      NimCompiler,
      "check",
      "--hints:off",
      "--path:" & (repoRoot / "libs" / "repro_core" / "src"),
      "--nimcache:" & (scratch / "nimcache"),
      consumer,
    ]
    let execution = runShell(shellCommand(command), scratch)
    check execution.code == 0
    if execution.code != 0:
      checkpoint(execution.output)
