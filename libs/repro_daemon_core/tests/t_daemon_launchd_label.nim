## A daemon's launchd label must identify the ENDPOINT, because the label
## namespace is per-user global while endpoints are not.
##
## WHAT WENT WRONG. The label was `"org.reprobuild.repro-daemon." &
## safePathSegment(config.endpoint.extractFilename, "user")` -- the endpoint's
## LAST COMPONENT only, the derivation `systemdUnitName` was moved off by
## `15bd7e7f` (see `t_daemon_transient_unit_name.nim` for the systemd half).
## Endpoints live in per-run scratch directories precisely because the
## basename is not unique: every one of them is some directory's `d.sock`, so
## every one of them wanted one label. On launchd the consequence is worse
## than on systemd. Measured on macOS (aarch64-darwin, 2026-10-14): a second
## `launchctl bootstrap` of a loaded label fails with `Bootstrap failed: 5:
## Input/output error`, but `launchWithLaunchd` never gets that far -- it
## boots out "any prior registration of this label" first, and `bootout`
## SIGTERMs the running job. The second daemon's launch therefore KILLED the
## first daemon. And `cleanupPlatformBackgroundRegistration` for one endpoint
## booted out whichever daemon held the shared label.
##
## WHAT THESE CASES ASSERT. The pure cases read the label out of
## `renderLaunchdUserAgentPlist` -- the exact plist `launchWithLaunchd` writes
## and hands to `launchctl bootstrap` -- rather than out of the naming proc,
## so each one is a statement about what launchd is actually ASKED for. They
## pin: distinct endpoints get distinct labels; one endpoint gets a stable
## label independent of everything else in the config (the launching CLI and
## the later `cleanupPlatformBackgroundRegistration` share only the
## endpoint); the label and its plist file name stay legal for the longest
## endpoint an AF_UNIX socket can carry; the basename stays readable, because
## the label is what `launchctl list` shows; and the plist path moves with the
## label.
##
## "The strings differ" is this repository's claim, not launchd's. The macOS
## cases hand the labels to the REAL launchd: two same-basename endpoints are
## launched with the launcher's own `bootout`-then-`bootstrap` sequence and
## BOTH jobs must still be alive, by pid; and the production
## `cleanupPlatformBackgroundRegistration` for one endpoint must not stop the
## other endpoint's job, nor miss its own when handed the endpoint relative
## to the working directory. Two more cases cover registrations made by a
## binary that still used the basename label: cleanup removes the one carrying
## ITS endpoint, and leaves alone one carrying another endpoint with the same
## basename.
##
## MOCK POLICY: no mocks. The naming is a pure function of the config, so the
## string cases need no filesystem and there is nothing to fake. The launchd
## cases use the REAL per-user launchd (`gui/<uid>`) with `/bin/sh` running
## `sleep` as the job, because the property under test is launchd's treatment
## of the label, not the daemon; every job they register is booted out in a
## `defer` -- leaving a registration behind is the sin this campaign is about.

import std/[monotimes, os, osproc, strutils, unittest]
import repro_test_support/reasoned_skip

import repro_daemon_core

when defined(macosx):
  import std/posix

const LabelKey = "<key>Label</key>\n  <string>"

proc configFor(endpoint: string): UserDaemonConfig =
  result = defaultUserDaemonConfig(devMode = false)
  result.endpoint = endpoint
  result.stateDir = endpoint.parentDir / "state"
  result.logPath = endpoint.parentDir / "daemon.log"

proc labelFor(config: UserDaemonConfig): string =
  ## The label the LAUNCHER registers, read back out of the plist it writes
  ## -- never recomputed here, so a naming rule the launcher did not pick up
  ## leaves these cases red.
  let plist = renderLaunchdUserAgentPlist("/nonexistent/repro", config)
  let start = plist.find(LabelKey)
  if start < 0:
    return ""
  let first = start + LabelKey.len
  let stop = plist.find("</string>", first)
  if stop < 0:
    return ""
  plist[first ..< stop]

when defined(macosx):
  # Endpoints unique to this process. Under the fixed naming that makes
  # the labels unique too; under the broken one they collapse, which is
  # the point.
  let tag = $getCurrentProcessId()
  let scratch = getTempDir() / ("repro-launchd-label-" & tag)
  let domain = "gui/" & $getuid()

  proc launchctl(args: varargs[string]): tuple[output: string,
      exitCode: int] =
    execCmdEx(quoteShellCommand(@["launchctl"] & @args))

  proc launchdReason(): string =
    ## Why the real-launchd cases cannot run here, or "" when they can.
    if findExe("launchctl").len == 0:
      return "no launchctl on PATH; asking launchd whether it keeps two " &
        "jobs apart requires launchd"
    if launchctl("print", domain).exitCode != 0:
      return "no " & domain & " launchd domain in this session (e.g. a " &
        "non-GUI login), so no user agent can be bootstrapped"
    ""

  proc jobPid(label: string): int =
    ## The running job's pid, or 0 when launchd has no such job or it is
    ## not running.
    let res = launchctl("print", domain & "/" & label)
    if res.exitCode != 0:
      return 0
    for line in res.output.splitLines():
      let stripped = line.strip()
      if stripped.startsWith("pid = "):
        return parseInt(stripped["pid = ".len .. ^1])
    0

  proc loaded(label: string): bool =
    launchctl("print", domain & "/" & label).exitCode == 0

  proc unloaded(label: string): bool =
    ## `bootout` can return while launchd is still tearing the job down
    ## (seen once under a loaded host: the job was still listed right after
    ## cleanup), so absence is given a few seconds to settle. A job that
    ## was never booted out stays loaded for all of them.
    for _ in 0 ..< 100:
      if not loaded(label):
        return true
      sleep(50)
    false

  proc alive(pid: int): bool =
    ## `bootout` returns before the job's process is reaped, so a
    ## SIGTERMed job is given a moment to disappear before it is judged
    ## alive.
    if pid <= 0:
      return false
    for _ in 0 ..< 20:
      if posix.kill(Pid(pid), 0) != 0:
        return false
      sleep(50)
    true

  proc writeJobPlist(label, endpoint, path: string) =
    ## A job that carries `--endpoint <endpoint>` in its program arguments,
    ## as the daemon's does, and stays alive long enough to be observed.
    createDir(path.parentDir)
    writeFile(path, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" &
      "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" " &
      "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" &
      "<plist version=\"1.0\">\n<dict>\n" &
      "  <key>Label</key>\n  <string>" & label & "</string>\n" &
      "  <key>ProgramArguments</key>\n  <array>\n" &
      "    <string>/bin/sh</string>\n    <string>-c</string>\n" &
      "    <string>sleep 300</string>\n    <string>sh</string>\n" &
      "    <string>--endpoint</string>\n" &
      "    <string>" & endpoint & "</string>\n" &
      "  </array>\n" &
      "  <key>RunAtLoad</key>\n  <true/>\n" &
      "  <key>KeepAlive</key>\n  <false/>\n" &
      "</dict>\n</plist>\n")

  proc launchLikeTheLauncher(label, endpoint: string): int =
    ## `launchWithLaunchd`'s own sequence -- boot out any prior job under
    ## the label, then bootstrap -- returning the bootstrap exit code.
    let plist = scratch / "plists" / (label & "-" & $getMonoTime().ticks &
      ".plist")
    writeJobPlist(label, endpoint, plist)
    discard launchctl("bootout", domain & "/" & label)
    result = launchctl("bootstrap", domain, plist).exitCode
    for _ in 0 ..< 40:
      if jobPid(label) > 0:
        break
      sleep(50)

  proc legacyLabel(endpoint: string): string =
    ## The label a binary from before the endpoint-keyed naming registered:
    ## frozen history, so restating it is the point. Only called with
    ## basenames that need no sanitising.
    "org.reprobuild.repro-daemon." & endpoint.extractFilename

suite "a launchd label identifies the endpoint, not its basename":
  test "endpoints differing only by their parent directory get different labels":
    let a = configFor("/tmp/repro-run-a/d.sock")
    let b = configFor("/tmp/repro-run-b/d.sock")
    checkpoint("a=" & labelFor(a))
    checkpoint("b=" & labelFor(b))
    check labelFor(a) != labelFor(b)

  test "six endpoints that all end in d.sock get six distinct labels":
    var labels: seq[string] = @[]
    for i in 0 ..< 6:
      labels.add(labelFor(configFor("/tmp/repro-" & $i & "/d.sock")))
    checkpoint(labels.join(" "))
    for i in 0 ..< labels.len:
      for j in i + 1 ..< labels.len:
        check labels[i] != labels[j]

  test "one endpoint always names one label":
    # The launcher registers the label and the cleanup boots it out in a
    # different process; the two agree only on the endpoint.
    let endpoint = "/tmp/repro-run-a/d.sock"
    check labelFor(configFor(endpoint)) == labelFor(configFor(endpoint))
    var other = configFor(endpoint)
    other.stateDir = "/somewhere/else"
    other.logPath = "/somewhere/else/log"
    other.devMode = true
    check labelFor(other) == labelFor(configFor(endpoint))

  test "the plist names a label at all, and names it once":
    # The premise every other case rests on: `labelFor` reads the real
    # selector rather than comparing two empty strings.
    let config = configFor("/tmp/repro-run-a/d.sock")
    let plist = renderLaunchdUserAgentPlist("/nonexistent/repro", config)
    check plist.count("<key>Label</key>") == 1
    check labelFor(config).len > 0
    check labelFor(config).startsWith("org.reprobuild.repro-daemon.")

  test "the label and its plist file stay legal for the longest endpoint":
    # `sun_path` is 108 bytes, so that is the worst case a unix endpoint can
    # present. The label is also a file name (`<label>.plist`), whose limit
    # is 255 bytes on APFS.
    let longName = "d" & repeat("x", 97) & ".sock"
    let endpoint = "/tmp/" & longName
    check endpoint.len == 108
    let label = labelFor(configFor(endpoint))
    checkpoint("len=" & $label.len)
    check (label & ".plist").len <= 255
    for ch in label:
      check ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_', '.', '-'}

  test "the endpoint basename is still readable in the label":
    # The label is what `launchctl list` shows and what someone types to
    # boot a daemon out.
    let label = labelFor(configFor("/tmp/repro-run-a/build.sock"))
    checkpoint(label)
    check "build.sock" in label

  test "the plist path follows the label":
    let a = configFor("/tmp/repro-run-a/d.sock")
    var b = configFor("/tmp/repro-run-b/d.sock")
    b.stateDir = a.stateDir
    check launchdPlistPath(a) != launchdPlistPath(b)
    check launchdPlistPath(a).extractFilename == labelFor(a) & ".plist"
    check launchdLabel(a) == labelFor(a)

  when defined(macosx):
    test "launchd keeps two same-basename daemons alive side by side":
      ## THE CASE ABOUT THE DEFECT RATHER THAN THIS FILE'S ARITHMETIC. Under
      ## the basename label the second launch's pre-emptive `bootout`
      ## SIGTERMs the first daemon; both must survive, judged by pid.
      let reason = launchdReason()
      if reason.len > 0:
        skip(reason)
        return
      let first = configFor(scratch / "a" / "d.sock")
      let second = configFor(scratch / "b" / "d.sock")
      let labels = [labelFor(first), labelFor(second)]
      for label in labels:
        if loaded(label):
          skip("a launchd job labelled " & label & " already exists, so " &
            "this case cannot tell a collision it caused from one it " &
            "inherited")
          return
      defer:
        for label in labels:
          discard launchctl("bootout", domain & "/" & label)
        removeDir(scratch)
      let firstExit = launchLikeTheLauncher(labels[0], first.endpoint)
      let firstPid = jobPid(labels[0])
      let secondExit = launchLikeTheLauncher(labels[1], second.endpoint)
      let secondPid = jobPid(labels[1])
      checkpoint("labels=" & labels[0] & "," & labels[1] & " exits=" &
        $firstExit & "," & $secondExit & " pids=" & $firstPid & "," &
        $secondPid)
      check firstExit == 0
      check secondExit == 0
      check firstPid > 0
      check secondPid > 0
      check firstPid != secondPid
      check alive(firstPid)
      check alive(secondPid)

    test "cleaning up one endpoint leaves another endpoint's daemon running":
      ## The production deregistration path. Under the basename label it
      ## booted out whichever daemon held the shared label.
      let reason = launchdReason()
      if reason.len > 0:
        skip(reason)
        return
      let mine = configFor(scratch / "mine" / "d.sock")
      let theirs = configFor(scratch / "theirs" / "d.sock")
      let theirLabel = labelFor(theirs)
      if loaded(theirLabel) or loaded(labelFor(mine)):
        skip("a launchd job with one of this case's labels already " &
          "exists, so this case cannot tell its own effect from it")
        return
      defer:
        discard launchctl("bootout", domain & "/" & theirLabel)
        removeDir(scratch)
      check launchLikeTheLauncher(theirLabel, theirs.endpoint) == 0
      let theirPid = jobPid(theirLabel)
      check theirPid > 0
      cleanupPlatformBackgroundRegistration(mine)
      checkpoint("label=" & theirLabel & " pid=" & $theirPid)
      check alive(theirPid)
      check loaded(theirLabel)

    test "cleanup given a relative endpoint stops the job of its absolute form":
      ## `repro daemon stop --endpoint d.sock` hands cleanup the endpoint as
      ## typed, but `startUserDaemon` anchors it before launching, so the job
      ## is registered under the label of the ABSOLUTE path. Under the
      ## basename label the two agreed by accident; under the endpoint-keyed
      ## one cleanup has to anchor, or it boots out a label nobody holds.
      let reason = launchdReason()
      if reason.len > 0:
        skip(reason)
        return
      createDir(scratch / "relative")
      # Resolved, because the process's working directory is reported
      # without symlinks (`/var` is `/private/var` on macOS) and cleanup
      # anchors against it.
      let dir = expandFilename(scratch / "relative")
      let absolute = configFor(dir / "d.sock")
      let label = labelFor(absolute)
      if loaded(label):
        skip("a launchd job labelled " & label & " already exists")
        return
      let previousDir = getCurrentDir()
      defer:
        setCurrentDir(previousDir)
        discard launchctl("bootout", domain & "/" & label)
        removeDir(scratch)
      check launchLikeTheLauncher(label, absolute.endpoint) == 0
      let pid = jobPid(label)
      check pid > 0
      setCurrentDir(dir)
      var relative = absolute
      relative.endpoint = "d.sock"
      cleanupPlatformBackgroundRegistration(relative)
      checkpoint("label=" & label & " pid=" & $pid)
      check unloaded(label)
      check not alive(pid)

    test "cleanup removes a basename-labelled registration for its own endpoint":
      ## A daemon launched by a binary from before the endpoint-keyed naming
      ## is registered under the basename label. Left alone it is a
      ## registration nothing will ever boot out.
      let reason = launchdReason()
      if reason.len > 0:
        skip(reason)
        return
      let mine = configFor(scratch / "legacy-mine" / ("legacy-" & tag &
        ".sock"))
      let label = legacyLabel(mine.endpoint)
      if loaded(label):
        skip("a launchd job labelled " & label & " already exists")
        return
      defer:
        discard launchctl("bootout", domain & "/" & label)
        removeDir(scratch)
      check launchLikeTheLauncher(label, mine.endpoint) == 0
      let pid = jobPid(label)
      check pid > 0
      let legacyPlist = mine.stateDir / "launchd" / (label & ".plist")
      writeJobPlist(label, mine.endpoint, legacyPlist)
      cleanupPlatformBackgroundRegistration(mine)
      checkpoint("label=" & label & " pid=" & $pid)
      check unloaded(label)
      check not alive(pid)
      check not fileExists(legacyPlist)

    test "cleanup leaves a basename-labelled registration for another endpoint":
      ## The same legacy label, but the job serves a DIFFERENT endpoint that
      ## happens to share the basename. Booting it out would stop someone
      ## else's daemon -- the defect this file exists for, through the back
      ## door.
      let reason = launchdReason()
      if reason.len > 0:
        skip(reason)
        return
      let basename = "legacy-other-" & tag & ".sock"
      let mine = configFor(scratch / "legacy-a" / basename)
      let theirs = configFor(scratch / "legacy-b" / basename)
      let label = legacyLabel(theirs.endpoint)
      check label == legacyLabel(mine.endpoint)
      if loaded(label):
        skip("a launchd job labelled " & label & " already exists")
        return
      defer:
        discard launchctl("bootout", domain & "/" & label)
        removeDir(scratch)
      check launchLikeTheLauncher(label, theirs.endpoint) == 0
      let pid = jobPid(label)
      check pid > 0
      cleanupPlatformBackgroundRegistration(mine)
      checkpoint("label=" & label & " pid=" & $pid)
      check alive(pid)
      check loaded(label)
