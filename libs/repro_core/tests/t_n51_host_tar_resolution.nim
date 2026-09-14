## N51 — the tar that is RESOLVED must be the tar that is EXECUTED.
##
## Three production sites built a ``tar`` command line whose argv[0] was the
## bare string ``"tar"`` and then reported failures against ``findExe("tar")``.
## On Windows those name different programs, because the two resolvers search
## different places: ``CreateProcessW`` searches the SYSTEM DIRECTORY before
## ``%PATH%``, and ``os.findExe`` never looks in the system directory at all.
## Measured in one process on the development host:
##
##   findExe   "tar"            -> ...\scoop\apps\git\2.55.0.5\usr\bin\tar.exe
##   execCmdEx "tar --version"  -> bsdtar 3.8.8 - libarchive 3.8.8
##   that findExe path --version-> tar (GNU tar) 1.35
##
## ``repro_core/host_tar.resolveHostTar`` exists to close that gap WITHOUT
## changing which program runs. This file is the check on that claim, and it
## is deliberately behavioural rather than structural: it does not assert that
## the resolver looked in a particular directory, it asserts that the binary
## the resolver returns IDENTIFIES ITSELF THE SAME WAY as the binary a bare
## ``tar`` command line runs. That is the property the production sites need,
## and it is the one that catches the two ways this can go wrong — picking
## ``%PATH%``'s GNU tar where the bare string runs System32's bsdtar, and
## following ``/bin/tar -> /bin/busybox`` on a multi-call host so that
## ``argv[0]`` stops saying ``tar``.
##
## VACUITY, stated per assertion rather than assumed away:
##
##   * The banner comparison would pass for any resolver if ``tarBanner``
##     returned the same string for everything — an empty string, say, from a
##     spawn that failed. So the banners are ALSO asserted non-empty and
##     asserted to contain "tar", which both real tars' banners do
##     ("tar (GNU tar) 1.35", "bsdtar 3.8.8 - libarchive 3.8.8") and a failed
##     spawn's empty capture does not.
##   * "Both banners are equal" would also hold if `tarBanner` ignored its
##     argument. The third test proves it does not, by running the SAME binary
##     with a flag it does not have and requiring a different answer. The
##     obvious control -- run some other program -- was tried first and
##     REJECTED: `/bin/sh --version` prints nothing on Alpine's busybox ash,
##     so that control silently did not run there, which is not a control.
##     It is kept as a secondary, reported check.
##   * On a host where ``%PATH%``'s tar IS the system tar, the divergence
##     this module exists for is not present, and a test that silently passed
##     there would be reporting on nothing. That case is detected and REPORTED
##     (`echo`) rather than hidden, so a green run says which host it was.

import std/[os, osproc, strutils, unittest]

import repro_core/host_tar

proc firstLineOf(exe, arg: string): string =
  ## First non-empty line of ``<exe> <arg>``, stdout and stderr merged, or ""
  ## if it could not be run. ``exe`` is quoted, so a space in the path is not
  ## an argument break.
  if exe.len == 0:
    return ""
  try:
    let res = execCmdEx(quoteShell(exe) & " " & arg)
    if res.exitCode != 0 and res.output.len == 0:
      return ""
    for line in res.output.splitLines:
      let s = line.strip()
      if s.len > 0:
        return s
    return ""
  except CatchableError:
    return ""

proc tarBanner(exe: string): string =
  firstLineOf(exe, "--version")

proc bareTarBanner(): string =
  ## First line of ``tar --version`` run through the SAME path production
  ## used before N51: a bare argv[0], resolved by the OS rather than by us.
  try:
    let res = execCmdEx("tar --version")
    for line in res.output.splitLines:
      let s = line.strip()
      if s.len > 0:
        return s
    return ""
  except CatchableError:
    return ""

suite "N51 repro_core/host_tar: resolved tar == executed tar":

  test "no REPRO_HOST_TAR override is in force":
    ## `resolveHostTar` honours `REPRO_HOST_TAR` so the N48 drivers can pin
    ## the tar they need to witness. If it is set when THIS file runs, the
    ## comparison below is against a tar nobody asked the OS for and the
    ## "resolved == executed" claim is not being tested at all.
    ##
    ## This is asserted rather than skipped ON PURPOSE. A skip here would be
    ## the whole failure mode this file exists to prevent, one level up: a
    ## green run that measured nothing. It fails, and it says why.
    let override = getEnv(HostTarOverrideEnv)
    if override.len > 0:
      echo "  ", HostTarOverrideEnv, "=", override
    check override.len == 0

  test "the resolver finds a tar and the file exists":
    let tar = resolveHostTar()
    echo "  resolveHostTar -> ", tar.exe, "  [", tar.origin, "]"
    check tar.exe.len > 0
    check fileExists(tar.exe)

  test "the resolved binary identifies itself exactly as a bare `tar` does":
    ## THE assertion. Everything else in this file exists to stop this one
    ## passing for the wrong reason.
    let tar = resolveHostTar()
    let resolvedBanner = tarBanner(tar.exe)
    let bareBanner = bareTarBanner()
    echo "  resolved : ", resolvedBanner
    echo "  bare argv: ", bareBanner

    # Non-vacuity (i): a comparison of two empty strings is not evidence.
    check resolvedBanner.len > 0
    check bareBanner.len > 0
    # Non-vacuity (ii): both must actually be a tar. A multi-call binary
    # reached by following a symlink answers with its OWN name instead
    # ("BusyBox v1.36.1 ..."), which this rejects.
    check resolvedBanner.toLowerAscii().contains("tar")
    check bareBanner.toLowerAscii().contains("tar")

    check resolvedBanner == bareBanner

  test "the banner reflects what was RUN — it is not a constant":
    ## Non-vacuity (iii). If `tarBanner` ignored its argument, or answered ""
    ## for everything, the test above would be green for ANY resolver.
    ##
    ## The control is the SAME binary given a flag it does not have. That is
    ## chosen over "run a different program" deliberately: the obvious POSIX
    ## control, `/bin/sh --version`, prints NOTHING on Alpine's busybox ash
    ## (measured), so the control silently did not run there — a control that
    ## can quietly not happen is not a control. The resolved tar, by
    ## contrast, is guaranteed present (the first test asserts it) and every
    ## tar answers an unknown option with a diagnostic.
    let tar = resolveHostTar()
    let versionText = tarBanner(tar.exe)
    let bogusText = firstLineOf(tar.exe, "--n51-definitely-not-an-option")
    echo "  --version      : ", versionText
    echo "  bogus option   : ", bogusText
    check versionText.len > 0
    check bogusText.len > 0
    check bogusText != versionText

    # Secondary control, REPORTED rather than asserted, because whether the
    # host's shell answers `--version` at all is a property of the host.
    let other =
      when defined(windows): getEnv("COMSPEC", r"C:\Windows\System32\cmd.exe")
      else: "/bin/sh"
    if fileExists(other):
      let otherText = tarBanner(other)
      if otherText.len > 0:
        echo "  control (", other, "): ", otherText
        check otherText != versionText
      else:
        echo "  NOTE: ", other, " printed nothing for --version, so the " &
             "second control did not run on this host."

  test "the divergence this module exists for is reported, not assumed":
    ## On Windows, `findExe` and a bare argv[0] disagree whenever the system
    ## directory holds a tar AND `%PATH%` holds a different one. Say which
    ## case this host is, so a green run is readable.
    when defined(windows):
      let systemTar = systemDirectoryTarPath()
      let pathTar = findExe("tar")
      echo "  system dir tar : ", systemTar,
           (if fileExists(systemTar): "" else: "   (ABSENT)")
      echo "  PATH tar       : ", pathTar
      if fileExists(systemTar) and pathTar.len > 0:
        let sysBanner = tarBanner(systemTar)
        let pathBanner = tarBanner(pathTar)
        echo "  system dir banner: ", sysBanner
        echo "  PATH banner      : ", pathBanner
        if sysBanner == pathBanner:
          echo "  NOTE: this host's PATH tar and system tar are the SAME " &
               "program, so the divergence N51 is about is NOT exercised here."
        else:
          echo "  This host DOES exercise the divergence: a findExe-based " &
               "resolution would have changed which tar runs."
          # And the resolver must have kept the executed one.
          check tarBanner(resolveHostTar().exe) == sysBanner
      else:
        echo "  NOTE: no system-directory tar, or no tar on PATH; the " &
             "Windows divergence is not exercised on this host."
    else:
      # On POSIX there is no system-directory tier, and the thing that can
      # still diverge is symlink following: `/bin/tar -> /bin/busybox` on
      # Alpine. Re-measured there during review, exit codes captured to a
      # file rather than read from an inline `$?` (which reported 0 for this
      # very command the first time round): `/bin/tar -tzf a.tar.gz` lists
      # the archive and exits 0, while `/bin/busybox -tzf a.tar.gz` answers
      # "-tzf: applet not found" and EXITS 127 — busybox refuses to dispatch
      # because argv[0] is no longer `tar`. So following the link does not
      # silently give a wrong answer; it stops tar working at all, and every
      # extraction through this resolver would fail on a multi-call host.
      let kept = resolveHostTar().exe
      let followed = findExe("tar", followSymlinks = true)
      echo "  resolved (link kept)     : ", kept
      echo "  findExe (link followed)  : ", followed
      if followed.len > 0 and followed != kept:
        echo "  This host DOES exercise symlink divergence."
        echo "  followed banner: ", tarBanner(followed)
      else:
        echo "  NOTE: `tar` is not a symlink on this host; the multi-call " &
             "hazard is not exercised here."
