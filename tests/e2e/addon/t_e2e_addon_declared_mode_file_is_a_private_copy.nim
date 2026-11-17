## Gate ``e2e_addon_declared_mode_file_is_a_private_copy``.
##
## An ``fs.systemFile`` that declares a ``mode`` or a ``group`` is a private
## copy on an add-on host: a regular file, ``root:<group>`` with exactly the
## declared permission bits, written by the switch's copy step as root and
## never placed in the world-readable static tree. One that declares
## ``form = "copy"`` is a copy too, and a file that was a link in the
## previous generation becomes a regular file in the next one. A file that
## declares none of the three stays a link into ``/etc/repro/static``
## (ReproOS Add-On Mode §7.2 step 5 and System Profile §"fs.systemFile",
## both amended 2026-11-16 for reprobuild-pm issue
## ``2026-11-12-fs-systemfile-cannot-express-mode-group-or-copy-form``:
## the declared mode was dropped, so a ``0640`` secret was published as a
## link into the static tree, readable by every local user).
##
## The unit tests (``t_system_file_declared_mode_and_group_hold``,
## ``t_addon_system_file_with_mode_or_group_is_a_private_copy``) hold the
## same properties in a user namespace and through the switch's planning;
## this gate holds them on a real guest, as root, through bootstrap, two
## applies of the real switch and uninstall.
##
## Steps, per base:
##
## 1. Generation 1: ``plain.conf`` (nothing declared), ``secret.conf``
##    (``mode = "0640"``, ``group = "adm"``, a group every supported base
##    ships) and ``toggled.conf`` (nothing declared).
##    - ``plain.conf`` and ``toggled.conf`` are links into the static tree.
##    - ``secret.conf`` is a regular file, ``640 root:adm``, which the
##      ``nobody`` account cannot read, and its bytes are nowhere in the
##      static tree.
## 2. Someone runs ``chmod 0644`` on ``secret.conf``. The next plan names it
##    as an update.
## 3. Generation 2 is the same profile, except that ``toggled.conf``
##    declares ``form = "copy"``.
##    - ``secret.conf`` is back to ``640 root:adm``.
##    - ``toggled.conf`` is a regular file with the same bytes, and the
##      static tree no longer carries it.
## 4. Generation 3 is generation 1 again. ``toggled.conf``'s bytes did not
##    change, so it stays a copy: an object keeps its form until its content
##    changes, so nothing is written (§7.2 step 5).
## 5. Generation 4 gives ``toggled.conf`` new bytes and declares nothing. It
##    is a link again, and ``addon verify`` reports no drift.
## 6. Uninstall succeeds.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``
## (``just e2e_addon_declared_mode_file_is_a_private_copy``). Bases:
## ``REPRO_ADDON_BASES`` (default here: debian-13-amd64,ubuntu-24.04-amd64).
##
## *Mocking.* None: a real guest as root, the real static add-on binary,
## the real switch.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed

const
  Secret = "repro-private-0640-marker"

proc profileText(toggledCopy: bool; toggled = "toggled"): string =
  "addOn {\n  managedEtcPrefixes = [\"/etc/repro-fixture/\"]\n}\n\n" &
  "fs.systemFile {\n  path = \"/etc/repro-fixture/plain.conf\"\n" &
  "  content = \"plain\n\"\n}\n\n" &
  "fs.systemFile {\n  path = \"/etc/repro-fixture/secret.conf\"\n" &
  "  content = \"" & Secret & "\n\"\n  mode = \"0640\"\n" &
  "  group = \"adm\"\n}\n\n" &
  "fs.systemFile {\n  path = \"/etc/repro-fixture/toggled.conf\"\n" &
  "  content = \"" & toggled & "\n\"\n" &
  (if toggledCopy: "  form = \"copy\"\n" else: "") & "}\n"

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
    proc kindOf(path: string): string =
      g.run("if [ -L " & path & " ]; then echo link; elif [ -f " & path &
            " ]; then echo file; else echo missing; fi").strip()
    proc statOf(path: string): string =
      g.run("stat -c '%a %U:%G' " & path).strip()
    proc linkTarget(path: string): string =
      g.run("readlink " & path & " || true").strip()
    proc staticHolds(text: string): bool =
      # The static tree is what /etc/repro/static resolves to now.
      g.exec("grep -rqF " & quoteShell(text) &
             " \"$(readlink -f /etc/repro/static)/\"").exitCode == 0

    # --- generation 1.
    let a1 = g.applyProfile(repro, "gen1", profileText(false))
    step("generation 1 applies", a1.exitCode == 0, a1.stdout & a1.stderr)
    step("an undeclared file is a link into the static tree",
         kindOf("/etc/repro-fixture/plain.conf") == "link" and
         linkTarget("/etc/repro-fixture/plain.conf").startsWith(
           "/etc/repro/static/"),
         kindOf("/etc/repro-fixture/plain.conf") & " " &
         linkTarget("/etc/repro-fixture/plain.conf"))
    step("vacuity guard: the static tree holds the undeclared file's bytes",
         staticHolds("plain"), g.run("ls -laR /etc/repro/static/ || true"))
    step("a declared-mode file is a regular file",
         kindOf("/etc/repro-fixture/secret.conf") == "file",
         kindOf("/etc/repro-fixture/secret.conf"))
    step("... 640 root:adm, exactly as declared",
         statOf("/etc/repro-fixture/secret.conf") == "640 root:adm",
         statOf("/etc/repro-fixture/secret.conf"))
    let other = g.exec("runuser -u nobody -- cat /etc/repro-fixture/secret.conf")
    step("... which another local user cannot read",
         other.exitCode != 0 and Secret notin other.stdout,
         "exit " & $other.exitCode & "\n" & other.stdout & other.stderr)
    step("... and whose bytes are nowhere in the world-readable static tree",
         not staticHolds(Secret), g.run("ls -laR /etc/repro/static/ || true"))
    step("a file to be toggled starts as a link",
         kindOf("/etc/repro-fixture/toggled.conf") == "link",
         kindOf("/etc/repro-fixture/toggled.conf"))

    # --- drift of the declared mode.
    discard g.run("chmod 0644 /etc/repro-fixture/secret.conf")
    let pl = g.planProfile(repro, "gen1", profileText(false))
    step("a chmod of the declared mode is drift the plan names",
         "secret.conf" in pl.stdout & pl.stderr and
         "update" in (pl.stdout & pl.stderr).toLowerAscii(),
         pl.stdout & pl.stderr)

    # --- generation 2: toggled.conf declares form = "copy".
    let a2 = g.applyProfile(repro, "gen2", profileText(true))
    step("generation 2 applies", a2.exitCode == 0, a2.stdout & a2.stderr)
    step("the declared mode is restored",
         statOf("/etc/repro-fixture/secret.conf") == "640 root:adm",
         statOf("/etc/repro-fixture/secret.conf"))
    step("a link whose resource now declares form = copy becomes a regular file",
         kindOf("/etc/repro-fixture/toggled.conf") == "file" and
         g.run("cat /etc/repro-fixture/toggled.conf") == "toggled\n",
         kindOf("/etc/repro-fixture/toggled.conf"))
    step("... and the new static tree does not carry it",
         not staticHolds("toggled"), g.run("ls -laR /etc/repro/static/ || true"))
    step("the undeclared file is still a link",
         kindOf("/etc/repro-fixture/plain.conf") == "link",
         kindOf("/etc/repro-fixture/plain.conf"))

    # --- generation 3: toggled.conf declares nothing again (copy -> link).
    let a3 = g.applyProfile(repro, "gen3", profileText(false))
    step("generation 3 applies", a3.exitCode == 0, a3.stdout & a3.stderr)
    step("a copy whose resource stops declaring form = copy, bytes unchanged, " &
         "stays a copy (nothing is written)",
         kindOf("/etc/repro-fixture/toggled.conf") == "file" and
         g.run("cat /etc/repro-fixture/toggled.conf") == "toggled\n",
         kindOf("/etc/repro-fixture/toggled.conf"))
    step("the declared-mode file is still 640 root:adm",
         statOf("/etc/repro-fixture/secret.conf") == "640 root:adm",
         statOf("/etc/repro-fixture/secret.conf"))
    # --- generation 4: new bytes for toggled.conf, nothing declared.
    let a4 = g.applyProfile(repro, "gen4", profileText(false, "toggled-v2"))
    step("generation 4 applies", a4.exitCode == 0, a4.stdout & a4.stderr)
    step("... and the changed undeclared file is a link again",
         kindOf("/etc/repro-fixture/toggled.conf") == "link" and
         g.run("cat /etc/repro-fixture/toggled.conf") == "toggled-v2\n",
         kindOf("/etc/repro-fixture/toggled.conf"))
    let vf = g.exec(repro & " system addon verify")
    step("verify reports no drift", vf.exitCode == 0, vf.stdout & vf.stderr)

    let un = g.exec(repro & " system addon uninstall")
    step("uninstall", un.exitCode == 0, un.stdout & un.stderr)
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

suite "e2e_addon_declared_mode_file_is_a_private_copy":
  test "a declared mode, group or copy form is a private copy on the host":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just e2e_addon_declared_mode_file_is_a_private_copy)")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": "e2e_addon_declared_mode_file_is_a_private_copy",
          "base": b.name, "arch": b.debArch,
          "backend": (if useIncus(): "incus" else: "qemu"),
          "mutation": mutation(), "reprobuild": gitHead(),
          "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord("e2e_addon_declared_mode_file_is_a_private_copy", record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
