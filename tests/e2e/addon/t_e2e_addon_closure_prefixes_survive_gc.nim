## Gate ``e2e_addon_closure_prefixes_survive_gc``.
##
## A unit bound to an apt closure (its rendered file binds the closure
## prefix read-only, ``BindReadOnlyPaths=``) runs from store prefixes the
## switch did not write as the generation's static tree: the closure's
## union prefix and one prefix per member ``.deb``. The switch attaches them
## to the ``addon-pending`` root in step 1 and the committed generation's
## root takes them over in step 9 (spec §7.2; threat model G38). The
## generation's ledger names only the static tree, so that hand-over is the
## closures' only route to a root, and this gate is what holds it.
##
## Three generations on one host, each a disabled unit bound to a fixture
## closure (the switch realises the closure in step 1 and never starts the
## unit, whose ``/usr`` the binding replaces with the closure's):
##
##   1. ``repro-g38-old.service`` bound to closure OLD;
##   2. ``repro-g38-new.service`` bound to closure NEW (OLD's unit removed);
##   3. the same unit, changed, still bound to NEW.
##
## Retention then keeps only the current and the previous generation and
## ``repro store gc --grace-seconds 0`` runs. Afterwards NEW's union prefix
## and its member's prefix are still in the store, and the current unit's
## rendered file binds that union prefix.
##
## Vacuity guard: the same collector removes OLD's union and member
## prefixes, which only generation 1 held -- so closure prefixes are
## collectable at all, and NEW survived because a root holds it.
##
## Falsifying mutation ``closure-prefixes-unrooted`` (``REPRO_ADDON_MUTATION``):
## the switch skips attaching its closures to the pending root, no
## generation root holds NEW, and gc collects it: red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``
## (``just e2e_addon_closure_prefixes_survive_gc``). Bases:
## ``REPRO_ADDON_BASES`` (default: the amd64 matrix).
##
## *Mocking.* None of behaviour. The fixture ``.deb`` files are built here
## and seeded into the realiser's ``.deb`` cache, where it verifies them
## against the lock exactly as it verifies a download, so the lock's
## archive URL is never contacted. The store, the switch, retention and the
## collector are the real add-on binary's on a real distribution image.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip

import repro_dsl_stdlib/packages/apt_closure

import ./addon_testbed
import ./deb_fixture_support

const
  Gate = "e2e_addon_closure_prefixes_survive_gc"
  OldUnit = "repro-g38-old.service"
  NewUnit = "repro-g38-new.service"

proc unitBlock(unit, description, lockText: string): string =
  "systemd.systemUnit {\n  name = \"" & unit & "\"\n" &
  "  content = \"[Unit]\nDescription=" & description & "\n[Service]\n" &
    "Type=oneshot\nExecStart=/usr/bin/true\n\"\n" &
  "  enabled = false\n" &
  "  aptClosureLock = \"" & lockText & "\"\n}\n"

proc seedCache(g: Guest; lock: AptClosureLock; debPath: string) =
  discard g.run("mkdir -p " & AddOnAptDebCacheDir & " && chmod 0700 " &
                AddOnAptDebCacheDir)
  g.copyTo(debPath, AddOnAptDebCacheDir & "/" & lock.debs[0].sha256 & ".deb")

proc fixtureDeb(work, name: string): tuple[path: string; lock: AptClosureLock] =
  result.path = work / (name & ".deb")
  writeDeb(result.path, @[dir("./"), dir("./usr/"), dir("./usr/share/"),
    dir("./usr/share/" & name & "/"),
    ("./usr/share/" & name & "/ok.txt", '0', 0o644, name & "\n", "")])
  result.lock = fixtureLock(name, result.path)

proc present(g: Guest; path: string): bool =
  g.exec("test -d " & quoteShell(path)).exitCode == 0

proc runBase(b: BaseImage; record: JsonNode; work: string): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    let oldF = fixtureDeb(work, "g38-old")
    let newF = fixtureDeb(work, "g38-new")
    let oldText = renderAptClosureLock(oldF.lock)
    let newText = renderAptClosureLock(newF.lock)
    let oldUnion = aptClosurePrefixPath(AddOnSystemStoreRoot, oldF.lock)
    let oldMember = aptDebPrefixPath(AddOnSystemStoreRoot, oldF.lock.debs[0])
    let newUnion = aptClosurePrefixPath(AddOnSystemStoreRoot, newF.lock)
    let newMember = aptDebPrefixPath(AddOnSystemStoreRoot, newF.lock.debs[0])
    record["prefixes"] = %*{"oldUnion": oldUnion, "oldMember": oldMember,
                            "newUnion": newUnion, "newMember": newMember}

    g = newGuest(b)
    g.boot()
    g.prepareBase()
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    if not g.bootstrapAddon(repro, step): return fails

    g.seedCache(oldF.lock, oldF.path)
    g.seedCache(newF.lock, newF.path)
    let a1 = g.applyProfile(repro, "g38-1",
      unitBlock(OldUnit, "G38 old", oldText))
    step("generation 1 (closure OLD) applies", a1.exitCode == 0,
         a1.stdout & a1.stderr)
    let a2 = g.applyProfile(repro, "g38-2",
      unitBlock(NewUnit, "G38 new", newText))
    step("generation 2 (closure NEW) applies", a2.exitCode == 0,
         a2.stdout & a2.stderr)
    let a3 = g.applyProfile(repro, "g38-3",
      unitBlock(NewUnit, "G38 new, changed", newText))
    step("generation 3 (closure NEW, unit changed) applies",
         a3.exitCode == 0, a3.stdout & a3.stderr)
    for (label, p) in [("OLD union", oldUnion), ("OLD member", oldMember),
                       ("NEW union", newUnion), ("NEW member", newMember)]:
      step(label & " prefix realised before gc", g.present(p), p)

    let ret = g.exec(repro &
      " system addon retention --keep-generations 0 --keep-days 0")
    step("retention keeps only the current and the previous generation",
         ret.exitCode == 0, ret.stdout & ret.stderr)
    let gc = g.exec(repro & " store gc --grace-seconds 0")
    step("repro store gc runs", gc.exitCode == 0, gc.stdout & gc.stderr)
    record["gc"] = %(gc.stdout & gc.stderr)

    # Vacuity guard: closure prefixes only an expired generation held go.
    step("gc collects OLD's union prefix (held only by generation 1)",
         not g.present(oldUnion), oldUnion)
    step("gc collects OLD's member prefix (held only by generation 1)",
         not g.present(oldMember), oldMember)
    # The property: what the current generation's unit binds stays.
    step("NEW's union prefix survives gc", g.present(newUnion), newUnion)
    step("NEW's member prefix survives gc", g.present(newMember), newMember)
    let rendered = g.run("cat /etc/systemd/system/" & NewUnit & " 2>&1")
    record["renderedUnit"] = %rendered
    step("the current unit binds NEW's union prefix read-only",
         "BindReadOnlyPaths=" in rendered and newUnion in rendered, rendered)
    step("the bound closure still carries its file",
         g.run("cat " & newUnion & "/usr/share/g38-new/ok.txt 2>&1").strip() ==
           "g38-new", newUnion)
    let v = g.exec(repro & " system addon verify")
    step("verify is ok after gc", v.exitCode == 0, v.stdout & v.stderr)
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

suite Gate:
  test "a closure the current generation binds survives repro store gc":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      let work = getTempDir() / ("repro-g38-gc-" & $getCurrentProcessId())
      createDir(work)
      defer: removeDir(work)
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": Gate, "base": b.name, "arch": b.debArch,
          "backend": (if useIncus(): "incus" else: "qemu"),
          "mutation": mutation(), "reprobuild": gitHead(),
          "started": $now().utc}
        let f = runBase(b, record, work)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord(Gate, record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
