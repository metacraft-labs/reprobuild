## Test seams of the add-on switch: places a crash-consistency gate can
## stop the switch at, to hard-reset the guest there or to change the
## host under it.
##
## A seam exists only in a build compiled with ``-d:reproAddonTestSeams``
## (``scripts/build_addon_static.sh --test-seams``). Without the define
## ``seamPause`` is an empty proc: the product binary has no control file,
## no environment variable and no flag that can stop a switch, and a seam
## build has a different SHA-256, so it is never mistaken for the
## published artefact (the same discipline as ``mutations.nim``).
##
## Protocol, all files under ``<state dir>/addon/``:
##
## - the gate writes ``test-pause-at`` holding one point name;
## - when the switch reaches that point it REMOVES ``test-pause-at``
##   (durably, so a reset-and-reboot never pauses a second time), writes
##   ``test-paused-at`` with the point name, and waits;
## - it continues when the gate creates ``test-resume`` (and removes both
##   files), or never, when the gate hard-resets the guest instead.
##
## Points: ``step-1`` … ``step-9`` (just after the pending marker records
## that step as completed), ``pre-write`` (before the first privileged
## write of steps 4-5 is checked) and ``mid-write`` (before the second:
## one write is on the host, the rest are not).

import std/os
when defined(reproAddonTestSeams):
  import std/strutils

const AddonTestSeams* {.booldefine: "reproAddonTestSeams".} = false

proc c_sync() {.importc: "sync", header: "<unistd.h>".}

proc seamControlDir*(stateDir: string): string = stateDir / "addon"

proc seamPause*(stateDir, point: string) =
  when AddonTestSeams:
    let dir = seamControlDir(stateDir)
    let ctl = dir / "test-pause-at"
    let paused = dir / "test-paused-at"
    let resume = dir / "test-resume"
    if not fileExists(ctl): return
    var want = ""
    try: want = readFile(ctl).strip()
    except IOError, OSError: return
    if want != point: return
    removeFile(ctl)
    # Durable before anyone can reset us: a guest reset right after the
    # pause must not find the control file again at boot.
    c_sync()
    writeFile(paused, point & "\n")
    stderr.writeLine("repro-addon test seam: paused at " & point)
    while not fileExists(resume):
      sleep(100)
    removeFile(resume)
    removeFile(paused)
    stderr.writeLine("repro-addon test seam: resumed at " & point)
  else:
    discard
