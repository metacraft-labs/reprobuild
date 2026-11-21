## ``runBounded`` (the generator's bounded git runner) must return
## everything the child wrote before it exited.
##
## The runner polls the child's pipes for 100 ms at a time and, when a poll
## finds nothing, checks whether the child has exited. A child that writes
## its answer and exits in the moment between a poll that found nothing and
## that check used to lose the answer: the runner saw "exited, nothing
## queued" from a poll taken before the write, stopped reading, and
## returned an empty stdout with exit code 0. Measured as an intermittent
## `t_repro_catalog_generate_and_verify_verbs` failure: `git cat-file -t`
## answered `commit`, the runner returned "", and the source was reported as
## "not-a-commit: <id> is a " -- an origin event (`gone`) for a version that
## was fetched.
##
## The child here is a script standing in for git: it sleeps for a time
## just past the runner's first poll (90 to 120 ms), prints one line and
## exits, while the runner sizes a watched directory of 60000 files after
## that poll (as it sizes the repository a fetch writes), so the exit often
## lands in that window. Every run must return the line.
##
## The window is a race, so a single run does not decide it: measured with
## the drain removed, 5 of 32 and 14 of 120 runs lost the line. 120 runs
## make a pass with the defect present vanishingly unlikely at that rate.
##
## Falsifying mutation: removing the drain after the child is seen to have
## exited loses the line in some of the runs.

import std/[os, strutils, tempfiles, unittest]

import repro_nimble_generator/egress
import repro_nimble_generator/origin_git

suite "the bounded git runner keeps the output of a child that exits":
  test "a line written just before exit is never lost":
    let dir = createTempDir("npc-run-bounded-", "")
    let sleepBin = findExe("sleep")
    check sleepBin.len > 0
    let durFile = dir / "duration"
    let script = dir / "git"
    writeFile(script, "#!/bin/sh\nread d < " & quoteShell(durFile) & "\n" &
      quoteShell(sleepBin) & " \"$d\"\necho commit\n")
    setFilePermissions(script, {fpUserRead, fpUserWrite, fpUserExec})
    # A watched directory large enough that sizing it -- which the runner
    # does between a poll and the exit check, as it does for a fetch into a
    # repository -- takes a few milliseconds: the window the child's exit
    # has to fall in.
    let watched = dir / "watched"
    for d in 0 ..< 200:
      createDir(watched / $d)
      for f in 0 ..< 300:
        writeFile(watched / $d / $f, "x")
    let g = OriginGit(gitBin: script)
    var lost = 0
    const Runs = 120
    for i in 0 ..< Runs:
      # 0.090 .. 0.120 s: around the end of the runner's first 100 ms poll,
      # after which it sizes the watched directory.
      writeFile(durFile, "0." & align($(90 + (i * 2) mod 32), 3, '0') & "\n")
      let r = runBounded(g, @["cat-file", "-t", "x"], dir, dir / "home",
        DefaultLimits, watchDir = watched)
      check r.code == 0
      if r.stdoutText != "commit\n":
        inc lost
        checkpoint "run " & $i & ": stdout " & r.stdoutText.escape()
    check lost == 0
    removeDir(dir)
