## Gate ``e2e_addon_floor_effective_unit_is_checked`` (milestone A9, review
## round 3's structural requirement; spec §10.1 *Amended 2026-11-04*).
##
## A floored unit never starts with a weaker floor than it was rendered
## under, whatever spelling, key, drop-in rule or default the floor's
## parse-time checks do not predict: after the switch's daemon-reload and
## before step 7 starts anything, the add-on reads each floored unit's
## effective properties with ``systemctl show`` and compares them with the
## floor (``repro_addon/effective_floor``); a difference is
## ``EAddOnFloorNotEffective``, nothing starts, and the switch reverts.
##
## The cases are review round 3's findings 1-5 (and 6): a unit that runs as
## root by an empty ``User=``, by ``DynamicUser=n``, or by a drop-in's
## ``User=`` reset; writable places the unit sets up (``ReadWritePaths=``, a
## bind, an ``exec`` tmpfs, a drop-in's ``StateDirectory=``); a quoted bind
## over the closure; an instance's drop-in over a floored template; a
## ``collision = "dropIn"`` unit over a floored one; ``PAMName=``. Each is
## applied by an operator on a fresh add-on host. A case passes when the
## apply is refused and the unit never started, or -- for a writable place
## the floor now covers -- when the unit runs and systemd shows it holding
## the floor (not root, the place in ``NoExecPaths=``). A positive control
## (a plain floored unit) must apply and start.
##
## Builds:
##
## - the product build: each case is refused at parse time, or held;
## - ``REPRO_ADDON_MUTATION=floor-static-r3-disabled`` (the allowlist and
##   every round-3 parse-time refusal and noexec line off): the effective
##   check alone must refuse every case, each refusal naming
##   ``EAddOnFloorNotEffective`` -- green;
## - ``REPRO_ADDON_MUTATION=floor-unchecked`` (both halves off): a unit
##   starts as root or with an executable writable place -- red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``.
##
## *Mocking.* None: the real add-on, the base's own systemd.

import std/[json, strutils, tables, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed

const Gate = "e2e_addon_floor_effective_unit_is_checked"

type Case = object
  name: string          ## the unit's name
  service: string       ## lines added to its [Service]
  extra: string         ## more resources (a drop-in, a dropIn unit)
  coveredPlace: string  ## a writable place the floor now covers (may run)
  first: string         ## a generation applied before the case's (the
                        ## floored template an instance's drop-in then
                        ## modifies must already be on the host)

proc unitResource(name, service, binary: string): string =
  ## A floored oneshot unit; a template is declared without ``[Install]``
  ## and is not enabled (it has no default instance).
  let tmpl = name.contains("@.")
  "systemd.systemUnit {\n  name = \"" & name & "\"\n  content = \"[Unit]\n" &
    "Description=A9 round 3\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\n" &
    service & "ExecStart=" & binary & " --version\n" &
    (if tmpl: "\"\n  enabled = false\n}\n"
     else: "\n[Install]\nWantedBy=multi-user.target\n\"\n  enabled = true\n}\n")

proc dropIn(unit, content: string): string =
  "systemd.systemDropIn {\n  unit = \"" & unit & "\"\n  name = \"x\"\n" &
    "  content = \"" & content & "\"\n}\n"

proc cases(binary, prefix: string): seq[Case] =
  @[Case(name: "a9e-user-empty.service", service: "User=\n"),
    Case(name: "a9e-dyn-n.service", service: "DynamicUser=n\n"),
    Case(name: "a9e-drop-user.service", service: "User=a9e\n",
         extra: dropIn("a9e-drop-user.service", "[Service]\nUser=\n")),
    Case(name: "a9e-rw.service", service: "User=a9e\nReadWritePaths=/var/lib/a9e-rw\n",
         coveredPlace: "/var/lib/a9e-rw"),
    Case(name: "a9e-bind.service",
         service: "User=a9e\nBindPaths=/var/lib/a9e-rw:/srv/a9e-b\n",
         coveredPlace: "/srv/a9e-b"),
    Case(name: "a9e-tmpfs-exec.service",
         service: "TemporaryFileSystem=/srv/a9e-t:mode=1777,exec\n"),
    Case(name: "a9e-drop-state.service", service: "",
         extra: dropIn("a9e-drop-state.service", "[Service]\nStateDirectory=a9e-evil\n")),
    Case(name: "a9e-quoted.service",
         service: "User=a9e\nBindPaths=/var/lib/a9e-rw:'" & prefix & "/drop'\n"),
    Case(name: "a9e-tpl@.service", service: "",
         extra: dropIn("a9e-tpl@1.service", "[Service]\nMemoryDenyWriteExecute=no\n"),
         first: "a9e-tpl@.service"),
    Case(name: "a9e-cd@.service", service: "User=a9e\n",
         extra: "systemd.systemUnit {\n  name = \"a9e-cd@1.service\"\n" &
                "  collision = \"dropIn\"\n  content = \"[Service]\nUser=\n\"\n}\n",
         first: "a9e-cd@.service"),
    Case(name: "a9e-pam.service", service: "User=a9e\nPAMName=login\n")]

proc invocation(g: Guest; unit: string): string =
  g.exec("systemctl show -p InvocationID --value " & unit).stdout.strip()

proc runBase(b: BaseImage; record: JsonNode): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    g = newGuest(b)
    g.boot()
    g.prepareBase()
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    if not g.bootstrapAddon(repro, step): return fails
    discard g.run("useradd -r -M -s /usr/sbin/nologin a9e; " &
                  "mkdir -p /var/lib/a9e-rw")
    let binary = g.run("ls -d /repro/store/prefixes/repro-addon/*/bin/repro " &
                       "| head -1").strip()
    let prefix = binary[0 ..< binary.len - "/bin/repro".len]
    let head = "addOn {\n  managedEtcPrefixes = []\n}\n\n"
    # The positive control: a plain floored unit applies and starts.
    var r = g.applyProfile(repro, "control", head &
      unitResource("a9e-control.service", "", binary))
    step("a plain floored unit applies", r.exitCode == 0, r.stdout & r.stderr)
    step("and starts", g.invocation("a9e-control.service").len > 0, "")
    let effectiveOnly = mutation() == "floor-static-r3-disabled"
    var results = newJArray()
    for c in cases(binary, prefix):
      let base = head & unitResource("a9e-control.service", "", binary)
      if c.first.len > 0:
        r = g.applyProfile(repro, c.name.split('.')[0] & "-first",
                           base & unitResource(c.name, c.service, binary))
        step(c.name & ": the floored template alone applies",
             r.exitCode == 0, r.stdout & r.stderr)
      let text = base & unitResource(c.name, c.service, binary) & c.extra
      r = g.applyProfile(repro, c.name.split('.')[0], text)
      let output = r.stdout & r.stderr
      let probeUnit = if c.name.contains("@."): c.name.replace("@.", "@1.")
                      else: c.name
      let started = g.invocation(probeUnit).len > 0
      var held = false
      if r.exitCode == 0 and c.coveredPlace.len > 0 and started:
        var show = initTable[string, string]()
        for l in g.exec("systemctl show -p User,DynamicUser,NoExecPaths " &
                        c.name).stdout.splitLines():
          let eq = l.find('=')
          if eq > 0: show[l[0 ..< eq]] = l[eq + 1 .. ^1]
        let user = show.getOrDefault("User")
        let notRoot = show.getOrDefault("DynamicUser") == "yes" or
                      (user.len > 0 and user notin ["root", "0"])
        var noexec = false
        for t in show.getOrDefault("NoExecPaths").splitWhitespace():
          if t.strip(leading = true, trailing = false, chars = {'-'}) ==
              c.coveredPlace: noexec = true
        held = notRoot and noexec
      results.add(%*{"case": c.name, "exit": r.exitCode, "started": started,
                     "held": held, "output": output[max(0, output.len - 600) .. ^1]})
      if c.coveredPlace.len > 0 and r.exitCode == 0:
        step(c.name & ": runs, holding its floor (not root, the place " &
             "noexec)", held and not effectiveOnly, output)
      else:
        step(c.name & ": refused, never started", r.exitCode != 0 and
             not started, output)
        if effectiveOnly:
          step(c.name & ": refused by the effective-unit check",
               "EAddOnFloorNotEffective" in output, output)
      # The host stays on the control's generation between cases.
      discard g.applyProfile(repro, "back", head &
        unitResource("a9e-control.service", "", binary))
    record["cases"] = results
  except CatchableError as e:
    fails.add(b.name & ": " & e.msg)
    steps.add(%*{"step": "exception", "ok": false, "detail": e.msg})
  finally:
    record["steps"] = steps
    if g != nil:
      record["guest"] = %g.name
      record["log"] = %g.log
      g.destroy()
  fails

suite Gate:
  test "a floored unit never starts weaker than its floor":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": Gate, "base": b.name, "arch": b.debArch,
          "backend": (if useIncus(): "incus" else: "qemu"),
          "mutation": mutation(), "reprobuild": gitHead(),
          "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord(Gate, record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
