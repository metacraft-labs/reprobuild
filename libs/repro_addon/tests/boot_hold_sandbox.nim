## The boot-hold unit's script in a sandbox, for the add-on's unit tests
## (``t_addon_floor_round20``, ``t_addon_floor_round21``): the unit's own
## ``bootHoldScript`` with its paths moved under a temporary directory, run
## under the dev shell's pinned dash (``$REPRO_DASH``), the ``/bin/sh`` of
## Debian and Ubuntu.
##
## *Mocking.* ``systemctl`` and ``sleep`` stand-ins on PATH, as the tests
## that import this say: the stand-in ``systemctl`` reports
## ``sysinit.target`` inactive, and on ``daemon-reload`` logs how many holds
## are on disk and exits with the status the case asks for; the stand-in
## ``sleep`` logs the fail-closed wait instead of waiting 120 s. A case may
## add a stand-in of its own (``standIn``). The VM gate
## ``t_e2e_addon_boot_hold_is_required`` runs the same script on a real boot.

import std/[os, strutils, tempfiles]

import repro_addon/generation0
import repro_addon/static_tree

type Sandbox* = tuple[tmp, state, root, written, etc, bin, log: string]

proc setup*(): Sandbox =
  let tmp = createTempDir("a9r20-", "-holds")
  result = (tmp, tmp / "state", tmp / "run-systemd-system",
            tmp / "run-addon" / "boot-holds-written", tmp / "etc-systemd-system",
            tmp / "bin", tmp / "log")
  createDir(result.bin)
  createDir(result.etc)
  writeFile(result.log, "")
  # daemon-reload logs the holds on disk when it runs, then answers with
  # A9_RELOAD (0: reloaded).
  writeFile(result.bin / "systemctl", "#!/bin/sh\n" &
    "case \"$1\" in is-active) exit 3;; daemon-reload) echo RELOAD-SEES " &
    "$(ls " & result.root & "/*.d/* 2>/dev/null | wc -l) >> " & result.log &
    "; exit ${A9_RELOAD:-0};; esac\nexit 0\n")
  writeFile(result.bin / "sleep", "#!/bin/sh\necho SLEEP \"$@\" >> " &
    result.log & "\nexit 0\n")
  for t in ["systemctl", "sleep"]:
    setFilePermissions(result.bin / t, {fpUserRead, fpUserWrite, fpUserExec})

proc dash*(): string =
  ## The dev shell's pinned dash (flake.nix ``REPRO_DASH``).
  result = getEnv("REPRO_DASH")
  doAssert result.len > 0 and fileExists(result),
    "REPRO_DASH does not name the dev shell's pinned dash (got '" & result &
    "'): the boot-hold script must be run under the shell Debian and " &
    "Ubuntu boot it with"

proc run*(s: Sandbox; reloadFails = false; limitSec = 0): string =
  ## The unit's own script with its paths moved under the sandbox; its
  ## output and the stand-ins' lines. ``limitSec`` bounds a case whose
  ## falsifying build can read without end (a list on ``/dev/full``).
  let script = bootHoldScript()
    .replace(BootHoldRecordPath, bootHoldRecordPath(s.state))
    .replace(BootHoldsWrittenList, s.written)
    .replace("/run/repro-addon", parentDir(s.written))
    .replace(RuntimeUnitDirPath, s.root)
    .replace(ConservativeHoldDir, s.etc)
    .replace("/usr/bin/", "")
  writeFile(s.tmp / "script.sh", script)
  discard execShellCmd("env PATH=" & s.bin & ":" & getEnv("PATH") &
    " A9_RELOAD=" & (if reloadFails: "1" else: "0") & " " &
    (if limitSec > 0: "timeout -k 2 " & $limitSec & " " else: "") & dash() & " " &
    s.tmp / "script.sh" & " >> " & s.log & " 2>&1")
  readFile(s.log)

proc standIn*(s: Sandbox; tool, body: string) =
  ## A stand-in for ``tool`` on the script's PATH: ``body`` after the
  ## ``#!/bin/sh`` line.
  writeFile(s.bin / tool, "#!/bin/sh\n" & body & "\n")
  setFilePermissions(s.bin / tool, {fpUserRead, fpUserWrite, fpUserExec})
