## The add-on after the A9 review's round 23 (ReproOS Add-On Mode spec
## §10.1, §13 decision 133; A9 review round 14): the revert hold's staging
## directory is durable before the record says ``staged``.
##
## ``placeRevertHold`` makes ``<root>/.repro-addon-revert-hold.<nonce>``,
## syncs ``<root>`` and only then records the step as ``staged``: a record
## that says ``staged`` over a staging directory a power loss took back
## would read as renamed, and an operator's ``<unit>.d`` made before the
## replay would be claimed. What a power loss keeps cannot be tested
## without one, so the test observes what makes it durable: the
## ``fsync(2)`` of ``<root>`` between the ``mkdir(2)`` of the staging
## directory and the rename that writes the ``staged`` record. It runs
## ``placeRevertHold`` in a child (this binary, ``--place-hold``) under
## ``strace -f -y``, which names the directory each descriptor is open on.
##
## And (second suite) a drop-in that would widen a floored service's
## ``IPAddressAllow=``/``IPAddressDeny=`` or ``ProcSubset=`` never passes
## as "no weakening": the profile's drop-ins may not set them (the drop-in
## allowlist, at parse time), and any drop-in the add-on did not install is
## refused whatever it sets (``foreign-drop-in``), before ``effective_floor``
## compares a single property. Generation 0's own units are not judged by
## that comparison at all: the effective check covers the floored units.
##
## Falsifying build, red here: ``revert-hold-staging-not-synced``.
##
## *Mocking.* None: the real file system, the real system calls, as the
## kernel reports them. ``strace`` is the dev shell's (flake.nix), resolved
## from PATH; a missing one is a failure, never a skip.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_infra/profile
import repro_infra/errors
import repro_infra/service_floor
import repro_addon/addon_apply
import repro_addon/effective_floor

if paramCount() == 3 and paramStr(1) == "--place-hold":
  discard placeRevertHold(paramStr(2), "a9r23.service", paramStr(3))
  quit(0)

proc tracedPlacement(state, root: string): seq[string] =
  ## The traced calls of one ``placeRevertHold`` in a child, in order.
  let strace = findExe("strace")
  doAssert strace.len > 0, "strace is not on PATH: run in the dev shell"
  let outFile = state & ".trace"
  let (o, c) = execCmdEx(quoteShellCommand([strace, "-f", "-y", "-qq",
    "-e", "trace=mkdir,mkdirat,fsync,rename,renameat,renameat2",
    "-o", outFile, getAppFilename(), "--place-hold", state, root]))
  doAssert c == 0, "the traced placement failed: " & o
  readFile(outFile).splitLines()

suite "A9 review round 23: the staging directory is durable before it is recorded staged":
  test "the root is synced between the staging mkdir and the staged record":
    let tmp = createTempDir("a9r23-", "-hold")
    defer: removeDir(tmp)
    let state = tmp / "state"
    let root = tmp / "units"
    createDir(state)
    createDir(root)
    let lines = tracedPlacement(state, root)
    var made, staged = -1
    var syncs: seq[int]
    for i, l in lines:
      if ("mkdir" in l) and RevertHoldStagingPrefix in l and made < 0: made = i
      if l.contains("fsync(") and l.contains("<" & root & ">"): syncs.add(i)
      if made >= 0 and staged < 0 and i > made and "rename" in l and
          "revert-hold-dirs" in l:
        staged = i
    checkpoint lines.join("\n")
    check made >= 0
    check staged > made
    var between = false
    for i in syncs:
      if i > made and i < staged: between = true
    check between

# ---------------------------------------------------------------------------
# IPAddressAllow=, IPAddressDeny= and ProcSubset= in the effective check
# (A9 review round 23: a design study asked whether a planted drop-in
# widening them passes as "no weakening", since ``effective_floor`` counts
# them among the settings that only restrict).

const
  Prefix = "/repro/store/prefixes/svc/1.0"

proc stanza(name, service: string; extra = ""): string =
  "systemd.systemUnit {\n  name = \"" & name & "\"\n  content = \"[Unit]\n" &
    "Description=x\n\n[Service]\n" & service & "\n[Install]\n" &
    "WantedBy=multi-user.target\n\"\n" & extra & "}\n"

proc refusedText(text: string): string =
  try:
    discard parseAddOnUserProfile(text)
  except ESystemProfileInvalid as e:
    return e.msg
  ""

proc renderedUnit(text: string; name = "a.service"): string =
  for r in parseAddOnUserProfile(text).resources:
    if r.kind == srkSystemdSystemUnit and r.suName == name:
      return renderedSystemUnitContent(r)

suite "A9 review round 23: widening egress or ProcSubset= by a drop-in":
  # A floored service that closes its own egress.
  let svc = "User=a\nIPAddressDeny=any\nIPAddressAllow=192.0.2.1\n" &
            "ProcSubset=pid\nExecStart=" & Prefix & "/bin/svc\n"
  let unitText = stanza("a.service", svc)
  test "the profile's own drop-in cannot set them: refused at parse time":
    check refusedText(unitText) == ""
    for line in ["IPAddressAllow=any", "IPAddressDeny=", "ProcSubset=all"]:
      let d = "systemd.systemDropIn {\n  unit = \"a.service\"\n  name = \"x\"\n" &
              "  content = \"[Service]\n" & line & "\n\"\n}\n"
      let why = refusedText(unitText & d)
      checkpoint line & ": " & why
      check why.len > 0
  test "any drop-in the add-on did not install is refused, whatever it sets":
    let ru = renderedUnit(unitText)
    check ru.len > 0
    let frag = "/etc/systemd/system/a.service"
    let planted = "/etc/systemd/system/a.service.d/zz-planted.conf"
    var e = EffectiveInput(unit: "a.service", rendered: ru, version: FloorVersion,
      fragment: frag, partialShow: true)
    e.show = parseShow("LoadState=loaded\nUser=a\nFragmentPath=" & frag & "\n" &
      "DropInPaths=" & planted & "\nIPAddressAllow=any\nIPAddressDeny=\n" &
      "ProcSubset=all\n")
    e.loaded = @[(path: frag, content: ru),
                 (path: planted, content: "[Service]\nIPAddressAllow=any\n" &
                                          "IPAddressDeny=\nProcSubset=all\n")]
    e.uidOf = proc (n: string): int = (if n == "a": 1000 else: -1)
    e.groupsOf = proc (n: string): seq[string] = @[n]
    e.gidOf = proc (g: string): int = (if g == "a": 1000 else: -1)
    e.inspectFile = proc (p: string): string = ""
    e.inspectPath = proc (p: string; uid: int; dynamic: bool): string = ""
    let p = effectiveFloorProblems(e).join("\n")
    checkpoint p
    check ("the drop-in " & planted & " is not one the add-on installed") in p
    check "[rule:foreign-drop-in key:DropInPaths]" in p
