## The `system.nim` text form carries every field value byte for byte.
##
## Governing spec: ``reprobuild-pm/spec/System-Profile-And-Infra-Apply.md``
## §Intent Layer, "The text form" — a field value is a double-quoted string
## whose only escape is a doubled quote (``""`` for ``"``); a ``#`` inside a
## value, on any of its lines, is value text.
##
## Why it matters: every compiled profile reaches the apply as text
## (``renderSystemProfileToText`` -> ``parseSystemProfile``), and every
## generation stores that text for rollback. Before this, a value could not
## hold a ``"`` at all (both renderers raised), so YAML, udev rules and
## ``caches.conf`` had to ride a side channel; and the parser stripped
## comments per line, so a multi-line value lost its ``#`` lines and was cut
## at an in-value ``#`` without a word (reprobuild-pm issue
## ``2026-10-30-system-profile-text-parser-drops-hash-text-inside-multi-line-quoted-values``).
##
## No mocks: the real DSL templates, the real adapter and renderer, the real
## parser, and the real editor on a real temporary file.

import std/[os, strutils, unittest]

import repro_elevation
import repro_infra
import repro_profile
import repro_profile_compile

const
  # A unit with a comment line, an in-value `#`, quoted Environment= values,
  # a `}` and a CRLF line: each one was lost or refused before.
  Unit = "[Unit]\n" &
    "Description=\"quoted\" exporter\n" &
    "# a comment line inside the value\n" &
    "\n" &
    "[Service]\n" &
    "Environment=\"GREETING=hello world\" \"EMPTY=\"\n" &
    "ExecStart=/bin/sh -c 'echo a#b; test \"$1\" = \"}\"'\r\n" &
    "\n" &
    "[Install]\n" &
    "WantedBy=multi-user.target\n"
  Yaml = "modules:\n  http_2xx:\n    prober: http\n" &
    "    http:\n      fail_if_body_not_matches_regexp: [\"ok\"]\n" &
    "  # yaml comment\n"
  UdevRule = "SUBSYSTEM==\"usb\", ATTRS{idVendor}==\"0764\", " &
    "SYMLINK+=\"ups-server-room\"\n"
  # Edges of the encoding: a value that IS a quote, starts or ends with one,
  # holds a run of them, or is empty.
  Edges = ["\"", "\"lead", "trail\"", "a\"\"\"b", "", "#", "\\\\server\\share"]

proc compiledProfile(unit = Unit): SystemProfile =
  var intent = ProfileIntent(name: "quoting")
  systemdSystemUnit(intent.resources, name = "q.service", content = unit)
  fsSystemFile(intent.resources, path = "/etc/q/blackbox.yml", content = Yaml)
  linuxUdevRule(intent.resources, name = "90-q.rules", content = UdevRule)
  for i, e in Edges:
    fsSystemFile(intent.resources, path = "/etc/q/edge" & $i,
      content = e)
  profileIntentToSystemProfile(intent)

proc contentOf(sp: SystemProfile; address: string): string =
  for r in sp.resources:
    if r.address == address:
      case r.kind
      of srkSystemdSystemUnit: return r.suContent
      of srkFsSystemFile: return r.sfContent
      of srkLinuxUdevRule: return r.udevContent
      else: discard
  raise newException(KeyError, "no resource " & address)

suite "system.nim text form: quoting and comments":
  test "issue reproduction: a # inside a multi-line value is kept":
    # The exact stanza from the issue, hand-written.
    let text = "systemd.systemUnit {\n" &
      "  name = \"x.service\"\n" &
      "  content = \"[Service]\n" &
      "# a comment line\n" &
      "ExecStart=/bin/echo a#b\n" &
      "\"\n" &
      "}\n"
    let sp = parseSystemProfile(text)
    check sp.resources.len == 1
    check sp.resources[0].suContent ==
      "[Service]\n# a comment line\nExecStart=/bin/echo a#b\n"

  test "comments outside values are still comments":
    let text = "# leading comment \"with an odd quote\n" &
      "fs.systemFile { # trailing comment\n" &
      "  path = \"/etc/q/a\"   # after a value\n" &
      "  content = \"x#y\" # and another\n" &
      "}\n# done\n"
    let sp = parseSystemProfile(text)
    check sp.resources.len == 1
    check sp.resources[0].sfPath == "/etc/q/a"
    check sp.resources[0].sfContent == "x#y"

  test "compiled profile -> text -> parse is byte-identical":
    let sp = compiledProfile()
    let text = renderSystemProfileToText(sp)
    let back = parseSystemProfile(text)
    check back.resources.len == sp.resources.len
    for r in sp.resources:
      check back.contentOf(r.address) == sp.contentOf(r.address)
    check back.contentOf("systemd.systemUnit:q.service") == Unit
    check back.contentOf("fs.systemFile:/etc/q/blackbox.yml") == Yaml
    check back.contentOf("linux.udevRule:90-q.rules") == UdevRule
    for i, e in Edges:
      check back.contentOf("fs.systemFile:/etc/q/edge" & $i) == e
    # And the typed operation the broker receives carries the same bytes.
    for r in back.resources:
      if r.kind == srkSystemdSystemUnit:
        check toPrivilegedOperation(r).suContent == Unit

  test "a doubled quote is the encoding, and only it":
    check quoteSystemValue("a\"b") == "\"a\"\"b\""
    check quoteSystemValue("") == "\"\""
    check quoteSystemValue("C:\\x\\") == "\"C:\\x\\\""

  test "backward compatibility: text written before the escape parses as before":
    # Single, undecoded backslashes, an empty value, a bool and a list.
    let text = "windows.registryValue {\n" &
      "  key = \"HKLM\\SOFTWARE\\Repro\"\n" &
      "  name = \"\"\n" &
      "  value = \"\\\\server\\share\"\n" &
      "}\n"
    let sp = parseSystemProfile(text)
    check sp.resources[0].regKey == "HKLM\\SOFTWARE\\Repro"
    check sp.resources[0].regName == ""
    check sp.resources[0].regValueLiteral == "\\\\server\\share"

  test "the editor renders, finds and removes a stanza whose value holds }":
    let dir = getTempDir() / "t_system_profile_text_quoting_" & $getCurrentProcessId()
    createDir(dir)
    defer: removeDir(dir)
    let path = dir / "system.nim"
    writeFile(path, "")
    # LF only: the editor picks ONE line ending for the whole file from the
    # first CRLF it sees, so a CRLF inside a value is not an editor case.
    let sp = compiledProfile(Unit.replace("\r\n", "\n"))
    var doc = loadSystemIntent(path)
    for r in sp.resources:
      addResource(doc, r)
    writeSystemIntent(doc)
    doc = loadSystemIntent(path)
    let spans = stanzaSpans(doc)
    check spans.len == sp.resources.len
    # Removing the unit (whose content holds `}` and blank lines) removes
    # exactly it; every other stanza still parses with its bytes intact.
    # The editor renders no `address =` line, so a re-parsed stanza is
    # addressed by the parser default, `realWorldIdentity`.
    var unitAddress, udevAddress, yamlAddress: string
    for r in sp.resources:
      case r.kind
      of srkSystemdSystemUnit: unitAddress = realWorldIdentity(r)
      of srkLinuxUdevRule: udevAddress = realWorldIdentity(r)
      of srkFsSystemFile:
        if r.sfPath == "/etc/q/blackbox.yml": yamlAddress = realWorldIdentity(r)
      else: discard
    check removeResource(doc, unitAddress)
    writeSystemIntent(doc)
    let after = parseSystemProfile(readFile(path))
    check after.resources.len == sp.resources.len - 1
    check after.contentOf(udevAddress) == UdevRule
    check after.contentOf(yamlAddress) == Yaml
    for i, e in Edges:
      var a = ""
      for r in sp.resources:
        if r.kind == srkFsSystemFile and r.sfPath == "/etc/q/edge" & $i:
          a = realWorldIdentity(r)
      check after.contentOf(a) == e
