## ReproOS-Agent-Harbor-Integration M3 verification
## ``e2e_agent_harbor_modifies_installed_source_package``.
##
## "A fixture application is located from its running binary, checked out,
## modified, built, tested, and previewed in isolation."
##
## Everything is real: the built ``./build/bin/repro`` builds and installs
## a from-source C package into a store, the installed binary runs, the
## agent host resolves it from ``/proc/<pid>/exe``, and every later step is
## a protocol plan the host checks and executes through
## ``ReprobuildBackend``, which runs ``repro`` again. The consent surface
## is driven by the test through the host's consent channel, because the
## subject is the host and backend, not the UI.
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

import std/[algorithm, os, osproc, sequtils, streams, strutils, tables, tempfiles, unittest]

import repro_agent_protocol
import repro_agent_backend
import repro_project_dsl/install_mirror_resolver

const ReprobuildRepoRoot = currentSourcePath().parentDir.parentDir.parentDir.parentDir
const reproBinary = ReprobuildRepoRoot / "build/bin/repro"

const greeterV1 = """
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
  if (argc > 1 && strcmp(argv[1], "serve") == 0) {
    while (getchar() != EOF) {}
    return 0;
  }
  puts("hello from greeter v1");
  return 0;
}
"""

const greeterV2 = greeterV1.replace("greeter v1", "greeter v2")

const InstallTarget = "install-mirror-greeter"
  ## The build edge that installs the package. A bare `repro build` builds
  ## every edge, the `test` action included, so a build would fail on a
  ## stale expectation; the agent builds and tests as separate steps.

const MirrorTools = ["repro-install-mirror-publish", "rm", "cp", "touch",
  "sed", "chmod", "find", "head", "od", "tr", "sort", "grep", "dirname",
  "basename", "wc", "patchelf", "readlink", "mktemp", "mv", "readelf", "cat"]

proc recipe(): string =
  result = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh
import repro_dsl_stdlib/types/package_result

package greeter:
  defaultToolProvisioning "path"

  versions:
    "1.0.0":
      sourceRevision = "local"

  uses:
    "sh"
    "mkdir"
    "cc"
"""
  for t in MirrorTools:
    result.add "    \"" & t & "\"\n"
  result.add """

  build:
    let compile = shell(
      command = "mkdir -p build/out/usr/bin && cc -O2 -o build/out/usr/bin/greeter src/main.c",
      actionId = "greeter.build.compile",
      extraOutputs = @["build/out/usr/bin/greeter"])
    appendRegisteredActionToolIdentityRefs(compile.id, ["mkdir", "cc"])
    emitInstallTreeMirror(compile, "build", "out", "greeter", "shell")
    let selftest = shell(
      command = "build/out/usr/bin/greeter > build/selftest.out && grep -qxF \"$(cat tests/expected.txt)\" build/selftest.out",
      actionId = "test", after = @[compile],
      extraInputs = @["tests/expected.txt"],
      extraOutputs = @["build/selftest.out"])
    appendRegisteredActionToolIdentityRefs(selftest.id, ["grep", "cat"])
"""

proc cleanup(dir: string) =
  discard execCmd("chmod -R u+w " & quoteShell(dir))
  removeDir(dir)

proc op(kind: OperationKind; target: string;
        args: openArray[(string, string)] = []): Operation =
  result = Operation(kind: kind, target: target)
  for (n, v) in args:
    result.args.add OpArg(name: n, value: v)
  result.args = result.args.sortedByIt(it.name)

when not defined(linux):
  echo "[SKIP] e2e_agent_harbor_modifies_installed_source_package: Linux only"
else:
  if not fileExists(reproBinary) or findExe("cc").len == 0:
    echo "[SKIP] e2e_agent_harbor_modifies_installed_source_package: " &
      "needs " & reproBinary & " and cc"
  else:
    suite "M3 — Agent Harbor modifies an installed source package":
      let tmp = createTempDir("agent-e2e-", "")
      let catalog = tmp / "catalog"
      let store = tmp / "store"
      let previewStore = tmp / "preview-store"
      let recipeDir = catalog / "greeter"
      createDir(recipeDir / "src")
      createDir(recipeDir / "tests")
      writeFile(recipeDir / "repro.nim", recipe())
      writeFile(recipeDir / "src" / "main.c", greeterV1)
      writeFile(recipeDir / "tests" / "expected.txt", "hello from greeter v1\n")
      # The repro binary's directory carries repro-install-mirror-publish,
      # which the install mirror runs by name.
      let toolPath = reproBinary.parentDir & ":" & getEnv("PATH")
      let env = [("PATH", toolPath), ("REPRO_STORE_ROOT", store),
                 ("REPRO_INSTALL_MIRROR_MODE", "hashed"),
                 ("REPRO_DAEMON", "off")]

      test "the fixture installs from source into the store":
        var cmd = "cd " & quoteShell(recipeDir) & " && env"
        for (k, v) in env:
          cmd.add " " & k & "=" & quoteShell(v)
        cmd.add " " & quoteShell(reproBinary) & " build"
        let (output, code) = execCmdEx(cmd)
        checkpoint output
        check code == 0
        check readRealizationInfoFile(catalog, "greeter").storeRelativePath.len > 0

      let installedRel = readRealizationInfoFile(catalog, "greeter").storeRelativePath
      let installedExe = store / installedRel / "usr" / "bin" / "greeter"
      let installedRecipeTree = recipeTreeDigest(recipeDir)

      let backend = newReprobuildBackend(reproBinary, store, @[catalog],
                                         previewStore, timeoutSeconds = 900)
      backend.extraEnv = @[("PATH", toolPath), ("REPRO_DAEMON", "off")]
      let host = newHost(backend, tmp / "workspaces")
      let consent = newConnection(chConsent)
      discard host.hello(consent, ProtocolVersion, {low(Family) .. high(Family)})
      let (sid, secret) = host.createSession(consent, "agent-harbor", @[
        parseGrant("context.active-app"), parseGrant("workspace.create:greeter"),
        parseGrant("source.read:greeter"), parseGrant("source.write:greeter"),
        parseGrant("build.run:greeter"), parseGrant("test.run:greeter"),
        parseGrant("preview.run:greeter")])
      let agent = newConnection(chProvider)
      discard host.hello(agent, ProtocolVersion, {low(Family) .. high(Family)})
      host.attach(agent, sid, secret)

      proc runPlan(intent: Intent; ops: seq[Operation];
                   declared: seq[string]): seq[OpResult] =
        let r = host.submitPlan(agent, Plan(sessionId: sid,
          intentId: intentId(intent), baseGeneration: "",
          operations: ops, declaredCapabilities: declared.mapIt(parseGrant(it))))
        check r.approvalRequired.len == 0
        host.execute(agent, r.planId.hex).results

      var ws = ""

      test "the running binary is located and checked out":
        # The user is running the installed greeter.
        let running = startProcess(installedExe, args = ["serve"],
                                   options = {})
        defer:
          running.inputStream.close()
          discard running.waitForExit()
          running.close()
        backend.activeAppPath = expandSymlink("/proc/" & $running.processID & "/exe")
        let intent = host.captureIntent(consent, sid,
          "make greeter say v2", @[parseGrant("context.active-app")])
        let rs = runPlan(intent, @[op(okOwnershipResolve, ActiveAppTarget),
                                   op(okCheckoutCreate, "greeter")],
                         @["context.active-app", "workspace.create:greeter"])
        check rs.mapIt(it.status) == @[osCompleted, osCompleted]
        checkpoint rs[0].output
        check "package=greeter\n" in rs[0].output
        check "prefix-path=" & expandFilename(store / installedRel) & "\n" in
          rs[0].output or "prefix-path=" & store / installedRel & "\n" in rs[0].output
        check "recipe-tree=" & installedRecipeTree & "\n" in rs[0].output
        ws = rs[1].detail
        check host.workspaces.hasKey(ws)

      let intent = host.captureIntent(consent, sid, "make greeter say v2")

      test "the unmodified checkout rebuilds to the installed output":
        let rs = runPlan(intent, @[op(okBuildRun, ws, {"target": InstallTarget})], @["build.run:greeter"])
        checkpoint rs[0].output
        check rs[0].status == osCompleted
        check rs[0].detail == installedRel

      test "an edit with a stale test fails the test, then passes":
        let edit = runPlan(intent,
          @[op(okSourceWrite, ws, {"path": "greeter/src/main.c",
                                   "content": greeterV2}),
            op(okBuildRun, ws, {"target": InstallTarget}), op(okTestRun, ws)],
          @["source.write:greeter", "build.run:greeter", "test.run:greeter"])
        checkpoint edit[1].output & "\n" & edit[2].output
        check edit[0].status == osCompleted
        check edit[1].status == osCompleted
        check edit[1].detail != installedRel
        check edit[2].status == osFailed
        let fixed = runPlan(intent,
          @[op(okSourceWrite, ws, {"path": "greeter/tests/expected.txt",
                                   "content": "hello from greeter v2\n"}),
            op(okTestRun, ws)],
          @["source.write:greeter", "test.run:greeter"])
        checkpoint fixed[^1].output
        check fixed.mapIt(it.status) == @[osCompleted, osCompleted]

      test "the preview runs the change in isolation and the diff is the edit":
        let rs = runPlan(intent,
          @[op(okPreviewStart, ws, {"executable": "usr/bin/greeter"}),
            op(okSourceDiff, ws)],
          @["preview.run:greeter", "source.read:greeter"])
        checkpoint rs[0].detail & "\n" & rs[0].output
        check rs[0].status == osCompleted
        check rs[0].output.strip == "hello from greeter v2"
        check ("prefix=" & installedRel) notin rs[0].detail
        let d = rs[1].output
        check "--- a/greeter/src/main.c" in d
        check "+  puts(\"hello from greeter v2\");" in d
        check "+hello from greeter v2" in d
        check d.count("diff --git") == 2

      test "nothing installed changed":
        check execProcess(installedExe).strip == "hello from greeter v1"
        check readRealizationInfoFile(catalog, "greeter").storeRelativePath ==
          installedRel
        check recipeTreeDigest(recipeDir) == installedRecipeTree
        # Only the installed package is in the installed store.
        var prefixes: seq[string]
        for kind, p in walkDir(store / "prefixes" / "greeter"):
          prefixes.add p.extractFilename
        check prefixes == @[installedRel.extractFilename]
        # The change's outputs went to the preview store.
        check dirExists(previewStore / "prefixes" / "greeter")

      cleanup(tmp)
