## Which ``tar`` binary a bare ``"tar"`` command line actually runs.
##
## N51 — RESOLVED AND EXECUTED MUST NAME THE SAME PROGRAM
## =====================================================
##
## Three sites in this tree built a ``tar`` command line whose argv[0] was the
## bare string ``"tar"`` and then reported failures against
## ``findExe "tar"``. On Windows those are DIFFERENT PROGRAMS, because the
## two resolvers do not search the same places:
##
##   * ``CreateProcessW`` with a bare name searches the application
##     directory, the parent's current directory, then the **system
##     directory**, the Windows directory, and only THEN ``%PATH%``.
##   * ``os.findExe`` searches the current directory and ``%PATH%``. It never
##     looks in the system directory.
##
## So on any Windows host with ``%WINDIR%\System32\tar.exe`` (every Windows 10
## 1803 and later) plus a GNU tar on ``%PATH%`` (Git for Windows, MSYS2,
## Scoop), the bare string ran bsdtar while the diagnostic named GNU tar.
## Measured in ONE process on this host, all three lines from the same run:
##
##   findExe   "tar"               -> …\scoop\apps\git\2.55.0.5\usr\bin\tar.exe
##   execCmdEx "tar --version"     -> bsdtar 3.8.8 - libarchive 3.8.8
##   execCmdEx <that path> " -V"   -> tar (GNU tar) 1.35
##
## Two things were wrong with that, and they are separate:
##
##   1. Every error message named a binary nobody had looked up, and every
##     ``findExe``-based measurement described a program that did not run.
##     ``Package-Model.md`` §254-273's class-2 tier requires the action
##     identity to record "the search path, resolved executable path, and
##     configured probes" — a resolution that does not match the execution
##     records nothing true.
##   2. It is not a resolution AT ALL. It is whatever ``CreateProcessW``
##     happens to find, including the PARENT'S CURRENT DIRECTORY — a
##     ``tar.exe`` dropped into a build tree would be executed in preference
##     to both.
##
## WHY THIS RESOLVER PREFERS THE SYSTEM DIRECTORY ON WINDOWS
## ---------------------------------------------------------
##
## The obvious fix — ``findExe "tar"`` and run what it returns — is NOT
## behaviour-preserving. It flips Windows production from System32's bsdtar
## to ``%PATH%``'s GNU tar: the one tar that carries BOTH defects W16
## measured (it unquotes ``-C`` operands, and reads a ``-f`` operand whose
## first ``:`` precedes any ``/`` as a remote ``host:path``). The N48 review
## declined that flip because it could not be validated at suite scale, and
## nothing here validates it either. A truthful diagnostic is not worth a
## silent change of program.
##
## So this resolver reproduces, EXPLICITLY, the order the bare string already
## had — system directory first, then ``PATH`` — minus the two entries that
## are a binary-planting hazard rather than a feature (the application
## directory and the parent's current directory). The program that runs after
## this change is the program that ran before it, on every host, and now it
## is also the program the error message names.
##
## The shape is not invented here: ``repro_tool_profiles``' conda arm already
## probes ``%WINDIR%\System32\tar.exe`` before falling back to PATH
## candidates, for the same reason (it is libarchive and therefore speaks
## zstd). This module is that rule, lifted to one place.
##
## The N48 operand fixes remain REQUIRED either way and are not made
## redundant by this: a Windows host with no ``System32\tar.exe`` falls
## through to ``%PATH%``'s GNU tar here exactly as it did through
## ``CreateProcessW``, and that is the tar the fixes exist for.
##
## WHY ``followSymlinks = false``
## ------------------------------
##
## ``os.findExe`` resolves symlinks by default. A shell does not. On a host
## where ``/bin/tar`` is a symlink into a MULTI-CALL binary — busybox on
## Alpine, and the Nix coreutils/toybox layouts ``msys2_source`` already
## guards against for ``sha256sum`` — following the link changes ``argv[0]``
## from ``tar`` to the multiplexer's own name, and the multiplexer then
## dispatches on that name instead of running tar. Keeping the link is what
## makes "resolved" mean the same program as "executed" on POSIX too.

import std/[os]

import repro_core/ambient_execution

const HostTarOverrideEnv* = "REPRO_HOST_TAR"
  ## Names the tar to use, by absolute path, overriding the search below.
  ##
  ## This exists because the search order it overrides is NOT otherwise
  ## reachable from a test. The N48 cases have to drive the product against a
  ## SPECIFIC tar -- GNU tar, whose two Windows defects they exist to pin --
  ## and their only lever was ``CreateProcessW``'s FIRST search entry: they
  ## copy the test binary next to a copy of GNU tar so that a bare ``tar``
  ## resolves to the neighbour. Making the resolution explicit takes that
  ## lever away, and a test that can no longer choose its tar does not fail,
  ## it goes VACUOUS -- it keeps reporting a GNU tar banner from its own
  ## ``execCmdEx "tar --version"`` while the product quietly runs bsdtar.
  ## That is the exact false green those tests were rewritten to escape, so
  ## the lever is REPLACED here rather than removed.
  ##
  ## An override naming a path that does not exist is an ERROR, not a reason
  ## to fall back. A silent fallback would make every test that sets this
  ## untrustworthy in precisely the way this whole exercise is about.

type
  HostTar* = object
    ## The tar this host will run, and how it was found. ``exe`` is empty
    ## when no tar was found at all; ``origin`` is always safe to print.
    exe*: string
    origin*: string

proc systemDirectoryTarPath*(): string =
  ## ``%WINDIR%\System32\tar.exe`` on Windows, "" elsewhere. Exposed so a
  ## test can assert which binary this module is supposed to prefer without
  ## re-deriving the path from the same constants the resolver uses.
  when defined(windows):
    getEnv("WINDIR", r"C:\Windows") / "System32" / "tar.exe"
  else:
    ""

proc hostTarSearchDescription*(): string =
  ## The search order, in words, for a diagnostic that has to explain why
  ## nothing was found.
  when defined(windows):
    HostTarOverrideEnv & r", then %WINDIR%\System32\tar.exe, then 'tar' on %PATH%"
  else:
    HostTarOverrideEnv & ", then 'tar' on $PATH"

proc resolveHostTar*(): HostTar =
  ## Resolve the ``tar`` this host runs. See the module comment for why the
  ## system directory comes first on Windows and why symlinks are not
  ## followed.
  let override = getEnv(HostTarOverrideEnv)
  if override.len > 0:
    if fileExists(override):
      return HostTar(exe: override,
        origin: HostTarOverrideEnv & " override")
    return HostTar(exe: "",
      origin: HostTarOverrideEnv & "=" & override & " names no existing file")
  when defined(windows):
    let systemTar = systemDirectoryTarPath()
    if fileExists(systemTar):
      return HostTar(exe: systemTar,
        origin: r"%WINDIR%\System32\tar.exe" &
                " (the system directory, which " &
                "CreateProcessW searches before %PATH%)")
  let onPath = uncontrolledFindExe("tar", followSymlinks = false)
  if onPath.len > 0:
    return HostTar(exe: onPath, origin: "'tar' on PATH")
  HostTar(exe: "", origin: "not found (looked in " &
    hostTarSearchDescription() & ")")
