## Engine-Threadpool TP-2 — the handoff is EXCLUSIVE, and LF-2 is still
## structural.
##
## WHAT THIS PINS, and why it cannot be pinned in process.
##
## TP-2 moves a ``MonitorHandle`` from the scheduler's slot into a
## shared-memory carrier and from there onto a pool worker. LF-2 — "a producer
## never runs without a consumer" — is held by DH-2 through two properties of
## the type, and the first of them is that ``=copy`` is ``{.error.}``, so two
## owners of one consumer cannot be WRITTEN DOWN. A carrier is exactly the
## shape that could quietly reintroduce a second owner, so the refusal is
## checked against the carrier rather than assumed to survive it.
##
## IT HAS TO BE DONE OUT OF PROCESS, and that is a measured fact rather than a
## preference. DH-2 correction 3: ``compiles()`` cannot see a ``{.error.}``
## ``=copy``, because the hook is injected after semantic analysis while
## ``compiles()`` answers from sem alone. A probe whose whole body was
## ``static: doAssert compiles((var a: MonitorHandle; var b = a; …))``
## COMPILES. So an in-process ``static: doAssert not compiles(<forbidden>)``
## would be a test that cannot fail. The property is observable only by
## driving the compiler and reading its EXIT CODE, which is what this file
## does.
##
## THE CONTROLS ARE THE POINT. A file of refusals proves nothing on its own —
## a probe that fails to compile for a typo refuses exactly as loudly as one
## that fails for the property. So every refusal is paired with an accepted
## probe that differs from it in the one construct under test, and the run is
## judged by exit code, never by a message.
##
## AND IT HAS TO BE ``nim c``, NOT ``nim check`` — MEASURED HERE, THE HARD
## WAY. The first version of this file drove ``nim check`` and every refusal
## probe COMPILED, with EMPTY compiler output and exit 0. The reason is the
## same one DH-2's correction 3 states: the ``=copy`` hook is injected AFTER
## semantic analysis, and ``nim check`` stops at sem. So ``nim check`` is as
## blind to a ``{.error.}`` ``=copy`` as ``compiles()`` is, and a probe
## harness built on it is a second test that cannot fail. ``--compileOnly``
## runs the codegen pass where the hook is injected and skips the C compiler,
## which is what DH-2's own exclusivity test does.
##
## EVERY REFUSAL IS ATTRIBUTED, not merely counted. A probe that fails to
## compile for a typo refuses exactly as loudly as one that fails for the
## property, so each refusing probe also has to produce the DIAGNOSTIC its
## property produces.
##
## NO MOCKS: the probes import the real ``io_mon``, and are compiled by the
## real toolchain from inside the repository so the repository's own
## ``config.nims`` resolves the paths.

import std/[os, osproc, strutils, unittest]

from repro_test_support import testCaseScratchSlug

template checkOrEcho(cond: untyped; msg: string) =
  ## `check` inside a plain `proc` prints "Check failed" and still reports
  ## `[OK]`, so every helper that asserts in this file is a template.
  if not (cond):
    echo msg
  check cond

const CarrierPreamble = """
import io_mon

type
  Carrier = ptr CarrierObj
  CarrierObj = object
    ## The shape ``monitor_finish.MonitorFinishNodeObj`` has: a handle living
    ## in manually-managed memory, reached through a ``ptr``.
    handle: MonitorHandle
    slot: int

proc newCarrier(): Carrier =
  cast[Carrier](allocShared0(sizeof(CarrierObj)))
"""

const
  CopyRefusalNeedle = "'=copy' is not available"
    ## The diagnostic Nim emits for a ``{.error.}``-annotated ``=copy``.
    ## Asserting on it is what distinguishes "the guarantee held" from "the
    ## probe was broken in some other way".
  GcSafetyRefusalNeedle = "is not GC-safe"

type Probe = object
  name: string
  mustCompile: bool
  needle: string
    ## For a refusing probe, the substring its diagnostic must contain. Empty
    ## for a probe that must compile.
  why: string
  body: string

proc probes(): seq[Probe] =
  @[
    Probe(
      name: "move-into-the-carrier-and-out-again",
      mustCompile: true,
      why: "THE CONTROL FOR EVERY REFUSAL BELOW. This is exactly what " &
        "``submitMonitorFinish`` and ``runMonitorFinishJob`` do — a handle " &
        "moved out of a scheduler slot into the carrier, and moved out of " &
        "the carrier into ``finishMonitor``. If this did not compile, the " &
        "refusals would be evidence of nothing but a broken probe.",
      body: CarrierPreamble & """
proc handOff(slot: var MonitorHandle): int =
  let node = newCarrier()
  node.handle = move(slot)
  var outcome = finishMonitor(move(node.handle))
  deallocShared(node)
  outcome.exitCode

proc probe() =
  ## CALLED, not merely defined. The `=copy` hook is injected during codegen,
  ## and a proc nothing reaches can be dropped before it gets there — which
  ## would make every refusal below unobservable for the wrong reason.
  var slot: MonitorHandle
  discard handOff(slot)

probe()
"""),
    Probe(
      name: "reading-the-carrier-handle-by-value",
      mustCompile: false,
      needle: CopyRefusalNeedle,
      why: "A SECOND OWNER, WRITTEN DOWN. Copying the handle out of the " &
        "carrier would leave the carrier holding one owner and the caller " &
        "another, which is the LF-2 orphan shape: whichever of the two is " &
        "dropped last releases a consumer the other may still be finishing.",
      body: CarrierPreamble & """
proc peek(node: Carrier): bool =
  let stolen = node.handle
  # ``node.handle`` is read AGAIN after ``stolen`` is bound, so the compiler
  # cannot turn the binding into a move (DH-2 made the same observation about
  # its own probe). This is a COPY or it is nothing.
  stolen.live and node.handle.live

proc probe() =
  discard peek(newCarrier())

probe()
"""),
    Probe(
      name: "copying-a-handle-between-two-carriers",
      mustCompile: false,
      needle: CopyRefusalNeedle,
      why: "THE SAME SECOND OWNER, arrived at without naming a local. A " &
        "carrier-to-carrier assignment is the shape a queue re-link or a " &
        "retry would take.",
      body: CarrierPreamble & """
proc relink(dst, src: Carrier) =
  dst.handle = src.handle
  doAssert src.handle.live == dst.handle.live

proc probe() =
  relink(newCarrier(), newCarrier())

probe()
"""),
    Probe(
      name: "handing-a-handle-to-createThread",
      mustCompile: false,
      needle: CopyRefusalNeedle,
      why: "DH-2's 19-attack finding, re-checked against THIS milestone's " &
        "code rather than inherited. ``typedthreads``'s ``param`` is not " &
        "``sink``, so even a ``move``d handle is copied into the thread " &
        "payload — which is why TP-2 uses a ``ptr`` carrier reached through " &
        "the pool rather than a per-monitor thread. If this ever started " &
        "compiling, the obvious design would become available and this " &
        "module's reasoning would need rewriting.",
      body: CarrierPreamble & """
proc worker(h: MonitorHandle) {.thread.} =
  discard h.live

proc spawnIt(slot: var MonitorHandle) =
  var t: Thread[MonitorHandle]
  createThread(t, worker, move(slot))
  joinThread(t)

proc probe() =
  var slot: MonitorHandle
  spawnIt(slot)

probe()
"""),
    Probe(
      name: "a-gcsafe-task-calling-finishMonitor",
      mustCompile: false,
      needle: GcSafetyRefusalNeedle,
      why: "THE ``{.cast(gcsafe).}`` IN THE TP-2 BLOCK OF " &
        "``repro_build_engine.nim`` IS NECESSARY " &
        "AND THIS IS WHERE THAT IS CHECKED. io-mon's ``finishMonitor`` " &
        "reaches three GC'd globals in ``writer.nim`` " &
        "(``fragmentRunToken``, ``setProducer``, ``setElemImage``), so a " &
        "``{.nimcall, gcsafe.}`` pool task cannot call it without the cast. " &
        "A REFUSAL HERE IS THE EXPECTED STATE; this case going RED means " &
        "``finishMonitor`` became gcsafe, which is good news and means the " &
        "cast — and this probe — should be deleted.",
      body: """
import io_mon

type
  Carrier = ptr CarrierObj
  CarrierObj = object
    handle: MonitorHandle

proc task(node: Carrier): int {.nimcall, gcsafe.} =
  var outcome = finishMonitor(move(node.handle))
  outcome.exitCode

proc probe() =
  discard task(cast[Carrier](allocShared0(sizeof(CarrierObj))))

probe()
"""),
    Probe(
      name: "the-same-task-with-the-cast",
      mustCompile: true,
      why: "THE CONTROL FOR THE REFUSAL ABOVE. Identical apart from the " &
        "cast, so the refusal is attributable to gcsafety and not to " &
        "anything else about the probe.",
      body: """
import io_mon

type
  Carrier = ptr CarrierObj
  CarrierObj = object
    handle: MonitorHandle

proc task(node: Carrier): int {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    var outcome = finishMonitor(move(node.handle))
    result = outcome.exitCode

proc probe() =
  discard task(cast[Carrier](allocShared0(sizeof(CarrierObj))))

probe()
""")]

suite "TP-2 monitor finish handoff exclusivity":
  test "the carrier cannot give a monitor two owners":
    ## Every probe compiled in its own process, judged by exit code, with the
    ## compiler's output shown only when the verdict is wrong.
    when not (defined(linux) or defined(macosx)):
      skip()
    else:
      let nim = findExe("nim")
      if nim.len == 0:
        # NOT a skip. Without a compiler this file's entire subject is
        # unobservable, and a green run that observed nothing is exactly the
        # failure shape this campaign keeps producing.
        echo "no `nim` on PATH: the handoff-exclusivity probes cannot be " &
          "compiled, and their property is observable in no other way " &
          "(`compiles()` cannot see a {.error.} `=copy` — DH-2 correction 3)."
      check nim.len > 0

      if nim.len > 0:
        let root = absolutePath("build" / "test-tmp" /
          "test_monitor_finish_handoff" / testCaseScratchSlug())
        if dirExists(root): removeDir(root)
        createDir(root)

        var wrong: seq[string] = @[]
        for probe in probes():
          let source = root / (probe.name.replace("-", "_") & ".nim")
          writeFile(source, probe.body)
          # ``--compileOnly`` reaches the codegen pass the ``=copy`` hook is
          # injected in and stops before the C compiler. ONE nimcache for
          # every probe: they all compile the same ``io_mon``, and a
          # per-probe cache would build that module six times.
          let (output, code) = execCmdEx(
            quoteShell(nim) &
            " c --threads:on --hints:off --warnings:off --colors:off" &
            " --compileOnly --nimcache:" & quoteShell(root / "cache") & " " &
            quoteShell(source) & " 2>&1")
          let compiled = code == 0
          var verdict = ""
          if compiled != probe.mustCompile:
            verdict =
              if probe.mustCompile: "was REFUSED but must compile"
              else: "COMPILED but must be refused"
          elif not compiled and probe.needle.len > 0 and
              probe.needle notin output:
            # REFUSED FOR THE WRONG REASON is a failure, not a pass. Without
            # this the file would report green on a probe broken by a typo.
            verdict = "was refused, but not for its own reason: the " &
              "diagnostic does not contain " & probe.needle.escape
          if verdict.len > 0:
            wrong.add probe.name
            echo "PROBE `", probe.name, "` ", verdict,
              " (nim c --compileOnly exit ", code, ")\n  ", probe.why,
              "\n--- compiler output\n", output.strip(), "\n---"
        checkOrEcho wrong.len == 0,
          "the compiler's verdict was wrong for: " & wrong.join(", ")
