## ReproOS-Agent-Harbor-Integration M3 verification
## ``e2e_agent_harbor_modifies_installed_source_package``.
##
## "A fixture application is located from its running binary, checked out,
## modified, built, tested, and previewed in isolation."
##
## Everything is real: the built ``./build/bin/repro`` builds and installs
## a from-source C package into a store (`agent_harbor_fixture`), the
## installed binary runs, the agent host resolves it from
## ``/proc/<pid>/exe``, and every later step is a protocol plan the host
## checks and executes through ``ReprobuildBackend``, which runs ``repro``
## again. The consent surface is driven by the test through the host's
## consent channel, because the subject is the host and backend, not the UI.
##
## What it shows, in order:
##   1. the running binary resolves to the ``greeter`` recipe and its prefix;
##   2. building the UNMODIFIED checkout reproduces the installed prefix's
##      realization hash, so the workspace source matches the installed
##      output;
##   3. a source edit with a stale test expectation fails ``test.run``, and
##      with the expectation updated passes it;
##   4. the preview runs the changed binary from the preview store with an
##      isolated HOME, and the diff is exactly the edit;
##   5. the installed prefix, the installed binary's behaviour and the
##      catalog recipe are unchanged, and nothing was published into the
##      installed store.
##
## Skip rule: Linux only (``/proc/<pid>/exe``), and ``./build/bin/repro``
## plus ``cc`` must exist.

import std/[os, osproc, sequtils, streams, strutils, tables, unittest]

import repro_agent_protocol
import repro_agent_backend
import repro_project_dsl/install_mirror_resolver

import ./agent_harbor_fixture

if not fixtureRunnable():
  echo "[SKIP] e2e_agent_harbor_modifies_installed_source_package: needs " &
    "Linux, " & reproBinary & " and cc"
else:
  suite "M3 — Agent Harbor modifies an installed source package":
    let f = newFixture("m3", @["context.active-app",
      "workspace.create:greeter", "source.read:greeter",
      "source.write:greeter", "build.run:greeter", "test.run:greeter",
      "preview.run:greeter"])
    var ws = ""

    test "the fixture installed from source into the store":
      check f.installedRel.len > 0
      check exeOutput(f.installedExe) == "hello from greeter v1"

    test "the running binary is located and checked out":
      # The user is running the installed greeter.
      let running = startProcess(f.installedExe, args = ["serve"], options = {})
      defer:
        running.inputStream.close()
        discard running.waitForExit()
        running.close()
      f.backend.activeAppPath = expandSymlink("/proc/" & $running.processID &
                                              "/exe")
      let intent = f.host.captureIntent(f.consent, f.sid,
        "make greeter say v2", @[parseGrant("context.active-app")])
      let rs = f.runPlan(intent, @[op(okOwnershipResolve, ActiveAppTarget),
                                   op(okCheckoutCreate, "greeter")],
                         @["context.active-app", "workspace.create:greeter"])
      check rs.mapIt(it.status) == @[osCompleted, osCompleted]
      checkpoint rs[0].output
      check "package=greeter\n" in rs[0].output
      check "prefix-path=" & f.store / f.installedRel & "\n" in rs[0].output
      check "recipe-tree=" & f.installedRecipeTree & "\n" in rs[0].output
      ws = rs[1].detail
      check f.host.workspaces.hasKey(ws)

    let intent = f.host.captureIntent(f.consent, f.sid, "make greeter say v2")

    test "the unmodified checkout rebuilds to the installed output":
      let rs = f.runPlan(intent, @[op(okBuildRun, ws, {"target": InstallTarget})],
                         @["build.run:greeter"])
      checkpoint rs[0].output
      check rs[0].status == osCompleted
      check rs[0].detail == f.installedRel

    test "an edit with a stale test fails the test, then passes":
      let edit = f.runPlan(intent,
        @[op(okSourceWrite, ws, {"path": "greeter/src/main.c",
                                 "content": greeterV2}),
          op(okBuildRun, ws, {"target": InstallTarget}), op(okTestRun, ws)],
        @["source.write:greeter", "build.run:greeter", "test.run:greeter"])
      checkpoint edit[1].output & "\n" & edit[2].output
      check edit[0].status == osCompleted
      check edit[1].status == osCompleted
      check edit[1].detail != f.installedRel
      check edit[2].status == osFailed
      let fixed = f.runPlan(intent,
        @[op(okSourceWrite, ws, {"path": "greeter/tests/expected.txt",
                                 "content": "hello from greeter v2\n"}),
          op(okTestRun, ws)],
        @["source.write:greeter", "test.run:greeter"])
      checkpoint fixed[^1].output
      check fixed.mapIt(it.status) == @[osCompleted, osCompleted]

    test "the preview runs the change in isolation and the diff is the edit":
      let rs = f.runPlan(intent,
        @[op(okPreviewStart, ws, {"executable": "usr/bin/greeter"}),
          op(okSourceDiff, ws)],
        @["preview.run:greeter", "source.read:greeter"])
      checkpoint rs[0].detail & "\n" & rs[0].output
      check rs[0].status == osCompleted
      check rs[0].output.strip == "hello from greeter v2"
      check "strategy=restart" in rs[0].detail
      check ("prefix=" & f.installedRel) notin rs[0].detail
      let d = rs[1].output
      check "--- a/greeter/src/main.c" in d
      check "+  puts(\"hello from greeter v2\");" in d
      check "+hello from greeter v2" in d
      check d.count("diff --git") == 2

    test "nothing installed changed":
      check exeOutput(f.installedExe) == "hello from greeter v1"
      check readRealizationInfoFile(f.catalog, "greeter").storeRelativePath ==
        f.installedRel
      check recipeTreeDigest(f.recipeDir) == f.installedRecipeTree
      # Only the installed package is in the installed store.
      var prefixes: seq[string]
      for kind, p in walkDir(f.store / "prefixes" / "greeter"):
        prefixes.add p.extractFilename
      check prefixes == @[f.installedRel.extractFilename]
      # The change's outputs went to the preview store.
      check dirExists(f.previewStore / "prefixes" / "greeter")

    cleanup(f.tmp)
