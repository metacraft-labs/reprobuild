## Every command line the published user guide
## (``docs/user-guide/addon-evidence.md``) prints is one the tools accept
## (A11 drill finding D2: two of its sink lines did not parse).
##
## Each ``sh`` block's lines (continuations joined) and each inline
## ``repro-evidence-sink ...`` / ``repro system addon ...`` command in the
## prose are parsed by the command's own parser: the sink's
## (``evidence_sink_cli.parseSinkCommand``), and for ``repro system addon``
## the verb is held to the CLI's usage text and, for ``contain`` and
## ``release``, to their own parser. Placeholders (``<port>``, ``<digest>``)
## are given sample values first; an elided line (``...``) is checked for
## its verb only.
##
## Falsifying build: ``sink-cli-equals-only`` (the old parser, which read
## ``--dir D`` as an empty ``--dir``): the sink lines go red.
##
## Mocks: none. The document is read from the tree.

import std/[os, strutils, unittest]

import repro_addon/cli
import repro_addon/containment
import repro_addon/evidence_sink_cli

const Guide = currentSourcePath().parentDir.parentDir.parentDir.parentDir /
              "docs" / "user-guide" / "addon-evidence.md"

proc commandLines(text: string): seq[string] =
  var inBlock = false
  var pending = ""
  for raw in text.splitLines():
    let line = raw.strip()
    if line.startsWith("```"):
      inBlock = line.startsWith("```sh") and not inBlock
      continue
    if inBlock and line.len > 0:
      if line.endsWith("\\"):
        pending.add(line[0 ..< ^1] & " ")
      else:
        result.add(pending & line)
        pending = ""
  # Inline code spans in the prose that are commands.
  var i = 0
  while true:
    let a = text.find('`', i)
    if a < 0: break
    let b = text.find('`', a + 1)
    if b < 0: break
    let span = text[a + 1 ..< b]
    if span.startsWith("repro-evidence-sink ") or
        span.startsWith("repro system addon "):
      result.add(span)
    i = b + 1

proc sample(line: string): string =
  line.multiReplace(("<port>", "7443"), ("<address>", "10.0.0.5"),
                    ("<digest>", "ab"), ("<file>", "/tmp/x"),
                    ("<you>", "alice"), ("<n>", "15"))

suite "the user guide's command lines parse":
  let lines = commandLines(readFile(Guide))
  var sinkLines, addonLines = 0

  test "every documented command parses":
    for l in lines:
      checkpoint l
      let args = parseCmdLine(sample(l))
      if args[0] == "repro-evidence-sink":
        inc sinkLines
        # A bare verb mentioned in the prose (`repro-evidence-sink read`)
        # needs its store to run; the documented form is still checked.
        if args.len == 2 and args[1] in SinkVerbs: continue
        var ok = true
        var why = ""
        try: discard parseSinkCommand(args[1 .. ^1])
        except SinkUsageError as e:
          ok = false
          why = e.msg
        check ok
        if not ok: checkpoint why
      elif args.len >= 4 and args[0] == "repro" and args[1] == "system" and
          args[2] == "addon":
        inc addonLines
        let verb = args[3]
        check ("\n  " & verb) in AddonUsage
        if verb in ["contain", "release"]:
          var ok = true
          try: discard parseContainArgs(args[4 .. ^1])
          except ValueError: ok = false
          check ok

  test "the check is not vacuous":
    check sinkLines >= 5
    check addonLines >= 6
