## W2 — end to end: ``repro exec`` runs the PINNED cross-repo producer binary,
## not an ambient binary of the same name; and when the pin is not materialized
## it says so out loud instead of running the ambient one in silence.
##
## Spec: ``Cross-Repo-Source-Consumption.md`` §4.2 (producer graph load +
## splice, executable channel). Milestone:
## ``Windows-Cacheable-Builds-Session-Residuals.milestones.org`` §W2.
##
## This is the black-box counterpart to
## ``libs/repro_cli_support/tests/t_w2_dev_env_producer_pin_binding.nim``,
## which pins the classification. Here the question is the one a developer
## actually asks: *which binary ran?*
##
## The fixture is deliberately the SC-2 fixture
## (``tests/integration/t_sc_executable_producer_edge_spliced_and_on_path.nim``)
## with the consuming BUILD ACTION replaced by a dev-env ACTIVATION, because
## the whole of W2 is the observation that those two surfaces answered the same
## declaration differently:
##
##   <scratch>/
##     prod/       producer project; its build edge writes build/bin/prod,
##                 which echoes a unique stamp
##     consumer/   ``uses: "prod"`` + a ``devEnv:`` block
##       .repro/develop-overrides.toml   prod -> ../prod
##     decoy/      an executable named ``prod`` echoing a DIFFERENT stamp,
##                 placed on the ambient PATH
##
## Three phases, in order, on one fixture:
##
##   1. **Cold — the producer has never been built.** ``repro exec`` must
##      still give the developer a working command (exit 0), must NOT start a
##      build of the producer's graph (asserted on the filesystem: the
##      producer's ``build/`` must still not exist afterwards), and must WARN,
##      naming the ambient binary that answers the name instead. Before W2
##      this phase was silent — the decoy ran, exit 0, no output. That silence
##      is the defect, and this phase is the regression test for it.
##
##   2. **Bound — after ``repro build`` materialized the producer.** The same
##      ``repro exec`` now runs the PRODUCER's stamp, not the decoy's, and
##      exports ``REPRO_DEV_ENV_PRODUCER_PINS`` naming the bound directory.
##      No warning: the pin did what it was asked. This is the user-facing
##      goal — "compiled once and cached", then used by the workspace's own
##      shell.
##
##   3. **Staleness — the producer output is removed while the dev-env
##      artifact is unchanged.** The RBDE artifact's bytes are captured before
##      and after and asserted IDENTICAL (nothing about the producer is part
##      of its cache key, by design), yet the activation flips back to the
##      decoy and the warning returns. This is the assertion that the binding
##      is re-derived at every activation rather than cached — the property
##      that makes "a shell can hand you a stale driver indefinitely"
##      impossible here.
##
## Interleaved with phases 1 and 2, on the same fixture, are the two
## PROMPT-TIME hook surfaces — ``__repro-native-shell-activate`` (what ``repro
## hooks ensure --shell bash|zsh|fish|powershell`` installs) and
## ``__repro-direnv-activate`` (``--shell-direnv``). They were fully silent:
## no notice, no bin dir, bound pin or not. They now REPORT and deliberately do
## not BIND, and both halves are asserted, cold and bound. Their stdout and
## stderr are kept apart (``runSplit``) precisely so "it said so" and "it did
## not apply it" can be checked independently rather than inferred from one
## merged blob.
##
## Falsifiability: caching the producer ops inside the RBDE artifact passes
## phases 1 and 2 and FAILS phase 3 (the flip never happens). Making the
## activation build the producer passes phases 2 and 3 and fails phase 1's
## filesystem assertion (``prod/build`` appears). Dropping the notice passes
## phases 2 and 3 and fails phase 1's stderr assertion. Removing the report
## call from BOTH hook helpers fails exactly the eight hook stderr assertions
## (four cold, four bound) and nothing else in this file — reproduced, and the
## session case below stays green. Making either hook BIND fails its
## ``not ... contains(prodRoot / "build" / "bin")``. Which of the two helpers
## went silent is discriminated by the structural audit rather than here.
##
## The SECOND case in this file covers a different activation surface for the
## same declaration: a ``repro dev --foreground`` SESSION. It is here rather
## than in the dev-session suite because the property is W2's, and because the
## defect it pins was a split-brain between two arms of one verb. ``repro dev``
## and ``repro up`` build their supervisor config once and then either run it
## in-process (``--foreground``) or serialise it to CLI args for a detached
## child that REBUILDS it. Only the child's rebuild set the producer resolver,
## so the detached arm bound pins and printed notices while ``--foreground``
## did neither — same verb, same flags, same workspace, different answer, no
## diagnostic. The resolver is now a REQUIRED PARAMETER of
## ``runDevSessionSupervisor`` rather than an optional config field, so the two
## arms cannot drift again without a compile error; this case is the
## behavioural half of that, and
## ``libs/repro_cli_support/tests/t_w2_activation_surfaces_declare_producer_ops.nim``
## is the structural half.
##
## That case asserts the notice while the supervisor is STILL RUNNING, by
## redirecting its stderr to a file and polling. That is not harness taste: on
## Windows a redirected ``stderr`` is fully buffered, so a session that runs
## for hours would hold its "this pin is not in effect" warning for hours and
## a session that is killed rather than stopped would lose it entirely — and
## a warning nobody can see until the session ends is the same silence W2
## exists to remove, arriving by a slower route. Reading a pipe after stopping
## the session cannot tell those three apart; this shape can. Falsifiability:
## dropping the ``stderr`` flush in ``emitDevEnvProducerNotices`` fails
## ``sawNoticeLive`` and NOTHING else in this file — not the pin assertions
## (they read a file the watch task wrote) and not even the post-stop notice
## assertions, because a buffer does flush at exit. Reproduced.
##
## Hermetic: every path in a fresh tempdir; the dev-env engine's action cache
## is project-local (``<outDir>/build-engine-cache``) by construction, and the
## producer build is pointed at a scratch ``--action-cache-root``. Nothing
## touches $HOME.

import std/[os, osproc, streams, strutils, unittest]

import repro_test_support

const
  producerStamp = "W2-PRODUCER-STAMP-9f2c1a"
  decoyStamp = "W2-DECOY-AMBIENT-4b7e2d"

const producerRepro = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package prod:
  defaultToolProvisioning "path"

  uses:
    "sh"

  executable prod:
    name: "prod"

  build:
    discard shell(
      command = "mkdir -p build/bin && " &
        "printf '#!/bin/sh\necho """ & producerStamp & """\n' > build/bin/prod && " &
        "chmod +x build/bin/prod",
      actionId = "prod.build.prod",
      extraOutputs = @["build/bin/prod"])
"""

# The consumer declares the producer in ``uses:`` and has a ``devEnv:`` block.
# It declares NO build action at all: the point is that the DEV-ENV surface
# honours the declaration, with no build of the consumer involved.
const consumerRepro = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package consumer:
  defaultToolProvisioning "path"

  uses:
    "sh"
    "prod"

  devEnv:
    activity "default"
    setEnv "W2_FIXTURE", "present"
"""

const developOverrides = """
schema = "reprobuild.workspace.develop-overrides.v1"

[[override]]
package = "prod"
local_path = "../prod"
state = "editable"
created_at = "2026-07-02T00:00:00Z"
"""

proc q(value: string): string = quoteShell(value)

proc requireShell(): string =
  let shBin = findExe("sh")
  if shBin.len == 0:
    raise newException(OSError,
      "this test drives `repro exec -- sh -c ...` so a POSIX `sh` must be on " &
      "PATH (Git for Windows provides one at <git>/usr/bin/sh.exe)")
  shBin

proc runSplit(exe: string; args: openArray[string]; cwd: string):
    tuple[code: int; outText, errText: string] =
  ## Like ``run`` but keeps the two streams APART, which the hook surfaces
  ## require: their stdout is a script the shell ``eval``s and their stderr is
  ## the producer notice. Asserting "the notice is present AND the script does
  ## not contain the bin dir" is only possible if the two are not merged.
  ##
  ## Deliberately NOT ``execCmdEx(... & " 2>file")``: on Windows Nim's
  ## ``poEvalCommand`` hands the command line to ``CreateProcess`` directly and
  ## never to ``cmd.exe``, so a redirection operator arrives at the child as a
  ## literal argv entry — which the CLI then rejects as an unexpected
  ## argument. That failure mode is silent about its cause (exit 1, both
  ## streams empty), so it is worth the two lines to avoid.
  ##
  ## Both streams are drained after exit rather than concurrently. Safe here
  ## because both payloads are a couple of kilobytes, far under the pipe
  ## buffer; a surface that could emit more would need a reader per stream.
  var process = startProcess(exe, args = @args, workingDir = cwd,
    options = {poUsePath})
  let code = process.waitForExit()
  let outText =
    if process.outputStream != nil: process.outputStream.readAll() else: ""
  let errText =
    if process.errorStream != nil: process.errorStream.readAll() else: ""
  process.close()
  (code: code, outText: outText, errText: errText)

proc run(command, cwd: string): tuple[code: int; output: string] =
  ## ``execCmdEx`` merges stderr into the returned output, which is what this
  ## test wants: the producer notice goes to stderr and the command's own
  ## output to stdout, and both are asserted.
  let res = execCmdEx(command, options = {poUsePath, poStdErrToStdOut},
    workingDir = cwd)
  (code: res.exitCode, output: res.output)

suite "e2e_dev_env_binds_materialized_producer":

  test "dev env binds a materialized producer and is loud when it cannot":
    discard requireShell()
    let repoRoot = getCurrentDir()
    let reproAbs = requireBinary(
      repoRoot / "build" / "bin" / addFileExt("repro", ExeExt),
      "reprobuild.apps.repro")

    let scratch = getTempDir() / "w2e2e-" & $getCurrentProcessId()
    removeDir(scratch)
    createDir(scratch)
    defer: removeDirEventually(scratch)

    let prodRoot = absolutePath(scratch / "prod")
    let consumerRoot = absolutePath(scratch / "consumer")
    let decoyDir = absolutePath(scratch / "decoy")
    let cacheRoot = absolutePath(scratch / "action-cache-root")
    createDir(prodRoot)
    createDir(consumerRoot)
    createDir(consumerRoot / ".repro")
    createDir(decoyDir)
    createDir(cacheRoot)
    writeFile(prodRoot / "repro.nim", producerRepro)
    writeFile(consumerRoot / "repro.nim", consumerRepro)
    writeFile(consumerRoot / ".repro" / "develop-overrides.toml",
      developOverrides)

    # The decoy: an executable named ``prod`` on the ambient PATH, echoing a
    # DIFFERENT stamp. Every phase below distinguishes "the pin ran" from "the
    # ambient tool ran" by which stamp comes back, so no phase can pass by
    # accident.
    writeFile(decoyDir / "prod",
      "#!/bin/sh\necho " & decoyStamp & "\n")
    when not defined(windows):
      inclFilePermissions(decoyDir / "prod",
        {fpUserExec, fpGroupExec, fpOthersExec})
    when defined(windows):
      # ``findExe`` (which the notice uses to name what will answer the name)
      # only sees PATHEXT extensions on Windows; ``sh`` only runs the
      # extensionless script. Both spellings sit in the same directory, so the
      # assertions below key on the DIRECTORY rather than on either filename.
      writeFile(decoyDir / "prod.bat", "@echo " & decoyStamp & "\r\n")

    let savedPath = getEnv("PATH")
    putEnv("PATH", decoyDir & $PathSep & savedPath)
    defer: putEnv("PATH", savedPath)

    let probe = q(reproAbs) & " exec -- sh -c " &
      q("command -v prod; prod; echo PINS=[$REPRO_DEV_ENV_PRODUCER_PINS]")

    # ---- Phase 1: cold. Nothing built; the pin cannot be honoured. ---------
    let producerBinary = prodRoot / "build" / "bin" / "prod"
    check not fileExists(producerBinary)

    checkpoint("phase 1: " & probe)
    let cold = run(probe, consumerRoot)
    checkpoint("phase 1 exit=" & $cold.code)
    checkpoint(cold.output)

    # The developer keeps a working command — a pin that cannot be honoured
    # must not cost them the environment.
    check cold.code == 0
    # ...but it is NOT silent, and the notice names the ambient answer.
    check cold.output.contains("cross-repo producer")
    check cold.output.contains("repro build")
    check cold.output.contains(decoyDir)
    # ...and the ambient binary is what actually ran, which is precisely why
    # the notice has to exist.
    check cold.output.contains(decoyStamp)
    check not cold.output.contains(producerStamp)
    # No pin was exported.
    check cold.output.contains("PINS=[]")
    # The activation started NO build of the producer. This is the cold-cache
    # safety property: an interactive activation never enters the producer's
    # graph.
    checkpoint("producer build dir exists after cold activation: " &
      $dirExists(prodRoot / "build"))
    check not dirExists(prodRoot / "build")

    # ---- The prompt-time hook surfaces, cold. -----------------------------
    # ``repro hooks ensure --shell bash|zsh|fish|powershell`` installs an rc
    # snippet that calls ``__repro-native-shell-activate`` on every ``cd`` /
    # ``chpwd`` / prompt, and ``--shell-direnv`` installs an ``.envrc`` block
    # that calls ``__repro-direnv-activate``. They are the surface a developer
    # who set up the hooks spends all day inside, and they were the LAST place
    # a declared pin could still go unmentioned: before this they emitted no
    # notice at all, bound pin or not.
    let nativeArgs = @["__repro-native-shell-activate", consumerRoot,
      "--shell", "bash"]
    let direnvArgs = @["__repro-direnv-activate", consumerRoot]

    checkpoint("cold native hook: " & nativeArgs.join(" "))
    let coldNative = runSplit(reproAbs, nativeArgs, consumerRoot)
    checkpoint("cold native exit=" & $coldNative.code)
    checkpoint("stderr: " & coldNative.errText)
    check coldNative.code == 0
    check coldNative.errText.contains("cross-repo producer")
    check coldNative.errText.contains(decoyDir)

    checkpoint("cold direnv hook: " & direnvArgs.join(" "))
    let coldDirenv = runSplit(reproAbs, direnvArgs, consumerRoot)
    checkpoint("cold direnv exit=" & $coldDirenv.code)
    checkpoint("stderr: " & coldDirenv.errText)
    check coldDirenv.code == 0
    check coldDirenv.errText.contains("cross-repo producer")
    check coldDirenv.errText.contains(decoyDir)

    # ---- Phase 2: build the producer, then activate again. ----------------
    let buildCmd = q(reproAbs) & " build" &
      " --tool-provisioning=path --daemon=off --log=quiet" &
      " --progress=quiet --measure=none" &
      " --action-cache-root=" & q(cacheRoot)
    checkpoint("phase 2 build: " & buildCmd)
    let built = run(buildCmd, prodRoot)
    checkpoint("phase 2 build exit=" & $built.code)
    checkpoint(built.output)
    check built.code == 0
    check fileExists(producerBinary)

    checkpoint("phase 2: " & probe)
    let bound = run(probe, consumerRoot)
    checkpoint("phase 2 exit=" & $bound.code)
    checkpoint(bound.output)
    check bound.code == 0
    # The PIN ran, not the decoy — the bare name now resolves to the
    # materialized producer output even though the decoy is still earlier in
    # the inherited PATH.
    check bound.output.contains(producerStamp)
    check not bound.output.contains(decoyStamp)
    # The binding is stated in the environment, not only inferable from PATH.
    check bound.output.contains("PINS=[prod=")
    # A pin that worked says nothing.
    check not bound.output.contains("cross-repo producer")

    # ``repro shell --print-env`` RENDERS the activation rather than applying
    # it, and that is a different arm of the code (``renderDevEnvArtifact``
    # vs ``activatedEnvironment``). A pin bound in one and missing from the
    # other would mean a developer's shell and the script they were shown
    # disagree, so it is asserted rather than assumed.
    let printCmd = q(reproAbs) & " shell --print-env=posix"
    checkpoint("phase 2 print-env: " & printCmd)
    let printed = run(printCmd, consumerRoot)
    checkpoint("phase 2 print-env exit=" & $printed.code)
    checkpoint(printed.output)
    check printed.code == 0
    check printed.output.contains(prodRoot / "build" / "bin")
    check printed.output.contains("REPRO_DEV_ENV_PRODUCER_PINS")

    # ---- The prompt-time hook surfaces, BOUND. ----------------------------
    # The decision recorded at both call sites: these two REPORT and do not
    # BIND. So with the producer materialized they must still say something —
    # a materialized pin that a surface is not applying is exactly the state a
    # developer has to be told about, because their ``repro shell`` and their
    # prompt now answer ``prod`` differently — and the script they emit must
    # NOT contain the producer bin dir.
    #
    # The no-bind half is asserted rather than assumed because it is the part
    # a future author is most likely to "fix" without reading why: the native
    # transition's unload re-derives its PATH removals from the artifact's
    # bytes, which will never contain a producer bin dir, so a prepend emitted
    # here would accumulate one copy per ``cd`` and never be removed.
    checkpoint("bound native hook: " & nativeArgs.join(" "))
    let boundNative = runSplit(reproAbs, nativeArgs, consumerRoot)
    checkpoint("bound native exit=" & $boundNative.code)
    checkpoint("stderr: " & boundNative.errText)
    checkpoint("stdout: " & boundNative.outText)
    check boundNative.code == 0
    check boundNative.errText.contains("does not put it on PATH")
    check boundNative.errText.contains("repro shell")
    check not boundNative.outText.contains(prodRoot / "build" / "bin")

    checkpoint("bound direnv hook: " & direnvArgs.join(" "))
    let boundDirenv = runSplit(reproAbs, direnvArgs, consumerRoot)
    checkpoint("bound direnv exit=" & $boundDirenv.code)
    checkpoint("stderr: " & boundDirenv.errText)
    check boundDirenv.code == 0
    check boundDirenv.errText.contains("does not put it on PATH")
    check boundDirenv.errText.contains("repro shell")
    check not boundDirenv.outText.contains(prodRoot / "build" / "bin")

    # ---- Phase 3: staleness. ----------------------------------------------
    # The dev-env artifact is unchanged by anything in phase 2 — a producer's
    # build OUTPUT is not one of its declared source inputs and deliberately
    # does not key it. Capture its bytes, remove the producer output, and
    # assert that the ARTIFACT is identical while the ANSWER flips. That pair
    # is the whole staleness argument: the binding is re-derived per
    # activation, so a cached artifact can never serve a stale pin.
    let artifactPath = consumerRoot / ".repro" / "dev-env" / "default" /
      "dev-env.rbde"
    check fileExists(artifactPath)
    let artifactBefore = readFile(artifactPath)

    let hidden = producerBinary & ".hidden"
    moveFile(producerBinary, hidden)
    defer:
      if fileExists(hidden):
        moveFile(hidden, producerBinary)

    checkpoint("phase 3: " & probe)
    let stale = run(probe, consumerRoot)
    checkpoint("phase 3 exit=" & $stale.code)
    checkpoint(stale.output)
    check stale.code == 0

    let artifactAfter = readFile(artifactPath)
    checkpoint("artifact bytes identical: " &
      $(artifactBefore == artifactAfter))
    check artifactBefore == artifactAfter

    # Same cached artifact, different — and correct — answer.
    check stale.output.contains(decoyStamp)
    check not stale.output.contains(producerStamp)
    check stale.output.contains("cross-repo producer")
    check stale.output.contains("PINS=[]")

# ---------------------------------------------------------------------------
# The dev-SESSION surface: ``repro dev --foreground``.
#
# Two producers, one session, so both halves of W2's rule are observed in a
# single supervisor run: ``prod`` is built before the session starts and must
# be BOUND inside the watch task's environment, while ``prod2`` is declared,
# has a checkout, and was never built, so it must be REPORTED on the session's
# own stderr.
# ---------------------------------------------------------------------------

const sessionProducerRepro = producerRepro

const unbuiltProducerRepro = """
import repro_project_dsl

package prod2:
  defaultToolProvisioning "path"
"""

# The consumer declares BOTH producers and a watch task. The task is what makes
# this a dev-env ACTIVATION rather than a bare supervisor: ``runTaskCommand``
# runs it inside ``activatedEnvironment``, which is exactly the call site the
# ``--foreground`` arm was reaching with a nil resolver.
const sessionConsumerRepro = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package consumer:
  defaultToolProvisioning "path"

  uses:
    "sh"
    "prod"
    "prod2"

  devEnv:
    activity "default"
    setEnv "W2_FIXTURE", "present"
    task "pins", command = "sh scripts/pins.sh"
"""

const sessionDevelopOverrides = """
schema = "reprobuild.workspace.develop-overrides.v1"

[[override]]
package = "prod"
local_path = "../prod"
state = "editable"
created_at = "2026-07-02T00:00:00Z"

[[override]]
package = "prod2"
local_path = "../prod2"
state = "editable"
created_at = "2026-07-02T00:00:00Z"
"""

# The task records what the ACTIVATED environment actually contains: the pin
# summary variable and the binary the bare name resolves to. Both are needed --
# ``REPRO_DEV_ENV_PRODUCER_PINS`` proves the pass ran, and the stamp proves the
# prepend won over the decoy that is earlier on the inherited PATH.
const pinsProbeScript = "#!/bin/sh\n" &
  "mkdir -p state\n" &
  "{\n" &
  "  echo \"PINS=[$REPRO_DEV_ENV_PRODUCER_PINS]\"\n" &
  "  echo \"WHICH=$(command -v prod)\"\n" &
  "  echo \"RAN=$(prod)\"\n" &
  "} >> state/pins.log\n"

# The session is launched through a tiny shell script rather than a pipe, and
# that is load-bearing rather than cosmetic. The notice assertion has to be
# checkable WHILE THE SUPERVISOR IS STILL RUNNING: on Windows a redirected
# ``stderr`` is fully buffered by the C runtime, so a long-lived process holds
# its warnings until it exits or the buffer fills. Reading a pipe after
# stopping the session cannot tell "the notice was emitted promptly" from "the
# notice was emitted at exit" from "the notice was lost because the process was
# killed" — and the first of those three is the property W2's rule actually
# demands. Redirecting to a file and polling it mid-session distinguishes them.
const sessionLauncherScript = "#!/bin/sh\n" &
  "exec \"$1\" dev \"$2\" --foreground --http=127.0.0.1:0" &
  " --debounce-ms=100 > session.out 2> session.err\n"

proc waitForFileContaining(path, needle: string; timeoutMs: int): bool =
  var waited = 0
  while waited <= timeoutMs:
    if fileExists(path):
      try:
        if readFile(path).contains(needle):
          return true
      except CatchableError:
        discard
    sleep(100)
    waited.inc(100)
  false

suite "e2e_dev_env_binds_materialized_producer_in_a_session":

  test "repro dev --foreground binds the pin and reports the one it cannot":
    discard requireShell()
    let repoRoot = getCurrentDir()
    let reproAbs = requireBinary(
      repoRoot / "build" / "bin" / addFileExt("repro", ExeExt),
      "reprobuild.apps.repro")

    let scratch = getTempDir() / "w2fg-" & $getCurrentProcessId()
    removeDir(scratch)
    createDir(scratch)
    defer: removeDirEventually(scratch)

    let prodRoot = absolutePath(scratch / "prod")
    let prod2Root = absolutePath(scratch / "prod2")
    let consumerRoot = absolutePath(scratch / "consumer")
    let decoyDir = absolutePath(scratch / "decoy")
    let cacheRoot = absolutePath(scratch / "action-cache-root")
    for dir in [prodRoot, prod2Root, consumerRoot, decoyDir, cacheRoot,
                consumerRoot / ".repro", consumerRoot / "scripts"]:
      createDir(dir)
    writeFile(prodRoot / "repro.nim", sessionProducerRepro)
    writeFile(prod2Root / "repro.nim", unbuiltProducerRepro)
    writeFile(consumerRoot / "repro.nim", sessionConsumerRepro)
    writeFile(consumerRoot / ".repro" / "develop-overrides.toml",
      sessionDevelopOverrides)
    writeFile(consumerRoot / "scripts" / "pins.sh", pinsProbeScript)
    writeFile(consumerRoot / "scripts" / "session.sh", sessionLauncherScript)

    # The same decoy as the first case: the assertion "the pin ran" is only
    # worth anything while something else of the same name is on PATH.
    writeFile(decoyDir / "prod", "#!/bin/sh\necho " & decoyStamp & "\n")
    when not defined(windows):
      inclFilePermissions(decoyDir / "prod",
        {fpUserExec, fpGroupExec, fpOthersExec})
    when defined(windows):
      writeFile(decoyDir / "prod.bat", "@echo " & decoyStamp & "\r\n")

    let savedPath = getEnv("PATH")
    putEnv("PATH", decoyDir & $PathSep & savedPath)
    defer: putEnv("PATH", savedPath)

    # Materialize ``prod`` BEFORE the session starts. ``prod2`` is left
    # unbuilt on purpose.
    let producerBinary = prodRoot / "build" / "bin" / "prod"
    let buildCmd = q(reproAbs) & " build" &
      " --tool-provisioning=path --daemon=off --log=quiet" &
      " --progress=quiet --measure=none" &
      " --action-cache-root=" & q(cacheRoot)
    checkpoint("session fixture build: " & buildCmd)
    let built = run(buildCmd, prodRoot)
    checkpoint("build exit=" & $built.code)
    checkpoint(built.output)
    check built.code == 0
    check fileExists(producerBinary)
    check not dirExists(prod2Root / "build")

    # ---- the foreground session -------------------------------------------
    let sessionErr = consumerRoot / "session.err"
    var session = startProcess(requireShell(),
      args = @["scripts/session.sh", reproAbs, consumerRoot],
      workingDir = consumerRoot,
      options = {poUsePath, poParentStreams})
    var stopped = false

    proc stopSession() =
      if stopped:
        return
      stopped = true
      discard run(q(reproAbs) & " down " & q(consumerRoot), consumerRoot)
      for _ in 0 ..< 50:
        if not session.running():
          break
        sleep(100)
      try:
        if session.running():
          session.terminate()
          discard session.waitForExit()
      except CatchableError:
        discard

    defer:
      stopSession()
      session.close()

    let pinsLog = consumerRoot / "state" / "pins.log"
    let sawTask = waitForFileContaining(pinsLog, "PINS=", 300000)

    # The notice, asserted while the supervisor is STILL RUNNING. If it is
    # sitting in a stdio buffer rather than on the developer's terminal this
    # times out, which is the correct verdict: a warning nobody can see until
    # the session ends is the silence W2 exists to remove, arriving by a slower
    # route. Reading the pipe after stopping the session could not tell those
    # apart, and on the run that exposed this it could not tell either from
    # "lost because the supervisor was terminated".
    let sawNoticeLive =
      sawTask and
      waitForFileContaining(sessionErr, "cross-repo producer", 60000)

    stopSession()
    let sessionOutput =
      if fileExists(sessionErr): readFile(sessionErr) else: ""
    checkpoint("session.err:\n" & sessionOutput)
    if fileExists(pinsLog):
      checkpoint("pins.log:\n" & readFile(pinsLog))
    check sawTask
    check sawNoticeLive

    let recorded = readFile(pinsLog)

    # (1) THE PIN. The watch task's environment carries the binding, and the
    # bare name resolves through it rather than to the decoy. This is the
    # assertion that was false for ``--foreground`` and true for the detached
    # arm of the very same command.
    check recorded.contains("PINS=[prod=")
    check recorded.contains(prodRoot / "build" / "bin")
    check recorded.contains("RAN=" & producerStamp)
    check not recorded.contains(decoyStamp)

    # (2) THE NOTICE. ``prod2`` is declared and unbuilt, so the session must
    # say so on its own stderr. A session that binds what it can and stays
    # quiet about what it cannot is only half of W2's rule, and it is the half
    # that lets a developer keep running the wrong binary for hours.
    check sessionOutput.contains("cross-repo producer")
    check sessionOutput.contains("prod2")
    check sessionOutput.contains("repro build")
    # ...and it is specific about which pin failed: the bound one stays silent.
    check not sessionOutput.contains("\"prod\" is declared in uses:")
