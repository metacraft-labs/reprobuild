## Test seams of the add-on switch: places a crash-consistency gate can
## stop the switch (or a recovery) at, to hard-reset the guest there or to
## change the host under it.
##
## A seam exists only in a build compiled with ``-d:reproAddonTestSeams``
## (``scripts/build_addon_static.sh --test-seams``). Without the define
## ``seamPause`` is an empty proc: the product binary has no control file,
## no environment variable and no flag that can stop a switch, and a seam
## build has a different SHA-256, so it is never mistaken for the
## published artefact (the same discipline as ``mutations.nim``).
##
## **A seam never syncs.** The point of stopping at a step is to reset the
## guest with whatever the switch itself made durable and nothing more; a
## seam that flushed the page cache would make every write durable and hide
## a missing fsync. Its own control files are therefore read by the gate
## from the running guest (the page cache) and are allowed to be lost by
## the reset.
##
## Protocol, all files under ``<state dir>/addon/``:
##
## - ``test-pause-at`` holds one point name. When the switch reaches that
##   point it removes the file, writes ``test-paused-at`` with the point
##   name and waits for ``test-resume`` (or for the gate's hard reset);
## - ``test-pause-recovery`` (written and synced by the gate BEFORE the
##   switch starts, so it survives the reset) makes the next recovery stop
##   at its start the same way, writing ``test-paused-at`` = ``recovery``:
##   the boot-timing gate holds a recovery there while it measures the
##   base's boot.
##
## Points: ``step-1`` … ``step-9`` (just after the pending marker records
## that step), ``pre-write`` and ``mid-write`` (before the first and the
## second privileged write of steps 4-5), ``commit-envelope`` (the
## generation envelope is durable, `current` not moved yet) and, in the
## ``current-remove-then-create`` mutation build, ``commit-current-removed``;
## ``secrets-mid-write`` (``addon_secrets.materialise``: the first secret
## file of a materialisation is in place, the others are not) and
## ``rotation-after-overwrite`` (the old key overwritten with NUL bytes,
## not yet replaced), ``secrets-holding-plaintext`` (``secret put`` holds
## the secret it read, before sealing it), and
## ``rotation-after-rename`` (``addon_secrets.retireCurrentKey``: the next
## key is renamed over the old one, ``recipient.pub`` and the ledger not yet
## brought up to date), and ``restore-before-archive`` (``state_sets``:
## the carried-state restore, before it reads an archive; its control files
## are under ``/var/lib/repro/system/addon/``), ``receipt-before-rename``
## and ``receipt-before-dir-fsync`` (``carried_state.writeReceipt``,
## through the restore: the new receipt written and fsync'd but not
## renamed; renamed, its directory not fsync'd).
## A switch that is a revert prefixes its points with ``revert:``, and a
## replay (a recovery) with ``replay:``.

import std/os
when defined(reproAddonTestSeams):
  import std/strutils

const AddonTestSeams* {.booldefine: "reproAddonTestSeams".} = false

proc seamControlDir*(stateDir: string): string = stateDir / "addon"

proc waitResume(dir, point: string) =
  ## Also ``test-paused-at-<point>`` and ``test-resume-<point>``: two
  ## processes can be paused at once (the network guard's gate holds the
  ## owner and a ``revert-network`` firing), each resumed by its own file.
  when AddonTestSeams:
    let paused = dir / "test-paused-at"
    let pausedHere = dir / ("test-paused-at-" & point)
    let resume = dir / "test-resume"
    let resumeHere = dir / ("test-resume-" & point)
    writeFile(paused, point & "\n")
    writeFile(pausedHere, point & "\n")
    stderr.writeLine("repro-addon test seam: paused at " & point)
    while not fileExists(resume) and not fileExists(resumeHere):
      sleep(100)
    for f in [resume, resumeHere, paused, pausedHere]:
      try: removeFile(f) except OSError: discard
    stderr.writeLine("repro-addon test seam: resumed at " & point)

proc seamPause*(stateDir, point: string) =
  when AddonTestSeams:
    let dir = seamControlDir(stateDir)
    let ctl = dir / "test-pause-at"
    if not fileExists(ctl): return
    var want = ""
    try: want = readFile(ctl).strip()
    except IOError, OSError: return
    if want != point: return
    removeFile(ctl)
    waitResume(dir, point)
  else:
    discard

proc seamPauseRecovery*(stateDir: string) =
  ## The recovery seam (see the module header).
  when AddonTestSeams:
    let dir = seamControlDir(stateDir)
    let ctl = dir / "test-pause-recovery"
    if not fileExists(ctl): return
    removeFile(ctl)
    waitResume(dir, "recovery")
  else:
    discard

proc seamSleepCommand*(args: seq[string]): int =
  ## ``repro system addon test-sleep <seconds>``, compiled into the seam
  ## build only: a command in the store that hangs, for the gate that
  ## checks ``confirmTimeout`` bounds an ``exec:`` health check.
  when AddonTestSeams:
    if args.len != 1: return 2
    sleep(parseInt(args[0]) * 1000)
    0
  else:
    2

proc seamFlag*(stateDir, name: string): bool =
  ## Seam builds only: true while ``<state dir>/addon/test-<name>`` exists.
  ## The network guard's gate uses it to make an act fail on purpose
  ## (``guard-arm-fails``: arming a guard timer, spec §4.5 step 4 control
  ## (x); ``network-step-fails``: a switch step after the network writes,
  ## control (g)). Always false in the product build.
  when AddonTestSeams:
    fileExists(seamControlDir(stateDir) / ("test-" & name))
  else:
    false

proc seamText*(stateDir, name: string): string =
  ## Seam builds only: the content of ``<state dir>/addon/test-<name>``, ""
  ## when absent. ``network-inject`` carries the MS-2 run's connection:
  ## its first line names a link, the rest is the keyfile the switch writes
  ## for that link instead of the one the planner rendered (spec §4.5, §13
  ## decision 86: the gate's own test program hands the switch a
  ## generation the planner refuses). Always "" in the product build.
  when AddonTestSeams:
    let p = seamControlDir(stateDir) / ("test-" & name)
    if not fileExists(p): return ""
    try: readFile(p) except IOError, OSError: ""
  else:
    ""
