## Two `repro` runs that compile (or platform-probe) the SAME profile in the
## SAME state directory at once must not work in that profile's directories
## at the same time: the second waits for the first, and both succeed.
##
## The failure this pins down
## --------------------------
## Everything a profile compile writes is named by the profile, not by the
## run: the nimcache `<state-dir>/profile-cache/nimcache/<profile-key>` (and,
## because `nim` runs in it, the `home_linkerArgs.txt` response file), the
## generated `.c` and `.o` files, the binary, the intent document, the
## envelope, and the `config.nims` / `.nimble` staged beside the profile,
## which the first run to finish deletes. Two shells running
## `repro home plan` on the default state directory used to do all of that
## concurrently: nothing serialised them (reprobuild-pm issue
## 2026-11-11-two-compiles-of-one-profile-in-one-state-dir-share-its-nimcache-unserialised).
## The platform probe of `repro home export` has the same shape: its scratch
## and document are named by the profile too.
##
## How the test makes the overlap deterministic
## --------------------------------------------
## A race is not a test; an overlap is. The sandbox's `nim` spy
## (`profile_compile_edge_harness.nim`) forwards to a gate script instead of
## the real compiler. The first `nim <command>` to reach the gate stops there
## until the test releases it, so the first run is held INSIDE its edge, in
## the profile's nimcache, for as long as the test likes. The test then
## starts the second run and watches for one of two things:
##
## * the second run reaches `nim <command>` too: the two runs are in the
##   profile's directories at once. That is the defect, and the case fails.
## * the second run sits in a blocked `flock` on the profile's own lock
##   file (`/proc/locks` lists it as a waiter on that file's inode) for
##   `BlockedFor`: it is waiting for the first. A wait on any other lock
##   (one of the engine's store locks, say) does not count, so the case
##   cannot pass because something else happened to serialise the runs.
##
## Either way the gate is then released and both runs must exit 0 with the
## profile's intent. Neither outcome depends on timing: on the unfixed code
## the second run has nothing to wait on and reaches `nim` however long it
## takes to get there.
##
## The second run is expected to be ANSWERED by the first's work: when it
## gets the profile, the action cache holds the record the first run just
## published, so it spawns no `nim` of that command at all.
##
## Measured against the unfixed engine (reprobuild `agents` @ `dd170ae260`,
## 2026-11-12, twice): both cases fail every time, the first with "the
## second run reached `nim c` while the first was still compiling", the
## second likewise with `nim dump`. What the overlap then broke varied: in
## one measurement the FIRST run of the first case failed too ("exited 0
## but printed no ProfileIntent JSON": the intent document both runs name
## was not there when the first went to read it); in the other both runs
## happened to exit 0. That is why the case asserts the overlap itself and
## not only the exit codes.
##
## Two state directories
## ----------------------
## The lock above is per state directory. Every Nim invocation over a
## profile also stages `config.nims` and a `.nimble` in the PROFILE's
## directory, which the first run to finish deletes, and two runs with
## different state directories (`repro home plan` beside a
## `deploy-agent compile-profile --state-dir ...`) share them
## (reprobuild-pm issue
## 2026-11-12-compiles-of-one-profile-in-two-state-dirs-share-the-files-staged-beside-it).
## The cases with a second state directory run the same experiment, with the
## second run's `$REPRO_HOME_STATE_DIR` pointing elsewhere; the wait it must
## show is on the lock of the profile DIRECTORY (`profileDirLockPath`). A
## second profile root in the same directory is held to the same lock.
## Unlike the one-state-directory cases, the second run is not answered from
## the first's record: its nimcache and binary are its own.
##
## Linux only: the waiter is read from `/proc/locks`, and the gate is a POSIX
## shell script. The lock is the same code on every platform.
##
## Mocks: none. Real `build/bin/repro`, real Nim and C toolchain, real io-mon.
## The gate only delays the real compiler; it changes none of its arguments.

import std/[os, osproc, strtabs, strutils, times, unittest]
when not defined(windows):
  import std/posix
from repro_core/paths import extendedPath
import repro_profile_compile
# `skip(reason)` on the hosts that build the suite with stock Nim.
import repro_test_support/reasoned_skip

import ./profile_compile_edge_harness

const ProfileBody = """
import repro_profile

profile "serialisedCompiles":
  resources:
    fsUserFile(hostFile = "~/serialised-compiles.txt", content = "once\n")
"""

const
  PollMs = 100
  BlockedFor = 2.0
    ## Seconds the second run must sit in a blocked `flock` to count as
    ## waiting for the first. See the header.
  Ceiling = 900.0
    ## Seconds after which a wait that should have ended fails the case
    ## instead of hanging the suite. Generous: the host may be loaded.

proc writeGate(sb: ProfileSandbox; command: string): string =
  ## Point the spy at a gate that holds the FIRST `nim <command>` until
  ## `<root>/release` exists, then runs the real compiler. Returns the
  ## release file's path. `mkdir` is the atomic test-and-set: only one
  ## invocation ever creates the marker. The gate also lets go when this
  ## test process is gone, so a test that is killed mid-case cannot leave
  ## a `repro` parked at the gate for good.
  let gateDir = sb.root / "gate"
  createDir(gateDir)
  let gate = gateDir / "nim-gate.sh"
  let release = sb.root / "release"
  writeFile(gate, "#!/bin/sh\n" &
    "if [ \"$1\" = " & quoteShell(command) & " ] && mkdir " &
      quoteShell(gateDir / "held") & " 2>/dev/null; then\n" &
    "  while [ ! -e " & quoteShell(release) & " ] && kill -0 " &
      $getCurrentProcessId() & " 2>/dev/null; do sleep 0.1; done\n" &
    "fi\n" &
    "exec " & quoteShell(sb.realNim) & " \"$@\"\n")
  setFilePermissions(gate, {fpUserRead, fpUserWrite, fpUserExec})
  # The spy's configuration: the log, then the compiler it forwards to.
  writeFile(extendedPath(sb.spyDir / "nim-spy.conf"),
    sb.spyLog & "\n" & gate & "\n")
  release

proc startRepro(sb: ProfileSandbox; args: openArray[string];
                transcript: string; stateDir = ""): Process =
  ## Start `repro <args>` against the sandbox with its output in
  ## `transcript` (a file, so an unread pipe can never stall it). A
  ## non-empty `stateDir` replaces the sandbox's state directory.
  let env = sb.sandboxEnv()
  if stateDir.len > 0:
    env["REPRO_HOME_STATE_DIR"] = stateDir
  startProcess("/bin/sh", workingDir = sb.root, env = env,
    args = @["-c", "exec \"$0\" \"$@\" >" & quoteShell(transcript) & " 2>&1",
      reproBinary()] & @args,
    options = {})

proc blockedOnFlock(pid: int; lockPath: string): bool =
  ## Whether `/proc/locks` lists `pid` as WAITING for a `flock` on
  ## `lockPath`. A waiter's line is
  ## "N: -> FLOCK ADVISORY WRITE <pid> <maj>:<min>:<ino> 0 EOF"; the file is
  ## matched by its inode, which is unique within the sandbox's file system.
  ## False while `lockPath` does not exist (the unfixed code never creates
  ## it).
  when defined(windows):
    false
  else:
    var st: Stat
    if stat(lockPath.cstring, st) != 0:
      return false
    let ino = $uint64(st.st_ino)
    for line in readFile("/proc/locks").splitLines():
      let f = line.splitWhitespace()
      if f.len >= 7 and f[1] == "->" and f[2] == "FLOCK" and
          f[5] == $pid and f[6].split(':')[^1] == ino:
        return true

type Overlap = enum
  secondWaited, secondReachedNim, secondExited, timedOut

proc watchSecond(sb: ProfileSandbox; command: string; second: Process;
                 lockPath: string): Overlap =
  ## Watch the second run until it reaches `nim <command>` or has waited in
  ## a `flock` on the profile's lock for `BlockedFor` seconds (see the
  ## header).
  let start = epochTime()
  var blockedSince = -1.0
  while epochTime() - start < Ceiling:
    if sb.nimSpawnCount(command) >= 2:
      return secondReachedNim
    if not second.running:
      return secondExited
    if blockedOnFlock(second.processID, lockPath):
      if blockedSince < 0:
        blockedSince = epochTime()
      elif epochTime() - blockedSince >= BlockedFor:
        return secondWaited
    else:
      blockedSince = -1.0
    sleep(PollMs)
  timedOut

proc waitForGate(sb: ProfileSandbox; command: string; first: Process): bool =
  ## Wait until the first run is held at the gate in `nim <command>`.
  let start = epochTime()
  while epochTime() - start < Ceiling:
    if sb.nimSpawnCount(command) >= 1 and dirExists(sb.root / "gate" / "held"):
      return true
    if not first.running:
      return false
    sleep(PollMs)
  false

proc finish(p: Process; transcript: string): tuple[code: int; text: string] =
  result.code = p.waitForExit()
  p.close()
  result.text = readFile(transcript)

proc runTwoAtOnce(sb: ProfileSandbox; args: openArray[string];
                  command: string; secondStateDir = ""): tuple[overlap: Overlap;
                  first, second: tuple[code: int; text: string];
                  spawnsAtRelease: int] =
  ## The case body: hold the first run in `nim <command>`, start the second,
  ## classify what the second did, release, and collect both.
  let release = writeGate(sb, command)
  let firstOut = sb.root / "first.txt"
  let secondOut = sb.root / "second.txt"
  let first = startRepro(sb, args, firstOut)
  var second: Process = nil
  try:
    if not waitForGate(sb, command, first):
      writeFile(release, "")
      result.first = finish(first, firstOut)
      checkpoint("the first run never reached `nim " & command & "`:\n" &
        result.first.text)
      check false
      return
    second = startRepro(sb, args, secondOut, secondStateDir)
    # Two state directories: the per-state-directory lock cannot be what
    # the second run waits on.
    let lockPath =
      if secondStateDir.len > 0:
        profileDirLockPath(profileDirLockKey(sb.profilePath))
      else:
        cachedProfileLockPath(sb.stateDir, profileCompileKey(sb.profilePath))
    result.overlap = watchSecond(sb, command, second, lockPath)
    result.spawnsAtRelease = sb.nimSpawnCount(command)
  finally:
    writeFile(release, "")
  result.first = finish(first, firstOut)
  result.second = finish(second, secondOut)

when not defined(linux):
  suite "profile compiles of one profile in one state directory":
    test "Linux only":
      skip("[platform N/A] Linux only: see the header of this file")
else:
  suite "profile compiles of one profile in one state directory":
    test "a second `repro home plan` waits for the compile in flight":
      let sb = newProfileSandbox("serialised-plan", ProfileBody)
      defer: sb.dispose()
      let r = runTwoAtOnce(sb, ["home", "plan"], "c")
      checkpoint("first run:\n" & r.first.text)
      checkpoint("second run:\n" & r.second.text)
      if r.overlap == secondReachedNim:
        checkpoint("the second run reached `nim c` while the first was " &
          "still compiling the same profile in the same state directory")
      check r.overlap == secondWaited
      check r.spawnsAtRelease == 1
      check r.first.code == 0
      check r.second.code == 0
      for run in [r.first, r.second]:
        check "serialised-compiles.txt" in run.text
      # The second run was answered from the record the first published.
      check cacheAnswered(sb.nimSpawnCount("c") - 1, 1,
        "the second run's compile edge")

    test "a second `repro home export` waits for the platform probe in " &
        "flight":
      let sb = newProfileSandbox("serialised-export", ProfileBody)
      defer: sb.dispose()
      # `nim dump` is the probe's first invocation (`platforms.nim`); the
      # compile before it is not held.
      let r = runTwoAtOnce(sb, ["home", "export"], "dump")
      checkpoint("first run:\n" & r.first.text)
      checkpoint("second run:\n" & r.second.text)
      if r.overlap == secondReachedNim:
        checkpoint("the second run reached `nim dump` while the first was " &
          "still probing the same profile in the same state directory")
      check r.overlap == secondWaited
      check r.spawnsAtRelease == 1
      check r.first.code == 0
      check r.second.code == 0
      for run in [r.first, r.second]:
        check "serialised-compiles.txt" in run.text
      check cacheAnswered(sb.nimSpawnCount("dump") - 1, 1,
        "the second run's platform-probe edge")

    test "a `repro home plan` in another state directory waits for the " &
        "compile in flight over the same profile directory":
      let sb = newProfileSandbox("serialised-plan-two-states", ProfileBody)
      defer: sb.dispose()
      let r = runTwoAtOnce(sb, ["home", "plan"], "c",
        secondStateDir = sb.root / "second-state")
      checkpoint("first run:\n" & r.first.text)
      checkpoint("second run:\n" & r.second.text)
      if r.overlap == secondReachedNim:
        checkpoint("the second run reached `nim c` while the first was " &
          "still compiling in the same profile directory")
      check r.overlap == secondWaited
      check r.spawnsAtRelease == 1
      check r.first.code == 0
      check r.second.code == 0
      for run in [r.first, r.second]:
        check "serialised-compiles.txt" in run.text

    test "a `repro home export` in another state directory waits for the " &
        "platform probe in flight over the same profile directory":
      let sb = newProfileSandbox("serialised-export-two-states", ProfileBody)
      defer: sb.dispose()
      let r = runTwoAtOnce(sb, ["home", "export"], "dump",
        secondStateDir = sb.root / "second-state")
      checkpoint("first run:\n" & r.first.text)
      checkpoint("second run:\n" & r.second.text)
      if r.overlap == secondReachedNim:
        checkpoint("the second run reached `nim dump` while the first was " &
          "still probing in the same profile directory")
      check r.overlap == secondWaited
      check r.spawnsAtRelease == 1
      check r.first.code == 0
      check r.second.code == 0
      for run in [r.first, r.second]:
        check "serialised-compiles.txt" in run.text
