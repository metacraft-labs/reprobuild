## Every command line the published user guide
## (``docs/user-guide/addon-evidence.md``) prints is one the tools accept
## (A11 drill finding D2: two of its sink lines did not parse).
##
## Each ``sh`` block's lines (continuations joined) and each inline
## ``repro-evidence-sink ...`` / ``repro system addon ...`` command in the
## prose are parsed WHOLE by the command's own parser: the sink's
## (``evidence_sink_cli.parseSinkCommand``), and for each ``repro system
## addon`` verb the guide uses, that verb's (``parsePreflightArgs``,
## ``parseBootstrapArgs``, ``parseEnrolArgs``, ``parseContainArgs``,
## ``parseUninstallArgs``, ``parseVerifyDiscardRecordArgs``, or no
## option at all). A verb the test has no parser for fails it, and so does
## an elided line (``...``) or a prose span that names a sink command
## without the tool (``addon-check --update-hosts``): every command the
## guide prints is one the reader can run (A11 review finding 16).
## Placeholders (``<port>``, ``<digest>``) are given sample values first.
##
## Falsifying build: ``sink-cli-equals-only`` (the old parser, which read
## ``--dir D`` as an empty ``--dir``): the sink lines go red.
##
## Mocks: none. The document is read from the tree.

import std/[os, strutils, unittest]

import repro_addon/cli
import repro_addon/containment
import repro_addon/evidence_enrol
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
                    ("<you>", "alice"), ("<n>", "15"),
                    ("<key>", "04ab"))

suite "the user guide's command lines parse":
  let text = readFile(Guide)
  let lines = commandLines(text)
  var sinkLines, addonLines = 0

  test "every documented command parses, whole":
    for l in lines:
      checkpoint l
      check "..." notin l
      let args = parseCmdLine(sample(l))
      var ok = true
      var why = ""
      try:
        if args[0] == "repro-evidence-sink":
          inc sinkLines
          discard parseSinkCommand(args[1 .. ^1])
        elif args.len >= 4 and args[0] == "repro" and args[1] == "system" and
            args[2] == "addon":
          inc addonLines
          let rest = args[4 .. ^1]
          case args[3]
          of "preflight": discard parsePreflightArgs(rest)
          of "bootstrap": discard parseBootstrapArgs(rest)
          of "evidence-enrol": discard parseEnrolArgs(rest)
          of "contain", "release": discard parseContainArgs(rest)
          of "uninstall": discard parseUninstallArgs(rest)
          of "verify-discard-record": discard parseVerifyDiscardRecordArgs(rest)
          of "evidence-credential-check", "migrate":
            if rest.len > 0: raise newException(ValueError, "takes no option")
          else:
            raise newException(ValueError, "no parser for " & args[3])
        else:
          raise newException(ValueError, "not a command the guide may print")
      except CatchableError as e:
        ok = false
        why = e.msg
      if not ok: checkpoint why
      check ok

  test "no prose names a sink command without its tool":
    for verb in SinkVerbs:
      check ("`" & verb & " --") notin text

  test "the check is not vacuous":
    check sinkLines >= 7
    check addonLines >= 7
